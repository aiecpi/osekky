import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'push_notification_service.dart';
import '../utils/logger.dart';

class SupabaseNotificationService {
  final _supabase = Supabase.instance.client;
  final PushNotificationService _pushNotificationService = PushNotificationService();
  final Set<String> _processedNotificationIds = {};
  Timer? _pollingTimer;

  /// Получить уведомления пользователя
  static const int defaultLimit = 50;

  Future<List<Map<String, dynamic>>> getNotifications(
    String userId, {
    DateTime? before,
    int limit = defaultLimit,
  }) async {
    try {
      // Загружаем уведомления без join (избегаем проблем с FK именами)
      var query = _supabase
          .from('notifications')
          .select('*')
          .eq('user_id', userId);

      if (before != null) {
        query = query.lt('created_at', before.toIso8601String());
      }

      final data = await query
          .order('created_at', ascending: false)
          .limit(limit);

      final notifications = List<Map<String, dynamic>>.from(data);

      // Группируем уведомления
      final groupedNotifications = _groupNotifications(notifications);

      // Собираем ID комментариев для батчевой загрузки (убираем N+1)
      final postCommentIds = <String>[];
      final debateCommentIds = <String>[];

      // Собираем все ID акторов для батчевой загрузки
      // Используем from_user_id как основной источник (там всегда есть данные)
      // actor_id как fallback
      final missingActorIds = <String>{};
      for (final notif in groupedNotifications) {
        if (notif['actor'] == null) {
          final fromUserId = notif['from_user_id'] as String?;
          final actorId = notif['actor_id'] as String?;
          final id = fromUserId ?? actorId;
          if (id != null) missingActorIds.add(id);
        }
      }

      // Батчевая загрузка акторов
      final Map<String, Map<String, dynamic>> loadedActors = {};
      if (missingActorIds.isNotEmpty) {
        try {
          final rows = await _supabase
              .from('users')
              .select('id, full_name, username, avatar_url, role')
              .inFilter('id', missingActorIds.toList());
          for (final row in rows) {
            loadedActors[row['id'] as String] = row;
          }
        } catch (e) {
          AppLogger.warning('[NOTIF] Не удалось загрузить акторов: $e', tag: 'SupabaseNotificationService');
        }
      }

      for (final notif in groupedNotifications) {
        if (notif['actor'] == null) {
          final fromUserId = notif['from_user_id'] as String?;
          final actorId = notif['actor_id'] as String?;
          final id = fromUserId ?? actorId;
          notif['actor'] = loadedActors[id] ?? {
            'id': id,
            'full_name': 'Пользователь',
            'username': 'user',
            'avatar_url': null,
          };
        }

        final dataField = notif['data'] as Map<String, dynamic>?;
        final hasCommentText = dataField?['comment_text'] != null;
        final commentId = notif['comment_id'] as String?;
        final notifType = notif['type'] as String?;

        if (!hasCommentText && commentId != null) {
          if (notifType == 'debate_comment' || notifType == 'debate_reply' || notifType == 'debate_like') {
            debateCommentIds.add(commentId);
          } else if (notifType == 'comment' || notifType == 'reply' || notifType == 'comment_like') {
            postCommentIds.add(commentId);
          }
        }
      }

      // Батчевый запрос для комментариев постов
      final Map<String, String> postCommentTexts = {};
      if (postCommentIds.isNotEmpty) {
        try {
          final rows = await _supabase
              .from('comments')
              .select('id, text')
              .inFilter('id', postCommentIds);
          for (final row in rows) {
            postCommentTexts[row['id'] as String] = row['text'] as String? ?? '';
          }
        } catch (_) {}
      }

      // Батчевый запрос для комментариев дебатов
      final Map<String, String> debateCommentTexts = {};
      if (debateCommentIds.isNotEmpty) {
        try {
          final rows = await _supabase
              .from('discussion_comments')
              .select('id, text')
              .inFilter('id', debateCommentIds);
          for (final row in rows) {
            debateCommentTexts[row['id'] as String] = row['text'] as String? ?? '';
          }
        } catch (_) {}
      }

      // Проставляем тексты комментариев в уведомления
      for (final notif in groupedNotifications) {
        final commentId = notif['comment_id'] as String?;
        if (commentId == null) continue;
        final notifType = notif['type'] as String?;
        if (notifType == 'debate_comment' || notifType == 'debate_reply' || notifType == 'debate_like') {
          if (debateCommentTexts.containsKey(commentId)) {
            notif['comment_text'] = debateCommentTexts[commentId];
          }
        } else if (notifType == 'comment' || notifType == 'reply' || notifType == 'comment_like') {
          if (postCommentTexts.containsKey(commentId)) {
            notif['comment_text'] = postCommentTexts[commentId];
          }
        }
      }

      return groupedNotifications;
    } catch (e, st) {
      AppLogger.error('Ошибка загрузки уведомлений', tag: 'SupabaseNotificationService', error: e, stackTrace: st);
      rethrow;
    }
  }

  /// Группирует уведомления по типу и связанному контенту
  List<Map<String, dynamic>> _groupNotifications(List<Map<String, dynamic>> notifications) {
    final grouped = <String, List<Map<String, dynamic>>>{};
    
    // Группируем уведомления по ключу: тип + post_id
    for (final notif in notifications) {
      final type = notif['type'] as String?;
      final postId = notif['post_id'] as String?;
      
      // Группируем только лайки и подписки
      if (type == 'like' || type == 'debate_like' || type == 'follow') {
        final key = '${type}_${postId ?? 'no_post'}';
        grouped.putIfAbsent(key, () => []).add(notif);
      } else {
        // Комментарии, ответы и другие не группируем
        final key = '${type}_${notif['id']}';
        grouped[key] = [notif];
      }
    }
    
    final result = <Map<String, dynamic>>[];
    
    for (final entry in grouped.entries) {
      final group = entry.value;
      if (group.length == 1) {
        // Одиночное уведомление - добавляем как есть
        result.add(group.first);
      } else {
        // Группируем несколько уведомлений
        final firstNotif = group.first;
        final type = firstNotif['type'] as String;
        final actors = group
            .map((n) => n['actor'])
            .where((actor) => actor != null)
            .map((actor) => actor as Map<String, dynamic>)
            .toList();
        
        // Создаем сгруппированное уведомление
        final groupedNotif = Map<String, dynamic>.from(firstNotif);
        
        if (type == 'like' || type == 'debate_like') {
          // Группируем лайки
          groupedNotif['title'] = _getGroupedLikeTitle(actors.length);
          groupedNotif['body'] = _getGroupedLikeBody(actors, type);
          groupedNotif['actors'] = actors; // Сохраняем всех акторов для UI
          groupedNotif['is_grouped'] = true;
          groupedNotif['group_count'] = actors.length;
        } else if (type == 'follow') {
          // Группируем подписки
          groupedNotif['title'] = 'Новые подписчики';
          groupedNotif['body'] = _getGroupedFollowBody(actors);
          groupedNotif['actors'] = actors;
          groupedNotif['is_grouped'] = true;
          groupedNotif['group_count'] = actors.length;
        }
        
        result.add(groupedNotif);
      }
    }
    
    // Сортируем по времени (берем самое свежее из группы)
    result.sort((a, b) {
      final aTime = DateTime.parse(a['created_at'] as String);
      final bTime = DateTime.parse(b['created_at'] as String);
      return bTime.compareTo(aTime);
    });
    
    return result;
  }

  String _getGroupedLikeTitle(int count) {
    if (count <= 3) {
      return 'Новые лайки';
    } else {
      return 'Много лайков';
    }
  }

  String _getGroupedLikeBody(List<Map<String, dynamic>> actors, String type) {
    final count = actors.length;
    if (count <= 3) {
      final names = actors.map((a) => a['full_name'] as String).take(3).join(', ');
      return names; // Возвращаем только имена, текст добавится на уровне UI
    } else {
      final firstNames = actors.take(2).map((a) => a['full_name'] as String).join(', ');
      final remaining = count - 2;
      return '$firstNames +$remaining'; // Возвращаем имена и количество
    }
  }

  String _getGroupedFollowBody(List<Map<String, dynamic>> actors) {
    final count = actors.length;
    if (count <= 3) {
      final names = actors.map((a) => a['full_name'] as String).take(3).join(', ');
      return names; // Возвращаем только имена
    } else {
      final firstNames = actors.take(2).map((a) => a['full_name'] as String).join(', ');
      final remaining = count - 2;
      return '$firstNames +$remaining'; // Возвращаем имена и количество
    }
  }

  /// Получить одно уведомление по ID (с данными актёра)
  Future<Map<String, dynamic>?> getNotificationById(String notificationId) async {
    try {
      final data = await _supabase
          .from('notifications')
          .select('*')
          .eq('id', notificationId)
          .maybeSingle();

      if (data == null) return null;

      // Загружаем актора отдельно (избегаем проблем с именами FK)
      final actorSourceId = data['from_user_id'] as String? ?? data['actor_id'] as String?;
      if (actorSourceId != null) {
        try {
          final actorData = await _supabase
              .from('users')
              .select('id, full_name, username, avatar_url, role')
              .eq('id', actorSourceId)
              .maybeSingle();
          data['actor'] = actorData ?? {
            'id': actorSourceId,
            'full_name': 'Пользователь',
            'username': 'user',
            'avatar_url': null,
          };
        } catch (_) {
          data['actor'] = {
            'id': actorSourceId,
            'full_name': 'Пользователь',
            'username': 'user',
            'avatar_url': null,
          };
        }
      } else {
        data['actor'] = null;
      }
      
      // Загружаем текст комментария если его нет в data
      final dataField = data['data'] as Map<String, dynamic>?;
      final hasCommentText = dataField?['comment_text'] != null;
      final commentId = data['comment_id'] as String?;
      final notifType = data['type'] as String?;
      
      if (!hasCommentText && commentId != null) {
        try {
          // Для дебатов загружаем из discussion_comments
          if (notifType == 'debate_comment' || notifType == 'debate_reply' || notifType == 'debate_like') {
            final commentData = await _supabase
                .from('discussion_comments')
                .select('text')
                .eq('id', commentId)
                .maybeSingle();
            if (commentData != null) {
              data['comment_text'] = commentData['text'] as String?;
            }
          } 
          // Для постов загружаем из comments
          else if (notifType == 'comment' || notifType == 'reply') {
            final commentData = await _supabase
                .from('comments')
                .select('text')
                .eq('id', commentId)
                .maybeSingle();
            if (commentData != null) {
              data['comment_text'] = commentData['text'] as String?;
            }
          }
        } catch (_) {
          // Игнорируем ошибку загрузки комментария
        }
      }

      return data;
    } catch (e, st) {
      AppLogger.error('Ошибка загрузки уведомления', tag: 'SupabaseNotificationService', error: e, stackTrace: st);
      return null;
    }
  }

  /// Получить количество непрочитанных уведомлений
  Future<int> getUnreadCount(String userId) async {
    try {
      final data = await _supabase
          .from('notifications')
          .select('id')
          .eq('user_id', userId)
          .eq('is_read', false)
          .count(CountOption.exact);
      return data.count;
    } catch (e, st) {
      AppLogger.error('Ошибка подсчёта непрочитанных уведомлений', tag: 'SupabaseNotificationService', error: e, stackTrace: st);
      return 0;
    }
  }

  /// Пометить уведомление как прочитанное
  Future<void> markAsRead(String notificationId) async {
    try {
      await _supabase
          .from('notifications')
          .update({'is_read': true})
          .eq('id', notificationId);
    } catch (e, st) {
      AppLogger.error('Ошибка пометки уведомления', tag: 'SupabaseNotificationService', error: e, stackTrace: st);
      rethrow;
    }
  }

  /// Пометить все уведомления как прочитанные
  Future<void> markAllAsRead(String userId) async {
    try {
      await _supabase
          .from('notifications')
          .update({'is_read': true})
          .eq('user_id', userId)
          .eq('is_read', false);
    } catch (e, st) {
      AppLogger.error('Ошибка пометки всех уведомлений', tag: 'SupabaseNotificationService', error: e, stackTrace: st);
      rethrow;
    }
  }

  /// Удалить уведомление
  Future<void> deleteNotification(String notificationId) async {
    try {
      await _supabase
          .from('notifications')
          .delete()
          .eq('id', notificationId);
    } catch (e, st) {
      AppLogger.error('Ошибка удаления уведомления', tag: 'SupabaseNotificationService', error: e, stackTrace: st);
      rethrow;
    }
  }

  /// Создать уведомление
  /// Типы уведомлений:
  /// - 'like' - лайк поста
  /// - 'comment_like' - лайк комментария
  /// - 'comment' - комментарий к посту
  /// - 'reply' - ответ на комментарий
  /// - 'follow' - подписка
  /// - 'mention' - упоминание
  /// - 'repost' - репост
  /// - 'debate_comment' - комментарий к дебату
  /// - 'debate_reply' - ответ на комментарий в дебате
  /// - 'debate_like' - лайк комментария в дебате
  Future<void> createNotification({
    required String userId,      // кому отправляем уведомление
    required String type,        // тип уведомления
    required String actorId,     // кто совершил действие
    String? postId,              // ID поста или дебата (если применимо)
    String? commentId,           // ID комментария (если применимо)
    String? text,                // дополнительный текст
    String? commentText,         // текст комментария
  }) async {
    try {
      // Не создаём уведомление, если пользователь сам совершил действие
      if (userId == actorId) {
        return;
      }
      AppLogger.info('[NOTIF-CREATE] type=$type userId=$userId actorId=$actorId postId=$postId commentId=$commentId', tag: 'SupabaseNotificationService');

      // Генерируем title и body на основе типа
      String title = '';
      String body = text ?? '';
      bool skipInsert = false;
      
      switch (type) {
        case 'like':
          title = 'Новый лайк';
          body = body.isEmpty ? 'Кто-то лайкнул ваш пост' : body;
          break;
        case 'comment_like':
          title = 'Лайк на комментарий';
          body = body.isEmpty ? 'Кто-то лайкнул ваш комментарий' : body;
          break;
        case 'comment':
          title = 'Новый комментарий';
          body = body.isEmpty ? 'Кто-то прокомментировал ваш пост' : body;
          break;
        case 'reply':
          title = 'Ответ на комментарий';
          body = body.isEmpty ? 'Кто-то ответил на ваш комментарий' : body;
          break;
        case 'follow':
          title = 'Новый подписчик';
          body = body.isEmpty ? 'Кто-то подписался на вас' : body;
          break;
        case 'mention':
          title = 'Упоминание';
          body = body.isEmpty ? 'Вас упомянули' : body;
          break;
        case 'repost':
          title = 'Репост';
          body = body.isEmpty ? 'Ваш пост репостнули' : body;
          break;
        // Уведомления для дебатов
        case 'debate_comment':
          title = 'Комментарий в дебате';
          body = body.isEmpty ? 'Кто-то прокомментировал ваш дебат' : body;
          break;
        case 'debate_reply':
          title = 'Ответ в дебате';
          body = body.isEmpty ? 'Кто-то ответил на ваш комментарий в дебате' : body;
          break;
        case 'debate_like':
          title = 'Лайк в дебате';
          body = body.isEmpty ? 'Кто-то лайкнул ваш комментарий в дебате' : body;
          break;
        case 'debate_vote':
          title = 'Голос в дебате';
          body = body.isEmpty ? 'Кто-то проголосовал в вашем дебате' : body;
          break;
        default:
          title = 'Уведомление';
          body = body.isEmpty ? 'У вас новое уведомление' : body;
      }

      // Типы у которых ТОЧНО есть DB-триггер (проверено по миграциям):
      // - like: on_post_like → notify_post_like (84_fix_notifications_rls.sql)
      // - comment: on_post_comment → notify_post_comment (84_fix_notifications_rls.sql)
      // - comment_like: on_comment_like → notify_comment_like (157_fix_notification_dedup_and_non_blocking.sql)
      // - debate_vote: on_debate_vote → notify_debate_vote (157_fix_notification_dedup_and_non_blocking.sql)
      //
      // Типы БЕЗ триггера — клиент ДОЛЖЕН писать в БД сам:
      // - follow, reply, mention, repost, debate_comment, debate_reply, debate_like
      const typesWithDbTrigger = {
        'like',
        'comment',
        'comment_like',
        'debate_vote',
      };

      if (!typesWithDbTrigger.contains(type)) {
        // Типы без триггера — пишем в БД вручную через RPC
        AppLogger.info('[NOTIF-DB] Пишем в БД: type=$type userId=$userId', tag: 'SupabaseNotificationService');
        final discussionId = (type == 'debate_comment' || type == 'debate_reply' || type == 'debate_like')
            ? postId
            : null;
        final actualPostId = (type == 'debate_comment' || type == 'debate_reply' || type == 'debate_like')
            ? null
            : postId;
        await _supabase.rpc('create_notification', params: {
          'p_user_id': userId,
          'p_type': type,
          'p_title': title,
          'p_body': body,
          'p_from_user_id': actorId,
          'p_post_id': actualPostId,
          'p_comment_id': commentId,
          'p_discussion_id': discussionId,
        });
        AppLogger.success('[NOTIF-DB] Запись создана в БД: type=$type', tag: 'SupabaseNotificationService');
      } else {
        AppLogger.info('[NOTIF-DB] Триггер БД создаст запись: type=$type (клиент только push)', tag: 'SupabaseNotificationService');
      }

      await _sendPushNotification(
        userId: userId,
        type: type,
        title: title,
        body: body,
        actorId: actorId,
        postId: postId,
        commentId: commentId,
      );
    } catch (e, st) {
      AppLogger.error('Ошибка создания уведомления', tag: 'SupabaseNotificationService', error: e, stackTrace: st);
      // Не пробрасываем ошибку, чтобы не ломать основной функционал
    }
  }

  Future<void> _sendPushNotification({
    required String userId,
    required String type,
    required String title,
    required String body,
    required String actorId,
    String? postId,
    String? commentId,
  }) async {
    try {
      final isDebate = type == 'debate_comment' || type == 'debate_reply' || type == 'debate_like' || type == 'debate_vote';
      final payload = <String, dynamic>{
        'type': type,
        'actor_id': actorId,
        if (postId != null && postId.isNotEmpty)
          if (isDebate) 'discussion_id': postId else 'post_id': postId,
        if (commentId != null && commentId.isNotEmpty) 'comment_id': commentId,
      };

      AppLogger.info('[PUSH-SEND] Отправляем push: type=$type userId=$userId payload=$payload', tag: 'SupabaseNotificationService');
      await _pushNotificationService.sendToUser(
        userId: userId,
        title: title,
        body: body,
        data: payload,
      );
      AppLogger.success('[PUSH-SEND] Push отправлен: type=$type userId=$userId', tag: 'SupabaseNotificationService');
    } catch (e, st) {
      AppLogger.warning('[PUSH-SEND] Ошибка отправки push: type=$type', tag: 'SupabaseNotificationService', error: e, stackTrace: st);
    }
  }

  /// Удалить все уведомления пользователя
  Future<void> deleteAllNotifications(String userId) async {
    try {
      await _supabase
          .from('notifications')
          .delete()
          .eq('user_id', userId);
    } catch (e, st) {
      AppLogger.error('Ошибка удаления всех уведомлений', tag: 'SupabaseNotificationService', error: e, stackTrace: st);
      rethrow;
    }
  }

  /// Подписка на realtime-уведомления пользователя
  Future<RealtimeChannel> subscribeToNotifications(
    String userId,
    void Function(Map<String, dynamic> newRecord) onInsert, {
    void Function(Map<String, dynamic> updatedRecord)? onUpdate,
  }) async {
    // Сбрасываем при каждой новой подписке (новая сессия / переход между юзерами)
    _processedNotificationIds.clear();
    _pollingTimer?.cancel();
    _pollingTimer = null;
    final channel = _supabase
        .channel('notifications:user:$userId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'notifications',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: userId,
          ),
          callback: (payload) {
            final id = payload.newRecord['id'] as String;
            _processedNotificationIds.add(id);
            onInsert(Map<String, dynamic>.from(payload.newRecord));
          },
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'notifications',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: userId,
          ),
          callback: (payload) {
            if (onUpdate != null) {
              onUpdate(Map<String, dynamic>.from(payload.newRecord));
            }
          },
        )
        .subscribe((status, error) {
          if (error != null) {
            AppLogger.error('Realtime subscription error', tag: 'SupabaseNotificationService', error: error);
          }
        });
    
    // Загружаем существующие уведомления чтобы не показывать их как новые
    try {
      final existingNotifications = await _supabase
          .from('notifications')
          .select('id')
          .eq('user_id', userId)
          .limit(10);
          
      for (final notification in existingNotifications) {
        _processedNotificationIds.add(notification['id'] as String);
      }
    } catch (e) {
      AppLogger.error('Ошибка загрузки существующих уведомлений', tag: 'SupabaseNotificationService', error: e);
    }
    
    // Останавливаем предыдущий таймер если есть
    _pollingTimer?.cancel();
    
    // Если realtime не работает, проверяем каждые 10 секунд только НОВЫЕ/НЕПРОЧИТАННЫЕ уведомления.
    // Важно: polling по "последним 10" даёт ложные срабатывания после relogin,
    // поэтому здесь берём только is_read=false.
    _pollingTimer = Timer.periodic(const Duration(seconds: 5), (timer) async {
      try {
        final connectivity = await Connectivity().checkConnectivity();
        if (connectivity == ConnectivityResult.none) {
          return;
        }

        final newNotifications = await _supabase
            .from('notifications')
            .select('*')
            .eq('user_id', userId)
            .eq('is_read', false)
            .order('created_at', ascending: false)
            .limit(10);
            
        // Фильтруем только необработанные уведомления
        final trulyNewNotifications = newNotifications.where((notification) {
          final id = notification['id'] as String;
          return !_processedNotificationIds.contains(id);
        }).toList();
            
        if (trulyNewNotifications.isNotEmpty) {
          for (final notification in trulyNewNotifications.reversed) {
            final id = notification['id'] as String;
            _processedNotificationIds.add(id);
            onInsert(Map<String, dynamic>.from(notification));
          }
        }
      } catch (e) {
        final errorText = e.toString();
        final isNetworkError = errorText.contains('Failed host lookup') ||
            errorText.contains('SocketException') ||
            errorText.contains('AuthRetryableFetchException') ||
            errorText.contains('ClientException') ||
            errorText.contains('Software caused connection abort') ||
            errorText.contains('Connection refused') ||
            errorText.contains('Connection reset') ||
            errorText.contains('Network is unreachable');
        if (isNetworkError) {
          // Не отменяем timer — продолжаем polling, просто пропускаем этот тик
          AppLogger.warning('[NOTIF] Polling: сетевая ошибка, пропускаем тик', tag: 'SupabaseNotificationService');
          return;
        }
        AppLogger.error('[NOTIF] Polling: ошибка проверки уведомлений', tag: 'SupabaseNotificationService', error: e);
      }
    });
    
    return channel;
  }

  Future<void> unsubscribe(RealtimeChannel channel) async {
    _pollingTimer?.cancel();
    _pollingTimer = null;
    _processedNotificationIds.clear();
    await _supabase.removeChannel(channel);
  }

  /// Вызывать при logout — гарантированно останавливает polling таймер
  void dispose() {
    _pollingTimer?.cancel();
    _pollingTimer = null;
    _processedNotificationIds.clear();
  }
}
