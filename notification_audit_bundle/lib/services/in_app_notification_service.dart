import 'dart:async';
import 'dart:convert';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../app_state.dart';
import '../screens/discussion_detail_screen.dart';
import '../utils/logger.dart';
import 'notification_service.dart';

/// Типы In-App уведомлений
enum InAppNotificationType {
  newMessage,      // Новое сообщение в чате
  newComment,      // Новый комментарий к посту
  commentReply,    // Ответ на комментарий
  postLike,        // Лайк на пост
  commentLike,     // Лайк на комментарий
  newFollower,     // Новый подписчик
  newDebate,       // Новый дебат (не используется)
  debateComment,   // Комментарий в дебате
  debateReply,     // Ответ на комментарий в дебате
  debateLike,      // Лайк на комментарий в дебате
  mention,         // Упоминание в посте/комментарии
  system,          // Системное уведомление
}

/// Модель уведомления
class InAppNotification {
  final String id;
  final InAppNotificationType type;
  final String title;
  final String body;
  final String? avatarUrl;
  final String? senderId;
  final String? senderName;
  final String? targetId; // ID чата, поста, комментария и т.д.
  final DateTime createdAt;
  final Map<String, dynamic>? data;

  InAppNotification({
    required this.id,
    required this.type,
    required this.title,
    required this.body,
    this.avatarUrl,
    this.senderId,
    this.senderName,
    this.targetId,
    this.data,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  /// Получить иконку для типа уведомления
  IconData get icon {
    switch (type) {
      case InAppNotificationType.newMessage:
        return Icons.chat_bubble;
      case InAppNotificationType.newComment:
        return Icons.comment;
      case InAppNotificationType.commentReply:
        return Icons.reply;
      case InAppNotificationType.postLike:
      case InAppNotificationType.commentLike:
      case InAppNotificationType.debateLike:
        return Icons.favorite;
      case InAppNotificationType.newFollower:
        return Icons.person_add;
      case InAppNotificationType.newDebate:
      case InAppNotificationType.debateComment:
      case InAppNotificationType.debateReply:
        return Icons.local_fire_department;
      case InAppNotificationType.mention:
        return Icons.alternate_email;
      case InAppNotificationType.system:
        return Icons.notifications;
    }
  }

  /// Получить цвет для типа уведомления
  Color get color {
    switch (type) {
      case InAppNotificationType.newMessage:
        return const Color(0xFF3390EC); // Telegram blue
      case InAppNotificationType.newComment:
      case InAppNotificationType.commentReply:
        return Colors.blue;
      case InAppNotificationType.postLike:
      case InAppNotificationType.commentLike:
        return Colors.red;
      case InAppNotificationType.newFollower:
        return Colors.purple;
      case InAppNotificationType.newDebate:
      case InAppNotificationType.debateComment:
      case InAppNotificationType.debateReply:
        return Colors.orange;
      case InAppNotificationType.debateLike:
        return Colors.red;
      case InAppNotificationType.mention:
        return Colors.teal;
      case InAppNotificationType.system:
        return Colors.grey;
    }
  }
}

/// Сервис для управления In-App уведомлениями
class InAppNotificationService {
  static final InAppNotificationService _instance = InAppNotificationService._internal();
  factory InAppNotificationService() => _instance;
  InAppNotificationService._internal();

  /// Глобальный ключ для показа уведомлений
  static GlobalKey<NavigatorState>? navigatorKey;
  
  /// Контроллер для стрима уведомлений
  final _notificationController = StreamController<InAppNotification>.broadcast();
  
  /// Стрим уведомлений
  Stream<InAppNotification> get notificationStream => _notificationController.stream;
  
  /// Текущий контекст для показа уведомлений
  BuildContext? _context;
  
  /// Текущий открытый чат (чтобы не показывать уведомления для него)
  String? _currentOpenChatId;
  
  /// Текущий открытый экран (чтобы не показывать уведомления на этом экране)
  String? _currentOpenScreen;
  
  /// Установить контекст
  void setContext(BuildContext context) {
    _context = context;
  }
  
  /// Установить текущий открытый чат
  void setCurrentOpenChat(String? chatId) {
    _currentOpenChatId = chatId;
  }
  
  /// Установить текущий открытый экран
  void setCurrentOpenScreen(String? screenName) {
    _currentOpenScreen = screenName;
  }
  
  /// Показать уведомление о новом сообщении
  void showNewMessageNotification({
    required String chatId,
    required String senderId,
    required String senderName,
    required String messageText,
    String? avatarUrl,
  }) {
    // Не показываем если этот чат открыт
    if (_currentOpenChatId == chatId) {
      return;
    }
    
    // Показываем только если мы НЕ в чатах
    if (_currentOpenScreen == 'chats') {
      return;
    }
    
    final notification = InAppNotification(
      id: 'msg_${DateTime.now().millisecondsSinceEpoch}',
      type: InAppNotificationType.newMessage,
      title: senderName,
      body: messageText.length > 50 ? '${messageText.substring(0, 50)}...' : messageText,
      avatarUrl: avatarUrl,
      senderId: senderId,
      senderName: senderName,
      targetId: chatId,
      data: {'chat_id': chatId, 'sender_id': senderId, 'other_user_id': senderId},
    );
    
    _showNotification(notification);
    
    // BUG-002: Показываем системное push-уведомление как в Telegram
    _showSystemPushNotification(
      title: senderName,
      body: messageText.length > 100 ? '${messageText.substring(0, 100)}...' : messageText,
      data: {'type': 'chat_message', 'chat_id': chatId, 'sender_id': senderId, 'other_user_id': senderId},
    );
  }
  
  /// Показать уведомление о новом комментарии
  void showNewCommentNotification({
    required String postId,
    required String commentId,
    required String senderId,
    required String senderName,
    required String commentText,
    String? avatarUrl,
  }) {
    final notification = InAppNotification(
      id: 'comment_${DateTime.now().millisecondsSinceEpoch}',
      type: InAppNotificationType.newComment,
      title: '$senderName прокомментировал(а)',
      body: commentText.length > 50 ? '${commentText.substring(0, 50)}...' : commentText,
      avatarUrl: avatarUrl,
      senderId: senderId,
      senderName: senderName,
      targetId: postId,
      data: {'post_id': postId, 'comment_id': commentId, 'comment_text': commentText},
    );
    
    _showNotification(notification);
  }
  
  /// Показать уведомление об ответе на комментарий
  void showCommentReplyNotification({
    required String postId,
    required String commentId,
    required String senderId,
    required String senderName,
    required String replyText,
    String? avatarUrl,
  }) {
    final notification = InAppNotification(
      id: 'reply_${DateTime.now().millisecondsSinceEpoch}',
      type: InAppNotificationType.commentReply,
      title: '$senderName ответил(а) на ваш комментарий',
      body: replyText.length > 50 ? '${replyText.substring(0, 50)}...' : replyText,
      avatarUrl: avatarUrl,
      senderId: senderId,
      senderName: senderName,
      targetId: postId,
      data: {'post_id': postId, 'comment_id': commentId, 'comment_text': replyText},
    );
    
    _showNotification(notification);
  }
  
  /// Показать уведомление о лайке на пост
  void showPostLikeNotification({
    required String postId,
    required String senderId,
    required String senderName,
    String? avatarUrl,
  }) {
    final notification = InAppNotification(
      id: 'like_${DateTime.now().millisecondsSinceEpoch}',
      type: InAppNotificationType.postLike,
      title: '$senderName',
      body: 'понравился ваш пост',
      avatarUrl: avatarUrl,
      senderId: senderId,
      senderName: senderName,
      targetId: postId,
      data: {'post_id': postId},
    );
    
    _showNotification(notification);
  }
  
  /// Показать уведомление о новом подписчике
  void showNewFollowerNotification({
    required String followerId,
    required String followerName,
    String? avatarUrl,
  }) {
    final notification = InAppNotification(
      id: 'follower_${DateTime.now().millisecondsSinceEpoch}',
      type: InAppNotificationType.newFollower,
      title: '$followerName',
      body: 'подписался на вас',
      avatarUrl: avatarUrl,
      senderId: followerId,
      senderName: followerName,
      targetId: followerId,
      data: {'follower_id': followerId},
    );
    
    _showNotification(notification);
  }
  
  /// Показать уведомление о лайке комментария
  void showCommentLikeNotification({
    required String senderId,
    required String senderName,
    required String commentText,
    String? avatarUrl,
  }) {
    final notification = InAppNotification(
      id: 'comment_like_${DateTime.now().millisecondsSinceEpoch}',
      type: InAppNotificationType.commentLike,
      title: '$senderName',
      body: 'оценил(а) ваш комментарий',
      avatarUrl: avatarUrl,
      senderId: senderId,
      senderName: senderName,
      data: {'comment_text': commentText},
    );
    
    _showNotification(notification);
  }
  
  /// Показать уведомление о новом дебате
  void showNewDebateNotification({
    required String debateId,
    required String authorId,
    required String authorName,
    required String debateTitle,
    String? avatarUrl,
  }) {
    final notification = InAppNotification(
      id: 'debate_${DateTime.now().millisecondsSinceEpoch}',
      type: InAppNotificationType.newDebate,
      title: '$authorName создал(а) дебат',
      body: debateTitle.length > 50 ? '${debateTitle.substring(0, 50)}...' : debateTitle,
      avatarUrl: avatarUrl,
      senderId: authorId,
      senderName: authorName,
      targetId: debateId,
      data: {'debate_id': debateId},
    );
    
    _showNotification(notification);
  }
  
  /// Показать уведомление о комментарии в дебате
  void showDebateCommentNotification({
    required String debateId,
    required String debateTitle,
    required String commentId,
    required String senderId,
    required String senderName,
    required String commentText,
    String? avatarUrl,
  }) {
    final notification = InAppNotification(
      id: 'debate_comment_${DateTime.now().millisecondsSinceEpoch}',
      type: InAppNotificationType.debateComment,
      title: senderName,
      body: commentText.length > 60 ? '${commentText.substring(0, 60)}...' : commentText,
      avatarUrl: avatarUrl,
      senderId: senderId,
      senderName: senderName,
      targetId: debateId,
      data: {
        'debate_id': debateId,
        'debate_title': debateTitle,
        'comment_id': commentId,
      },
    );
    
    _showNotification(notification);
  }
  
  /// Показать уведомление об ответе в дебате
  void showDebateReplyNotification({
    required String debateId,
    required String debateTitle,
    required String commentId,
    required String senderId,
    required String senderName,
    required String replyText,
    String? avatarUrl,
  }) {
    final notification = InAppNotification(
      id: 'debate_reply_${DateTime.now().millisecondsSinceEpoch}',
      type: InAppNotificationType.debateReply,
      title: senderName,
      body: replyText.length > 60 ? '${replyText.substring(0, 60)}...' : replyText,
      avatarUrl: avatarUrl,
      senderId: senderId,
      senderName: senderName,
      targetId: debateId,
      data: {
        'debate_id': debateId,
        'debate_title': debateTitle,
        'comment_id': commentId,
      },
    );
    
    _showNotification(notification);
  }
  
  /// Показать уведомление о лайке на комментарий в дебате
  void showDebateLikeNotification({
    required String debateId,
    required String debateTitle,
    required String commentId,
    required String senderId,
    required String senderName,
    String? avatarUrl,
  }) {
    final notification = InAppNotification(
      id: 'debate_like_${DateTime.now().millisecondsSinceEpoch}',
      type: InAppNotificationType.debateLike,
      title: senderName,
      body: 'понравился ваш комментарий в дебате',
      avatarUrl: avatarUrl,
      senderId: senderId,
      senderName: senderName,
      targetId: debateId,
      data: {
        'debate_id': debateId,
        'debate_title': debateTitle,
        'comment_id': commentId,
      },
    );
    
    _showNotification(notification);
  }
  
  /// Показать системное уведомление
  void showSystemNotification({
    required String title,
    required String body,
  }) {
    final notification = InAppNotification(
      id: 'system_${DateTime.now().millisecondsSinceEpoch}',
      type: InAppNotificationType.system,
      title: title,
      body: body,
    );
    
    _showNotification(notification);
  }
  
  /// Внутренний метод показа уведомления
  void _showNotification(InAppNotification notification) {
    
    // Вибрация при уведомлении
    HapticFeedback.mediumImpact();
    
    // Отправляем в стрим
    _notificationController.add(notification);
    
    // Обновляем список уведомлений в AppState
    try {
      // Получаем AppState через контекст если возможно
      if (_context != null) {
        final appState = _context!.read<AppState>();
        
        if (notification.type != InAppNotificationType.newMessage) {
          // Список уведомлений обновляется через realtime и явные открытия экрана
        } else {
          // Для сообщений обновляем только счетчик
          appState.refreshUnreadMessagesCount();
        }
      }
    } catch (e) {
      AppLogger.error('Ошибка обработки уведомления', tag: 'InAppNotification', error: e);
    }
    
    // Показываем визуальное уведомление
    if (_context != null) {
      _showOverlayNotification(_context!, notification);
    }
  }
  
  /// Показать overlay уведомление (баннер сверху)
  void _showOverlayNotification(BuildContext context, InAppNotification notification) {
    final overlay = Overlay.of(context);
    
    late OverlayEntry overlayEntry;
    
    overlayEntry = OverlayEntry(
      builder: (context) => _NotificationBanner(
        notification: notification,
        onDismiss: () {
          overlayEntry.remove();
        },
        onTap: () {
          overlayEntry.remove();
          _handleNotificationTap(context, notification);
        },
      ),
    );
    
    overlay.insert(overlayEntry);
    
    // Автоматически скрываем через 4 секунды
    Future.delayed(const Duration(seconds: 4), () {
      if (overlayEntry.mounted) {
        overlayEntry.remove();
      }
    });
  }
  
  /// Обработка нажатия на уведомление
  void _handleNotificationTap(BuildContext context, InAppNotification notification) {
    
    switch (notification.type) {
      case InAppNotificationType.newMessage:
        // Переход к списку чатов (вкладка 1 = дебаты/чаты)
        Navigator.of(context).pushNamedAndRemoveUntil('/main', (route) => false);
        break;
      case InAppNotificationType.newComment:
      case InAppNotificationType.commentReply:
        // Переход к посту
        final postId = notification.targetId;
        if (postId != null) {
          Navigator.of(context).pushNamed('/post', arguments: {
            'postId': postId,
            'commentId': notification.data?['comment_id'] as String?,
          });
        }
        break;
      case InAppNotificationType.postLike:
      case InAppNotificationType.commentLike:
        // Переход к посту
        final postId = notification.targetId;
        if (postId != null) {
          Navigator.of(context).pushNamed('/post', arguments: {'postId': postId});
        }
        break;
      case InAppNotificationType.newFollower:
        final followerId = notification.targetId ?? notification.data?['follower_id'] as String?;
        if (followerId != null) {
          Navigator.of(context).pushNamed('/user', arguments: followerId);
        } else {
          Navigator.of(context).pushNamedAndRemoveUntil('/main', (route) => false);
        }
        break;
      case InAppNotificationType.mention:
        // Переход к посту с упоминанием
        final postId = notification.targetId;
        if (postId != null) {
          Navigator.of(context).pushNamed('/post', arguments: {'postId': postId});
        }
        break;
      case InAppNotificationType.newDebate:
      case InAppNotificationType.debateComment:
      case InAppNotificationType.debateReply:
      case InAppNotificationType.debateLike:
        // Переход к дебату
        final debateId = notification.targetId ?? notification.data?['debate_id'] as String?;
        if (debateId != null) {
          final appState = Provider.of<AppState>(context, listen: false);
          final discussion = appState.discussions.where((d) => d.id == debateId).firstOrNull;
          if (discussion != null) {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => DiscussionDetailScreen(discussion: discussion),
              ),
            );
          }
        }
        break;
      case InAppNotificationType.system:
        break;
    }
  }
  
  /// BUG-002: Показать системное push-уведомление
  void _showSystemPushNotification({
    required String title,
    required String body,
    Map<String, dynamic>? data,
  }) {
    try {
      final payload = data != null ? jsonEncode(data) : null;
      NotificationService().showLocalNotification(
        title: title,
        body: body,
        payload: payload,
        channelId: data?['type'] == 'chat_message' ? 'chat_messages' : 'activity_notifications',
        channelName: data?['type'] == 'chat_message' ? 'Chat Messages' : 'Activity Notifications',
        channelDescription: data?['type'] == 'chat_message'
            ? 'Notifications for new chat messages'
            : 'Likes, comments, follows and other activity notifications',
      );
      AppLogger.info('System push notification shown: $title', tag: 'InAppNotification');
    } catch (e) {
      AppLogger.error('Failed to show system push notification', tag: 'InAppNotification', error: e);
    }
  }
  
  /// Закрыть сервис
  void dispose() {
    _notificationController.close();
  }
}

/// Виджет баннера уведомления — стиль Instagram / Threads
class _NotificationBanner extends StatefulWidget {
  final InAppNotification notification;
  final VoidCallback onDismiss;
  final VoidCallback onTap;

  const _NotificationBanner({
    required this.notification,
    required this.onDismiss,
    required this.onTap,
  });

  @override
  State<_NotificationBanner> createState() => _NotificationBannerState();
}

class _NotificationBannerState extends State<_NotificationBanner>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<Offset> _slideAnimation;
  late Animation<double> _fadeAnimation;
  double _dragOffset = 0;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 420),
      vsync: this,
    );

    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, -1.5),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
    ));

    _fadeAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.0, 0.6, curve: Curves.easeOut),
    ));

    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _dismiss() {
    _controller.reverse().then((_) {
      if (mounted) widget.onDismiss();
    });
  }

  @override
  Widget build(BuildContext context) {
    final notification = widget.notification;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final topPadding = MediaQuery.of(context).padding.top;

    return Positioned(
      top: topPadding + 10,
      left: 12,
      right: 12,
      child: SlideTransition(
        position: _slideAnimation,
        child: FadeTransition(
          opacity: _fadeAnimation,
          child: Transform.translate(
            offset: Offset(0, _dragOffset),
            child: GestureDetector(
              onTap: widget.onTap,
              onVerticalDragUpdate: (d) {
                if (d.delta.dy < 0) {
                  setState(() => _dragOffset = (_dragOffset + d.delta.dy).clamp(-60.0, 0.0));
                }
              },
              onVerticalDragEnd: (d) {
                if (_dragOffset < -20 || (d.primaryVelocity ?? 0) < -400) {
                  _dismiss();
                } else {
                  setState(() => _dragOffset = 0);
                }
              },
              child: ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                      color: isDark
                          ? Colors.black.withValues(alpha: 0.72)
                          : Colors.white.withValues(alpha: 0.88),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: isDark
                            ? Colors.white.withValues(alpha: 0.08)
                            : Colors.black.withValues(alpha: 0.06),
                        width: 1,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: isDark ? 0.45 : 0.12),
                          blurRadius: 24,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        // Аватар / иконка приложения
                        _buildAvatar(notification, isDark),
                        const SizedBox(width: 12),

                        // Контент
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // Имя приложения + время
                              Row(
                                children: [
                                  Text(
                                    'Osekky',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: isDark
                                          ? Colors.white.withValues(alpha: 0.45)
                                          : Colors.black.withValues(alpha: 0.4),
                                      letterSpacing: 0.2,
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    '·',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: isDark
                                          ? Colors.white.withValues(alpha: 0.3)
                                          : Colors.black.withValues(alpha: 0.3),
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    'сейчас',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: isDark
                                          ? Colors.white.withValues(alpha: 0.35)
                                          : Colors.black.withValues(alpha: 0.35),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 3),
                              // Заголовок — имя пользователя жирным
                              Text(
                                notification.title,
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: isDark ? Colors.white : Colors.black,
                                  height: 1.2,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              if (notification.body.isNotEmpty) ...[
                                const SizedBox(height: 2),
                                Text(
                                  notification.body,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w400,
                                    color: isDark
                                        ? Colors.white.withValues(alpha: 0.7)
                                        : Colors.black.withValues(alpha: 0.65),
                                    height: 1.3,
                                  ),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAvatar(InAppNotification notification, bool isDark) {
    final hasAvatar = notification.avatarUrl != null && notification.avatarUrl!.isNotEmpty;

    if (hasAvatar) {
      return Stack(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.12)
                    : Colors.black.withValues(alpha: 0.06),
                width: 1.5,
              ),
            ),
            child: ClipOval(
              child: CachedNetworkImage(
                imageUrl: notification.avatarUrl!,
                fit: BoxFit.cover,
                placeholder: (_, __) => Container(
                  color: const Color(0xFF003e70).withValues(alpha: 0.12),
                  child: const Icon(Icons.person, color: Color(0xFF003e70), size: 22),
                ),
                errorWidget: (_, __, ___) => Container(
                  color: const Color(0xFF003e70).withValues(alpha: 0.12),
                  child: const Icon(Icons.person, color: Color(0xFF003e70), size: 22),
                ),
              ),
            ),
          ),
          // Иконка типа уведомления поверх аватара
          Positioned(
            bottom: 0,
            right: 0,
            child: Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                color: _getTypeColor(notification.type),
                shape: BoxShape.circle,
                border: Border.all(
                  color: isDark ? Colors.black : Colors.white,
                  width: 1.5,
                ),
              ),
              child: Icon(
                _getTypeSmallIcon(notification.type),
                size: 10,
                color: Colors.white,
              ),
            ),
          ),
        ],
      );
    }

    // Без аватара — иконка приложения
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: const Color(0xFF003e70),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(
        notification.icon,
        color: Colors.white,
        size: 22,
      ),
    );
  }

  Color _getTypeColor(InAppNotificationType type) {
    switch (type) {
      case InAppNotificationType.postLike:
      case InAppNotificationType.commentLike:
      case InAppNotificationType.debateLike:
        return Colors.red;
      case InAppNotificationType.newFollower:
        return Colors.purple;
      case InAppNotificationType.newMessage:
        return const Color(0xFF003e70);
      case InAppNotificationType.newComment:
      case InAppNotificationType.commentReply:
        return Colors.blue;
      default:
        return Colors.orange;
    }
  }

  IconData _getTypeSmallIcon(InAppNotificationType type) {
    switch (type) {
      case InAppNotificationType.postLike:
      case InAppNotificationType.commentLike:
      case InAppNotificationType.debateLike:
        return Icons.favorite;
      case InAppNotificationType.newFollower:
        return Icons.person_add;
      case InAppNotificationType.newMessage:
        return Icons.chat_bubble;
      case InAppNotificationType.newComment:
      case InAppNotificationType.commentReply:
        return Icons.comment;
      default:
        return Icons.notifications;
    }
  }
}
