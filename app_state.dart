import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:collection/collection.dart';
import 'package:uuid/uuid.dart';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide User;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import 'models.dart';
import 'app_state_supabase.dart';
import 'config/features.dart';
import 'services/service_locator.dart';
import 'services/supabase_post_service.dart';
import 'services/supabase_user_service.dart';
import 'services/supabase_follow_request_service.dart';
import 'services/supabase_notification_service.dart';
import 'services/supabase_chat_service.dart';
import 'services/supabase_discussion_service.dart';
import 'services/supabase_storage_service.dart';
import 'services/supabase_community_service.dart';
import 'services/supabase_block_service.dart';
import 'services/supabase_report_service.dart';
import 'services/avatar_crop_service.dart';
import 'services/audio_service.dart';
import 'services/rate_limit_service.dart';
import 'services/presence_service.dart';
import 'services/cache_service.dart';
import 'services/supabase_auth_service.dart';
import 'services/firebase_notification_service.dart';
import 'services/offline_queue_service.dart';
import 'services/in_app_notification_service.dart';
import 'services/push_notification_service.dart';
import 'services/supabase_settings_service.dart';
import 'services/notification_service.dart';
import 'utils/logger.dart';
import 'l10n/app_localizations.dart';

// Глобальное состояние приложения
class AppState extends ChangeNotifier with SupabaseProfileMixin {
  static const String _websiteTextSeparator = '|||OsekkyWebsiteText|||';
  static final AppState _instance = AppState._internal();
  static bool _initialized = false;
  factory AppState() {
    if (!_initialized) {
      _initialized = true;
      _instance.initializeData();
      _instance._initializeServices();
    }
    return _instance;
  }
  AppState._internal();

  // Инициализация всех сервисов
  Future<void> _initializeServices() async {
    try {
      // Инициализация ServiceLocator
      await ServiceLocator.initialize();
      
      // Инициализация кэша
      await Services.cache.initialize();
      AppLogger.info('CacheService инициализирован', tag: 'AppState');
      
      // Инициализация офлайн-очереди
      final queue = Services.offlineQueue;
      await queue.initialize();
      queue.onExecuteAction = _executeOfflineAction;
      
      AppLogger.info('Все сервисы инициализированы', tag: 'AppState');
    } catch (e) {
      AppLogger.error('Ошибка инициализации сервисов', tag: 'AppState', error: e);
    }
  }

  // Выполнение офлайн-действия при восстановлении сети
  Future<bool> _executeOfflineAction(OfflineAction action) async {
    final userId = action.data['userId'] as String? ?? '';
    final postId = action.data['postId'] as String? ?? '';

    try {
      switch (action.type) {
        case OfflineActionType.like:
          await Services.posts.likePost(userId, postId);
          return true;
        case OfflineActionType.unlike:
          await Services.posts.unlikePost(userId, postId);
          return true;
        case OfflineActionType.bookmark:
          await Services.posts.addBookmark(userId, postId);
          return true;
        case OfflineActionType.unbookmark:
          await Services.posts.removeBookmark(userId, postId);
          return true;
        case OfflineActionType.follow:
          final targetId = action.data['targetId'] as String? ?? '';
          await Services.users.followUser(userId, targetId);
          return true;
        case OfflineActionType.unfollow:
          final targetId = action.data['targetId'] as String? ?? '';
          await Services.users.unfollowUser(userId, targetId);
          return true;
        case OfflineActionType.createPost:
          final text      = action.data['text']      as String? ?? '';
          final mediaUrls = (action.data['mediaUrls'] as List?)?.cast<String>();
          final mediaType = action.data['mediaType']  as String?;
          final isAnon    = action.data['isAnonymous'] as bool? ?? false;
          final isAdult   = action.data['isAdult']     as bool? ?? false;
          final parts     = (action.data['parts'] as List?)?.cast<String>();
          final result = await Services.posts.createPost(
            userId:      userId,
            text:        text,
            mediaUrls:   mediaUrls,
            mediaType:   mediaType,
            isAnonymous: isAnon,
            isAdult:     isAdult,
            parts:       parts,
          );
          return result != null;
        case OfflineActionType.comment:
          final commentText   = action.data['text']     as String? ?? '';
          final commentPostId = action.data['postId']   as String? ?? '';
          final parentId      = action.data['parentId'] as String?;
          if (commentText.isEmpty || commentPostId.isEmpty) return false;
          final commentId = action.data['commentId'] as String? ?? const Uuid().v4();
          final commentData = await Services.posts.addComment(
            id:       commentId,
            postId:   commentPostId,
            userId:   userId,
            text:     commentText,
            parentId: parentId,
          );
          return commentData != null;
        default:
          return false;
      }
    } catch (e) {
      AppLogger.error('Ошибка выполнения офлайн-действия: ${action.type.name}', tag: _logTag, error: e);
      return false;
    }
  }

  // Попытка синхронизации офлайн-очереди
  Future<void> syncOfflineQueue() async {
    final queue = Services.offlineQueue;
    if (!queue.hasPendingActions) return;
    final synced = await queue.syncQueue();
    if (synced > 0) {
      AppLogger.info('Синхронизировано $synced офлайн-действий', tag: _logTag);
      notifyListeners();
    }
  }

  void notify() {
    notifyListeners();
  }

  Future<void> _loadLastKnownAuthUserId() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _lastKnownAuthUserId = prefs.getString('last_known_auth_user_id');
    } catch (_) {}
  }

  Future<void> _saveLastKnownAuthUserId(String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('last_known_auth_user_id', userId);
    } catch (_) {}
  }
  
  // StreamController для сигналов скролла к началу
  final _scrollToTopController = StreamController<bool>.broadcast();
  Stream<bool> get scrollToTopStream => _scrollToTopController.stream;
  
  @override
  void dispose() {
    _scrollToTopController.close();
    // BUG-009: Очищаем connectivity subscription
    _connectivitySubscription?.cancel();
    super.dispose();
  }

  void _updateLastPartnerMessageTimestamp(String chatId, List<ChatMessage> messages) {
    if (_currentUser == null) return;
    final lastIncoming = messages.lastWhereOrNull((m) => m.sender.id != _currentUser!.id);
    if (lastIncoming != null) {
      _lastPartnerMessageAt[chatId] = lastIncoming.createdAt;
      _markOutgoingMessagesReadUpTo(chatId, lastIncoming.createdAt);
    }
  }

  Future<void> sendChatMessageWithTempIdToChatId({
    required String chatId,
    required String tempId,
    required String otherUserId,
    required String text,
    String? mediaUrl,
    String? mediaType,
    String? videoThumbnail,
    String? replyToId,
  }) async {
    if (_currentUser == null) return;

    final validReplyToId = replyToId?.startsWith('temp_') == true ? null : replyToId;

    try {
      final messageData = await _supabaseChatService.sendMessage(
        chatId: chatId,
        senderId: _currentUser!.id,
        text: text,
        mediaUrl: mediaUrl,
        mediaType: mediaType,
        videoThumbnail: videoThumbnail,
        replyToId: validReplyToId,
      );

      if (messageData != null) {
        AudioService.playSuccessSound();
        final realMessage = _mapSupabaseMessageToChatMessage(messageData);

        final index = _chatMessages.indexWhere((m) => m.id == tempId);
        if (index != -1) {
          _chatMessages[index] = realMessage;
        }

        if (_chatMessagesCache.containsKey(chatId)) {
          final cacheIndex = _chatMessagesCache[chatId]!.indexWhere((m) => m.id == tempId);
          if (cacheIndex != -1) {
            _chatMessagesCache[chatId]![cacheIndex] = realMessage;
          }
        }

        if (_chatPreviewCache.containsKey(chatId)) {
          final chatPreview = Map<String, dynamic>.from(_chatPreviewCache[chatId]!);
          chatPreview['last_message'] = realMessage.text;
          chatPreview['last_message_at'] = realMessage.createdAt.toUtc().toIso8601String();
          chatPreview['last_message_sender_id'] = realMessage.sender.id;
          _chatPreviewCache[chatId] = chatPreview;
        }

        notifyListeners();
      } else {
        markOptimisticMessageFailed(tempId);
      }
    } catch (e) {
      markOptimisticMessageFailed(tempId);
    }
  }

  void _handlePartnerMessageReceived(String chatId, ChatMessage message) {
    if (_currentUser == null) return;
    if (message.sender.id == _currentUser!.id) return;

    final timestamp = message.createdAt;
    final existing = _lastPartnerMessageAt[chatId];
    if (existing == null || timestamp.isAfter(existing)) {
      _lastPartnerMessageAt[chatId] = timestamp;
    }

    _markOutgoingMessagesReadUpTo(chatId, timestamp);
  }

  /// Пометить оптимистичное сообщение как неотправленное (не удаляя из UI)
  void markOptimisticMessageFailed(String tempId) {
    final index = _chatMessages.indexWhere((m) => m.id == tempId);
    if (index != -1) {
      final chatId = _chatMessages[index].chatId;
      _chatMessages[index] = _chatMessages[index].copyWith(
        isSending: false,
        sendFailed: true,
      );

      if (_chatMessagesCache.containsKey(chatId)) {
        final cacheIndex = _chatMessagesCache[chatId]!.indexWhere((m) => m.id == tempId);
        if (cacheIndex != -1) {
          _chatMessagesCache[chatId]![cacheIndex] = _chatMessages[index];
        }
      }

      notifyListeners();
    }
  }

  Future<bool> retryFailedMessage(String tempId) async {
    if (!Features.useSupabaseChats || _currentUser == null) return false;

    ChatMessage? failed;
    int mainIndex = _chatMessages.indexWhere((m) => m.id == tempId);
    if (mainIndex != -1) {
      failed = _chatMessages[mainIndex];
    } else {
      // Пытаемся найти в кеше (и потом обновить основной список)
      for (final entry in _chatMessagesCache.entries) {
        final idx = entry.value.indexWhere((m) => m.id == tempId);
        if (idx != -1) {
          failed = entry.value[idx];
          break;
        }
      }
    }

    if (failed == null) return false;
    if (!failed.sendFailed) return false;

    final chatId = failed.chatId;

    void updateTemp(ChatMessage updated) {
      final index = _chatMessages.indexWhere((m) => m.id == tempId);
      if (index != -1) {
        _chatMessages[index] = updated;
      }
      final cached = _chatMessagesCache[chatId];
      if (cached != null) {
        final cidx = cached.indexWhere((m) => m.id == tempId);
        if (cidx != -1) {
          cached[cidx] = updated;
        }
      }
    }

    // Помечаем как отправляющееся
    updateTemp(failed.copyWith(isSending: true, sendFailed: false));
    notifyListeners();

    try {
      String? mediaUrl = failed.mediaUrl;
      String? mediaType = failed.mediaType;
      String? videoThumbnail = failed.videoThumbnail;

      // Если медиа локальное (не http/https) — перезаливаем
      if (mediaUrl != null && mediaUrl.isNotEmpty) {
        final isRemote = mediaUrl.startsWith('http://') || mediaUrl.startsWith('https://');
        if (!isRemote && (mediaType == 'image' || mediaType == 'video')) {
          final file = File(mediaUrl);
          if (await file.exists()) {
            final result = await SupabaseStorageService().uploadChatMedia(chatId, file);
            mediaUrl = result?['url'];
            if (mediaType == 'video') {
              videoThumbnail = result?['thumbnailUrl'];
            }
          }
        }
      }

      // Если это чисто медиа и upload не получился — возвращаем ошибку
      if ((failed.text.isEmpty) && (failed.mediaType != null) && (mediaUrl == null || mediaUrl.isEmpty)) {
        updateTemp(failed.copyWith(isSending: false, sendFailed: true));
        notifyListeners();
        return false;
      }

      final messageData = await _supabaseChatService.sendMessage(
        chatId: chatId,
        senderId: _currentUser!.id,
        text: failed.text,
        mediaUrl: mediaUrl,
        mediaType: mediaType,
        videoThumbnail: videoThumbnail,
        replyToId: failed.replyToId?.startsWith('temp_') == true ? null : failed.replyToId,
      );

      if (messageData == null) {
        updateTemp(failed.copyWith(isSending: false, sendFailed: true));
        notifyListeners();
        return false;
      }

      final realMessage = _mapSupabaseMessageToChatMessage(messageData);

      // Заменяем temp в основном списке
      final index = _chatMessages.indexWhere((m) => m.id == tempId);
      if (index != -1) {
        _chatMessages[index] = realMessage;
      }

      // Заменяем temp в кеше
      final cached = _chatMessagesCache[chatId];
      if (cached != null) {
        final cidx = cached.indexWhere((m) => m.id == tempId);
        if (cidx != -1) {
          cached[cidx] = realMessage;
          cached.sort((a, b) => b.createdAt.compareTo(a.createdAt));
        }
      }

      // Превью чата
      if (_chatPreviewCache.containsKey(chatId)) {
        final chatPreview = Map<String, dynamic>.from(_chatPreviewCache[chatId]!);
        chatPreview['last_message'] = realMessage.text.isNotEmpty
            ? realMessage.text
            : (realMessage.mediaType == 'image' ? '📷 Фото' : (realMessage.mediaType == 'video' ? '🎥 Видео' : ''));
        chatPreview['last_message_at'] = realMessage.createdAt.toUtc().toIso8601String();
        chatPreview['last_message_sender_id'] = realMessage.sender.id;
        _chatPreviewCache[chatId] = chatPreview;
      }

      unawaited(_saveChatsToCache());
      notifyListeners();
      return true;
    } catch (e) {
      updateTemp(failed.copyWith(isSending: false, sendFailed: true));
      notifyListeners();
      return false;
    }
  }

  void _markOutgoingMessagesReadUpTo(String chatId, DateTime timestamp) {
    if (_currentUser == null) return;
    bool changed = false;
    for (int i = 0; i < _chatMessages.length; i++) {
      final msg = _chatMessages[i];
      if (msg.chatId == chatId &&
          msg.sender.id == _currentUser!.id &&
          !msg.isRead &&
          !msg.createdAt.isAfter(timestamp)) {
        _chatMessages[i] = msg.copyWith(isRead: true);
        changed = true;
      }
    }

    final cached = _chatMessagesCache[chatId];
    if (cached != null) {
      for (int i = 0; i < cached.length; i++) {
        final msg = cached[i];
        if (msg.sender.id == _currentUser!.id && !msg.isRead && !msg.createdAt.isAfter(timestamp)) {
          cached[i] = msg.copyWith(isRead: true);
          changed = true;
        }
      }
    }

    if (changed) {
      unawaited(_saveChatsToCache());
      notifyListeners();
    }
  }

  static const _logTag = 'AppState';
  // Текущий пользователь
  User? _currentUser;
  
  // Голоса пользователя в опросах (pollId -> Set<optionId>)
  final Map<String, Set<String>> _userPollVotes = {};

  Map<String, Set<String>> _groupPollVotes(List<Map<String, dynamic>> pollVotes) {
    final Map<String, Set<String>> groupedVotes = {};
    for (final vote in pollVotes) {
      final pollId = vote['poll_id']?.toString();
      final optionId = vote['option_id']?.toString();
      if (pollId == null || optionId == null) continue;
      groupedVotes.putIfAbsent(pollId, () => <String>{}).add(optionId);
    }
    return groupedVotes;
  }

  void _applyUserPollVotes(
    List<Map<String, dynamic>> pollVotes, {
    bool resetAll = false,
  }) {
    if (resetAll) {
      _userPollVotes.clear();
    }
    if (pollVotes.isEmpty) return;

    final groupedVotes = _groupPollVotes(pollVotes);
    groupedVotes.forEach((pollId, options) {
      _userPollVotes[pollId] = {...options};
    });
  }
  
  // Локализация
  Locale _currentLocale = const Locale('ru', 'RU');
  Locale get currentLocale => _currentLocale;
  
  void setLocale(Locale locale) {
    _currentLocale = locale;
    _saveSettings();
    notifyListeners();
  }

  // Тема приложения удалена - используется только светлая тема
  
  // Состояние загрузки
  bool _isLoading = false;
  bool get isLoading => _isLoading;
  bool _hasEverLoadedPosts = false;
  bool get hasEverLoadedPosts => _hasEverLoadedPosts;
  bool _isOffline = false;
  bool get isOffline => _isOffline;

  String? _lastKnownAuthUserId;
  String? get effectiveCurrentUserId {
    final authId = Supabase.instance.client.auth.currentUser?.id;
    return _currentUser?.id ?? authId ?? _lastKnownAuthUserId;
  }
  
  // Pagination
  bool _isLoadingMore = false;
  bool get isLoadingMore => _isLoadingMore;
  bool _hasMoreData = true;
  bool get hasMoreData => _hasMoreData;
  int _currentPage = 0;
  final int _postsPerPage = 15; // Оптимизировано для быстрой загрузки
  // BUG-007: Cursor для pagination (ID последнего поста)
  String? _lastPostId;
  // Filter state
  FilterType? _currentFilter;
  FilterType? get currentFilter => _currentFilter;
  
  // Данные
  List<Story> _stories = [];
  final Map<String, List<Story>> _userStoriesCache = {};
  final Set<String> _userStoriesLoading = {};
  final Set<String> _userStoriesFullyLoaded = {}; // Все посты пользователя загружены
  Set<String> _likedPostIds = {};
  Set<String> _bookmarkedPostIds = {};
  
  // Дебаунс для _recalculateStoryCommentsCount
  Timer? _commentsCountDebounceTimer;
  final Set<String> _pendingCommentsCountUpdates = {};
  
  // Блокировка от множественных загрузок комментариев
  final Set<String> _loadingComments = {};
  bool _hasLoadedUserData = false;
  bool _hasLoadedLikes = false;
  List<Story> _savedStories = [];
  bool _isSavedStoriesLoading = false;
  List<Story> _likedStories = [];
  bool _isLikedStoriesLoading = false;
  List<Question> _questions = [];
  List<User> _users = [];
  List<User> _recommendedUsers = []; // Кэш рекомендованных пользователей для Supabase
  // Регистр уникальности (персистентный)
  Set<String> _registeredEmails = {};   // нормализованные email (lowercase)
  Set<String> _registeredPhones = {};   // нормализованные телефоны (только цифры, 7XXXXXXXXXX)
  Set<String> _registeredUsernames = {}; // lowercased
  // Загрузка списков
  bool _isNotificationsLoading = false;
  bool _isLoadingMoreNotifications = false;
  bool _hasLoadedNotifications = false;
  bool _hasMoreNotifications = true;
  bool _isChatsLoading = false;
  bool _hasLoadedChats = false;
  int _unreadNotificationsCount = 0;
  int _cachedUnreadMessagesCount = 0;
  // Индикатор "печатает..." по чатам
  final Set<String> _typingChats = {};
  // История поиска
  List<String> _searchHistory = [];
  Set<String> _followedUsers = {};
  Set<String> _pendingFollowRequests = {}; // Заявки на подписку (для закрытых аккаунтов)
  List<Comment> _comments = []; // Список всех комментариев
  final Set<String> _viewedStoryIds = {}; // Защита от повторного инкремента просмотров в рамках сессии
  final Set<String> _loadedPostIds = {}; // Флаг для отслеживания загруженных постов
  final Map<String, bool> _hasMoreComments = {}; // Есть ли ещё комментарии для загрузки
  List<ChatMessage> _chatMessages = []; // Список всех сообщений в чатах
  final Map<String, List<ChatMessage>> _chatMessagesCache = {}; // Кэш сообщений по chatId
  final Map<String, DateTime> _lastPartnerMessageAt = {}; // Последнее сообщение собеседника по chatId
  final Map<String, Map<String, dynamic>> _chatPreviewCache = {}; // Кэш данных чатов
  final Map<String, User> _chatUsersCache = {}; // Кэш собеседников по chatId
  final Map<String, RealtimeChannel> _chatRealtimeChannels = {}; // Realtime каналы по chatId
  final Map<String, RealtimeChannel> _commentsRealtimeChannels = {}; // Realtime каналы комментариев по postId
  RealtimeChannel? _chatListRealtimeChannel;
  RealtimeChannel? _outgoingMessagesRealtimeChannel;
  RealtimeChannel? _notificationsRealtimeChannel;
  final Map<String, String> _userIdToChatId = {}; // Маппинг userId -> chatId для Supabase
  bool _hasLoadedChatCache = false;
  final SupabaseChatService _supabaseChatService = SupabaseChatService();
  final SupabaseNotificationService _supabaseNotificationService = SupabaseNotificationService();
  final SupabaseBlockService _supabaseBlockService = SupabaseBlockService();
  final SupabaseReportService _supabaseReportService = SupabaseReportService();
  final SupabaseCommunityService _supabaseCommunityService = SupabaseCommunityService();
  final SupabaseDiscussionService _supabaseDiscussionService = SupabaseDiscussionService();
  final SupabaseSettingsService _supabaseSettingsService = SupabaseSettingsService();
  List<Community> _communities = []; // Список сообществ
  Set<String> _joinedCommunities = {}; // ID вступленных сообществ
  List<AppNotification> _notifications = []; // Список уведомлений
  String? _notificationFilter;
  Set<String> _blockedUsers = {}; // ID заблокированных пользователей
  List<Report> _reports = []; // Список жалоб
  List<DiscussionTopic> _dialogs = []; // Список диалогов
  List<DialogAnswer> _dialogAnswers = []; // Список ответов в диалогах
  Set<String> _hiddenUsers = {}; // ID скрытых пользователей (не интересно)
  Set<String> _notInterestedPosts = {}; // ID постов, помеченных как "не интересно"
  
    
  // Настройки приватности
  bool _privateAccount = false;
  bool _showOnlineStatus = true;
  bool _showStories = true;
  bool _allowMessages = true;
  bool _showFollowers = true;
  bool _showFollowing = true;
  String _whoCanSeeMyPosts = 'everyone'; // everyone, followers, nobody (BUG-030: код вместо локализированной строки)
  String _whoCanMessageMe = 'everyone'; // everyone, followers, nobody
  
  // Настройки уведомлений
  bool _pushNotifications = true;
  bool _emailNotifications = false;
  bool _likesNotifications = true;
  bool _commentsNotifications = true;
  bool _followsNotifications = true;
  bool _messagesNotifications = true;
  
  // Счетчики непрочитанных
  int get unreadMessagesCount {
    if (!Features.useSupabaseChats) {
      return _chatMessages
          .where((m) => !m.isRead && m.sender.id != currentUser?.id && !m.isDeletedForMe)
          .length;
    }
    return _cachedUnreadMessagesCount;
  }
  
  // Геттер для длины офлайн очереди
  int get offlineQueueLength {
    try {
      final queue = OfflineQueueService();
      return queue.getQueueLength();
    } catch (e) {
      AppLogger.error('Ошибка получения длины очереди', tag: _logTag, error: e);
      return 0;
    }
  }

  // Геттеры настроек
  bool get privateAccount => _privateAccount;
  bool get showOnlineStatus => _showOnlineStatus;
  bool get showStories => _showStories;
  bool get allowMessages => _allowMessages;
  bool get showFollowers => _showFollowers;
  bool get showFollowing => _showFollowing;
  String get whoCanSeeMyPosts => _whoCanSeeMyPosts;
  String get whoCanMessageMe => _whoCanMessageMe;

  /// Может ли текущий пользователь написать пользователю [userId].
  /// Проверяет публично известные настройки приватности из кэша профиля.
  /// Реальная серверная проверка происходит в getOrCreateChat (can_message_user RPC).
  bool canUserMessage(String userId) {
    final user = getUserById(userId);
    if (user == null) return true; // неизвестно — разрешаем, сервер проверит
    // privacy_messages из users таблицы (migration 121): everyone/followers/nobody
    final perm = user.privacyMessages ?? user.whoCanMessage;
    if (perm == null || perm == 'everyone' || perm == 'all') return true;
    if (perm == 'nobody') return false;
    if (perm == 'followers') return followedUsers.contains(userId);
    return true;
  }
  bool get pushNotifications => _pushNotifications;
  bool get emailNotifications => _emailNotifications;
  bool get likesNotifications => _likesNotifications;
  bool get commentsNotifications => _commentsNotifications;
  bool get followsNotifications => _followsNotifications;
  bool get messagesNotifications => _messagesNotifications;
  // BUG-025: showAdultContent — показывать 18+ контент (пользователь старше 18)
  bool get showAdultContent {
    final birthDate = _currentUser?.birthDate;
    if (birthDate == null) return false;
    final age = DateTime.now().difference(birthDate).inDays ~/ 365;
    return age >= 18;
  }

  // Геттеры
  List<Story> get stories {
    // Фильтруем скрытые посты и посты от скрытых/заблокированных пользователей
    final filtered = _stories.where((story) {
      if (_notInterestedPosts.contains(story.id)) return false;
      if (_hiddenUsers.contains(story.author.id)) return false;
      if (_blockedUsers.contains(story.author.id)) return false;
      return true;
    }).toList();

    return filtered;
  }
  List<Story> get allStories => _stories; // Все посты без фильтрации
  
  // Получить актуальную Story по ID (для обновления счётчиков)
  Story? getStoryById(String storyId) {
    try {
      return _stories.firstWhere((s) => s.id == storyId);
    } catch (e) {
      return null;
    }
  }
  List<Story> get savedStories => Features.useSupabasePosts ? _savedStories : _stories.where((s) => s.isBookmarked).toList();
  List<Story> get likedStories => Features.useSupabasePosts ? _likedStories : _stories.where((s) => s.isLiked).toList();
  bool get isSavedStoriesLoading => _isSavedStoriesLoading;
  bool get isLikedStoriesLoading => _isLikedStoriesLoading;
  List<Question> get questions => List.unmodifiable(_questions);
  List<User> get users => _users;
  List<Comment> get allComments => _comments;
  User? get currentUser => _currentUser;
  bool get isNotificationsLoading => _isNotificationsLoading;
  bool get hasLoadedNotifications => _hasLoadedNotifications;
  bool get isChatsLoading => _isChatsLoading;
  bool get hasLoadedChats => _hasLoadedChats;
  List<String> get searchHistory => _searchHistory;
  bool isChatTyping(String chatId) => _typingChats.contains(chatId);
  Set<String> get followedUsers => _followedUsers;
  Set<String> get pendingFollowRequests => _pendingFollowRequests;
  Set<String> get blockedUsers => _blockedUsers;
  List<AppNotification> get notifications => _notifications;
  bool get hasBookmarkedMessages => _chatMessages.any((m) => m.isBookmarked && !m.isDeletedForMe);
  List<ChatMessage> getAllBookmarkedMessages() {
    return _chatMessages
        .where((m) => m.isBookmarked && !m.isDeletedForMe)
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }
  List<AppNotification> get filteredNotifications {
    final List<AppNotification> base;
    if (_notificationFilter == null || _notificationFilter == 'all') {
      base = List<AppNotification>.from(_notifications);
    } else {
      base = _notifications.where((n) => n.type.name == _notificationFilter).toList();
    }
    // Фильтруем уведомления от заблокированных пользователей
    base.removeWhere((n) => n.fromUser != null && _blockedUsers.contains(n.fromUser!.id));
    base.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return base;
  }
  void setNotificationFilter(String? filter) {
    if (_notificationFilter == filter) return;
    _notificationFilter = filter;
    notifyListeners();
  }
  bool get isLoadingMoreNotifications => _isLoadingMoreNotifications;
  bool get hasMoreNotifications => _hasMoreNotifications;
  String? get notificationFilter => _notificationFilter;
  int get unreadNotificationsCount => _unreadNotificationsCount;
  List<DiscussionTopic> get dialogs => _dialogs;
  List<DialogAnswer> get dialogAnswers => _dialogAnswers;
  List<User> get blockedUsersList {
    final blockedList = <User>[];
    for (final userId in _blockedUsers) {
      // Ищем в загруженных пользователях
      final user = _users.firstWhere(
        (u) => u.id == userId,
        orElse: () => User(
          id: userId,
          name: 'Пользователь',
          username: 'user',
          avatar: '',
          isPremium: false,
          karma: 0,
          isBlocked: true,
        ),
      );
      blockedList.add(user);
    }
    return blockedList;
  }
  List<User> get hiddenUsersList => _users.where((u) => _hiddenUsers.contains(u.id)).toList();
  Set<String> get notInterestedPosts => _notInterestedPosts;

  // Реализация метода из mixin
  @override
  void setCurrentUserFromSupabase(User user) {
    final previousUserId = _currentUser?.id;
    setCurrentUser(user);

    // Важно: при смене аккаунта сбрасываем user-specific кеши,
    // иначе _likedPostIds может протечь между аккаунтами.
    if (previousUserId != null && previousUserId.isNotEmpty && previousUserId != user.id) {
      _likedPostIds.clear();
      _bookmarkedPostIds.clear();
      _hasLoadedLikes = false;
    }
    _loadUserDataAsync(force: true);
    
    // Загружаем посты если они ещё не загружены
    if (Features.useSupabasePosts && _stories.isEmpty && !_isLoading) {
      unawaited(_loadInitialPosts());
    }
  }

  List<String> _splitTextIntoParts(String text, int maxCharsPerPart) {
    // BUG-035: проверка на пустую строку и разбиение по границам слов
    if (text.isEmpty) return [text];
    if (text.length <= maxCharsPerPart) return [text];

    final List<String> parts = [];
    int start = 0;
    while (start < text.length) {
      int end = start + maxCharsPerPart;
      if (end >= text.length) {
        parts.add(text.substring(start).trim());
        break;
      }
      // Ищем границу слова (пробел) назад от end
      int splitAt = end;
      while (splitAt > start && text[splitAt] != ' ' && text[splitAt] != '\n') {
        splitAt--;
      }
      // Если пробел не найден — жёстко разбиваем по maxCharsPerPart
      if (splitAt == start) splitAt = end;
      final part = text.substring(start, splitAt).trim();
      if (part.isNotEmpty) parts.add(part);
      start = splitAt + 1;
    }
    return parts.isEmpty ? [text] : parts;
  }

  // ============================================
  // УВЕДОМЛЕНИЯ
  // ============================================

  // BUG-023: обновляем badge иконки приложения при изменении счётчика непрочитанных
  void _updateBadgeCount(int count) {
    _unreadNotificationsCount = count;
    unawaited(NotificationService().setBadgeCount(count));
  }

  /// Загрузить уведомления
  Future<void> loadNotifications({bool loadMore = false}) async {
    if (!Features.useSupabaseNotifications || !Features.useSupabaseUsers) return;
    
    final startUserId = effectiveCurrentUserId;

    // Если пользователь не загружен - завершаем загрузку без ошибки
    if (startUserId == null || startUserId.isEmpty) {
      AppLogger.warning('[NOTIF] loadNotifications: userId пустой, пропускаем', tag: _logTag);
      _isNotificationsLoading = false;
      _hasLoadedNotifications = true;
      notifyListeners();
      return;
    }

    if (loadMore) {
      if (_isLoadingMoreNotifications || !_hasMoreNotifications || _notifications.isEmpty) {
        return;
      }
      _isLoadingMoreNotifications = true;
    } else {
      // Если уже загружаем — не запускаем повторно (избегаем дублей)
      if (_isNotificationsLoading) {
        AppLogger.info('[NOTIF] loadNotifications: уже загружается, пропускаем', tag: _logTag);
        return;
      }
      _isNotificationsLoading = true;
      _hasMoreNotifications = true;
    }
    AppLogger.info('[NOTIF] loadNotifications: userId=$startUserId loadMore=$loadMore', tag: _logTag);
    notifyListeners();

    try {
      final before = loadMore && _notifications.isNotEmpty
          ? _notifications.last.createdAt
          : null;

      List<Map<String, dynamic>> data;
      int retryCount = 0;
      const maxRetries = 3;
      
      while (true) {
        try {
          data = await _supabaseNotificationService.getNotifications(
            startUserId,
            before: before,
          );
          break; // Success
        } catch (e) {
          retryCount++;
          final errorText = e.toString();
          final isNetworkError = errorText.contains('Failed host lookup') ||
              errorText.contains('SocketException') ||
              errorText.contains('AuthRetryableFetchException') ||
              errorText.contains('ClientException') ||
              errorText.contains('Software caused connection abort') ||
              errorText.contains('Connection refused') ||
              errorText.contains('Network is unreachable') ||
              errorText.contains('TimeoutException') ||
              errorText.contains('Connection reset');
              
          if (!isNetworkError || retryCount >= maxRetries) {
            rethrow; // Not network error or max retries reached
          }
          
          AppLogger.warning('[NOTIF] Retry $retryCount/$maxRetries после сетевой ошибки: $errorText', tag: _logTag);
          await Future.delayed(Duration(milliseconds: 500 * retryCount)); // Exponential backoff
        }
      }

      if (effectiveCurrentUserId != startUserId) {
        return;
      }

      AppLogger.info('[NOTIF] Загружено ${data.length} записей из БД', tag: _logTag);
      final fetched = data.map(_mapSupabaseNotification).toList();
      AppLogger.info('[NOTIF] Отображено ${fetched.length} уведомлений. Типы: ${fetched.map((n) => n.type.name).toSet()}', tag: _logTag);

      if (loadMore) {
        for (final notif in fetched) {
          if (_notifications.every((existing) => existing.id != notif.id)) {
            _notifications.add(notif);
          }
        }
      } else {
        // Сохраняем временные push-уведомления (id начинается с temp_)
        final tempNotifications = _notifications.where((n) => n.id.startsWith('temp_')).toList();
        _notifications = fetched;
        // Добавляем временные уведомления обратно в начало
        _notifications.insertAll(0, tempNotifications);
      }

      _notifications.sort((a, b) => b.createdAt.compareTo(a.createdAt));

      if (fetched.length < SupabaseNotificationService.defaultLimit) {
        _hasMoreNotifications = false;
      }

      if (!loadMore) {
        _updateBadgeCount(await _supabaseNotificationService.getUnreadCount(startUserId));
        if (effectiveCurrentUserId != startUserId) {
          return;
        }
        _hasLoadedNotifications = true;
        unawaited(_subscribeToNotificationsRealtime());
      }

      await _saveNotifications();
      _isOffline = false;
    } catch (e) {
      final errorText = e.toString();
      final isNetworkError = errorText.contains('Failed host lookup') ||
          errorText.contains('SocketException') ||
          errorText.contains('AuthRetryableFetchException') ||
          errorText.contains('ClientException') ||
          errorText.contains('Software caused connection abort') ||
          errorText.contains('Connection refused') ||
          errorText.contains('Network is unreachable') ||
          errorText.contains('TimeoutException') ||
          errorText.contains('Connection reset');
      if (isNetworkError) {
        AppLogger.warning('[NOTIF] Сетевая ошибка при загрузке уведомлений: $errorText', tag: _logTag);
      } else {
        AppLogger.error('Ошибка загрузки уведомлений', tag: _logTag, error: e);
      }
      _isOffline = true;
    } finally {
      if (loadMore) {
        _isLoadingMoreNotifications = false;
      } else {
        _isNotificationsLoading = false;
      }
      notifyListeners();
    }
  }

  /// Добавить уведомление из push-данных в список мгновенно (без ожидания БД)
  void addNotificationFromPush(Map<String, dynamic> data) {
    if (_currentUser == null) return;
    
    try {
      final type = data['type'] as String?;
      if (type == null || type.isEmpty) return;
      
      // Пропускаем сообщения чатов — они обрабатываются отдельно
      if (type == 'chat_message' || type == 'message') return;
      
      // Создаём временное уведомление из push данных
      final tempId = 'temp_${DateTime.now().millisecondsSinceEpoch}';
      final now = DateTime.now();
      
      // Маппинг типов из push в NotificationType
      final notificationType = _mapNotificationType(type);
      
      // Загружаем данные актора если есть from_user_id
      User? actor;
      final fromUserId = data['from_user_id'] as String?;
      if (fromUserId != null) {
        actor = _users.firstWhere((u) => u.id == fromUserId, orElse: () => User(
          id: fromUserId,
          name: data['actor_name'] as String? ?? 'Пользователь',
          username: data['actor_username'] as String? ?? 'user',
          avatar: data['actor_avatar'] as String? ?? '',
          isPremium: false,
          karma: 0,
        ));
      }
      
      // Собираем уведомление
      final notification = AppNotification(
        id: tempId,
        type: notificationType,
        fromUser: actor,
        title: data['title'] as String? ?? getLocalizedNotificationTitle(type),
        message: data['body'] as String? ?? data['message'] as String? ?? '',
        createdAt: now,
        isRead: false,
        relatedId: data['post_id'] as String? ?? data['discussion_id'] as String? ?? '',
        commentText: data['comment_text'] as String?,
      );
      
      // Добавляем в начало списка
      _notifications.insert(0, notification);
      
      // Обновляем badge count
      _updateBadgeCount((_badgeCount ?? 0) + 1);
      
      notifyListeners();
      
      AppLogger.info('[PUSH-UI] Добавлено уведомление в state: type=$type from=${actor?.name}', tag: _logTag);
      
    } catch (e, st) {
      AppLogger.error('[PUSH-UI] Ошибка добавления уведомления из push', tag: _logTag, error: e, stackTrace: st);
    }
  }

  Future<void> loadMoreNotifications() async {
    await loadNotifications(loadMore: true);
  }

  Future<void> _fetchUserStories(String userId, {bool force = false}) async {
    if (_userStoriesLoading.contains(userId)) return;
    if (!force && _userStoriesCache.containsKey(userId)) return;

    _setUserStoriesLoading(userId, true);
    // НЕ вызываем notifyListeners() здесь - это вызывает ошибку во время build
    // notifyListeners();

    try {
      // Если force=true - очищаем кэш полностью перед загрузкой
      if (force) {
        _userStoriesCache.remove(userId);
        _userStoriesFullyLoaded.remove(userId); // Сбрасываем флаг полной загрузки
        AppLogger.info('Кэш постов пользователя $userId очищен (force=true)', tag: _logTag);
      }
      
      final postService = SupabasePostService();
      final posts = await postService.getUserPosts(userId, page: 0, limit: 10);

      // BUG-022: используем кэш лайков/закладок вместо перезагрузки при каждом открытии профиля
      final Set<String> likedPostIds = _hasLoadedLikes ? _likedPostIds : {};
      final Set<String> bookmarkedPostIds = _hasLoadedLikes ? _bookmarkedPostIds : {};

      final processedStories = posts.map((postData) {
        final normalizedPost = Map<String, dynamic>.from(postData);
        final rawAuthor = postData['users'];
        if (rawAuthor is Map) {
          final author = Map<String, dynamic>.from(rawAuthor);
          normalizedPost['author'] = {
            'id': author['id'],
            'name': author['full_name'] ?? author['username'] ?? 'Пользователь',
            'username': author['username'] ?? 'user',
            'avatar': author['avatar_url'] ?? '',
            'is_verified': author['is_verified'] ?? false,
            'followers_count': author['followers_count'] ?? 0,
            'following_count': author['following_count'] ?? 0,
            'posts_count': author['posts_count'] ?? 0,
            'role': author['role'] ?? 'user',
            'premium_expires_at': author['premium_expires_at'],
          };
        }
        final story = Story.fromJson(normalizedPost);
        // Восстанавливаем состояние лайков/закладок из кэша
        return story.copyWith(
          isLiked: likedPostIds.contains(story.id),
          isBookmarked: bookmarkedPostIds.contains(story.id),
        );
      }).cast<Story>().toList();

      _userStoriesCache[userId] = processedStories;

      // Если постов нет - не пытаемся загружать больше
      if (posts.isEmpty) {
        _userStoriesFullyLoaded.add(userId);
      }

      notifyListeners();
    } catch (e, st) {
      AppLogger.error('Ошибка загрузки постов пользователя $userId', tag: _logTag, error: e, stackTrace: st);
      _userStoriesCache[userId] = [];
      _userStoriesFullyLoaded.add(userId);
      notifyListeners();
    } finally {
      _setUserStoriesLoading(userId, false);
    }
  }

  // Загрузить больше постов пользователя (пагинация)
  Future<void> loadMoreUserStories(String userId) async {
    if (_userStoriesLoading.contains(userId)) return;
    
    final cachedStories = _userStoriesCache[userId] ?? [];
    final currentPage = (cachedStories.length / 10).floor();
    
    _setUserStoriesLoading(userId, true);

    try {
      final postService = SupabasePostService();
      final posts = await postService.getUserPosts(userId, page: currentPage, limit: 10);
      
      if (posts.isEmpty) {
        _userStoriesFullyLoaded.add(userId); // Отмечаем что все посты загружены
        notifyListeners(); // Обновляем UI чтобы скрыть кнопку "Загрузить еще"
        return;
      }

      // BUG-018: используем кэш лайков/закладок — не перезагружаем при каждой пагинации профиля
      final Set<String> likedPostIds = _hasLoadedLikes ? _likedPostIds : {};
      final Set<String> bookmarkedPostIds = _hasLoadedLikes ? _bookmarkedPostIds : {};

      final stories = <Story>[];
      for (final post in posts) {
        final story = await _mapSupabasePostToStoryWithLikes(post, likedPostIds, bookmarkedPostIds);
        stories.add(story);
      }

      // Пересчитываем счётчики комментариев для постов, у которых уже загружены комментарии
      for (final story in stories) {
        if (_loadedPostIds.contains(story.id)) {
          final storyIndex = stories.indexOf(story);
          final commentCount = _comments.where((c) => c.storyId == story.id).length;
          stories[storyIndex] = story.copyWith(comments: commentCount);
        }
      }

      // Добавляем новые посты к существующим
      _userStoriesCache[userId] = [...cachedStories, ...stories];
      notifyListeners(); // Обновляем UI чтобы показать новые посты
    } catch (e) {
      AppLogger.error('Ошибка загрузки дополнительных постов пользователя $userId', tag: _logTag, error: e);
    } finally {
      _setUserStoriesLoading(userId, false);
    }
  }

  // Загрузить ВСЕ посты пользователя для аналитики
  Future<List<Story>> loadAllUserStoriesForAnalytics(String userId) async {
    // Если уже полностью загружены — возвращаем кэш
    if (_userStoriesFullyLoaded.contains(userId)) {
      return _userStoriesCache[userId] ?? [];
    }
    
    // Сначала убедимся что первая страница загружена
    if (!_userStoriesCache.containsKey(userId) || _userStoriesCache[userId]!.isEmpty) {
      await _fetchUserStories(userId, force: true);
    }
    
    // Загружаем все посты пагинацией с защитой от бесконечного цикла
    int maxIterations = 50; // Максимум 500 постов (50 * 10)
    while (!_userStoriesFullyLoaded.contains(userId) && maxIterations > 0) {
      final beforeCount = _userStoriesCache[userId]?.length ?? 0;
      await loadMoreUserStories(userId);
      final afterCount = _userStoriesCache[userId]?.length ?? 0;
      
      // Если количество не изменилось — выходим
      if (afterCount == beforeCount) {
        _userStoriesFullyLoaded.add(userId);
        break;
      }
      maxIterations--;
    }
    
    return _userStoriesCache[userId] ?? [];
  }

  Future<void> _ensureInteractionSetsLoaded() async {
    if (_hasLoadedLikes || _currentUser == null) return;
    try {
      final postService = SupabasePostService();
      final userId = _currentUser!.id;
      
      final userLikes = await postService.getUserLikes(userId);
      _likedPostIds = userLikes.map((like) => like['post_id'] as String).toSet();
      
      final userBookmarks = await postService.getUserBookmarks(userId);
      _bookmarkedPostIds = userBookmarks.toSet();
      
      final pollVotes = await postService.getUserPollVotes(userId);
      for (final vote in pollVotes) {
        final pollId = vote['poll_id']?.toString();
        final optionId = vote['option_id']?.toString();
        if (pollId != null && optionId != null) {
          _userPollVotes[pollId] ??= {};
          _userPollVotes[pollId]!.add(optionId);
        }
      }
      _hasLoadedLikes = true;
      // Кэшируем для быстрого старта при следующем запуске
      _cacheInteractionIds(userId);
    } catch (e) {
      // Ignore interaction load errors
    }
  }

  Future<void> _cacheInteractionIds(String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('liked_ids_$userId', _likedPostIds.toList());
      await prefs.setStringList('bookmarked_ids_$userId', _bookmarkedPostIds.toList());
    } catch (_) {}
  }

  void _updateStoryInUserCaches(Story story) {
    final authorId = story.author.id;
    final cachedStories = _userStoriesCache[authorId];
    if (cachedStories == null) return;

    final index = cachedStories.indexWhere((s) => s.id == story.id);
    if (index != -1) {
      // Создаем новый список чтобы гарантированно обновить UI
      final newStories = List<Story>.from(cachedStories);
      newStories[index] = story;
      _userStoriesCache[authorId] = newStories;
    }
  }

  void _updateSavedStoriesWith(Story story) {
    if (!Features.useSupabasePosts) return;
    final stories = List<Story>.from(_savedStories);
    final index = stories.indexWhere((s) => s.id == story.id);

    if (story.isBookmarked) {
      if (index != -1) {
        stories[index] = story;
      } else {
        stories.insert(0, story);
      }
      _savedStories = stories;
    } else if (index != -1) {
      stories.removeAt(index);
      _savedStories = stories;
    }
  }

  void _updateLikedStoriesWith(Story story) {
    if (!Features.useSupabasePosts) return;
    final stories = List<Story>.from(_likedStories);
    final index = stories.indexWhere((s) => s.id == story.id);

    if (story.isLiked) {
      if (index != -1) {
        stories[index] = story;
      } else {
        stories.insert(0, story);
      }
      _likedStories = stories;
    } else if (index != -1) {
      stories.removeAt(index);
      _likedStories = stories;
    }
  }

  NotificationType _mapNotificationType(String type) {
    switch (type) {
      case 'like':
        return NotificationType.like;
      case 'comment_like':
        return NotificationType.commentLike;
      case 'comment':
        return NotificationType.comment;
      case 'reply':
        return NotificationType.reply;
      case 'follow':
        return NotificationType.follow;
      case 'mention':
        return NotificationType.mention;
      case 'repost':
        return NotificationType.repost;
      case 'system':
        return NotificationType.system;
      case 'premium':
        return NotificationType.premium;
      case 'community':
        return NotificationType.community;
      case 'email_change':
        return NotificationType.emailChange;
      // Уведомления для дебатов
      case 'debate_comment':
        return NotificationType.debateComment;
      case 'debate_reply':
        return NotificationType.debateReply;
      case 'debate_like':
        return NotificationType.debateLike;
      case 'debate_vote':
        return NotificationType.debateVote;
      default:
        AppLogger.warning('[NOTIF] Неизвестный тип уведомления: "$type" — маппим в system', tag: _logTag);
        return NotificationType.system;
    }
  }

  String _getNotificationTitle(String type) {
    // Возвращаем тип для последующей локализации в UI
    return type;
  }
  
  // Публичный метод для преобразования NotificationType в строку типа
  String notificationTypeToString(NotificationType type) {
    switch (type) {
      case NotificationType.like:
        return 'like';
      case NotificationType.commentLike:
        return 'comment_like';
      case NotificationType.comment:
        return 'comment';
      case NotificationType.reply:
        return 'reply';
      case NotificationType.follow:
        return 'follow';
      case NotificationType.mention:
        return 'mention';
      case NotificationType.repost:
        return 'repost';
      case NotificationType.system:
        return 'system';
      case NotificationType.premium:
        return 'premium';
      case NotificationType.community:
        return 'community';
      case NotificationType.emailChange:
        return 'email_change';
      case NotificationType.debateComment:
        return 'debate_comment';
      case NotificationType.debateReply:
        return 'debate_reply';
      case NotificationType.debateLike:
        return 'debate_like';
      case NotificationType.debateVote:
        return 'debate_vote';
    }
  }
  
  // Публичный метод для получения локализованного заголовка уведомления по NotificationType
  String getLocalizedNotificationTitleByType(BuildContext context, NotificationType type) {
    return getLocalizedNotificationTitle(context, notificationTypeToString(type));
  }
  
  // Публичный метод для получения локализованного заголовка уведомления
  String getLocalizedNotificationTitle(BuildContext context, String type) {
    final loc = AppLocalizations.of(context);
    switch (type) {
      case 'like':
        return loc.notifNewLike;
      case 'comment_like':
        return loc.notifCommentLike;
      case 'comment':
        return loc.notifNewComment;
      case 'reply':
        return loc.notifNewReply;
      case 'follow':
        return loc.notifNewFollower;
      case 'mention':
        return loc.notifMention;
      case 'repost':
        return loc.notifRepost;
      case 'system':
        return loc.notifSystem;
      case 'premium':
        return loc.notifPremium;
      case 'community':
        return loc.notifCommunity;
      case 'email_change':
        return loc.notifEmailChange;
      case 'debate_comment':
        return loc.notifDebateComment;
      case 'debate_reply':
        return loc.notifDebateReply;
      case 'debate_like':
        return loc.notifDebateLike;
      case 'debate_vote':
        return 'Голос в дебате';
      default:
        return loc.notifDefault;
    }
  }

  String _getNotificationMessage(String type, String? text, {String? commentText}) {
    // Сохраняем оригинальный текст для последующей локализации в UI
    return text ?? '';
  }
  
  // Публичный метод для получения локализованного сообщения уведомления
  String getLocalizedNotificationMessage(BuildContext context, String type, String? text, {String? commentText}) {
    final loc = AppLocalizations.of(context);
    
    // Для сгруппированных уведомлений добавляем локализованный текст
    if (text != null && !text.contains(' ')) {
      // Если text содержит только имена (без пробелов в конце), добавляем локализованный текст
      if (type == 'like' || type == 'debate_like') {
        return '$text ${loc.likedYourPost}';
      } else if (type == 'follow') {
        return '$text ${loc.followedYou}';
      }
    }
    
    // Для текстов с +N (например "User1, User2 +3")
    if (text != null && text.contains('+')) {
      if (type == 'like' || type == 'debate_like') {
        return '$text ${loc.likedYourPost}';
      } else if (type == 'follow') {
        return '$text ${loc.followedYou}';
      }
    }
    
    switch (type) {
      case 'like':
        return loc.notifMsgLikedPost;
      case 'comment_like':
        return loc.notifMsgLikedComment;
      case 'comment':
        if (commentText != null && commentText.isNotEmpty) {
          return loc.notifMsgCommented.replaceFirst('{text}', commentText);
        }
        return loc.notifMsgCommentedPost;
      case 'reply':
        if (commentText != null && commentText.isNotEmpty) {
          return loc.notifMsgReplied.replaceFirst('{text}', commentText);
        }
        return loc.notifMsgRepliedComment;
      case 'follow':
        return loc.notifMsgFollowed;
      case 'mention':
        return loc.notifMsgMentioned;
      case 'repost':
        return loc.notifMsgReposted;
      case 'debate_comment':
        if (commentText != null && commentText.isNotEmpty) {
          return loc.notifMsgDebateCommented.replaceFirst('{text}', commentText);
        }
        return loc.notifMsgDebateCommentedSimple;
      case 'debate_reply':
        if (commentText != null && commentText.isNotEmpty) {
          return loc.notifMsgDebateReplied.replaceFirst('{text}', commentText);
        }
        return text ?? loc.notifMsgDebateRepliedSimple;
      case 'debate_like':
        return loc.notifMsgDebateLiked;
      case 'debate_vote':
        return 'Проголосовал(а) в вашем дебате';
      default:
        return text ?? '';
    }
  }

  /// Пометить уведомление как прочитанное
  Future<void> markNotificationAsRead(String notificationId) async {
    if (!Features.useSupabaseNotifications || !Features.useSupabaseUsers) {
      return;
    }

    final userId = effectiveCurrentUserId;
    if (userId == null || userId.isEmpty) {
      return;
    }

    try {
      await _supabaseNotificationService.markAsRead(notificationId);

      final index = _notifications.indexWhere((n) => n.id == notificationId);
      if (index != -1) {
        _notifications[index] = _notifications[index].copyWith(isRead: true);
        _updateBadgeCount(await _supabaseNotificationService.getUnreadCount(userId));
        await _saveNotifications();
        notifyListeners();
      }
    } catch (e) {
      AppLogger.error('Ошибка пометки уведомления как прочитанного', tag: _logTag, error: e);
    }
  }

  /// Пометить все уведомления как прочитанные
  Future<void> markAllNotificationsAsRead() async {
    if (!Features.useSupabaseNotifications || !Features.useSupabaseUsers) {
      return;
    }

    final userId = effectiveCurrentUserId;
    if (userId == null || userId.isEmpty) {
      return;
    }

    final previousNotifications = List<AppNotification>.from(_notifications);
    final previousUnreadCount = _unreadNotificationsCount;

    try {
      // Сразу обновляем локально — UX как у соцсетей: открыл экран → бейдж исчез
      _notifications = _notifications.map((n) => n.copyWith(isRead: true)).toList();
      _updateBadgeCount(0);
      notifyListeners();

      await _supabaseNotificationService.markAllAsRead(userId);

      _updateBadgeCount(await _supabaseNotificationService.getUnreadCount(userId));
      await _saveNotifications();
      notifyListeners();
    } catch (e) {
      AppLogger.error('Ошибка пометки всех уведомлений как прочитанных', tag: _logTag, error: e);
      _notifications = previousNotifications;
      _updateBadgeCount(previousUnreadCount);
      notifyListeners();
    }
  }

  /// Удалить уведомление
  Future<void> deleteNotification(String notificationId) async {
    if (!Features.useSupabaseNotifications || !Features.useSupabaseUsers) return;

    try {
      final notificationService = SupabaseNotificationService();
      await notificationService.deleteNotification(notificationId);

      // Удаляем локально
      final wasUnread = _notifications
          .firstWhere((n) => n.id == notificationId, orElse: () => AppNotification.empty())
          .isRead == false;
      _notifications.removeWhere((n) => n.id == notificationId);
      if (wasUnread) {
        _updateBadgeCount((_unreadNotificationsCount - 1).clamp(0, 9999));
      }
      await _saveNotifications();
      notifyListeners();
    } catch (e) {
      AppLogger.error('Ошибка удаления уведомления', tag: _logTag, error: e);
    }
  }

  // Очистить данные пользователя при выходе
  void clearUserData() {
    if (_notificationsRealtimeChannel != null) {
      unawaited(_supabaseNotificationService.unsubscribe(_notificationsRealtimeChannel!));
      _notificationsRealtimeChannel = null;
    }
    if (_chatListRealtimeChannel != null) {
      unawaited(_supabaseChatService.unsubscribe(_chatListRealtimeChannel!));
      _chatListRealtimeChannel = null;
    }
    if (_outgoingMessagesRealtimeChannel != null) {
      unawaited(_supabaseChatService.unsubscribe(_outgoingMessagesRealtimeChannel!));
      _outgoingMessagesRealtimeChannel = null;
    }
    _currentUser = null;
    resetSupabaseProfile();
    _stories = [];
    _userStoriesCache.clear();
    _userStoriesLoading.clear();
    _userStoriesFullyLoaded.clear();
    _likedPostIds.clear();
    CacheService().clearAll();
    _bookmarkedPostIds.clear();
    
    // BUG-013: Очищаем историю поиска при logout
    _searchHistory.clear();
    unawaited(clearSearchHistory());
    
    // Очищаем SharedPreferences от данных профиля
    unawaited(_clearUserPreferences());
    _hasLoadedLikes = false;
    _savedStories = [];
    _likedStories = [];
    _isSavedStoriesLoading = false;
    _isLikedStoriesLoading = false;
    _questions = [];
    _users = [];
    _followedUsers.clear();
    _notifications.clear();
    _chatMessages.clear();
    _chatMessagesCache.clear();
    _chatPreviewCache.clear();
    _chatUsersCache.clear();
    _userIdToChatId.clear();
    _viewedStoryIds.clear();
    unsubscribeFromAllChats();
    _hasLoadedChatCache = false;
    _hasLoadedUserData = false;
    _notInterestedPosts.clear();
    _hiddenUsers.clear();
    _blockedUsers.clear();
    _pendingFollowRequests.clear();
    unawaited(_clearChatCache());
    // BUG-034: очищаем офлайн-очередь чтобы действия одного пользователя
    // не синхронизировались под другим после смены аккаунта
    unawaited(OfflineQueueService().clearQueue());
    notifyListeners();
  }

  /// Очистить SharedPreferences от данных профиля
  Future<void> _clearUserPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('user_city');
      await prefs.remove('user_bio');
      await prefs.remove('user_website');
      await prefs.remove('user_website_text');
      await prefs.remove('last_known_auth_user_id');
      AppLogger.info('SharedPreferences очищены', tag: _logTag);
    } catch (e) {
      AppLogger.error('Ошибка очистки SharedPreferences', tag: _logTag, error: e);
    }
  }

  // Установить текущего пользователя
  void setCurrentUser(User user) {
    _currentUser = user;

    if (user.id.isNotEmpty) {
      _lastKnownAuthUserId = user.id;
      unawaited(_saveLastKnownAuthUserId(user.id));
      
      // Проверяем Premium статус при входе
      unawaited(SupabaseAuthService().checkAndUpdatePremiumStatus(user.id));
      
      // Синхронизируем FCM токен с Supabase
      unawaited(FirebaseNotificationService.syncFCMToken());
    }
    
    // Загружаем локальные поля профиля сразу (profileColor, city, bio, website)
    _loadProfileFieldsLocally().then((fields) {
      if (_currentUser == null) return;
      final profileColor = fields['profileColor'] as String?;
      final city = fields['city'] as String?;
      final bio = fields['bio'] as String?;
      final website = fields['website'] as String?;
      final websiteText = fields['websiteText'] as String?;
      
      bool needsUpdate = false;
      User updated = _currentUser!;
      
      if (profileColor != null && updated.profileColor != profileColor) {
        updated = updated.copyWith(profileColor: profileColor);
        needsUpdate = true;
      }
      if (city != null && updated.city != city) {
        updated = updated.copyWith(city: city);
        needsUpdate = true;
      }
      if (bio != null && updated.bio != bio) {
        updated = updated.copyWith(bio: bio);
        needsUpdate = true;
      }
      if (website != null && updated.website != website) {
        updated = updated.copyWith(website: website);
        needsUpdate = true;
      }
      if (websiteText != null && updated.websiteText != websiteText) {
        updated = updated.copyWith(websiteText: websiteText);
        needsUpdate = true;
      }
      
      if (needsUpdate) {
        _currentUser = updated;
        notifyListeners();
      } else {
        // Всегда уведомляем, чтобы UI обновился с локальными полями
        notifyListeners();
      }
    });
    
    // Обновляем в списке пользователей
    final index = _users.indexWhere((u) => u.id == 'current_user');
    if (index != -1) {
      _users[index] = user;
    } else {
      _users.insert(0, user);
    }
    
    // Обновляем автора во всех постах текущего пользователя
    for (var i = 0; i < _stories.length; i++) {
      if (_stories[i].author.id == 'current_user' || _stories[i].author.id == user.id) {
        _stories[i] = Story(
          id: _stories[i].id,
          text: _stories[i].text,
          author: user, // Обновляем автора
          createdAt: _stories[i].createdAt,
          likes: _stories[i].likes,
          comments: _stories[i].comments,
          reposts: _stories[i].reposts,
          views: _stories[i].views,
          isLiked: _stories[i].isLiked,
          isBookmarked: _stories[i].isBookmarked,
          media: _stories[i].media,
          poll: _stories[i].poll,
          isAnonymous: _stories[i].isAnonymous,
          parts: _stories[i].parts,
        );
      }
    }
    
    // Обновляем автора во всех комментариях текущего пользователя
    for (var i = 0; i < _comments.length; i++) {
      if (_comments[i].author.id == 'current_user' || _comments[i].author.id == user.id) {
        _comments[i] = _comments[i].copyWith(author: user);
      }
    }
    
    notifyListeners();

    if (Features.useSupabaseUsers) {
      unawaited(_syncFcmToken());
    }

    if (Features.useSupabaseNotifications && Features.useSupabaseUsers) {
      unawaited(loadNotifications());
    }

    if (Features.useSupabasePosts) {
      // После авторизации подгружаем лайкнутые и сохранённые посты
      unawaited(loadLikedPosts());
      unawaited(loadBookmarkedPosts());
    }
  }

  // BUG-009: Connectivity listener для автоматического обновления после reconnect
  StreamSubscription<ConnectivityResult>? _connectivitySubscription;
  
  // Инициализация данных (оптимизированная)
  Future<void> initializeData() async {
    await _loadLastKnownAuthUserId();
    await _loadPendingCommentsFromCache();
    await _loadPendingCommentLikesFromCache();
    
    // Проверяем существование пользователя в БД
    if (Features.useSupabaseAuth || Features.useSupabaseUsers) {
      final session = Supabase.instance.client.auth.currentSession;
      if (session != null) {
        try {
          final userId = session.user.id;
          final userExists = await Supabase.instance.client
              .from('users')
              .select('id')
              .eq('id', userId)
              .maybeSingle()
              .timeout(const Duration(seconds: 5));
          
          if (userExists == null) {
            // Пользователь удален из БД - выходим
            AppLogger.warning('[AUTH] LOGOUT: пользователь удалён из БД при инициализации', tag: _logTag);
            await Supabase.instance.client.auth.signOut();
            throw Exception('User deleted from database');
          }
        } catch (e) {
          final errStr = e.toString();
          if (errStr.contains('User deleted from database')) rethrow;
          // При таймауте или сетевой ошибке — НЕ делаем logout
          // Сессия локально валидна, продолжаем без проверки БД
          AppLogger.warning('[AUTH] Проверка БД при инициализации не удалась (сеть?), продолжаем: $errStr', tag: _logTag);
        }
      }
    }
    
    // BUG-009: Инициализируем connectivity listener
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen((result) {
      if (result != ConnectivityResult.none && _isOffline) {
        // Сеть восстановилась - сбрасываем offline флаг и обновляем данные
        AppLogger.info('Сеть восстановлена, обновляем данные', tag: _logTag);
        _isOffline = false;
        
        // Автоматически обновляем ленту при восстановлении сети
        if (_hasEverLoadedPosts && _currentUser != null) {
          unawaited(refreshFeed());
        }
        
        // Обновляем уведомления
        if (_hasLoadedNotifications && _currentUser != null) {
          unawaited(loadNotifications());
        }
      }
    });
    
    // ВАЖНО: Загружаем язык СРАЗУ при старте, до загрузки пользователя
    await _loadSettingsFromPrefs(localeOnly: true);

    if (Features.useSupabaseUsers || Features.useSupabaseAuth) {
      _users = [];
      
      // ВАЖНО: Загружаем пользователя асинхронно чтобы не блокировать UI
      unawaited(loadSupabaseCurrentUser().timeout(
        const Duration(seconds: 3),
        onTimeout: () {
          AppLogger.warning('Timeout загрузки профиля (3с), продолжаем без профиля', tag: _logTag);
        },
      ).catchError((e) {
        AppLogger.error('Ошибка загрузки профиля Supabase', tag: _logTag, error: e);
      }));

      final authId = Supabase.instance.client.auth.currentUser?.id;
      if (authId != null && authId.isNotEmpty) {
        _lastKnownAuthUserId = authId;
        unawaited(_saveLastKnownAuthUserId(authId));
      }
      
      // Инициализируем Presence для онлайн-статуса (неблокирующе)
      if (_currentUser != null) {
        PresenceService().initialize(_currentUser!.id, showOnlineStatus: _showOnlineStatus);
      }
      
      // Загружаем остальные данные в фоне
      _loadUserDataAsync(force: true);
      
      // Регистрируем callback для realtime обновления UI при получении push-уведомления
      FirebaseNotificationService.onPushReceived = (data) {
        AppLogger.info('[PUSH-UI] Получен push, добавляем в state', tag: _logTag);
        // Добавляем уведомление в список мгновенно (не ждём БД)
        addNotificationFromPush(data);
        // Также перезагружаем через задержку для синхронизации с БД
        Future.delayed(const Duration(milliseconds: 800), () {
          if (_currentUser != null) {
            unawaited(loadNotifications());
          }
        });
      };

      subscribeToAuthChanges(notifyListeners, onSignedIn: () {
        if (Features.useSupabaseChats) {
          loadChats();
        }
        _loadUserDataAsync(force: true);

        if (Features.useSupabasePosts && _currentUser != null) {
          unawaited(_loadInitialPosts(force: true));
        }
        
        // Инициализируем Presence при входе
        if (_currentUser != null) {
          PresenceService().initialize(_currentUser!.id, showOnlineStatus: _showOnlineStatus);
        }
      });
    } else {
      _users = [];
      initializeMockUsers(_users, setCurrentUser);
      _loadUserDataAsync(force: true);
    }

    // Мгновенно восстанавливаем badge уведомлений из кэша
    unawaited(_loadNotificationsFromCache());

    // Загружаем скрытые посты/пользователей И кэшированные лайки/закладки ДО загрузки постов
    // чтобы они были отфильтрованы сразу и не мелькали в ленте
    try {
      final prefs = await SharedPreferences.getInstance();
      final localHiddenPosts = prefs.getStringList('hidden_posts') ?? [];
      _notInterestedPosts = localHiddenPosts.toSet();
      final localHiddenUsers = prefs.getStringList('hidden_users') ?? [];
      _hiddenUsers = localHiddenUsers.toSet();
      // Загружаем кэш лайков/закладок для мгновенного отображения при старте
      final userId = Supabase.instance.client.auth.currentUser?.id;
      if (userId != null && userId.isNotEmpty) {
        final cachedLikes = prefs.getStringList('liked_ids_$userId') ?? [];
        final cachedBookmarks = prefs.getStringList('bookmarked_ids_$userId') ?? [];
        if (cachedLikes.isNotEmpty) _likedPostIds = cachedLikes.toSet();
        if (cachedBookmarks.isNotEmpty) _bookmarkedPostIds = cachedBookmarks.toSet();
      }
    } catch (e) {
      // Ignore
    }

    // Параллельно загружаем блокировки/скрытых в фоне — не блокируем UI
    unawaited(Future.wait([
      _loadBlockedUsers(),
      _loadHiddenUsers(),
      _loadHiddenPosts(),
    ]).catchError((e) {
      AppLogger.error('Ошибка загрузки блокировок/скрытых', tag: _logTag, error: e);
      return <void>[];
    }));

    // Посты загружаем в фоне — UI рендерится сразу, скелетон покажет загрузку
    if (Features.useSupabasePosts && _currentUser != null) {
      unawaited(_loadInitialPosts());
    }
    
    notifyListeners();
  }

  // Загрузить подписки из Supabase
  Future<void> _loadFollowsFromSupabase() async {
    try {
      final userService = SupabaseUserService();
      final currentUserId = _currentUser?.id;
      
      if (currentUserId == null || currentUserId.isEmpty) {
        return;
      }

      // Загружаем список тех, на кого подписан текущий пользователь
      final following = await userService.getFollowing(currentUserId);
      _followedUsers.clear();

      for (final item in following) {
        final followingId = item['following_id'] as String?;
        if (followingId != null) {
          _followedUsers.add(followingId);
        }
      }
      notifyListeners();
    } catch (e) {
      AppLogger.error('Ошибка загрузки подписок', tag: _logTag, error: e);
    }
  }

  // Загрузить pending заявки на подписку из Supabase
  Future<void> _loadPendingFollowRequests() async {
    try {
      final currentUserId = _currentUser?.id;
      if (currentUserId == null || currentUserId.isEmpty) return;

      final followRequestService = SupabaseFollowRequestService();
      final pendingIds = await followRequestService.getSentPendingRequestUserIds(currentUserId);
      _pendingFollowRequests = pendingIds;
      notifyListeners();
    } catch (e) {
      AppLogger.error('Ошибка загрузки pending заявок', tag: _logTag, error: e);
    }
  }

  // Принять заявку на подписку
  Future<bool> acceptFollowRequest(String requestId, String fromUserId) async {
    try {
      final followRequestService = SupabaseFollowRequestService();
      final userService = SupabaseUserService();
      final currentUserId = _currentUser?.id;
      if (currentUserId == null) return false;

      // Принимаем заявку
      final accepted = await followRequestService.acceptFollowRequest(requestId);
      if (!accepted) return false;

      // Создаём подписку
      await userService.followUser(fromUserId, currentUserId);

      // Уведомляем отправителя
      if (Features.useSupabaseNotifications) {
        final notificationService = SupabaseNotificationService();
        await notificationService.createNotification(
          userId: fromUserId,
          type: 'follow',
          actorId: currentUserId,
        );
      }

      notifyListeners();
      AppLogger.success('Заявка принята: $fromUserId', tag: _logTag);
      return true;
    } catch (e) {
      AppLogger.error('Ошибка принятия заявки', tag: _logTag, error: e);
      return false;
    }
  }

  // Отклонить заявку на подписку
  Future<bool> rejectFollowRequest(String requestId) async {
    try {
      final followRequestService = SupabaseFollowRequestService();
      final rejected = await followRequestService.rejectFollowRequest(requestId);
      if (rejected) {
        notifyListeners();
      }
      return rejected;
    } catch (e) {
      AppLogger.error('Ошибка отклонения заявки', tag: _logTag, error: e);
      return false;
    }
  }

  // Получить входящие заявки на подписку
  Future<List<Map<String, dynamic>>> getIncomingFollowRequests() async {
    try {
      final currentUserId = _currentUser?.id;
      if (currentUserId == null) return [];

      final followRequestService = SupabaseFollowRequestService();
      return await followRequestService.getIncomingRequests(currentUserId);
    } catch (e) {
      AppLogger.error('Ошибка получения входящих заявок', tag: _logTag, error: e);
      return [];
    }
  }

  // Получить количество входящих заявок
  Future<int> getIncomingFollowRequestsCount() async {
    try {
      final currentUserId = _currentUser?.id;
      if (currentUserId == null) return 0;

      final followRequestService = SupabaseFollowRequestService();
      return await followRequestService.getIncomingRequestsCount(currentUserId);
    } catch (e) {
      AppLogger.error('Ошибка подсчёта заявок', tag: _logTag, error: e);
      return 0;
    }
  }

  // Загрузить первую страницу постов из Supabase
  Future<void> _loadInitialPosts({bool force = false}) async {
    // BUG-006: Показываем кэш СРАЗУ без спиннера для мгновенного отклика
    if (_stories.isEmpty) {
      await _loadStoriesFromCache();
      if (_stories.isNotEmpty) {
        _hasEverLoadedPosts = true;
        notifyListeners(); // показываем кэш немедленно БЕЗ _isLoading = true
      }
    }

    final cachedStoriesById = <String, Story>{
      for (final story in _stories) story.id: story,
    };

    // BUG-006: Загружаем лайки/закладки в фоне, не блокируя UI
    unawaited(_ensureInteractionSetsLoaded());

    // НЕ показываем спиннер если уже есть кэш
    if (_stories.isEmpty) {
      _isLoading = true;
      notifyListeners();
    }
    
    try {
      // Проверяем авторизацию перед загрузкой постов
      if (Features.useSupabaseAuth && _currentUser == null) {
        AppLogger.warning('Нет текущего пользователя, пропускаем загрузку постов', tag: _logTag);
        // НЕ очищаем посты — оставляем кэш видимым
        _isLoading = false;
        notifyListeners();
        return;
      }
      
      final postService = SupabasePostService();
      
      // Временно используем обычную ленту по дате чтобы новые посты появлялись сразу
      // TODO: Вернуть getSmartFeed после исправления кэширования в SQL функции
      final posts = await postService.getFeed(
        page: 0,
        limit: _postsPerPage,
        filter: 'new',
      );


      // Получаем все лайки, закладки и голоса в опросах текущего пользователя
      Set<String> likedPostIds = {};
      Set<String> bookmarkedPostIds = {};
      final currentUserId = _currentUser?.id;
      if (currentUserId != null && currentUserId.isNotEmpty) {
        try {
          final userLikes = await postService.getUserLikes(currentUserId);
          likedPostIds = userLikes.map((like) => like['post_id'] as String).toSet();
          
          final userBookmarks = await postService.getUserBookmarks(currentUserId);
          bookmarkedPostIds = userBookmarks.toSet();
          
          // Загружаем голоса в опросах и полностью обновляем кэш
          final pollVotes = await postService.getUserPollVotes(currentUserId);
          _applyUserPollVotes(pollVotes, resetAll: true);
        } catch (e) {
          // Ignore interaction errors
        }
      }

      _likedPostIds = likedPostIds;
      _bookmarkedPostIds = bookmarkedPostIds;
      _hasLoadedLikes = true;
      // Кэшируем для быстрого старта при следующем запуске
      if (currentUserId != null && currentUserId.isNotEmpty) {
        unawaited(_cacheInteractionIds(currentUserId));
      }

      // Перезаписываем свежими данными с сервера, но сохраняем локально созданные посты
      final newStories = <Story>[];
      final serverPostIds = <String>{};

      for (final postData in posts) {
        var story = await _mapSupabasePostToStoryWithLikes(postData, likedPostIds, bookmarkedPostIds);
        final cached = cachedStoriesById[story.id];
        if (cached != null) {
          if (story.images.isEmpty && cached.images.isNotEmpty) {
            story = story.copyWith(images: cached.images, media: cached.media);
          }
          if (story.media.isEmpty && cached.media.isNotEmpty) {
            story = story.copyWith(media: cached.media);
          }
        }
        newStories.add(story);
        serverPostIds.add(story.id);
      }

      // Добавляем локально созданные посты, которых еще нет на сервере
      // и сохраняем порядок: новые локальные посты сверху
      final localStories = _stories.where((story) => !serverPostIds.contains(story.id)).toList();
      newStories.insertAll(0, localStories);

      _stories = newStories;


      // НЕ загружаем комментарии здесь - они загружаются при открытии поста
      // Это критично для производительности!

      await _saveStoriesToCache();

      _isOffline = false;
      
      // Синхронизируем офлайн-очередь при восстановлении сети
      unawaited(syncOfflineQueue());

      // BUG-033: автопереподписка realtime при восстановлении сети
      if (_chatListRealtimeChannel == null && Features.useSupabaseChats && _currentUser != null) {
        _subscribeToChatListRealtime();
      }
      if (_notificationsRealtimeChannel == null && Features.useSupabaseNotifications && _currentUser != null) {
        unawaited(_subscribeToNotificationsRealtime());
      }

      _currentPage = 0;
      _hasMoreData = posts.length >= _postsPerPage;
      _hasEverLoadedPosts = true;
    } catch (e) {
      AppLogger.error('Ошибка загрузки постов', tag: _logTag, error: e);
      _isOffline = true;
      _hasMoreData = false;
      _hasEverLoadedPosts = true;
      await _loadStoriesFromCache();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }


  Future<void> _loadUserDataAsync({bool force = false}) async {
    if (_hasLoadedUserData && !force) return;
    if (Features.useSupabaseUsers && _currentUser == null) {
      return;
    }

    try {
      // Настройки — первыми, остальные зависят от них
      await _loadSettings(forceSupabase: true);

      // Параллельная загрузка независимых данных (1-й пакет)
      final futures1 = <Future>[];
      if (Features.useSupabaseUsers) {
        futures1.add(_loadFollowsFromSupabase());
        futures1.add(_loadPendingFollowRequests());
        futures1.add(loadRecommendedUsers());
      } else {
        futures1.add(_loadFollowedUsers());
      }
      if (Features.useSupabasePosts) {
        if (_currentUser != null && _currentUser!.id.isNotEmpty) {
          futures1.add(loadLikedPosts());
          futures1.add(loadBookmarkedPosts());
        }
      } else {
        futures1.add(_loadLikedPosts());
        futures1.add(_loadBookmarks());
      }
      futures1.add(_loadSearchHistory());
      futures1.add(_loadJoinedCommunities());
      futures1.add(_loadBlockedUsers());
      futures1.add(_loadHiddenUsers());
      futures1.add(_loadHiddenPosts());
      await Future.wait(futures1, eagerError: false);

      // 2-й пакет — критичные для UI данные
      await Future.wait([
        loadNotifications(),
        if (Features.useSupabaseChats) loadChats(),
      ], eagerError: false);

      _hasLoadedUserData = true;
      notifyListeners();

      // 3-й пакет — менее критичные, в фоне с задержкой чтобы не тормозить старт
      unawaited(Future.delayed(const Duration(seconds: 2), () async {
        try {
          await Future.wait([
            _loadCommunities(),
            _loadReports(),
            _loadSavedDiscussionIds(),
            loadDiscussions(force: true),
          ], eagerError: false);
        } catch (e) {
          AppLogger.warning('Ошибка фоновой загрузки данных', tag: _logTag, error: e);
        }
      }));
    } catch (e) {
      AppLogger.error('Ошибка загрузки пользовательских данных', tag: _logTag, error: e);
    }
  }

  // BUG-007: Загрузить больше постов (cursor-based pagination)
  Future<void> loadMoreStories() async {
    if (_isLoadingMore || !_hasMoreData) return;
    if (_isOffline) return;
    if (!Features.useSupabasePosts) return;
    if (_stories.isEmpty) return;

    final lastStory = _stories.last;
    _lastPostId = lastStory.id;
    setState(() => _isLoadingMore = true);

    try {
      final postService = SupabasePostService();
      
      await _ensureInteractionSetsLoaded();

      // BUG-007: Используем cursor-based pagination через created_at последнего поста
      final newPosts = await postService.getFeedWithCursor(
        cursor: lastStory.createdAt,
        limit: _postsPerPage,
        filter: 'new',
      );

      if (newPosts.isEmpty) {
        _hasMoreData = false;
      } else {
        // Дедупликация: собираем существующие ID
        final existingIds = _stories.map((s) => s.id).toSet();
        int addedCount = 0;

        // Конвертируем и добавляем только новые посты
        for (final postData in newPosts) {
          final postId = postData['id'] as String?;
          if (postId != null && existingIds.contains(postId)) continue;

          final story = await _mapSupabasePostToStoryWithLikes(postData, _likedPostIds, _bookmarkedPostIds);
          _stories.add(story);
          existingIds.add(story.id);
          addedCount++;

          if (_loadedPostIds.contains(story.id)) {
            _recalculateStoryCommentsCount(story.id);
          }
        }

        // Если вернулось меньше limit постов - данные кончились
        if (newPosts.length < _postsPerPage) {
          _hasMoreData = false;
        }
        
        // Если все дубли - пробуем ещё раз
        if (addedCount == 0 && newPosts.length >= _postsPerPage) {
          _hasMoreData = true;
        } else if (addedCount == 0) {
          _hasMoreData = false;
        }
      }
    } catch (e) {
      AppLogger.error('Ошибка загрузки постов при догрузке', tag: _logTag, error: e);
      _isOffline = true;
      _hasMoreData = false;
    } finally {
      _isLoadingMore = false;
      notifyListeners();
    }
  }

  // Конвертировать Supabase пост в Story модель (с готовым списком лайков и закладок)
  Future<Story> _mapSupabasePostToStoryWithLikes(
    Map<String, dynamic> postData,
    Set<String> likedPostIds, [
    Set<String>? bookmarkedPostIds,
    Map<String, Set<String>>? userPollVotesOverride,
  ]) async {
    final userData = postData['users'] as Map<String, dynamic>?;
    
    // Определяем Premium из role / is_premium / premium_expires_at
    final roleString = userData?['role'] as String?;
    final isPremiumFlag = userData?['is_premium'] as bool? ?? false;
    
    // Парсим premium_expires_at
    DateTime? premiumExpiresAt;
    if (userData?['premium_expires_at'] != null) {
      try {
        premiumExpiresAt = DateTime.parse(userData!['premium_expires_at'] as String);
      } catch (e) {
        AppLogger.warning('Ошибка парсинга premium_expires_at для поста', tag: 'AppState', error: e);
      }
    }
    final isPremium = roleString == 'premium' || isPremiumFlag || premiumExpiresAt != null;
    
    final author = User(
      id: userData?['id'] as String? ?? '',
      name: userData?['full_name'] as String? ?? 'Пользователь',
      username: userData?['username'] as String? ?? 'user',
      avatar: userData?['avatar_url'] as String? ?? '',
      isPremium: isPremium,
      premiumExpiresAt: premiumExpiresAt,
      karma: 0,
      isVerified: userData?['is_verified'] as bool? ?? false,
    );

    // Получаем текст из поля 'content' (реальное имя колонки в БД)
    final text = postData['content'] as String? ?? postData['text'] as String? ?? '';
    
    // Получаем медиа URLs
    final mediaUrls = postData['media_urls'] as List<dynamic>?;
    final fallbackImages = postData['images'] as List<dynamic>?;
    final images = (mediaUrls ?? fallbackImages)?.map((url) => url.toString()).toList() ?? [];
    final media = images
        .where((path) => path.isNotEmpty)
        .map((path) => MediaItem(path: path, type: MediaType.image))
        .toList();

    // Получаем части поста если есть; если нет — разбиваем длинный текст автоматически
    final partsData = postData['parts'] as List<dynamic>?;
    List<String>? parts = partsData?.map((part) => part.toString()).toList();
    if ((parts == null || parts.length < 2) && text.length > 500) {
      parts = _splitTextIntoParts(text, 500);
    }

    Poll? poll;
    final pollData = postData['poll'] as Map<String, dynamic>?;
    if (pollData != null) {
      final optionsData = pollData['options'] as List<dynamic>? ?? [];
      final pollId = pollData['id']?.toString() ?? '';
      final userVotes = userPollVotesOverride?[pollId] ?? _userPollVotes[pollId] ?? <String>{};
      
      final pollOptions = optionsData.map((option) {
        final optionMap = option as Map<String, dynamic>;
        final optionId = optionMap['id']?.toString() ?? '';
        final baseVotes = optionMap['votes'] as int? ?? 0;
        final baseVotedBy = (optionMap['voted_by'] as List<dynamic>?)?.map((v) => v.toString()).toList() ?? [];
        // Apply user's vote if not reflected yet
        final isVotedByUser = userVotes.contains(optionId);
        final finalVotes = isVotedByUser && !baseVotedBy.contains(_currentUser?.id ?? '') ? baseVotes + 1 : baseVotes;
        final finalVotedBy = isVotedByUser && !baseVotedBy.contains(_currentUser?.id ?? '') ? [...baseVotedBy, _currentUser?.id ?? ''] : baseVotedBy;
        return PollOption(
          id: optionId,
          text: optionMap['text']?.toString() ?? '',
          votes: finalVotes,
          votedBy: finalVotedBy,
        );
      }).toList();
      
      // Пересчитываем totalVotes из опций
      final totalVotes = pollOptions.fold<int>(0, (sum, option) => sum + option.votes);
      
      poll = Poll(
        id: pollId,
        question: pollData['question']?.toString() ?? '',
        endsAt: pollData['ends_at'] != null ? DateTime.tryParse(pollData['ends_at'].toString()) : null,
        totalVotes: totalVotes,
        options: pollOptions,
      );
    }

    // Проверяем лайкнул ли текущий пользователь этот пост
    final postId = postData['id'] as String;
    // BUG-014: если лайк в процессе — не затираем оптимистическое состояние
    final bool isLiked;
    if (_likePending.contains(postId)) {
      isLiked = _likedPostIds.contains(postId);
    } else {
      isLiked = likedPostIds.contains(postId);
    }
    final isBookmarked = bookmarkedPostIds?.contains(postId) ?? false;
    final serverLikes = (postData['likes_count'] as num?)?.toInt() ?? 0;
    final likesCount = isLiked && serverLikes == 0 ? 1 : serverLikes;

    // Обрабатываем оригинальный пост для репостов
    Story? quotedStory;
    final quotedStoryData = postData['quoted_story'] as Map<String, dynamic>?;
    if (quotedStoryData != null) {
      quotedStory = await _mapSupabasePostToStoryWithLikes(
        quotedStoryData,
        likedPostIds,
        bookmarkedPostIds,
        userPollVotesOverride,
      );
    }

    return Story(
      id: postId,
      text: text,
      author: author,
      createdAt: DateTime.parse(postData['created_at'] as String).toLocal(),
      likes: likesCount,
      comments: postData['comments_count'] as int? ?? 0,
      reposts: postData['reposts_count'] as int? ?? 0,
      views: postData['views_count'] as int? ?? 0,
      isLiked: isLiked,
      isBookmarked: isBookmarked,
      images: images,
      media: media,
      isAnonymous: postData['is_anonymous'] as bool? ?? false,
      isAdult: postData['is_adult'] as bool? ?? false,
      parts: parts, // Добавляем части
      poll: poll, // Добавляем опрос
      quotedStory: quotedStory, // Добавляем оригинальный пост для репостов
    );
  }


  void setState(Function() fn) {
    fn();
    notifyListeners();
  }

  void _initializeCommunities() {
    _communities = [];
    _joinedCommunities = {};
  }

  // ============================================================================
  // ПОСТЫ (STORIES) - Создание, редактирование, лайки, закладки
  // ============================================================================

  // Добавление новой истории
  Future<void> addStory(Story story) async {
    // Rate limit убран - серверная защита через RLS достаточна
    
    if (Features.useSupabasePosts) {
      try {
        final postService = SupabasePostService();
        final storageService = SupabaseStorageService();
        final currentUserId = _currentUser?.id ?? '';
        
        // Проверяем что пользователь авторизован
        if (currentUserId.isEmpty) {
          throw Exception('Пользователь не авторизован');
        }

        // Загружаем медиа в Storage если есть
        List<String> uploadedMediaUrls = [];
        if (story.media.isNotEmpty) {
          int failedCount = 0;
          for (var media in story.media) {
            try {
              final file = File(media.path);
              String? url;
              if (media.isImage) {
                url = await storageService.uploadPostImage(currentUserId, file);
              } else if (media.isVideo) {
                url = await storageService.uploadVideo(currentUserId, file);
              }
              if (url != null) {
                uploadedMediaUrls.add(url);
              } else {
                failedCount++;
                AppLogger.error('Медиа не загружено (null url): ${media.path}', tag: _logTag);
              }
            } catch (e) {
              failedCount++;
              AppLogger.error('Ошибка загрузки медиа: ${media.path}', tag: _logTag, error: e);
            }
          }
          // Если НИ ОДНО медиа не загрузилось — пробрасываем ошибку
          if (failedCount > 0 && uploadedMediaUrls.isEmpty) {
            throw Exception('Не удалось загрузить медиафайлы. Проверьте интернет-соединение.');
          }
          // Если часть медиа не загрузилась — логируем предупреждение
          if (failedCount > 0) {
            AppLogger.warning('Загружено ${uploadedMediaUrls.length}/${story.media.length} медиафайлов', tag: _logTag);
          }
        }

        // Части: если явно переданы пользователем (через разделитель ---) или текст > 500 символов
        List<String>? parts = story.parts != null && story.parts!.length > 1 ? story.parts : null;
        final String postText = story.text;
        
        // Автоматически разбиваем длинный текст на части по 500 символов
        if (parts == null && postText.length > 500) {
          parts = _splitTextIntoParts(postText, 500);
        }

        final postData = await postService.createPost(
          userId: currentUserId,
          text: postText,
          mediaUrls: uploadedMediaUrls.isNotEmpty ? uploadedMediaUrls : null,
          isAnonymous: story.isAnonymous,
          isAdult: story.isAdult,
          quotedPostId: story.quotedStory?.id, // Передаем ID оригинального поста для репостов
          parts: parts,
          pollQuestion: story.poll?.question,
          pollOptions: story.poll?.options.map((o) => o.text).toList(),
          pollEndsAt: story.poll?.endsAt,
          allowMultipleAnswers: story.poll?.allowMultipleAnswers ?? false,
        );

        if (postData == null) {
          throw Exception('Не удалось создать пост в Supabase');
        }
        
        AppLogger.info('Пост создан на сервере: id=${postData['id']}, created_at=${postData['created_at']}', tag: _logTag);

        Poll? persistedPoll;
        final supabasePollData = postData['poll'] as Map<String, dynamic>?;
        if (supabasePollData != null) {
          final optionsData = supabasePollData['options'] as List<dynamic>? ?? [];
          persistedPoll = Poll(
            id: supabasePollData['id']?.toString() ?? story.poll?.id ?? '',
            question: supabasePollData['question']?.toString() ?? story.poll?.question ?? '',
            endsAt: supabasePollData['ends_at'] != null
                ? DateTime.tryParse(supabasePollData['ends_at'].toString())
                : story.poll?.endsAt,
            allowMultipleAnswers: supabasePollData['allow_multiple_answers'] as bool?
                ?? story.poll?.allowMultipleAnswers
                ?? false,
            totalVotes: supabasePollData['total_votes'] as int?
                ?? supabasePollData['votes_count'] as int?
                ?? story.poll?.totalVotes
                ?? 0,
            options: optionsData.map((option) {
              final optionMap = option as Map<String, dynamic>;
              return PollOption(
                id: optionMap['id']?.toString() ?? '',
                text: optionMap['text']?.toString() ?? optionMap['option_text']?.toString() ?? '',
                votes: optionMap['votes'] as int?
                    ?? optionMap['vote_count'] as int?
                    ?? 0,
                votedBy: (optionMap['voted_by'] as List<dynamic>?)?.map((v) => v.toString()).toList() ?? const [],
              );
            }).toList(),
          );
        }

        final newStoryId = postData['id'] as String;
        final newStory = story.copyWith(
          id: newStoryId,
          author: _currentUser!,
          createdAt: DateTime.parse(postData['created_at'] as String).toLocal(),
          likes: 0, // Новый пост всегда 0 лайков, игнорируем данные сервера
          comments: 0,
          reposts: 0,
          views: postData['views_count'] as int? ?? 0,
          isLiked: false,
          isBookmarked: false,
          images: uploadedMediaUrls,
          media: story.media,
          poll: persistedPoll ?? story.poll,
          isAnonymous: story.isAnonymous,
          parts: parts,
          quotedStory: story.quotedStory,
        );

        // Добавляем в начало ленты
        _stories = List<Story>.from(_stories)..insert(0, newStory);
        // Регистрируем ID чтобы при следующем refreshStories пост не переместился
        _loadedPostIds.add(newStoryId);
        
        AppLogger.info('Новый пост добавлен в ленту: ${newStory.id}, всего постов: ${_stories.length}', tag: _logTag);
        
        final currentAuthorId = _currentUser!.id;
        final authorStories = _userStoriesCache[currentAuthorId];
        _userStoriesFullyLoaded.remove(currentAuthorId);
        if (authorStories != null) {
          _userStoriesCache[currentAuthorId] = [newStory, ...authorStories.where((story) => story.id != newStory.id)];
        } else {
          _userStoriesCache[currentAuthorId] = [newStory];
        }

        notifyListeners();
        
      } catch (e) {
        AppLogger.error('Ошибка создания поста', tag: _logTag, error: e);
        rethrow;
      }
      // Подаем сигнал для скролла к началу
      _scrollToTopController.add(true);
    } else {
      // Локальный режим
      _stories.insert(0, story);
      
      // TODO: Добавить уведомления об упоминаниях через Supabase
      notifyListeners();
      
      // Подаем сигнал для скролла к началу
      _scrollToTopController.add(true);
    }
  }

  // Удобный метод для создания вопроса
  Future<bool> createQuestion({
    required String title,
    String? description,
    String? imageUrl,
    required QuestionCategory category,
    bool isAnonymous = false,
  }) async {
    try {
      final author = _currentUser ??
          (_users.isNotEmpty
              ? _users.first
              : User(
                  id: 'local_user',
                  name: 'Вы',
                  username: 'you',
                  avatar: '',
                  isPremium: false,
                  karma: 0,
                ));

      final question = Question(
        id: const Uuid().v4(),
        title: title,
        description: description,
        author: author,
        createdAt: DateTime.now(),
        category: category,
        imageUrl: imageUrl,
        isAnonymous: isAnonymous,
        answersCount: 0,
        viewsCount: 0,
        isResolved: false,
      );

      // Добавляем в список вопросов
      _questions.insert(0, question);

      // Создаем карточку в общем фиде и сохраняем в Supabase через addStory
      final questionTextBuffer = StringBuffer('❓ ${question.title}');
      if ((question.description ?? '').trim().isNotEmpty) {
        questionTextBuffer
          ..write('\n\n')
          ..write(question.description!.trim());
      }

      final questionStory = Story(
        id: question.id,
        text: questionTextBuffer.toString(),
        author: question.author,
        createdAt: question.createdAt,
        likes: 0,
        comments: 0,
        reposts: 0,
        views: 0,
        isLiked: false,
        isBookmarked: false,
        images: question.imageUrl != null ? [question.imageUrl!] : const [],
        media: question.imageUrl != null
            ? [MediaItem(path: question.imageUrl!, type: MediaType.image)]
            : const [],
        isAnonymous: question.isAnonymous,
      );

      await addStory(questionStory);
      return true;
    } catch (e) {
      AppLogger.error('Ошибка создания вопроса', tag: _logTag, error: e);
      return false;
    }
  }

  // Удобный метод для создания истории с параметрами
  Future<bool> createStory({
    required String text,
    List<String>? images,
    bool isAdultContent = false,
    bool isAnonymous = false,
    Poll? poll,
  }) async {
    try {
      final author = _currentUser ??
          (_users.isNotEmpty
              ? _users.first
              : User(
                  id: 'local_user',
                  name: 'Вы',
                  username: 'you',
                  avatar: '',
                  isPremium: false,
                  karma: 0,
                ));

      final mediaItems = images?.map((path) => MediaItem(
        path: path,
        type: MediaType.image,
      )).toList() ?? [];

      // Разбиваем длинный текст на части по 500 символов для удобного чтения
      final parts = text.length > 500 ? _splitTextIntoParts(text, 500) : null;
      
      final story = Story(
        id: const Uuid().v4(),
        text: text,
        author: author,
        createdAt: DateTime.now(),
        likes: 0,
        comments: 0,
        reposts: 0,
        views: 0,
        isLiked: false,
        isBookmarked: false,
        images: images ?? [],
        media: mediaItems,
        poll: poll,
        parts: parts,
        isAnonymous: isAnonymous,
        isAdult: isAdultContent,
      );

      await addStory(story);
      return true;
    } catch (e) {
      AppLogger.error('Ошибка создания истории', tag: _logTag, error: e);
      return false;
    }
  }
  
  // Редактирование поста
  Future<void> editStory(String storyId, String newText, List<String>? newImages, {List<String>? parts}) async {
    final index = _stories.indexWhere((s) => s.id == storyId);
    if (index != -1) {
      final oldStory = _stories[index];
      
      // Оптимистичное обновление UI
      final updatedStory = _stories[index].copyWith(
        text: newText,
        images: newImages,
        parts: parts,
        isEdited: true,
      );
      _stories[index] = updatedStory;
      
      // Обновляем в кэше пользователя (профиль)
      _updateStoryInUserCaches(updatedStory);
      _updateSavedStoriesWith(updatedStory);
      _updateLikedStoriesWith(updatedStory);
      
      notifyListeners();

      // Сохраняем в Supabase
      if (Features.useSupabasePosts) {
        try {
          final postService = SupabasePostService();
          final currentUserId = _currentUser?.id ?? '';
          await postService.editPost(
            postId: storyId,
            userId: currentUserId,
            text: newText,
            images: newImages,
            parts: parts,
          );
        } catch (e) {
          AppLogger.error('Ошибка редактирования поста в Supabase', tag: _logTag, error: e);
          // Откатываем изменения при ошибке
          _stories[index] = oldStory;
          _updateStoryInUserCaches(oldStory);
          _updateSavedStoriesWith(oldStory);
          _updateLikedStoriesWith(oldStory);
          notifyListeners();
          rethrow;
        }
      }
    }
  }
  
  // Удаление поста
  Future<void> deleteStory(String storyId) async {
    // Оптимистичное удаление из UI
    final index = _stories.indexWhere((s) => s.id == storyId);
    Story? deletedStory;
    if (index != -1) {
      deletedStory = _stories[index];
      // Создаем новый список, чтобы Flutter гарантированно увидел изменения
      _stories = List.from(_stories)..removeAt(index);
    } else {
      for (final stories in _userStoriesCache.values) {
        final storyIndex = stories.indexWhere((s) => s.id == storyId);
        if (storyIndex != -1) {
          deletedStory = stories[storyIndex];
          break;
        }
      }
    }

    final authorId = deletedStory?.author.id;
    final authorStories = authorId != null ? _userStoriesCache[authorId] : null;

    for (final entry in _userStoriesCache.entries.toList()) {
      final updatedStories = entry.value.where((s) => s.id != storyId).toList();
      if (updatedStories.length != entry.value.length) {
        _userStoriesCache[entry.key] = updatedStories;
      }
    }

    if (authorId != null) {
      AppLogger.info('Пост $storyId удален из кэша пользователя $authorId', tag: _logTag);
    }

    // Удаляем из сохранённых и лайкнутых списков
    _savedStories.removeWhere((s) => s.id == storyId);
    _likedStories.removeWhere((s) => s.id == storyId);

    // Удаляем ID из множеств
    _likedPostIds.remove(storyId);
    _bookmarkedPostIds.remove(storyId);
    _notInterestedPosts.remove(storyId);
    _loadedPostIds.remove(storyId);

    // Чистим связанные комментарии и уведомления
    _comments.removeWhere((c) => c.storyId == storyId);
    _notifications.removeWhere((n) => n.relatedId == storyId);

    await _saveStoriesToCache();

    // Обновляем UI
    notifyListeners();
    
    // Удаляем из Supabase если используем его
    if (Features.useSupabasePosts) {
      try {
        final postService = SupabasePostService();
        final currentUserId = _currentUser?.id ?? '';
        await postService.deletePost(storyId, currentUserId);
        AppLogger.info('Пост $storyId удален из Supabase', tag: _logTag);
      } catch (e) {
        AppLogger.error('Ошибка удаления поста', tag: _logTag, error: e);
        // Откатываем изменения при ошибке
        if (index != -1 && deletedStory != null) {
          _stories = List.from(_stories)..insert(index, deletedStory);
        }
        if (authorStories != null && authorId != null) {
          _userStoriesCache[authorId] = authorStories;
        }
        await _saveStoriesToCache();
        notifyListeners();
        rethrow;
      }
    }
  }
  
  // Скрыть пользователя (не интересно)
  Future<void> hideUser(String userId) async {
    if (_currentUser == null || userId == _currentUser!.id) return;

    _hiddenUsers.add(userId);
    notifyListeners();

    if (Features.useSupabaseUsers) {
      try {
        await _supabaseBlockService.hideUser(_currentUser!.id, userId);
      } catch (e) {
        // Ignore hide errors
      }
    }

    await _saveHiddenUsers();
  }
  
  // Показать пользователя (убрать из скрытых)
  Future<bool> unhideUser(String userId) async {
    final removed = _hiddenUsers.remove(userId);
    notifyListeners();

    if (Features.useSupabaseUsers) {
      try {
        final success = await _supabaseBlockService.unhideUser(_currentUser!.id, userId);
        if (!success) {
          if (removed) {
            _hiddenUsers.add(userId);
            notifyListeners();
          }
          return false;
        }
      } catch (e) {
        if (removed) {
          _hiddenUsers.add(userId);
          notifyListeners();
        }
        return false;
      }
    }

    await _saveHiddenUsers();
    return true;
  }
  
  // Пометить пост как "не интересно"
  Future<void> markPostAsNotInterested(String postId) async {
    _notInterestedPosts.add(postId);
    notifyListeners();

    if (Features.useSupabasePosts && _currentUser != null) {
      try {
        await _supabaseBlockService.hidePost(_currentUser!.id, postId);
      } catch (e) {
        // Ignore hide errors
      }
    }

    await _saveHiddenPosts();
  }
  
  // Убрать пост из "не интересно"
  Future<bool> unmarkPostAsNotInterested(String postId) async {
    final removed = _notInterestedPosts.remove(postId);
    notifyListeners();

    if (Features.useSupabasePosts && _currentUser != null) {
      try {
        final success = await _supabaseBlockService.unhidePost(_currentUser!.id, postId);
        if (!success) {
          if (removed) {
            _notInterestedPosts.add(postId);
            notifyListeners();
          }
          return false;
        }
      } catch (e) {
        if (removed) {
          _notInterestedPosts.add(postId);
          notifyListeners();
        }
        return false;
      }
    }

    await _saveHiddenPosts();
    return true;
  }
  
  // Голосование в опросе
  Future<void> voteInPoll(String storyId, String optionId) async {
    final storyIndex = _stories.indexWhere((s) => s.id == storyId);
    if (storyIndex == -1) return;
    final story = _stories[storyIndex];
    if (story.poll == null || !story.poll!.isActive) return;
    final poll = story.poll!;
    final currentUserId = _currentUser?.id ?? '';

    // Optimistic UI update
    final alreadyVoted = poll.options.any((o) => o.votedBy.contains(currentUserId));
    final updatedOptions = poll.options.map((option) {
      if (option.id == optionId) {
        if (!option.votedBy.contains(currentUserId)) {
          return option.copyWith(
            votes: option.votes + 1,
            votedBy: [...option.votedBy, currentUserId],
          );
        }
      } else if (alreadyVoted && !poll.allowMultipleAnswers) {
        if (option.votedBy.contains(currentUserId)) {
          return option.copyWith(
            votes: option.votes - 1,
            votedBy: option.votedBy.where((id) => id != currentUserId).toList(),
          );
        }
      }
      return option;
    }).toList();
    final totalVotes = updatedOptions.fold<int>(0, (sum, option) => sum + option.votes);
    final updatedPoll = poll.copyWith(
      options: updatedOptions,
      totalVotes: totalVotes,
    );
    _stories[storyIndex] = story.copyWith(poll: updatedPoll);
    // Update local vote tracking
    _userPollVotes[poll.id] ??= {};
    _userPollVotes[poll.id]!.add(optionId);
    notifyListeners();

    // Send vote to server
    try {
      final postService = SupabasePostService();
      await postService.voteInPoll(
        userId: currentUserId,
        pollId: poll.id,
        optionId: optionId,
      );
    } catch (e) {
      // Revert on error
      _stories[storyIndex] = story.copyWith(poll: poll);
      _userPollVotes[poll.id]?.remove(optionId);
      notifyListeners();
      rethrow;
    }
  }
  
  // ============================================================================
  // КОММЕНТАРИИ - Добавление, редактирование, лайки
  // ============================================================================

  // Получить комментарии к посту
  List<Comment> getComments(String storyId) {
    final comments = _comments.where((c) {
      if (c.storyId != storyId) return false;
      // Фильтруем комментарии от заблокированных пользователей
      if (_blockedUsers.contains(c.author.id)) return false;
      return true;
    }).toList();
    
    if (comments.isEmpty) return comments;
    
    // Сортируем по времени (старые сверху, новые внизу)
    comments.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    
    return comments;
  }

  int getCommentCount(String storyId) => _comments.where((c) => c.storyId == storyId).length;

  static const int _commentsPageSize = 50;

  bool hasMoreCommentsForPost(String postId) => _hasMoreComments[postId] ?? false;

  // Загрузить комментарии из Supabase (только один раз за сессию)
  Future<void> loadCommentsForPost(String postId, {bool force = false}) async {
    if (!Features.useSupabasePosts) return;
    if (_loadingComments.contains(postId)) return;
    if (!force && _loadedPostIds.contains(postId)) return;

    _loadingComments.add(postId);
    _loadedPostIds.add(postId);
    
    try {
      final postService = SupabasePostService();
      
      // Используем оптимизированный метод с лайками в одном запросе
      final commentsData = await postService.getCommentsOptimized(
        postId,
        limit: _commentsPageSize,
        offset: 0,
        currentUserId: _currentUser?.id,
      );
      _hasMoreComments[postId] = commentsData.length >= _commentsPageSize;

      // Сохраняем локальные комментарии, которые ещё не синхронизированы с Supabase
      final Map<String, Comment> pendingLocalComments = {
        for (final c in _comments.where((c) => c.storyId == postId && c.isPendingSync)) c.id: c,
      };

      // Полностью очищаем комментарии для этого поста (пересоберём из Supabase + pending)
      _comments.removeWhere((c) => c.storyId == postId);

      // Сначала создаём map всех комментариев для поиска корня цепочки
      final Map<String, Map<String, dynamic>> commentsById = {
        for (final data in commentsData)
          if (data['id'] != null) data['id'] as String: data
      };

      // Функция для поиска корневого комментария
      String? _findRootCommentId(String? commentId) {
        var currentId = commentId;
        final visited = <String>{};
        while (currentId != null && !visited.contains(currentId)) {
          visited.add(currentId);
          final parentId = commentsById[currentId]?['parent_id'] as String?;
          if (parentId == null) return currentId;
          currentId = parentId;
        }
        return currentId;
      }

      int addedCount = 0;
      int skippedNoUser = 0;
      
      for (final commentData in commentsData) {
        // Поддерживаем оба формата: RPC (user_*) и обычный JOIN (users)
        final user = commentData['users'] as Map<String, dynamic>?;
        final isRpcFormat = user == null && commentData['user_id'] != null;
        
        // Для RPC формата берём данные напрямую
        final userId = isRpcFormat 
            ? commentData['user_id'] as String 
            : user?['id'] as String?;
        
        if (userId == null) {
          skippedNoUser++;
          continue;
        }
        addedCount++;
        
        final parentId = commentData['parent_id'] as String?;
        String? replyToAuthor;
        if (parentId != null) {
          final parentComment = commentsById[parentId];
          // Для RPC формата берём user_full_name напрямую
          if (parentComment != null) {
            final parentIsAnonymous = parentComment['is_anonymous'] as bool? ?? false;
            replyToAuthor = parentIsAnonymous
                ? 'Аноним'
                : parentComment['user_full_name'] as String?
                    ?? (parentComment['users'] as Map<String, dynamic>?)?['full_name'] as String?;
          }
        }
        
        final threadRootId = parentId == null
            ? commentData['id'] as String
            : _findRootCommentId(parentId) ?? parentId;
        
        // Получаем данные пользователя в зависимости от формата
        final String username;
        final String fullName;
        final String avatarUrl;
        final bool isVerified;
        final String? roleString;
        
        if (isRpcFormat) {
          // RPC формат: user_* поля
          username = commentData['user_username'] as String? ?? '';
          fullName = commentData['user_full_name'] as String? ?? username;
          avatarUrl = commentData['user_avatar_url'] as String? ?? '';
          isVerified = commentData['user_is_verified'] as bool? ?? false;
          roleString = commentData['user_role'] as String?;
        } else {
          // Обычный JOIN: users объект
          username = user?['username'] as String? ?? '';
          fullName = user?['full_name'] as String? ?? username;
          avatarUrl = user?['avatar_url'] as String? ?? '';
          isVerified = user?['is_verified'] as bool? ?? false;
          roleString = user?['role'] as String?;
        }
        
        final premiumExpiresAtRaw = isRpcFormat
            ? commentData['user_premium_expires_at']
            : user?['premium_expires_at'];
        final premiumExpiresAt = premiumExpiresAtRaw is String
            ? DateTime.tryParse(premiumExpiresAtRaw)
            : null;
        final isPremium = roleString == 'premium' || (user?['is_premium'] as bool? ?? false) || premiumExpiresAt != null;
        
        var comment = Comment(
          id: commentData['id'] as String,
          storyId: postId,
          author: User(
            id: userId,
            username: username,
            name: fullName,
            avatar: avatarUrl,
            isPremium: isPremium,
            premiumExpiresAt: premiumExpiresAt,
            isVerified: isVerified,
            bio: '',
            followersCount: 0,
            followingCount: 0,
            isFollowed: false,
            isPrivate: false,
          ),
          text: commentData['text'] as String? ?? '',
          createdAt: DateTime.parse(commentData['created_at'] as String).toLocal(),
          updatedAt: commentData['updated_at'] != null 
              ? DateTime.parse(commentData['updated_at'] as String).toLocal()
              : null,
          likes: commentData['likes_count'] as int? ?? 0,
          isLiked: commentData['is_liked'] as bool? ?? false,
          replyToId: parentId,
          replyToAuthor: replyToAuthor,
          replyTargetId: parentId,
          threadRootId: threadRootId,
          isPendingSync: false,
          mediaUrl: commentData['media_url'] as String?,
          mediaType: commentData['media_type'] as String?,
          mediaWidth: commentData['media_width'] as int?,
          mediaHeight: commentData['media_height'] as int?,
          isAnonymous: commentData['is_anonymous'] as bool? ?? false,
          isPinned: commentData['is_pinned'] as bool? ?? false,
        );

        // Если есть локальный pending с таким же id — переносим дополнительные поля
        final pending = pendingLocalComments.remove(comment.id);
        if (pending != null) {
          comment = comment.copyWith(
            replyToAuthor: pending.replyToAuthor ?? comment.replyToAuthor,
            replyTargetId: pending.replyTargetId ?? comment.replyTargetId,
            threadRootId: pending.threadRootId ?? comment.threadRootId,
            isPendingSync: false,
          );
        }

        _comments.add(comment);
      }
      
      // Добавляем оставшиеся локальные pending-комментарии (которых нет в Supabase)
      _comments.addAll(pendingLocalComments.values);

      // Обновляем счётчик комментариев для поста
      _recalculateStoryCommentsCount(postId);
      
      // Подписываемся на realtime обновления комментариев
      _subscribeToCommentsRealtime(postId);
      
      AppLogger.success('Загружено комментариев: ${commentsData.length}', tag: _logTag);
    } catch (e) {
      AppLogger.error('Ошибка загрузки комментариев', tag: _logTag, error: e);
      _isOffline = true;
      _loadedPostIds.remove(postId);
    } finally {
      // Всегда убираем блокировку
      _loadingComments.remove(postId);
    }
  }

  // Загрузить следующую страницу комментариев (пагинация)
  Future<bool> loadMoreCommentsForPost(String postId) async {
    if (!Features.useSupabasePosts) return false;
    if (!(_hasMoreComments[postId] ?? false)) return false;

    try {
      final postService = SupabasePostService();
      final currentCount = _comments.where((c) => c.storyId == postId).length;

      final commentsData = await postService.getCommentsOptimized(
        postId,
        limit: _commentsPageSize,
        offset: currentCount,
        currentUserId: _currentUser?.id,
      );

      if (commentsData.isEmpty) {
        _hasMoreComments[postId] = false;
        notifyListeners();
        return false;
      }

      _hasMoreComments[postId] = commentsData.length >= _commentsPageSize;

      // Строим map уже загруженных + новых для поиска корня
      final existingById = <String, Map<String, dynamic>>{};
      for (final c in commentsData) {
        if (c['id'] != null) existingById[c['id'] as String] = c;
      }

      String? findRoot(String? id) {
        var cur = id;
        final visited = <String>{};
        while (cur != null && !visited.contains(cur)) {
          visited.add(cur);
          final parentId = existingById[cur]?['parent_id'] as String?;
          if (parentId == null) return cur;
          cur = parentId;
        }
        return cur;
      }

      for (final commentData in commentsData) {
        final id = commentData['id'] as String?;
        if (id == null) continue;
        if (_comments.any((c) => c.id == id)) continue; // уже есть

        final comment = _mapSupabaseCommentToComment(commentData, postId,
            rootFinder: findRoot);
        _comments.add(comment);
      }

      // Пересчитываем комментарии только если пост есть в _stories
      if (_stories.any((s) => s.id == postId)) {
        _recalculateStoryCommentsCount(postId);
      }
      notifyListeners();
      AppLogger.success('Догружено комментариев: ${commentsData.length}', tag: _logTag);
      return _hasMoreComments[postId] ?? false;
    } catch (e) {
      AppLogger.error('Ошибка догрузки комментариев', tag: _logTag, error: e);
      return false;
    }
  }

  // Подписка на realtime комментарии
  void _subscribeToCommentsRealtime(String postId) {
    if (_commentsRealtimeChannels.containsKey(postId)) return;
    
    final postService = SupabasePostService();
    final channel = postService.subscribeToComments(postId, (record, event) async {
      
      if (event == PostgresChangeEvent.insert) {
        // Новый комментарий - загружаем его данные
        final commentId = record['id'] as String?;
        if (commentId == null) return;
        
        // Загружаем только один комментарий по ID (не все комментарии поста)
        try {
          final commentData = await postService.getCommentById(commentId);
          
          if (commentData != null && commentData.isNotEmpty) {
            final newComment = _mapSupabaseCommentToComment(commentData, postId);
            final existingIndex = _comments.indexWhere((c) => c.id == commentId);
            
            if (existingIndex != -1) {
              // Обновляем существующий комментарий (избегаем дубликатов)
              _comments[existingIndex] = newComment;
              AppLogger.info('Обновлён комментарий через realtime: $commentId', tag: _logTag);
            } else {
              // Добавляем новый
              _comments.add(newComment);
              AppLogger.success('Добавлен новый комментарий через realtime: $commentId', tag: _logTag);
            }
            
            // Сортируем по времени
            _comments.sort((a, b) => a.createdAt.compareTo(b.createdAt));
            _recalculateStoryCommentsCount(postId);
            notifyListeners();
          }
        } catch (e) {
          AppLogger.error('Ошибка загрузки нового комментария', tag: _logTag, error: e);
        }
      } else if (event == PostgresChangeEvent.update) {
        // Обновление комментария
        final commentId = record['id'] as String?;
        if (commentId == null) return;
        
        final index = _comments.indexWhere((c) => c.id == commentId);
        if (index != -1) {
          _comments[index] = _comments[index].copyWith(
            text: record['text'] as String? ?? _comments[index].text,
            likes: record['likes_count'] as int? ?? _comments[index].likes,
            // isLiked не трогаем — он управляется локально через toggleCommentLike
            isPinned: record['is_pinned'] as bool? ?? _comments[index].isPinned,
          );
          notifyListeners();
        }
      } else if (event == PostgresChangeEvent.delete) {
        // Удаление комментария
        final commentId = record['id'] as String?;
        if (commentId == null) return;
        
        _comments.removeWhere((c) => c.id == commentId);
        _recalculateStoryCommentsCount(postId);
        notifyListeners();
      }
    });
    
    _commentsRealtimeChannels[postId] = channel;
  }

  // Отписка от realtime комментариев
  Future<void> unsubscribeFromCommentsRealtime(String postId) async {
    final channel = _commentsRealtimeChannels.remove(postId);
    if (channel != null) {
      await SupabasePostService().unsubscribeFromComments(channel);
    }
  }

  Comment _mapSupabaseCommentToComment(
    Map<String, dynamic> commentData,
    String postId, {
    String? Function(String? id)? rootFinder,
  }) {
    final user = commentData['users'] as Map<String, dynamic>?;
    final parentId = commentData['parent_id'] as String?;

    String? replyToAuthor;
    String? threadRootId;
    final replyTargetId = parentId;

    if (parentId == null) {
      threadRootId = commentData['id'] as String;
    } else {
      Comment? parent;
      try {
        parent = _comments.firstWhere((c) => c.id == parentId);
      } catch (_) {
        parent = null;
      }

      if (rootFinder != null) {
        threadRootId = rootFinder(parentId) ?? parentId;
      } else {
        threadRootId = parent?.threadRootId ?? parentId;
      }
      replyToAuthor = parent?.isAnonymous == true ? 'Аноним' : parent?.author.name;
    }
    
    final mediaUrl = commentData['media_url'] as String?;
    final premiumExpiresAtRaw = user?['premium_expires_at'];
    final premiumExpiresAt = premiumExpiresAtRaw is String
        ? DateTime.tryParse(premiumExpiresAtRaw)
        : null;
    final isPremium = (user?['role'] as String?) == 'premium' || (user?['is_premium'] as bool? ?? false) || premiumExpiresAt != null;
    
    return Comment(
      id: commentData['id'] as String,
      storyId: postId,
      author: User(
        id: user?['id'] as String? ?? '',
        username: user?['username'] as String? ?? 'user',
        name: user?['full_name'] as String? ?? 'Пользователь',
        avatar: user?['avatar_url'] as String? ?? '',
        isPremium: isPremium,
        premiumExpiresAt: premiumExpiresAt,
        isVerified: user?['is_verified'] as bool? ?? false,
        bio: '',
        followersCount: 0,
        followingCount: 0,
        isFollowed: false,
        isPrivate: false,
      ),
      text: commentData['text'] as String? ?? '',
      createdAt: DateTime.parse(commentData['created_at'] as String).toLocal(),
      updatedAt: commentData['updated_at'] != null 
          ? DateTime.parse(commentData['updated_at'] as String).toLocal()
          : null,
      likes: commentData['likes_count'] as int? ?? 0,
      isLiked: commentData['is_liked'] as bool? ?? false,
      replyToId: parentId,
      replyToAuthor: replyToAuthor,
      replyTargetId: replyTargetId,
      threadRootId: threadRootId,
      isAnonymous: commentData['is_anonymous'] as bool? ?? false,
      mediaUrl: mediaUrl,
      mediaType: commentData['media_type'] as String?,
      mediaWidth: commentData['media_width'] as int?,
      mediaHeight: commentData['media_height'] as int?,
      isPinned: commentData['is_pinned'] as bool? ?? false,
    );
  }

  /// Получить локально загруженные комментарии для дебата
  List<DiscussionComment> getDiscussionComments(String discussionId) {
    return _discussionComments[discussionId] ?? [];
  }

  // Получить самый залайканный комментарий
  Comment? getTopComment(String storyId) {
    final comments = _comments.where((c) => c.storyId == storyId && c.replyToId == null).toList();
    if (comments.isEmpty) return null;
    
    // Находим комментарий с максимальным количеством лайков
    comments.sort((a, b) => b.likes.compareTo(a.likes));
    return comments.first.likes > 0 ? comments.first : null;
  }

  // Загрузить топ-комментарий для поста из Supabase
  Future<void> loadTopCommentForPost(String postId) async {
    if (!Features.useSupabasePosts) return;
    
    // Если уже загружали комментарии для этого поста, не нужно загружать топ отдельно
    if (_loadedPostIds.contains(postId)) return;
    
    try {
      final postService = SupabasePostService();
      final topCommentData = await postService.getTopComment(postId);
      
      if (topCommentData == null) return;
      
      // Проверяем, нет ли уже этого комментария локально
      final existingIndex = _comments.indexWhere((c) => c.id == topCommentData['id']);
      if (existingIndex != -1) return;
      
      // Добавляем топ-комментарий в локальный список
      final user = topCommentData['users'] as Map<String, dynamic>?;
      final premiumExpiresAtRaw = user?['premium_expires_at'];
      final premiumExpiresAt = premiumExpiresAtRaw is String
          ? DateTime.tryParse(premiumExpiresAtRaw)
          : null;
      final isPremium = (user?['role'] as String?) == 'premium' || (user?['is_premium'] as bool? ?? false) || premiumExpiresAt != null;
      final topComment = Comment(
        id: topCommentData['id'] as String,
        storyId: postId,
        author: User(
          id: user?['id'] as String? ?? '',
          username: user?['username'] as String? ?? 'user',
          name: user?['full_name'] as String? ?? 'Пользователь',
          avatar: user?['avatar_url'] as String? ?? '',
          isPremium: isPremium,
          premiumExpiresAt: premiumExpiresAt,
          karma: 0,
          isVerified: user?['is_verified'] as bool? ?? false,
        ),
        text: topCommentData['text'] as String? ?? '',
        createdAt: DateTime.parse(topCommentData['created_at'] as String).toLocal(),
        updatedAt: topCommentData['updated_at'] != null 
            ? DateTime.parse(topCommentData['updated_at'] as String).toLocal()
            : null,
        likes: topCommentData['likes_count'] as int? ?? 0,
        isLiked: false, // Лайки загружаются отдельно
        isPendingSync: false,
      );
      
      // BUG-032: проверяем лайкнул ли текущий пользователь этот комментарий
      bool isLiked = false;
      final currentUserId = _currentUser?.id;
      if (currentUserId != null && currentUserId.isNotEmpty) {
        try {
          final likedIds = await postService.getUserCommentLikes(currentUserId, [topComment.id]);
          isLiked = likedIds.contains(topComment.id);
        } catch (_) {}
      }
      _comments.add(isLiked ? topComment.copyWith(isLiked: true) : topComment);
      notifyListeners();
    } catch (e) {
      AppLogger.error('Ошибка загрузки топ-комментария', tag: _logTag, error: e);
      _isOffline = true;
    }
  }

  // Добавить комментарий (локально сразу, затем синхронизировать с Supabase)
  Future<void> addComment(Comment comment) async {
    // Проверка rate limit
    if (_currentUser != null) {
      final rateLimitService = RateLimitService();
      if (!rateLimitService.canComment(_currentUser!.id)) {
        AppLogger.warning('Rate limit: слишком много комментариев', tag: _logTag);
        throw Exception('Слишком много комментариев. Подождите минуту.');
      }
    }
    
    // 1. Добавляем локально сразу (пользователь видит результат)
    // Дедупликация: не добавляем если комментарий с таким id уже есть
    if (_comments.any((c) => c.id == comment.id)) return;
    _comments.add(comment);
    _recalculateStoryCommentsCount(comment.storyId);
    unawaited(_savePendingCommentsToCache());
    
    // Воспроизводим звук комментария
    AudioService.playCommentSound();
    
    // notifyListeners() уже вызывается в _recalculateStoryCommentsCount
    
    // 2. Пытаемся отправить в Supabase в фоне
    if (Features.useSupabasePosts && _currentUser != null) {
      try {
        final postService = SupabasePostService();
        final currentUserId = _currentUser!.id;

        // parentId в БД соответствует корневому комментарию ветки (replyToId)
        final parentId = comment.replyToId;

        final result = await postService.addComment(
          id: comment.id,
          postId: comment.storyId,
          userId: currentUserId,
          text: comment.text,
          parentId: parentId,
          mediaUrl: comment.mediaUrl,
          mediaType: comment.mediaType,
          mediaWidth: comment.mediaWidth,
          mediaHeight: comment.mediaHeight,
          isAnonymous: comment.isAnonymous,
        );

        if (result != null) {
          // Обновляем комментарий данными с сервера, но сохраняем локальные поля ветки
          final index = _comments.indexWhere((c) => c.id == comment.id);
          if (index != -1) {
            final serverComment = _mapSupabaseCommentToComment(result, comment.storyId)
                .copyWith(
                  replyToAuthor: comment.replyToAuthor,
                  replyTargetId: comment.replyTargetId,
                  threadRootId: comment.threadRootId,
                  isPendingSync: false,
                );
            _comments[index] = serverComment;
            _recalculateStoryCommentsCount(comment.storyId);
            unawaited(_savePendingCommentsToCache());
          }
          AppLogger.success('Комментарий синхронизирован с Supabase', tag: _logTag);
          
          // Создаём уведомление для автора поста
          if (Features.useSupabaseNotifications && Features.useSupabaseUsers) {
            try {
              final currentUserId = _currentUser!.id;

              String? recipientId;
              String notificationType;

              if (comment.replyToId != null) {
                notificationType = 'reply';
                final targetId = comment.replyTargetId ?? comment.replyToId;
                Comment? parent;
                try {
                  parent = _comments.firstWhere((c) => c.id == targetId);
                } catch (_) {
                  parent = null;
                }
                recipientId = parent?.author.id;
              } else {
                notificationType = 'comment';
                String? authorId;
                try {
                  final story = _stories.firstWhere((s) => s.id == comment.storyId);
                  authorId = story.author.id;
                } catch (_) {
                  authorId = null;
                }
                if (authorId == null || authorId.isEmpty) {
                  try {
                    final data = await Supabase.instance.client
                        .from('posts_safe')
                        .select('user_id')
                        .eq('id', comment.storyId)
                        .maybeSingle();
                    authorId = data?['user_id'] as String?;
                  } catch (_) {
                    authorId = null;
                  }
                }
                recipientId = authorId;
              }

              if (notificationType == 'reply' && (recipientId == null || recipientId.isEmpty)) {
                final targetId = comment.replyTargetId ?? comment.replyToId;
                if (targetId != null && targetId.isNotEmpty) {
                  try {
                    final data = await Supabase.instance.client
                        .from('comments')
                        .select('user_id')
                        .eq('id', targetId)
                        .maybeSingle();
                    recipientId = data?['user_id'] as String?;
                  } catch (_) {
                    recipientId = recipientId;
                  }
                }
              }

              if (recipientId != null && recipientId.isNotEmpty && recipientId != currentUserId) {
                final notificationService = SupabaseNotificationService();
                await notificationService.createNotification(
                  userId: recipientId,
                  type: notificationType,
                  actorId: currentUserId,
                  postId: comment.storyId,
                  commentId: comment.id,
                  commentText: comment.text,
                );
              }
            } catch (e) {
              AppLogger.warning('Не удалось создать уведомление о комментарии', tag: _logTag, error: e);
            }
            
            // Отправляем уведомления для @упоминаний
            try {
              final mentions = RegExp(r'@(\w+)').allMatches(comment.text);
              if (mentions.isNotEmpty) {
                final notificationService = SupabaseNotificationService();
                final currentUserId = _currentUser!.id;
                final mentionedUsernames = mentions.map((m) => m.group(1)!).toSet();
                
                for (final username in mentionedUsernames) {
                  try {
                    final userData = await Supabase.instance.client
                        .from('users')
                        .select('id')
                        .eq('username', username)
                        .maybeSingle();
                    
                    if (userData != null) {
                      final mentionedUserId = userData['id'] as String;
                      if (mentionedUserId != currentUserId) {
                        await notificationService.createNotification(
                          userId: mentionedUserId,
                          type: 'mention',
                          actorId: currentUserId,
                          postId: comment.storyId,
                          commentId: comment.id,
                          commentText: comment.text,
                        );
                      }
                    }
                  } catch (_) {}
                }
              }
            } catch (e) {
              AppLogger.warning('Не удалось отправить уведомления об упоминаниях', tag: _logTag, error: e);
            }
          }
        }
      } catch (e) {
        // Ошибка Supabase — помечаем isPendingSync: true, чтобы не потерялся при перезагрузке
        AppLogger.warning('Не удалось синхронизировать комментарий с Supabase', tag: _logTag, error: e);
        final idx = _comments.indexWhere((c) => c.id == comment.id);
        if (idx != -1 && !_comments[idx].isPendingSync) {
          _comments[idx] = _comments[idx].copyWith(isPendingSync: true);
          unawaited(_savePendingCommentsToCache());
          notifyListeners();
        }
        await OfflineQueueService().enqueue(
          OfflineActionType.comment,
          {
            'userId': _currentUser!.id,
            'postId': comment.storyId,
            'commentId': comment.id,
            'text': comment.text,
            'parentId': comment.replyToId,
          },
        );
      }
    }
  }

  // Лайк комментария (локально сразу, затем синхронизировать с Supabase)
  Future<void> toggleCommentLike(String commentId) async {
    // Защита от двойного нажатия — если лайк уже в процессе, игнорируем
    if (_commentLikePending.contains(commentId)) return;
    _commentLikePending.add(commentId);

    try {
      await _toggleCommentLikeInternal(commentId);
    } finally {
      _commentLikePending.remove(commentId);
    }
  }

  Future<void> _toggleCommentLikeInternal(String commentId) async {
    final index = _comments.indexWhere((c) => c.id == commentId);
    if (index == -1) return;

    final comment = _comments[index];

    // Запоминаем состояние ДО изменения для уведомления и отката
    final wasLiked = comment.isLiked;

    // 1. Обновляем локально сразу
    _comments[index] = comment.copyWith(
      isLiked: !wasLiked,
      likes: wasLiked ? (comment.likes > 0 ? comment.likes - 1 : 0) : comment.likes + 1,
    );
    unawaited(_savePendingCommentLikesToCache());
    notifyListeners();

    // 2. Пытаемся синхронизировать с Supabase в фоне
    if (Features.useSupabasePosts && _currentUser != null) {
      try {
        final postService = SupabasePostService();
        final currentUserId = Supabase.instance.client.auth.currentUser?.id ?? _currentUser?.id;
        if (currentUserId == null || currentUserId.isEmpty) {
          return;
        }
        await postService.toggleCommentLike(commentId, currentUserId);
        unawaited(_clearPendingCommentLikeFromCache(commentId));
        
        // Отправляем уведомление если лайк поставлен (не снят) и автор не текущий пользователь
        if (!wasLiked && comment.author.id != currentUserId) {
          try {
            await _supabaseNotificationService.createNotification(
              userId: comment.author.id,
              type: 'comment_like',
              postId: comment.storyId,
              actorId: currentUserId,
              commentId: commentId,
              text: '${_currentUser?.name ?? 'Кто-то'} лайкнул(а) ваш комментарий',
            );
          } catch (e) {
            AppLogger.warning('Не удалось отправить уведомление о лайке комментария', tag: _logTag, error: e);
          }
        }
      } catch (e) {
        AppLogger.warning('Не удалось синхронизировать лайк с Supabase', tag: _logTag, error: e);
        // Откатываем локальное изменение при ошибке
        final rollbackIndex = _comments.indexWhere((c) => c.id == commentId);
        if (rollbackIndex != -1) {
          _comments[rollbackIndex] = _comments[rollbackIndex].copyWith(
            isLiked: wasLiked,
            likes: wasLiked ? _comments[rollbackIndex].likes + 1 : (_comments[rollbackIndex].likes > 0 ? _comments[rollbackIndex].likes - 1 : 0),
          );
          unawaited(_savePendingCommentLikesToCache());
          notifyListeners();
        }
      }
    }
  }

  Future<void> _savePendingCommentsToCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = Supabase.instance.client.auth.currentUser?.id ?? _currentUser?.id;
      final key = userId == null || userId.isEmpty
          ? 'pending_comments_cache'
          : 'pending_comments_cache_$userId';
      final encoded = _comments
          .where((c) => c.isPendingSync)
          .map((c) => {
                'id': c.id,
                'story_id': c.storyId,
                'author': {
                  'id': c.author.id,
                  'username': c.author.username,
                  'full_name': c.author.name,
                  'avatar_url': c.author.avatar,
                  'is_verified': c.author.isVerified,
                  'role': c.author.isPremium ? 'premium' : 'free',
                  'premium_expires_at': c.author.premiumExpiresAt?.toIso8601String(),
                },
                'text': c.text,
                'created_at': c.createdAt.toIso8601String(),
                'updated_at': c.updatedAt?.toIso8601String(),
                'likes_count': c.likes,
                'is_liked': c.isLiked,
                'parent_id': c.replyToId,
                'reply_to_author': c.replyToAuthor,
                'reply_target_id': c.replyTargetId,
                'thread_root_id': c.threadRootId,
                'is_pending_sync': c.isPendingSync,
                'is_anonymous': c.isAnonymous,
                'media_url': c.mediaUrl,
                'media_type': c.mediaType,
                'media_width': c.mediaWidth,
                'media_height': c.mediaHeight,
                'is_pinned': c.isPinned,
              })
          .toList();
      await prefs.setString(key, jsonEncode(encoded));
    } catch (e) {
      AppLogger.warning('Ошибка сохранения pending комментариев', tag: _logTag, error: e);
    }
  }

  Future<void> _loadPendingCommentsFromCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = Supabase.instance.client.auth.currentUser?.id ?? _lastKnownAuthUserId ?? _currentUser?.id;
      final key = userId == null || userId.isEmpty
          ? 'pending_comments_cache'
          : 'pending_comments_cache_$userId';
      final raw = prefs.getString(key);
      if (raw == null || raw.isEmpty) return;
      final decoded = List<Map<String, dynamic>>.from(jsonDecode(raw) as List);
      for (final item in decoded) {
        final author = Map<String, dynamic>.from(item['author'] as Map? ?? {});
        final premiumExpiresAtRaw = author['premium_expires_at'];
        final premiumExpiresAt = premiumExpiresAtRaw is String ? DateTime.tryParse(premiumExpiresAtRaw) : null;
        final restored = Comment(
          id: item['id'] as String? ?? '',
          storyId: item['story_id'] as String? ?? '',
          author: User(
            id: author['id'] as String? ?? '',
            username: author['username'] as String? ?? 'user',
            name: author['full_name'] as String? ?? 'Пользователь',
            avatar: author['avatar_url'] as String? ?? '',
            isPremium: (author['role'] as String?) == 'premium',
            premiumExpiresAt: premiumExpiresAt,
            isVerified: author['is_verified'] as bool? ?? false,
            bio: '',
            followersCount: 0,
            followingCount: 0,
            isFollowed: false,
            isPrivate: false,
          ),
          text: item['text'] as String? ?? '',
          createdAt: (DateTime.tryParse(item['created_at'] as String? ?? '') ?? DateTime.now()).toLocal(),
          updatedAt: item['updated_at'] != null ? DateTime.tryParse(item['updated_at'] as String)?.toLocal() : null,
          likes: item['likes_count'] as int? ?? 0,
          isLiked: item['is_liked'] as bool? ?? false,
          replyToId: item['parent_id'] as String?,
          replyToAuthor: item['reply_to_author'] as String?,
          replyTargetId: item['reply_target_id'] as String?,
          threadRootId: item['thread_root_id'] as String?,
          isPendingSync: item['is_pending_sync'] as bool? ?? true,
          isAnonymous: item['is_anonymous'] as bool? ?? false,
          mediaUrl: item['media_url'] as String?,
          mediaType: item['media_type'] as String?,
          mediaWidth: item['media_width'] as int?,
          mediaHeight: item['media_height'] as int?,
          isPinned: item['is_pinned'] as bool? ?? false,
        );
        if (restored.id.isNotEmpty && !_comments.any((c) => c.id == restored.id)) {
          _comments.add(restored);
        }
      }
    } catch (e) {
      AppLogger.warning('Ошибка загрузки pending комментариев', tag: _logTag, error: e);
    }
  }

  Future<void> _savePendingCommentLikesToCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = Supabase.instance.client.auth.currentUser?.id ?? _currentUser?.id;
      final key = userId == null || userId.isEmpty
          ? 'pending_comment_likes_cache'
          : 'pending_comment_likes_cache_$userId';
      final encoded = _comments
          .where((c) => c.isLiked || c.likes > 0)
          .map((c) => {
                'id': c.id,
                'is_liked': c.isLiked,
                'likes_count': c.likes,
              })
          .toList();
      await prefs.setString(key, jsonEncode(encoded));
    } catch (e) {
      AppLogger.warning('Ошибка сохранения pending лайков комментариев', tag: _logTag, error: e);
    }
  }

  Future<void> _loadPendingCommentLikesFromCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = Supabase.instance.client.auth.currentUser?.id ?? _lastKnownAuthUserId ?? _currentUser?.id;
      final key = userId == null || userId.isEmpty
          ? 'pending_comment_likes_cache'
          : 'pending_comment_likes_cache_$userId';
      final raw = prefs.getString(key);
      if (raw == null || raw.isEmpty) return;
      final decoded = List<Map<String, dynamic>>.from(jsonDecode(raw) as List);
      for (final item in decoded) {
        final commentId = item['id'] as String?;
        if (commentId == null || commentId.isEmpty) continue;
        final index = _comments.indexWhere((c) => c.id == commentId);
        if (index == -1) continue;
        _comments[index] = _comments[index].copyWith(
          isLiked: item['is_liked'] as bool? ?? _comments[index].isLiked,
          likes: item['likes_count'] as int? ?? _comments[index].likes,
        );
      }
    } catch (e) {
      AppLogger.warning('Ошибка загрузки pending лайков комментариев', tag: _logTag, error: e);
    }
  }

  Future<void> _clearPendingCommentLikeFromCache(String commentId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = Supabase.instance.client.auth.currentUser?.id ?? _currentUser?.id;
      final key = userId == null || userId.isEmpty
          ? 'pending_comment_likes_cache'
          : 'pending_comment_likes_cache_$userId';
      final raw = prefs.getString(key);
      if (raw == null || raw.isEmpty) return;
      final decoded = List<Map<String, dynamic>>.from(jsonDecode(raw) as List)
        ..removeWhere((item) => item['id'] == commentId);
      await prefs.setString(key, jsonEncode(decoded));
    } catch (e) {
      AppLogger.warning('Ошибка очистки pending лайка комментария', tag: _logTag, error: e);
    }
  }

  // Редактировать комментарий (локально сразу, затем синхронизировать с Supabase)
  Future<void> editComment(String commentId, String newText) async {
    final index = _comments.indexWhere((c) => c.id == commentId);
    if (index != -1) {
      final oldComment = _comments[index];
      
      // Проверяем, можно ли редактировать (в течение 10 минут)
      if (!oldComment.canEdit) {
        return;
      }
      
      // 1. Обновляем локально сразу
      _comments[index] = _comments[index].copyWith(
        text: newText,
        updatedAt: DateTime.now(),
      );
      notifyListeners();
      
      // 2. Пытаемся синхронизировать с Supabase в фоне
      if (Features.useSupabasePosts && _currentUser != null) {
        try {
          final postService = SupabasePostService();
          final currentUserId = _currentUser!.id;
          await postService.editComment(commentId, currentUserId, newText);
          AppLogger.success('Комментарий отредактирован в Supabase', tag: _logTag);
        } catch (e) {
          AppLogger.warning('Не удалось синхронизировать редактирование с Supabase', tag: _logTag, error: e);
          // Откатываем локальное изменение при ошибке
          final rollbackIndex = _comments.indexWhere((c) => c.id == commentId);
          if (rollbackIndex != -1) {
            _comments[rollbackIndex] = oldComment;
            notifyListeners();
          }
        }
      }
    }
  }

  
  // Удалить комментарий (локально сразу, затем синхронизировать с Supabase)
  Future<void> deleteComment(String commentId) async {
    final index = _comments.indexWhere((c) => c.id == commentId);
    if (index != -1) {
      final comment = _comments[index];
      
      // 1. Удаляем локально сразу
      _comments.removeAt(index);
      _recalculateStoryCommentsCount(comment.storyId);
      // notifyListeners() уже вызывается в _recalculateStoryCommentsCount
      
      // 2. Пытаемся удалить из Supabase в фоне
      if (Features.useSupabasePosts && _currentUser != null) {
        try {
          final postService = SupabasePostService();
          final currentUserId = _currentUser!.id;
          await postService.deleteComment(commentId, currentUserId);
        } catch (e) {
          AppLogger.warning('Не удалось удалить комментарий из Supabase', tag: _logTag, error: e);
          // Локальное удаление остаётся в силе
        }
      }
    }
  }

  // Закрепить/открепить комментарий (только автор поста)
  Future<void> togglePinComment(String commentId, String storyId) async {
    final storyIndex = _stories.indexWhere((s) => s.id == storyId);
    if (storyIndex == -1) return;
    final story = _stories[storyIndex];
    if (_currentUser == null || story.author.id != _currentUser!.id) return;

    final index = _comments.indexWhere((c) => c.id == commentId);
    if (index == -1) return;

    final comment = _comments[index];
    final newPinState = !comment.isPinned;

    // Оптимистичное обновление локально
    if (newPinState) {
      for (int i = 0; i < _comments.length; i++) {
        if (_comments[i].storyId == storyId && _comments[i].isPinned) {
          _comments[i] = _comments[i].copyWith(isPinned: false);
        }
      }
    }

    _comments[index] = comment.copyWith(isPinned: newPinState);
    notifyListeners();

    // Синхронизация с Supabase
    try {
      final postService = SupabasePostService();
      await postService.togglePinComment(commentId, storyId, newPinState);
      AppLogger.success('Закрепление комментария синхронизировано с БД', tag: _logTag);
    } catch (e) {
      AppLogger.warning('Не удалось синхронизировать закрепление с Supabase', tag: _logTag, error: e);
    }
  }

  void _recalculateStoryCommentsCount(String storyId) {
    
    // Добавляем в очередь на обновление
    _pendingCommentsCountUpdates.add(storyId);
    
    // Отменяем предыдущий таймер
    _commentsCountDebounceTimer?.cancel();
    
    // Устанавливаем новый таймер с дебаунсом 100мс
    _commentsCountDebounceTimer = Timer(const Duration(milliseconds: 100), () {
      if (_pendingCommentsCountUpdates.isEmpty) return;
      
      // Обрабатываем все ожидающие обновления
      final updatesToProcess = Set<String>.from(_pendingCommentsCountUpdates);
      _pendingCommentsCountUpdates.clear();
      
      
      for (final currentStoryId in updatesToProcess) {
        _processCommentsCountUpdate(currentStoryId);
      }
    });
  }
  
  void _processCommentsCountUpdate(String storyId) {
    // Считаем ВСЕ комментарии (и главные, и подответы)
    final commentCount = _comments.where((c) => c.storyId == storyId).length;
    
    // Сначала ищем в _stories (посты)
    final storyIndex = _stories.indexWhere((s) => s.id == storyId);
    if (storyIndex != -1) {
      final story = _stories[storyIndex];
      final updatedStory = story.copyWith(comments: commentCount);

      // Обновляем основной список
      final oldCount = story.comments;
      _stories = List.from(_stories);
      _stories[storyIndex] = updatedStory;

      // Обновляем кэш профиля, чтобы число совпадало на карточках в профиле
      final authorId = story.author.id;
      final cachedStories = _userStoriesCache[authorId];
      if (cachedStories != null) {
        final cachedIndex = cachedStories.indexWhere((s) => s.id == storyId);
        if (cachedIndex != -1) {
          final newCachedStories = List<Story>.from(cachedStories);
          newCachedStories[cachedIndex] = cachedStories[cachedIndex].copyWith(comments: commentCount);
          _userStoriesCache[authorId] = newCachedStories;
        }
      }

      notifyListeners();
    }
  }

  // Переключить закладку
  Future<void> toggleBookmark(String storyId) async {
    final index = _stories.indexWhere((s) => s.id == storyId);
    if (index != -1) {
      final story = _stories[index];
      
      // Оптимистичное обновление UI
      final updatedStory = story.copyWith(isBookmarked: !story.isBookmarked);
      
      // ВАЖНО: Создаем новый список чтобы Flutter увидел изменения!
      _stories = List.from(_stories);
      _stories[index] = updatedStory;
      
      _updateStoryInUserCaches(updatedStory);
      _updateSavedStoriesWith(updatedStory);
      _updateLikedStoriesWith(updatedStory); // Обновляем также в лайкнутых
      final currentUserIdForCache = _currentUser?.id ?? Supabase.instance.client.auth.currentUser?.id ?? '';
      if (Features.useSupabasePosts) {
        if (updatedStory.isBookmarked) {
          _bookmarkedPostIds.add(storyId);
        } else {
          _bookmarkedPostIds.remove(storyId);
        }
        if (currentUserIdForCache.isNotEmpty) {
          unawaited(_cacheInteractionIds(currentUserIdForCache));
        }
      }
      notifyListeners();
      
      // Сохраняем в Supabase
      if (Features.useSupabasePosts) {
        try {
          final postService = SupabasePostService();
          final currentUserId = _currentUser?.id ?? '';
          
          if (story.isBookmarked) {
            // Удаляем из закладок
            await postService.removeBookmark(currentUserId, storyId);
          } else {
            // Добавляем в закладки
            await postService.addBookmark(currentUserId, storyId);
          }
        } catch (e) {
          AppLogger.error('Ошибка переключения закладки', tag: _logTag, error: e);
          // Сохраняем в офлайн-очередь вместо отката UI
          final currentUserId = _currentUser?.id ?? '';
          await OfflineQueueService().enqueue(
            story.isBookmarked ? OfflineActionType.unbookmark : OfflineActionType.bookmark,
            {'userId': currentUserId, 'postId': storyId},
          );
        }
      }
    }
  }

  // Получить сохранённые посты
  Future<void> loadBookmarkedPosts() async {
    if (!Features.useSupabasePosts || _isSavedStoriesLoading) return;

    final currentUserId = _currentUser?.id;
    if (currentUserId == null || currentUserId.isEmpty) return;

    _isSavedStoriesLoading = true;
    notifyListeners();

    try {
      final postService = SupabasePostService();
      
      // Загружаем актуальные лайки, закладки и голоса
      final userLikes = await postService.getUserLikes(currentUserId);
      _likedPostIds = userLikes.map((like) => like['post_id'] as String).toSet();
      
      final userBookmarks = await postService.getUserBookmarks(currentUserId);
      _bookmarkedPostIds = userBookmarks.toSet();
      
      // Загружаем голоса в опросах (добавляем к уже известным)
      final pollVotes = await postService.getUserPollVotes(currentUserId);
      _applyUserPollVotes(pollVotes);
      final localPollVotes = _groupPollVotes(pollVotes);
      
      final bookmarkedPosts = await postService.getBookmarkedPosts(currentUserId);

      final stories = <Story>[];
      for (final post in bookmarkedPosts) {
        try {
          final story = await _mapSupabasePostToStoryWithLikes(
            post,
            _likedPostIds,
            _bookmarkedPostIds,
            localPollVotes,
          );
          stories.add(story);
        } catch (e) {
          // Skip invalid bookmarks
        }
      }

      // Пересчитываем счётчики комментариев для постов, у которых уже загружены комментарии
      for (final story in stories) {
        if (_loadedPostIds.contains(story.id)) {
          final storyIndex = stories.indexOf(story);
          final commentCount = _comments.where((c) => c.storyId == story.id).length;
          stories[storyIndex] = story.copyWith(comments: commentCount);
        }
      }

      _savedStories = stories;
    } catch (e) {
      AppLogger.error('Ошибка загрузки закладок', tag: _logTag, error: e);
    } finally {
      _isSavedStoriesLoading = false;
      notifyListeners();
    }
  }

  Future<void> loadLikedPosts() async {
    if (!Features.useSupabasePosts) {
      await _loadLikedPosts();
      return;
    }

    if (_isLikedStoriesLoading) return;

    final currentUserId = _currentUser?.id;
    if (currentUserId == null || currentUserId.isEmpty) return;

    _isLikedStoriesLoading = true;
    notifyListeners();

    try {
      final postService = SupabasePostService();
      
      // Загружаем актуальные лайки, закладки и голоса
      final userLikes = await postService.getUserLikes(currentUserId);
      _likedPostIds = userLikes.map((like) => like['post_id'] as String).toSet();
      
      final userBookmarks = await postService.getUserBookmarks(currentUserId);
      _bookmarkedPostIds = userBookmarks.toSet();
      
      // Загружаем голоса в опросах (добавляем/обновляем в кэше)
      final pollVotes = await postService.getUserPollVotes(currentUserId);
      _applyUserPollVotes(pollVotes);
      final localPollVotes = _groupPollVotes(pollVotes);
      
      final likedPosts = await postService.getLikedPosts(currentUserId);

      final stories = <Story>[];
      for (final post in likedPosts) {
        try {
          final story = await _mapSupabasePostToStoryWithLikes(
            post,
            _likedPostIds,
            _bookmarkedPostIds,
            localPollVotes,
          );
          stories.add(story);
        } catch (e) {
          // Skip invalid likes
        }
      }

      // Пересчитываем счётчики комментариев для постов, у которых уже загружены комментарии
      for (final story in stories) {
        if (_loadedPostIds.contains(story.id)) {
          final storyIndex = stories.indexOf(story);
          final commentCount = _comments.where((c) => c.storyId == story.id).length;
          stories[storyIndex] = story.copyWith(comments: commentCount);
        }
      }

      _likedStories = stories;
    } catch (e) {
      AppLogger.error('Ошибка загрузки лайкнутых постов', tag: _logTag, error: e);
    } finally {
      _isLikedStoriesLoading = false;
      notifyListeners();
    }
  }

  // ============================================================================
  // ЧАТЫ И СООБЩЕНИЯ - Отправка, получение, редактирование
  // ============================================================================

  // Получить сообщения чата
  List<ChatMessage> getChatMessages(String userIdOrChatId) {
    // Для Supabase: преобразуем userId в chatId если нужно
    String chatId = userIdOrChatId;
    if (Features.useSupabaseChats && _userIdToChatId.containsKey(userIdOrChatId)) {
      chatId = _userIdToChatId[userIdOrChatId]!;
    } else if (!Features.useSupabaseChats) {
      chatId = 'chat_$userIdOrChatId';
    }

    if (_chatMessagesCache.containsKey(chatId)) {
      final cached = _chatMessagesCache[chatId]!;
      return List<ChatMessage>.from(cached);
    }

    final messages = _chatMessages.where((m) => m.chatId == chatId).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt)); // От новых к старым
    _chatMessagesCache[chatId] = messages;
    return messages;
  }

  // Добавить сообщение в чат
  void addChatMessage(ChatMessage message) {
    // Проверяем, нет ли уже такого сообщения (избегаем дубликатов)
    final exists = _chatMessages.any((m) => m.id == message.id);
    if (exists) {
      return;
    }
    
    // Проверяем, есть ли временное сообщение (optimistic UI) которое нужно заменить
    final tempIndex = _chatMessages.indexWhere((m) {
      if (!m.id.startsWith('temp_')) return false;
      if (m.chatId != message.chatId) return false;
      if (m.sender.id != message.sender.id) return false;
      if (m.text != message.text) return false;
      final delta = m.createdAt.difference(message.createdAt).inSeconds;
      return delta.abs() <= 5; // 5 секунд разницы
    });
    
    if (tempIndex != -1) {
      // Заменяем временное сообщение на реальное
      _chatMessages[tempIndex] = message;
      final chatMessages = _chatMessagesCache[message.chatId];
      if (chatMessages != null) {
        final cacheIndex = chatMessages.indexWhere((m) => m.id.startsWith('temp_') && m.text == message.text);
        if (cacheIndex != -1) {
          chatMessages[cacheIndex] = message;
        }
      }
      unawaited(_saveChatsToCache());
      notifyListeners();
      return;
    }
    
    // Доп. защита от дублей (на случай расхождений id)
    final nearDuplicate = _chatMessages.any((m) {
      if (m.chatId != message.chatId) return false;
      if (m.sender.id != message.sender.id) return false;
      if (m.text != message.text) return false;
      final delta = m.createdAt.difference(message.createdAt).inSeconds;
      return delta.abs() <= 1;
    });
    if (nearDuplicate) {
      return;
    }
    
    _chatMessages.add(message);
    final chatMessages = _chatMessagesCache.putIfAbsent(message.chatId, () => []);
    // Добавляем новое сообщение в начало (кеш отсортирован от новых к старым)
    chatMessages.insert(0, message);
    // Сортируем от новых к старым для reverse ListView
    chatMessages.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    unawaited(_saveChatsToCache());
    notifyListeners();
  }

  /// Проверить, отключены ли уведомления для чата
  bool isChatMuted(String chatId) {
    final preview = _chatPreviewCache[chatId];
    return preview?['is_muted'] == true;
  }

  // Получить список активных чатов (пользователей с которыми есть переписка)
  List<User> getActiveChats() {
    if (!Features.useSupabaseChats) {
      final Set<String> chatIds = {};
      for (final message in _chatMessages) {
        chatIds.add(message.chatId);
      }
      final Set<String> userIds = {};
      for (final chatId in chatIds) {
        final userId = chatId.replaceFirst('chat_', '');
        userIds.add(userId);
      }
      return _users.where((u) => userIds.contains(u.id)).toList();
    }

    final entries = _chatUsersCache.entries
        .map((e) {
          final chatId = e.key;
          final lastMessageAtRaw = _chatPreviewCache[chatId]?['last_message_at'] as String?;
          final lastMessageAt = lastMessageAtRaw != null ? _parseSupabaseTimestamp(lastMessageAtRaw) : null;
          return (chatId: chatId, user: e.value, lastMessageAt: lastMessageAt);
        })
        .toList();

    entries.sort((a, b) {
      final ta = a.lastMessageAt;
      final tb = b.lastMessageAt;
      if (ta == null && tb == null) return 0;
      if (ta == null) return 1;
      if (tb == null) return -1;
      return tb.compareTo(ta);
    });

    return entries.map((e) => e.user).toList();
  }

  // Получить последнее сообщение с пользователем
  ChatMessage? getLastMessage(String userId) {
    if (!Features.useSupabaseChats) {
      final chatId = 'chat_$userId';
      final messages = _chatMessages.where((m) => m.chatId == chatId).toList();
      if (messages.isEmpty) return null;
      messages.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return messages.first;
    }

    // Для Supabase: получаем реальный chatId
    final chatId = _userIdToChatId[userId];
    if (chatId == null) return null;
    
    // Сначала проверяем превью чата (всегда актуальное из базы)
    final chatData = _chatPreviewCache[chatId];
    final previewLastMessage = chatData?['last_message'] as String?;
    
    // Проверяем, есть ли сообщения в кеше
    if (_chatMessagesCache.containsKey(chatId)) {
      final messages = _chatMessagesCache[chatId]!;
      if (messages.isNotEmpty) {
        // Проверяем, совпадает ли первое сообщение в кеше с превью
        final cacheFirstMessage = messages.first.text;
        
        // Если кеш устарел (не совпадает с превью), используем превью
        if (previewLastMessage != null && cacheFirstMessage != previewLastMessage) {
          // Кеш устарел, переходим к созданию фейкового сообщения из превью
        } else {
          // Ищем последнее непрочитанное входящее сообщение (список отсортирован от новых к старым)
          for (int i = 0; i < messages.length; i++) {
            final msg = messages[i];
            if (!msg.isRead && msg.sender.id != _currentUser?.id) {
              return msg;
            }
          }
          
          // Если нет непрочитанных входящих, возвращаем абсолютное последнее сообщение (первый элемент = самый новый)
          return messages.first;
        }
      }
    }
    
    // Если сообщений нет в кеше или кеш устарел, создаём фейковое из last_message чата
    if (chatData != null && chatData['last_message'] != null) {
      // Определяем, кто отправил последнее сообщение
      final lastMessageSenderId = chatData['last_message_sender_id'] as String?;
      User sender;
      
      if (lastMessageSenderId == _currentUser?.id) {
        // Последнее сообщение от меня
        sender = _currentUser!;
      } else {
        // Последнее сообщение от собеседника
        sender = _chatUsersCache[chatId] ?? User(id: '', name: '', username: '', avatar: '', isPremium: false, karma: 0);
      }
      
      // Проверяем есть ли непрочитанные по счетчику
      final unreadCount = getUnreadCount(userId);
      final isUnread = unreadCount > 0 && lastMessageSenderId != _currentUser?.id;
      
      // Парсим время - если null, не создаем фейковое сообщение (ждем реальные данные)
      final lastMessageAt = chatData['last_message_at'] as String?;
      if (lastMessageAt == null) {
        return null;
      }
      final createdAt = _parseSupabaseTimestamp(lastMessageAt);
      
      final previewMessage = ChatMessage(
        id: chatId,
        chatId: chatId,
        sender: sender,
        text: chatData['last_message'] as String,
        createdAt: createdAt,
        isRead: !isUnread,
      );
      return previewMessage;
    }
    
    return null;
  }

  // Обновление ленты (pull-to-refresh)
  Future<void> refreshFeed() async {
    if (_isLoading) return;

    _isLoading = true;
    notifyListeners();

    try {
      if (Features.useSupabasePosts) {
        // Принудительно загружаем свежие данные из БД
        await refreshStories();
        _isOffline = false;
      }
    } catch (e) {
      AppLogger.error('Ошибка обновления ленты', tag: _logTag, error: e);
      _isOffline = true;
      if (Features.useSupabasePosts) {
        await _loadStoriesFromCache();
      }
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<Story?> fetchStoryById(String storyId) async {
    if (!Features.useSupabasePosts) return null;
    try {
      await _ensureInteractionSetsLoaded();

      final postService = SupabasePostService();
      final post = await postService.getPostById(storyId);
      if (post == null) return null;

      final story = await _mapSupabasePostToStoryWithLikes(
        post,
        _likedPostIds,
        _bookmarkedPostIds,
      );

      final existingIndex = _stories.indexWhere((s) => s.id == story.id);
      if (existingIndex != -1) {
        _stories = List<Story>.from(_stories);
        _stories[existingIndex] = story;
      } else {
        _stories = List<Story>.from(_stories);
        _stories.insert(0, story);
      }
      notifyListeners();
      return story;
    } catch (e) {
      AppLogger.warning('Не удалось загрузить пост по id=$storyId', tag: _logTag, error: e);
      return null;
    }
  }
  
  // Вступить/Выйти из сообщества
  Future<void> toggleJoinCommunity(String communityId) async {
    if (_joinedCommunities.contains(communityId)) {
      await leaveCommunity(communityId);
    } else {
      await joinCommunity(communityId);
    }
  }

  // Защита от двойного нажатия лайка поста
  final Set<String> _likePending = {};

  // Защита от двойного нажатия лайка комментария
  final Set<String> _commentLikePending = {};

  // Защита от двойного нажатия голосования в дебатах
  final Set<String> _votePending = {};

  // Лайк/дизлайк
  Future<void> toggleLike(String storyId) async {
    // Защита от двойного нажатия — если лайк уже в процессе, игнорируем
    if (_likePending.contains(storyId)) return;
    _likePending.add(storyId);

    try {
      await _toggleLikeInternal(storyId);
    } finally {
      _likePending.remove(storyId);
    }
  }

  Future<void> _toggleLikeInternal(String storyId) async {
    final index = _stories.indexWhere((story) => story.id == storyId);
    if (index == -1) return;

    // Проверка rate limit
    if (_currentUser != null) {
      final rateLimitService = RateLimitService();
      if (!rateLimitService.canLike(_currentUser!.id)) {
        return;
      }
    }

    final story = _stories[index];

    final currentUserId = Supabase.instance.client.auth.currentUser?.id ?? '';
    if (currentUserId.isEmpty) {
      return;
    }

    // Определяем реальное состояние лайка для текущего пользователя
    bool wasLiked = _likedPostIds.contains(storyId);
    if (Features.useSupabasePosts && !_hasLoadedLikes) {
      try {
        final postService = SupabasePostService();
        wasLiked = await postService.isLiked(currentUserId, storyId);
        if (wasLiked) {
          _likedPostIds.add(storyId);
        } else {
          _likedPostIds.remove(storyId);
        }
      } catch (_) {}
    }
    
    // Оптимистичное обновление UI
    final newLikesCount = wasLiked 
        ? (story.likes > 0 ? story.likes - 1 : 0)
        : story.likes + 1;
    
    final updatedStory = story.copyWith(
      isLiked: !wasLiked,
      likes: newLikesCount,
    );
    
    _stories = List.from(_stories);
    _stories[index] = updatedStory;
    
    // Воспроизводим звук лайка
    AudioService.playLikeSound();
    
    _updateStoryInUserCaches(updatedStory);
    _updateLikedStoriesWith(updatedStory);
    _updateSavedStoriesWith(updatedStory);
    if (Features.useSupabasePosts) {
      if (updatedStory.isLiked) {
        _likedPostIds.add(storyId);
      } else {
        _likedPostIds.remove(storyId);
      }
      unawaited(_cacheInteractionIds(currentUserId));
    }
    notifyListeners();
    
    if (Features.useSupabasePosts) {
      try {
        final postService = SupabasePostService();

        // Используем атомарный RPC (SECURITY DEFINER — обходит RLS проблемы)
        final result = await postService.toggleLike(currentUserId, storyId);
        final serverLiked = result['liked'] as bool?;
        final serverLikesCount = result['likes_count'] as int?;

        if (serverLiked != null) {
          if (serverLiked) {
            _likedPostIds.add(storyId);
          } else {
            _likedPostIds.remove(storyId);
          }
        }

        final idx = _stories.indexWhere((s) => s.id == storyId);
        if (idx != -1 && (serverLiked != null || serverLikesCount != null)) {
          _stories = List<Story>.from(_stories);
          _stories[idx] = _stories[idx].copyWith(
            isLiked: serverLiked ?? _stories[idx].isLiked,
            likes: serverLikesCount ?? _stories[idx].likes,
          );
          _updateStoryInUserCaches(_stories[idx]);
          _updateLikedStoriesWith(_stories[idx]);
          _updateSavedStoriesWith(_stories[idx]);
          notifyListeners();
        }

        // Отправляем уведомление автору поста при лайке (не при снятии лайка)
        final isNowLiked = serverLiked ?? !wasLiked;
        if (isNowLiked && Features.useSupabaseNotifications && Features.useSupabaseUsers) {
          try {
            final postAuthorId = story.author.id;
            if (postAuthorId.isNotEmpty && postAuthorId != currentUserId) {
              final notificationService = SupabaseNotificationService();
              await notificationService.createNotification(
                userId: postAuthorId,
                type: 'like',
                actorId: currentUserId,
                postId: storyId,
              );
            }
          } catch (e) {
            AppLogger.warning('Не удалось создать уведомление о лайке', tag: _logTag, error: e);
          }
        }
      } catch (e) {
        AppLogger.error('Ошибка лайка', tag: _logTag, error: e);
        final rollbackIndex = _stories.indexWhere((s) => s.id == storyId);
        if (rollbackIndex != -1) {
          _stories = List<Story>.from(_stories);
          _stories[rollbackIndex] = story.copyWith(
            isLiked: wasLiked,
            likes: story.likes,
          );
          if (wasLiked) {
            _likedPostIds.add(storyId);
          } else {
            _likedPostIds.remove(storyId);
          }
          _updateStoryInUserCaches(_stories[rollbackIndex]);
          _updateLikedStoriesWith(_stories[rollbackIndex]);
          _updateSavedStoriesWith(_stories[rollbackIndex]);
          notifyListeners();
        }
        // Сохраняем в офлайн-очередь для синхронизации позже
        await OfflineQueueService().enqueue(
          wasLiked ? OfflineActionType.unlike : OfflineActionType.like,
          {'userId': currentUserId, 'postId': storyId},
        );
      }
    } else {
      _saveLikedPosts();
    }
  }

  // Увеличить счетчик просмотров
  void incrementViews(String storyId) {
    if (_viewedStoryIds.contains(storyId)) {
      return;
    }

    final index = _stories.indexWhere((story) => story.id == storyId);
    if (index != -1) {
      _viewedStoryIds.add(storyId);
      final story = _stories[index];
      _stories[index] = story.copyWith(
        views: story.views + 1,
      );
      notifyListeners();
      
      // Отправляем на сервер
      if (Features.useSupabasePosts) {
        final postService = SupabasePostService();
        unawaited(postService.incrementViews(storyId));
      }
    }
  }

  // Создать репост с комментарием
  Future<bool> createRepost(Story originalStory, String comment) async {
    try {
      final currentUser = _currentUser ??
          (_users.isNotEmpty
              ? _users.first
              : User(
                  id: 'local_user',
                  name: 'Вы',
                  username: 'you',
                  avatar: '',
                  isPremium: false,
                  karma: 0,
                ));

      final newStory = Story(
        id: const Uuid().v4(),
        text: comment,
        author: currentUser,
        createdAt: DateTime.now(),
        likes: 0,
        comments: 0,
        reposts: 0,
        views: 0,
        isLiked: false,
        isBookmarked: false,
        images: [], // Репост не имеет своих изображений
        isAdult: originalStory.isAdult,
        quotedStory: originalStory, // Сохраняем оригинал для отображения
      );

      // ВАЖНО: Создаем новый список чтобы Flutter увидел изменения!
      _stories = List.from(_stories);
      
      // Добавляем локально СРАЗУ для мгновенного отображения
      _stories.insert(0, newStory);
      
      // Увеличиваем счетчик репостов у оригинального поста ЛОКАЛЬНО
      final originalIndex = _stories.indexWhere((s) => s.id == originalStory.id);
      if (originalIndex != -1) {
        _stories[originalIndex] = _stories[originalIndex].copyWith(
          reposts: _stories[originalIndex].reposts + 1,
        );
      }
      
      notifyListeners();
      
      // Подаем сигнал для скролла к началу
      _scrollToTopController.add(true);

      // Сохраняем в Supabase асинхронно
      if (Features.useSupabasePosts) {
        try {
          // Сохраняем репост напрямую, без вызова addStory чтобы избежать дублирования
          final postService = SupabasePostService();
          final currentUserId = _currentUser?.id ?? '';
          
          if (currentUserId.isEmpty) {
            throw Exception('Пользователь не авторизован');
          }

          final postData = await postService.createPost(
            userId: currentUserId,
            text: comment,
            mediaUrls: null,
            isAnonymous: false,
            isAdult: originalStory.isAdult,
            quotedPostId: originalStory.id, // Передаем ID оригинального поста
          );

          if (postData == null) {
            throw Exception('Не удалось создать репост в Supabase');
          }

          // Обновляем локальный пост с ID из БД
          final updatedStory = newStory.copyWith(
            id: postData['id'] as String,
            createdAt: DateTime.parse(postData['created_at'] as String).toLocal(),
          );
          
          // Находим и заменяем временный пост на пост с ID из БД
          final tempIndex = _stories.indexWhere((s) => s.id == newStory.id);
          if (tempIndex != -1) {
            _stories[tempIndex] = updatedStory;
          }
          
          notifyListeners();
          
          // Обновляем счетчик в Supabase только для оригинального поста
          try {
            await postService.incrementReposts(originalStory.id);
          } catch (e) {
            AppLogger.warning('Не удалось обновить счётчик репостов', tag: _logTag, error: e);
          }

          // Уведомление автору оригинального поста
          if (Features.useSupabaseNotifications &&
              Features.useSupabaseUsers &&
              originalStory.author.id != currentUserId) {
            try {
              final notificationService = SupabaseNotificationService();
              await notificationService.createNotification(
                userId: originalStory.author.id,
                type: 'repost',
                actorId: currentUserId,
                postId: originalStory.id,
              );
            } catch (_) {}
          }
        } catch (e) {
          AppLogger.error('Ошибка сохранения репоста в БД', tag: _logTag, error: e);
          // Откатываем локальные изменения при ошибке
          _stories.removeWhere((s) => s.id == newStory.id);
          if (originalIndex != -1) {
            _stories[originalIndex] = _stories[originalIndex].copyWith(
              reposts: _stories[originalIndex].reposts - 1,
            );
          }
          notifyListeners();
          return false;
        }
      }
      
      return true;
    } catch (e) {
      AppLogger.error('Ошибка создания репоста', tag: _logTag, error: e);
      return false;
    }
  }

  // Репост дебата как поста в ленту
  Future<bool> repostDiscussion(Discussion discussion, String comment) async {
    if (_currentUser == null) return false;
    try {
      final postService = SupabasePostService();
      final currentUserId = _currentUser!.id;

      // Формируем текст репоста: комментарий + ссылка на дебат
      final repostText = comment.isNotEmpty
          ? '$comment\n\n🔥 Дебат: «${discussion.question}»'
          : '🔥 Дебат: «${discussion.question}»';

      if (Features.useSupabasePosts) {
        final postData = await postService.createPost(
          userId: currentUserId,
          text: repostText,
          mediaUrls: discussion.imageUrl != null ? [discussion.imageUrl!] : null,
          isAnonymous: false,
          isAdult: false,
        );

        if (postData == null) return false;

        // Добавляем в ленту локально
        final newStory = Story(
          id: postData['id'] as String,
          text: repostText,
          author: _currentUser!,
          createdAt: DateTime.now(),
          likes: 0,
          comments: 0,
          reposts: 0,
          views: 0,
          isLiked: false,
          isBookmarked: false,
        );
        _stories = List.from(_stories)..insert(0, newStory);
        _scrollToTopController.add(true);
        notifyListeners();
      }

      AppLogger.success('Дебат репостнут', tag: _logTag);
      return true;
    } catch (e) {
      AppLogger.error('Ошибка репоста дебата', tag: _logTag, error: e);
      return false;
    }
  }

  // Подписка/отписка
  Future<bool> toggleFollow(String userId) async {
    // Проверяем, что это не свой профиль
    if (_currentUser?.id == userId) {
      return false;
    }
    
    final isFollowing = _followedUsers.contains(userId);
    final isPending = _pendingFollowRequests.contains(userId);
    
    // Находим пользователя в локальном списке
    final userIndex = _users.indexWhere((u) => u.id == userId);
    // Также ищем в рекомендациях
    final recIndex = _recommendedUsers.indexWhere((u) => u.id == userId);
    
    // Оптимистичное обновление UI
    if (isFollowing) {
      // Отписка
      _followedUsers.remove(userId);
      if (userIndex != -1) {
        final user = _users[userIndex];
        _users[userIndex] = user.copyWith(
          followersCount: user.followersCount - 1,
          isFollowed: false,
        );
      }
      // Не удаляем из рекомендаций, только обновляем статус
      if (recIndex != -1) {
        final user = _recommendedUsers[recIndex];
        _recommendedUsers[recIndex] = user.copyWith(
          followersCount: user.followersCount - 1,
          isFollowed: false,
        );
      }
    } else if (isPending) {
      // Отмена заявки
      _pendingFollowRequests.remove(userId);
    } else {
      // Подписка
      _followedUsers.add(userId);
      if (userIndex != -1) {
        final user = _users[userIndex];
        if (user.isPrivate) {
          // Закрытый аккаунт - отправляем заявку
          _pendingFollowRequests.add(userId);
          _followedUsers.remove(userId); // Убираем из подписок, т.к. это заявка
        } else {
          // Открытый аккаунт - сразу подписываемся
          _users[userIndex] = user.copyWith(
            followersCount: user.followersCount + 1,
            isFollowed: true,
          );
        }
      }
      // Обновляем статус в рекомендациях, но не удаляем
      if (recIndex != -1) {
        final user = _recommendedUsers[recIndex];
        if (user.isPrivate) {
          _pendingFollowRequests.add(userId);
          _followedUsers.remove(userId);
        } else {
          _recommendedUsers[recIndex] = user.copyWith(
            followersCount: user.followersCount + 1,
            isFollowed: true,
          );
        }
      }
    }
    
    // Обновляем счетчик подписок у текущего пользователя
    if (_currentUser != null) {
      _currentUser = _currentUser!.copyWith(
        followingCount: _followedUsers.length,
      );
    }
    
    notifyListeners();
    
    // Сохраняем в Supabase если используем его
    if (Features.useSupabaseUsers) {
      try {
        final userService = SupabaseUserService();
        final followRequestService = SupabaseFollowRequestService();
        final currentUserId = _currentUser?.id ?? '';
        
        if (currentUserId.isEmpty) {
          AppLogger.warning('Попытка подписки без авторизации', tag: _logTag);
          return false;
        }
        
        if (isFollowing) {
          await userService.unfollowUser(currentUserId, userId);
        } else if (isPending) {
          await followRequestService.cancelFollowRequest(currentUserId, userId);
        } else {
          // Проверяем, приватный ли аккаунт
          bool targetIsPrivate = false;
          if (userIndex != -1) {
            targetIsPrivate = _users[userIndex].isPrivate;
          } else if (recIndex != -1) {
            targetIsPrivate = _recommendedUsers[recIndex].isPrivate;
          }

          if (targetIsPrivate) {
            final requestSent = await followRequestService.sendFollowRequest(currentUserId, userId);
            if (!requestSent) {
              throw Exception('Не удалось отправить заявку на подписку');
            }
          } else {
            await userService.followUser(currentUserId, userId);
          
            // Создаём уведомление для пользователя
            if (Features.useSupabaseNotifications) {
              final notificationService = SupabaseNotificationService();
              await notificationService.createNotification(
                userId: userId,
                type: 'follow',
                actorId: currentUserId,
              );
            }
          }
        }

        // Перегружаем подписки, чтобы синхронизировать состояние
        await _loadFollowsFromSupabase();
        // Загружаем актуальные pending заявки
        await _loadPendingFollowRequests();
        AppLogger.success('Подписки синхронизированы', tag: _logTag);
        return true;
      } catch (e) {
        AppLogger.error('Ошибка подписки в Supabase', tag: _logTag, error: e);
        // Откатываем изменения при ошибке
        if (isFollowing) {
          _followedUsers.add(userId);
        } else {
          _followedUsers.remove(userId);
        }
        _pendingFollowRequests.remove(userId);
        notifyListeners();
        return false;
      }
    } else {
      _saveFollowedUsers();
      return true;
    }
  }
  
  // Активация Premium (только синхронизация с сервером)
  Future<void> activatePremium() async {
    if (_currentUser == null) return;
    
    // НЕ активируем клиентом — только перезапрашиваем статус с сервера
    await _syncPremiumWithSupabase(_currentUser!.id);
    
    // Обновляем локальный кэш из БД
    await refreshCurrentUser();
  }

  /// Перезагрузить текущего пользователя из Supabase
  Future<void> refreshCurrentUser() async {
    if (!Features.useSupabaseUsers) return;
    
    try {
      // Получаем userId из Supabase Auth если _currentUser ещё null
      final userId = _currentUser?.id ?? Supabase.instance.client.auth.currentUser?.id;
      if (userId == null) {
        AppLogger.warning('Не удалось получить userId для refreshCurrentUser', tag: _logTag);
        return;
      }
      
      final userService = SupabaseUserService();
      final updatedProfile = await userService.getProfile(userId);
      if (updatedProfile != null) {
        final updatedUser = await _mapSupabaseProfileMapToUserWithLocal(updatedProfile);
        _currentUser = updatedUser;
        
        // Обновляем пользователя в списке пользователей
        final userIndex = _users.indexWhere((u) => u.id == userId);
        if (userIndex != -1) {
          _users[userIndex] = updatedUser;
        } else {
          _users.add(updatedUser);
        }
        
        // Обновляем author во всех постах ленты (чтобы Premium галочка появилась мгновенно)
        _stories = _stories.map((s) {
          if (s.author.id == userId) return s.copyWith(author: updatedUser);
          return s;
        }).toList();
        
        notifyListeners();
        AppLogger.success('Профиль пользователя обновлён: ${updatedUser.name}', tag: _logTag);
      }
    } catch (e) {
      AppLogger.error('Ошибка перезагрузки профиля', tag: _logTag, error: e);
    }
  }

  Future<void> _syncPremiumWithSupabase(String userId) async {
    try {
      // НЕ устанавливаем premium клиентом — только перезапрашиваем статус
      final userService = SupabaseUserService();
      await userService.reloadUser(userId); // перезагружаем данные с сервера
      AppLogger.success('Premium статус перезапрошен с сервера', tag: _logTag);
    } catch (e, stack) {
      AppLogger.error('Не удалось перезапросить Premium статус', tag: _logTag, error: e, stackTrace: stack);
    }
  }

  // Поиск историй
  List<Story> searchStories(String query) {
    if (query.isEmpty) return _stories;
    
    final lowercaseQuery = query.toLowerCase();
    return _stories.where((story) {
      final matchesText = story.text.toLowerCase().contains(lowercaseQuery);
      final matchesAuthor = !story.isAnonymous &&
          (story.author.name.toLowerCase().contains(lowercaseQuery) ||
           story.author.username.toLowerCase().contains(lowercaseQuery));
      return matchesText || matchesAuthor;
    }).toList();
  }

  // Поиск пользователей
  List<User> searchUsers(String query) {
    if (query.isEmpty) return [];
    
    final lowercaseQuery = query.toLowerCase();
    return _users.where((user) {
      return user.name.toLowerCase().contains(lowercaseQuery) ||
             user.username.toLowerCase().contains(lowercaseQuery);
    }).toList();
  }

  // Установить фильтр (локальная фильтрация — мгновенно)
  Future<void> setFilter(FilterType filter) async {
    if (_currentFilter == filter) return;
    _currentFilter = filter;
    notifyListeners();
  }

  // Сбросить фильтр
  Future<void> resetFilter() async {
    if (_currentFilter == null) return;
    _currentFilter = null;
    notifyListeners();
  }

  // Фильтрация историй
  List<Story> getFilteredStories(FilterType filter) {
    // Используем stories getter (он фильтрует заблокированных и скрытых пользователей)
    List<Story> result = List<Story>.from(stories);
    
    switch (filter) {
      case FilterType.hot:
        // Осек дня: посты за последние 24 часа, сортированные по популярности
        // Если постов за 24ч мало — расширяем окно до 48ч
        final now = DateTime.now();
        final window24 = now.subtract(const Duration(hours: 24));
        final window48 = now.subtract(const Duration(hours: 48));
        final recent24 = result.where((s) => s.createdAt.isAfter(window24)).toList();
        result = recent24.length >= 3 ? recent24 : result.where((s) => s.createdAt.isAfter(window48)).toList();
        // Scoring: лайки × 3 + комментарии × 2 + репосты × 4 + просмотры / 10
        result.sort((a, b) {
          final scoreA = a.likes * 3 + a.comments * 2 + a.reposts * 4 + a.views ~/ 10;
          final scoreB = b.likes * 3 + b.comments * 2 + b.reposts * 4 + b.views ~/ 10;
          return scoreB.compareTo(scoreA);
        });
        return result;
      case FilterType.comments:
        // Сортируем по комментариям (самые обсуждаемые)
        result.sort((a, b) => b.comments.compareTo(a.comments));
        return result;
      case FilterType.subscriptions:
        final filtered = result.where((story) => 
            _followedUsers.contains(story.author.id)).toList();
        // Если локальных результатов мало — подгружаем с сервера в фоне
        if (filtered.length < 5 && _followedUsers.isNotEmpty && _currentUser != null) {
          _loadFollowingFeedInBackground();
        }
        return filtered;
      case FilterType.new_:
        // Свежие осеки: сортируем по дате (новые сверху)
        result.sort((a, b) => b.createdAt.compareTo(a.createdAt));
        return result;
      case FilterType.adult:
      case FilterType.anonymous:
      case FilterType.elite:
        // Эти фильтры больше не используются
        return result;
    }
  }

  bool _isLoadingFollowingFeed = false;
  Future<void> _loadFollowingFeedInBackground() async {
    if (_isLoadingFollowingFeed || _currentUser == null) return;
    _isLoadingFollowingFeed = true;
    try {
      final postService = SupabasePostService();
      final rawPosts = await postService.getFollowingFeed(
        userId: _currentUser!.id,
        limit: 30,
      );
      if (rawPosts.isNotEmpty) {
        final existingIds = _stories.map((s) => s.id).toSet();
        final newStories = rawPosts
            .where((p) => !existingIds.contains(p['id']))
            .map((p) => Story.fromJson(p))
            .toList();
        if (newStories.isNotEmpty) {
          _stories = [..._stories, ...newStories];
          notifyListeners();
        }
      }
    } catch (e) {
      AppLogger.warning('Фоновая загрузка ленты подписок не удалась', tag: _logTag, error: e);
    } finally {
      _isLoadingFollowingFeed = false;
    }
  }

  // Получить истории пользователя
  List<Story> getUserStories(String userId) {
    if (!Features.useSupabasePosts) {
      // Для локального режима - берем из главного фида
      return _stories.where((story) => story.author.id == userId).toList();
    }

    // Всегда используем отдельный кэш для постов пользователя
    final cachedStories = _userStoriesCache[userId];
    if (cachedStories != null) {
      return cachedStories;
    }

    // Если все посты уже загружены и кэш пустой - не загружаем снова
    if (_userStoriesFullyLoaded.contains(userId)) {
      return const [];
    }

    // Если кэша нет — инициируем загрузку и временно возвращаем пустой список
    if (!_userStoriesLoading.contains(userId)) {
      _fetchUserStories(userId);
    }

    return const [];
  }

  bool isUserStoriesLoading(String userId) => _userStoriesLoading.contains(userId);
  
  // Проверяем загружены ли все посты пользователя
  bool isUserStoriesFullyLoaded(String userId) => _userStoriesFullyLoaded.contains(userId);

  void _setUserStoriesLoading(String userId, bool isLoading) {
    final changed = isLoading
        ? _userStoriesLoading.add(userId)
        : _userStoriesLoading.remove(userId);

    if (changed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (hasListeners) {
          notifyListeners();
        }
      });
    }
  }

  Future<void> refreshUserStories(String userId) async {
    if (!Features.useSupabasePosts) return;
    await _fetchUserStories(userId, force: true);
  }

  // Принудительное обновление ленты из БД (без кэша)
  Future<void> refreshStories() async {
    if (!Features.useSupabasePosts) return;
    
    try {
      _isLoading = true;
      notifyListeners();
      
      // Очищаем кэш
      _stories.clear();
      _loadedPostIds.clear();
      
      // Загружаем свежие данные
      await _loadInitialPosts(force: true);
      
      AppLogger.success('Лента обновлена из БД', tag: _logTag);
    } catch (e, st) {
      AppLogger.error('Ошибка обновления ленты', tag: _logTag, error: e, stackTrace: st);
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  // Публичный метод для загрузки дополнительных постов пользователя
  Future<void> loadMoreUserStoriesPublic(String userId) async {
    if (!Features.useSupabasePosts) return;
    await loadMoreUserStories(userId);
  }

  /// Получить реальное количество постов пользователя из Supabase
  Future<int> getUserPostsCount(String userId) async {
    if (!Features.useSupabasePosts) {
      final count = _stories.where((story) => story.author.id == userId).length;
      return count;
    }
    
    try {
      final postService = SupabasePostService();
      final count = await postService.getUserPostsCount(userId);
      return count;
    } catch (e) {
      AppLogger.error('Ошибка получения количества постов пользователя $userId', tag: _logTag, error: e);
      return _stories.where((story) => story.author.id == userId).length;
    }
  }

  // Получить пользователя по ID
  User? getUserById(String userId) {
    try {
      return _users.firstWhere((user) => user.id == userId);
    } catch (e) {
      return null;
    }
  }

  Future<User?> fetchUserProfile(String userId) async {
    final existingUser = getUserById(userId);

    if (!Features.useSupabaseUsers) {
      return existingUser;
    }

    try {
      final userService = SupabaseUserService();
      final profileData = await userService.getProfile(userId);
      if (profileData == null) {
        return existingUser;
      }

      final fetchedUser = await _mapSupabaseProfileMapToUserWithLocal(profileData);
      final userIndex = _users.indexWhere((u) => u.id == userId);
      if (userIndex == -1) {
        _users.add(fetchedUser);
      } else {
        _users[userIndex] = fetchedUser;
      }
      notifyListeners();
      return fetchedUser;
    } catch (e) {
      AppLogger.error('Ошибка загрузки профиля пользователя', tag: _logTag, error: e);
      return existingUser;
    }
  }

  User _mapSupabaseProfileMapToUser(Map<String, dynamic> data) {
    final avatarUrl = data['avatar_url'] as String?;
    String? website = data['website'] as String?;
    String? websiteText = data['website_text'] as String?;
    if (website != null && website.contains(_websiteTextSeparator)) {
      final parts = website.split(_websiteTextSeparator);
      if (parts.length >= 2) {
        websiteText = parts.first;
        website = parts.sublist(1).join(_websiteTextSeparator);
      }
    }
    final roleString = data['role'] as String?;
    final bool isPremiumFlag =
        roleString == 'premium' || (data['is_premium'] as bool? ?? false);
    final List<String> links = [];
    if (website != null && website.isNotEmpty) {
      links.add(website);
    }

    // Парсим дату рождения
    DateTime? birthDate;
    if (data['birth_date'] != null) {
      final birthDateString = data['birth_date'] as String;
      try {
        birthDate = DateTime.parse(birthDateString);
      } catch (e) {
        AppLogger.error('Ошибка парсинга birth_date: $birthDateString', tag: 'AppState', error: e);
        birthDate = null;
      }
    }
    
    // Парсим gender
    final gender = data['gender'] as String?;
    
    // Парсим phone
    final phone = data['phone'] as String?;
    
    // Парсим email
    final email = data['email'] as String?;

    // Парсим premium_expires_at
    DateTime? premiumExpiresAt;
    if (data['premium_expires_at'] != null) {
      try {
        premiumExpiresAt = DateTime.parse(data['premium_expires_at'] as String);
        AppLogger.info('Premium expires at загружен: $premiumExpiresAt для пользователя ${data['username']}', tag: 'AppState');
      } catch (e) {
        AppLogger.warning('Ошибка парсинга premium_expires_at', tag: 'AppState', error: e);
      }
    } else {
      AppLogger.info('premium_expires_at = null для пользователя ${data['username']}, isPremiumFlag=$isPremiumFlag', tag: 'AppState');
    }

    return User(
      id: data['id'] as String,
      name: data['full_name'] as String? ?? 'Пользователь',
      username: data['username'] as String? ?? 'user',
      avatar: avatarUrl ?? '',
      bio: data['bio'] as String?,
      website: website,
      websiteText: websiteText,
      links: links,
      location: data['location'] as String?,
      city: data['city'] as String?,
      profileColor: data['profile_color'] as String?,
      birthDate: birthDate,
      gender: gender,
      phone: phone,
      email: email,
      isPremium: isPremiumFlag,
      premiumExpiresAt: premiumExpiresAt,
      karma: data['karma'] as int? ?? 0,
      followersCount: data['followers_count'] as int? ?? 0,
      followingCount: data['following_count'] as int? ?? 0,
      isFollowed: false,
      isOnline: false,
      lastSeen: null,
      isVerified: data['is_verified'] as bool? ?? false,
      isPrivate: data['is_private'] as bool? ?? false,
      role: _mapSupabaseRole(roleString),
      allowMessages: data['allow_messages'] as bool?,
      whoCanMessage: data['who_can_message'] as String?,
      privacyMessages: data['privacy_messages'] as String?,
    );
  }

  // Асинхронная версия маппинга с локальными полями
  Future<User> _mapSupabaseProfileMapToUserWithLocal(Map<String, dynamic> data) async {
    final baseUser = _mapSupabaseProfileMapToUser(data);
    
    // Загружаем локальные поля (gender, birthDate, profileColor)
    final localFields = await _loadProfileFieldsLocally();
    
    final result = baseUser.copyWith(
      gender: baseUser.gender ?? localFields['gender'] as String?,
      birthDate: baseUser.birthDate ?? localFields['birthDate'] as DateTime?,
      profileColor: baseUser.profileColor ?? localFields['profileColor'] as String?,
      city: (baseUser.city == null || baseUser.city!.isEmpty) ? localFields['city'] as String? : baseUser.city,
      bio: (baseUser.bio == null || baseUser.bio!.isEmpty) ? localFields['bio'] as String? : baseUser.bio,
      website: (baseUser.website == null || baseUser.website!.isEmpty) ? localFields['website'] as String? : baseUser.website,
      websiteText: (baseUser.websiteText == null || baseUser.websiteText!.isEmpty) ? localFields['websiteText'] as String? : baseUser.websiteText,
    );
    
    // Сохраняем поля из Supabase локально для быстрого доступа при следующем старте
    // ВАЖНО: только непустые значения — не перетираем локальные данные пустыми из Supabase
    final prefs = await SharedPreferences.getInstance();
    if (result.city != null && result.city!.isNotEmpty) await prefs.setString('user_city', result.city!);
    if (result.bio != null && result.bio!.isNotEmpty) await prefs.setString('user_bio', result.bio!);
    if (result.website != null && result.website!.isNotEmpty) await prefs.setString('user_website', result.website!);
    if (result.websiteText != null && result.websiteText!.isNotEmpty) await prefs.setString('user_website_text', result.websiteText!);
    if (result.gender != null && result.gender!.isNotEmpty) await prefs.setString('user_gender', result.gender!);
    if (result.profileColor != null && result.profileColor!.isNotEmpty) {
      await prefs.setString('user_profile_color', result.profileColor!);
    }
    
    return result;
  }

  UserRole _mapSupabaseRole(String? role) {
    switch (role) {
      case 'premium':
        return UserRole.premium;
      case 'moderator':
        return UserRole.moderator;
      case 'admin':
        return UserRole.admin;
      default:
        return UserRole.free;
    }
  }

  // Редактирование сообщения
  
  // Удаление сообщения
  Future<void> deleteMessage(String chatId, String messageId, {required bool forEveryone}) async {
    final index = _chatMessages.indexWhere((m) => m.id == messageId);
    if (index == -1) return;
    
    final message = _chatMessages[index];
    
    if (forEveryone) {
      // Удалить у всех можно только в течение 1 часа
      final timeSinceCreation = DateTime.now().difference(message.createdAt);
      if (timeSinceCreation.inHours > 1) {
        return;
      }
      
      // Обновляем локально
      _chatMessages[index] = message.copyWith(
        isDeletedForEveryone: true,
        text: 'Сообщение удалено',
      );
      
      // Удаляем из Supabase
      if (Features.useSupabaseChats) {
        try {
          await _supabaseChatService.deleteMessage(messageId);
        } catch (e) {
          AppLogger.error('Ошибка удаления сообщения', tag: _logTag, error: e);
          _chatMessages[index] = message;
        }
      }
    } else {
      // Удалить только у себя (локально)
      _chatMessages[index] = message.copyWith(
        isDeletedForMe: true,
      );
    }
    
    notifyListeners();
  }

  // Получить сообщение по ID
  ChatMessage? getMessageById(String chatId, String messageId) {
    try {
      return _chatMessages.firstWhere((m) => m.id == messageId && m.chatId == chatId);
    } catch (e) {
      return null;
    }
  }

  // Добавить/изменить реакцию на сообщение
  Future<void> toggleReaction(String chatId, String messageId, ReactionType reaction) async {
    // Ищем сообщение по ID (chatId может отличаться)
    final index = _chatMessages.indexWhere((m) => m.id == messageId);
    if (index == -1) return;
    
    final message = _chatMessages[index];
    final newReactions = Map<String, ReactionType>.from(message.reactions);
    final currentUserId = _currentUser?.id ?? 'current_user';
    
    // Если уже есть такая же реакция - убираем, иначе добавляем/меняем
    final isRemoving = newReactions[currentUserId] == reaction;
    if (isRemoving) {
      newReactions.remove(currentUserId);
    } else {
      newReactions[currentUserId] = reaction;
    }
    
    _chatMessages[index] = message.copyWith(reactions: newReactions);
    
    // Обновляем кеш
    final realChatId = message.chatId;
    if (_chatMessagesCache.containsKey(realChatId)) {
      final cacheIndex = _chatMessagesCache[realChatId]!.indexWhere((m) => m.id == messageId);
      if (cacheIndex != -1) {
        _chatMessagesCache[realChatId]![cacheIndex] = _chatMessages[index];
      }
    }
    
    notifyListeners();
    
    // Сохраняем в Supabase
    if (Features.useSupabaseChats) {
      try {
        await _supabaseChatService.toggleMessageReaction(
          messageId, 
          currentUserId, 
          isRemoving ? null : reaction.name,
        );
      } catch (e) {
        AppLogger.error('Ошибка сохранения реакции', tag: _logTag, error: e);
      }
    }
    
    unawaited(_saveChatsToCache());
  }

  // Закрепить/открепить сообщение
  Future<void> togglePinMessage(String chatId, String messageId) async {
    final index = _chatMessages.indexWhere((m) => m.id == messageId);
    if (index == -1) return;
    
    final message = _chatMessages[index];
    final newPinned = !message.isPinned;
    
    // Обновляем локально
    _chatMessages[index] = message.copyWith(isPinned: newPinned);
    notifyListeners();
    
    // Обновляем в Supabase
    if (Features.useSupabaseChats) {
      try {
        if (_currentUser == null) return;
        await _supabaseChatService.togglePinMessage(messageId, newPinned, _currentUser!.id);
        
        // BUG-021: Обновляем кэш чата после закрепления
        await _updateChatCacheAfterPin(chatId, messageId, newPinned);
        AppLogger.success('Сообщение закреплено и кэш обновлен', tag: _logTag);
      } catch (e) {
        AppLogger.error('Ошибка закрепления сообщения', tag: _logTag, error: e);
        // Откатываем изменения
        _chatMessages[index] = message;
        notifyListeners();
      }
    }
  }

  // BUG-021: Обновление кэша чата после закрепления сообщения
  Future<void> _updateChatCacheAfterPin(String chatId, String messageId, bool isPinned) async {
    try {
      // Обновляем кэш превью чата
      final cachedPreview = _chatPreviewCache[chatId];
      if (cachedPreview != null) {
        if (isPinned) {
          // Если закрепляем сообщение, обновляем pinned_message_id в превью
          _chatPreviewCache[chatId] = Map<String, dynamic>.from(cachedPreview)
            ..['pinnedMessageId'] = messageId
            ..['pinnedMessageText'] = _chatMessages
                .firstWhere((m) => m.id == messageId)
                .text
                .replaceAll('\n', ' ');
        } else {
          // Если открепляем, убираем pinned_message_id
          _chatPreviewCache[chatId] = Map<String, dynamic>.from(cachedPreview)
            ..['pinnedMessageId'] = null
            ..['pinnedMessageText'] = null;
        }
      }
      
      // Обновляем кэш сообщений
      final cachedMessages = _chatMessagesCache[chatId];
      if (cachedMessages != null) {
        final messageIndex = cachedMessages.indexWhere((m) => m.id == messageId);
        if (messageIndex != -1) {
          cachedMessages[messageIndex] = cachedMessages[messageIndex].copyWith(isPinned: isPinned);
        }
      }
      
      notifyListeners();
    } catch (e) {
      AppLogger.error('Ошибка обновления кэша после закрепления', tag: _logTag, error: e);
    }
  }

  // Добавить/убрать из избранного
  Future<void> toggleBookmarkMessage(String chatId, String messageId) async {
    final index = _chatMessages.indexWhere((m) => m.id == messageId);
    if (index == -1) return;
    
    final message = _chatMessages[index];
    final newBookmarked = !message.isBookmarked;
    
    // Обновляем локально
    _chatMessages[index] = message.copyWith(isBookmarked: newBookmarked);
    notifyListeners();
    
    // Обновляем в Supabase
    if (Features.useSupabaseChats) {
      try {
        if (_currentUser == null) return;
        await _supabaseChatService.toggleBookmarkMessage(messageId, newBookmarked, _currentUser!.id);
      } catch (e) {
        AppLogger.error('Ошибка добавления сообщения в избранное', tag: _logTag, error: e);
        // Откатываем изменения
        _chatMessages[index] = message;
        notifyListeners();
      }
    }
  }

  // Поиск сообщений в чате
  List<ChatMessage> searchMessages(String userIdOrChatId, String query) {
    if (query.isEmpty) return [];
    
    // Преобразуем userId в chatId если нужно
    String chatId = userIdOrChatId;
    if (Features.useSupabaseChats && _userIdToChatId.containsKey(userIdOrChatId)) {
      chatId = _userIdToChatId[userIdOrChatId]!;
    } else if (!Features.useSupabaseChats) {
      chatId = 'chat_$userIdOrChatId';
    }
    
    final lowercaseQuery = query.toLowerCase();
    return _chatMessages
        .where((m) => 
            m.chatId == chatId && 
            !m.isDeletedForMe &&
            !m.isDeletedForEveryone &&
            m.text.isNotEmpty &&
            m.text.toLowerCase().contains(lowercaseQuery))
        .toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  }

  // Получить закрепленные сообщения
  List<ChatMessage> getPinnedMessages(String userIdOrChatId) {
    // Преобразуем userId в chatId если нужно
    String chatId = userIdOrChatId;
    if (Features.useSupabaseChats && _userIdToChatId.containsKey(userIdOrChatId)) {
      chatId = _userIdToChatId[userIdOrChatId]!;
    } else if (!Features.useSupabaseChats) {
      chatId = 'chat_$userIdOrChatId';
    }
    
    return _chatMessages
        .where((m) => m.chatId == chatId && m.isPinned && !m.isDeletedForMe)
        .toList();
  }

  // Получить избранные сообщения
  List<ChatMessage> getBookmarkedMessages(String userIdOrChatId) {
    // Преобразуем userId в chatId если нужно
    String chatId = userIdOrChatId;
    if (Features.useSupabaseChats && _userIdToChatId.containsKey(userIdOrChatId)) {
      chatId = _userIdToChatId[userIdOrChatId]!;
    } else if (!Features.useSupabaseChats) {
      chatId = 'chat_$userIdOrChatId';
    }
    
    return _chatMessages
        .where((m) => m.chatId == chatId && m.isBookmarked && !m.isDeletedForMe)
        .toList();
  }

  // =============================
  // Supabase чаты
  // =============================

  Future<void> _loadSupabaseChats() async {
    if (_currentUser == null) return;

    final userId = _currentUser!.id;

    final chatsData = await _supabaseChatService.getChats(userId);

    // Очищаем кеши чатов, но обновляем сообщения без лага
    _chatPreviewCache.clear();
    _chatUsersCache.clear();
    _userIdToChatId.clear();
    
    // НЕ очищаем _chatMessagesCache чтобы избежать лага
    // Вместо этого обновим last_message в кеше из базы
    
    // Обновляем последнее сообщение в кеше если оно изменилось
    for (final chat in chatsData) {
      final chatId = chat['id'] as String;
      final lastMessage = chat['last_message'] as String?;
      final cachedMessages = _chatMessagesCache[chatId];
      
      if (cachedMessages != null && cachedMessages.isNotEmpty && lastMessage != null) {
        final currentLastMessage = cachedMessages.first.text; // Первый = самый новый
        if (currentLastMessage != lastMessage) {
          // Загружаем свежие сообщения для этого чата в фоне (только последние 50)
          unawaited(_loadSupabaseMessages(chatId, limit: 50));
        }
      }
    }

    for (final chat in chatsData) {
      final chatId = chat['id'] as String;
      _chatPreviewCache[chatId] = chat;

      final user1 = chat['user1'] as Map<String, dynamic>?;
      final user2 = chat['user2'] as Map<String, dynamic>?;

      Map<String, dynamic>? otherUserData;
      if (user1 != null && user1['id'] != userId) {
        otherUserData = user1;
      } else if (user2 != null && user2['id'] != userId) {
        otherUserData = user2;
      }

      if (otherUserData != null) {
        final otherUser = _mapSupabaseUserToUser(otherUserData);
        _chatUsersCache[chatId] = otherUser;
        // Сохраняем маппинг userId -> chatId
        _userIdToChatId[otherUser.id] = chatId;
      }

      // НЕ загружаем сообщения здесь — они загрузятся при открытии чата
      // await _loadSupabaseMessages(chatId);

      if (!_chatRealtimeChannels.containsKey(chatId)) {
        _subscribeToChatRealtime(chatId);
      }
    }
    
    // ВАЖНО: уведомляем UI об изменениях
    await _saveChatsToCache();
    notifyListeners();
    _subscribeToChatListRealtime();
  }

  Future<void> _refreshUnreadMessagesCount() async {
    if (!Features.useSupabaseChats || _currentUser == null) {
      if (_cachedUnreadMessagesCount != 0) {
        _cachedUnreadMessagesCount = 0;
        notifyListeners();
      }
      return;
    }

    try {
      final total = await _supabaseChatService.getUnreadCount(_currentUser!.id);
      if (_cachedUnreadMessagesCount != total) {
        _cachedUnreadMessagesCount = total;
        notifyListeners();
      }
    } catch (e, st) {
      AppLogger.error('Ошибка обновления счётчика сообщений', tag: _logTag, error: e, stackTrace: st);
    }
  }

  Future<void> refreshUnreadMessagesCount() async {
    await _refreshUnreadMessagesCount();
  }

  Future<void> _loadSupabaseMessages(String chatId, {int offset = 0, int limit = 50, bool prepend = false}) async {
    final messagesData = await _supabaseChatService.getMessages(chatId, limit: limit, offset: offset);

    final List<ChatMessage> messages = [];
    for (final item in messagesData) {
      try {
        final message = _mapSupabaseMessageToChatMessage(item);
        messages.add(message);
      } catch (e) {
        AppLogger.error('Ошибка маппинга сообщения: $e', tag: _logTag);
      }
    }
    
    // Сортируем сообщения от новых к старым (для reverse: true в ListView)
    messages.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    
    // Обновляем кеш сообщений
    if (prepend && _chatMessagesCache.containsKey(chatId)) {
      // Добавляем более старые сообщения в конец списка (они старее текущих)
      final existingMessages = _chatMessagesCache[chatId]!;
      // Убираем дубликаты по ID
      final existingIds = existingMessages.map((m) => m.id).toSet();
      final newMessages = messages.where((m) => !existingIds.contains(m.id)).toList();
      final allMessages = [...existingMessages, ...newMessages];
      _chatMessagesCache[chatId] = allMessages;
    } else {
      // Заменяем кеш (первая загрузка)
      _chatMessagesCache[chatId] = messages;
    }

    // Применяем статус прочитано к загруженным сообщениям
    final lastPartner = _lastPartnerMessageAt[chatId];
    if (lastPartner != null && _currentUser != null) {
      for (int i = 0; i < messages.length; i++) {
        final msg = messages[i];
        if (msg.sender.id == _currentUser!.id && !msg.isRead && !msg.createdAt.isAfter(lastPartner)) {
          messages[i] = msg.copyWith(isRead: true);
        }
      }
    }

    // Обновляем отметку последнего сообщения собеседника и помечаем исходящие как прочитанные
    _updateLastPartnerMessageTimestamp(chatId, messages);

    // Синхронизируем превью чата с последним сообщением (первый элемент = самый новый)
    if (!prepend && messages.isNotEmpty && _chatPreviewCache.containsKey(chatId)) {
      final lastMessage = messages.first; // Первый = самый новый
      final chatPreview = Map<String, dynamic>.from(_chatPreviewCache[chatId]!);
      chatPreview['last_message'] = lastMessage.text;
      chatPreview['last_message_at'] = lastMessage.createdAt.toUtc().toIso8601String();
      chatPreview['last_message_sender_id'] = lastMessage.sender.id;
      _chatPreviewCache[chatId] = chatPreview;
      unawaited(_saveChatsToCache());
    }

    notifyListeners();
  }

  // Загрузить более старые сообщения (пагинация)
  Future<void> loadMoreMessages(String chatId) async {
    final cachedMessages = _chatMessagesCache[chatId];
    if (cachedMessages == null) {
      // Если кеша нет, загружаем последние сообщения
      await _loadSupabaseMessages(chatId);
      return;
    }

    if (cachedMessages.isEmpty) return;

    // Используем offset для пагинации - загружаем более старые сообщения
    final currentCount = cachedMessages.length;
    await _loadSupabaseMessages(
      chatId,
      offset: currentCount,
      limit: 50,
      prepend: true,
    );
  }

  Future<Map<String, dynamic>?> ensureSupabaseChat(String otherUserId) async {
    if (_currentUser == null) return null;

    final chatData = await _supabaseChatService.getOrCreateChat(_currentUser!.id, otherUserId);

    if (chatData == null) return null;

    final chatId = chatData['id'] as String;
    if (!_chatPreviewCache.containsKey(chatId)) {
      _chatPreviewCache[chatId] = chatData;
    }

    if (!_chatUsersCache.containsKey(chatId)) {
      Map<String, dynamic>? otherUserRaw;
      if ((chatData['user1_id'] as String) == otherUserId) {
        otherUserRaw = chatData['user1'] as Map<String, dynamic>?;
      } else {
        otherUserRaw = chatData['user2'] as Map<String, dynamic>?;
      }

      if (otherUserRaw != null) {
        final otherUser = _mapSupabaseUserToUser(otherUserRaw);
        _chatUsersCache[chatId] = otherUser;
        // Сохраняем маппинг userId -> chatId
        _userIdToChatId[otherUserId] = chatId;
      }
    }

    // ВСЕГДА перезагружаем сообщения при входе в чат чтобы избежать проблем с temp_ ID
    await _loadSupabaseMessages(chatId);
    unawaited(_markChatAsDelivered(chatId));

    if (!_chatRealtimeChannels.containsKey(chatId)) {
      _subscribeToChatRealtime(chatId);
    }

    return chatData;
  }

  void _subscribeToChatRealtime(String chatId) {
    final channel = _supabaseChatService.subscribeToMessages(chatId, (messageData, eventType) async {
      
      if (eventType == PostgresChangeEvent.insert) {
        // Для INSERT нужно загрузить полные данные
        final fullMessageData = await _supabaseChatService.getMessageById(messageData['id']);
        if (fullMessageData != null) {
          final message = _mapSupabaseMessageToChatMessage(fullMessageData);
          addChatMessage(message);
          _handlePartnerMessageReceived(chatId, message);
          
          // Если это входящее сообщение - сразу помечаем как доставленное
          if (_currentUser != null && message.sender.id != _currentUser!.id) {
            unawaited(_markChatAsDelivered(chatId));
            
            // Увеличиваем счётчик непрочитанных для бейджа
            _cachedUnreadMessagesCount++;
            notifyListeners();
            
            // Системное push-уведомление придёт через Firebase автоматически
            // In-App уведомления для чатов отключены - только системные
          }
          
          // Обновляем last_message в кеше чата
          if (_chatPreviewCache.containsKey(chatId)) {
            final chatData = Map<String, dynamic>.from(_chatPreviewCache[chatId]!);
            chatData['last_message'] = message.text;
            chatData['last_message_at'] = message.createdAt.toUtc().toIso8601String();
            chatData['last_message_sender_id'] = fullMessageData['sender_id'];
            
            // Увеличиваем unread_count если сообщение не от текущего пользователя
            if (_currentUser != null && fullMessageData['sender_id'] != _currentUser!.id) {
              final user1Id = chatData['user1_id'] as String?;
              final user2Id = chatData['user2_id'] as String?;
              
              if (user1Id == _currentUser!.id) {
                chatData['unread_count_user1'] = ((chatData['unread_count_user1'] as int?) ?? 0) + 1;
              } else if (user2Id == _currentUser!.id) {
                chatData['unread_count_user2'] = ((chatData['unread_count_user2'] as int?) ?? 0) + 1;
              }
            }
            _chatPreviewCache[chatId] = chatData;
            // Обновляем UI чтобы чат переместился наверх списка
            notifyListeners();
          }
        }
      } else if (eventType == PostgresChangeEvent.update) {
        
        final fullMessageData = await _supabaseChatService.getMessageById(messageData['id']);
        if (fullMessageData != null) {
          final updatedMessage = _mapSupabaseMessageToChatMessage(fullMessageData);
          final index = _chatMessages.indexWhere((m) => m.id == updatedMessage.id);
          
          if (index != -1) {
            _chatMessages[index] = updatedMessage;
          }
          
          // Также обновляем в кэше
          final cachedMessages = _chatMessagesCache[chatId];
          if (cachedMessages != null) {
            final cacheIndex = cachedMessages.indexWhere((m) => m.id == updatedMessage.id);
            if (cacheIndex != -1) {
              cachedMessages[cacheIndex] = updatedMessage;
            }
          }

          // Сообщение уже обновлено выше, просто сохраняем в кеш
          unawaited(_saveChatsToCache());
        }
      } else if (eventType == PostgresChangeEvent.delete) {
        // Для DELETE удаляем из списка
        final id = messageData['id'] as String;
        _chatMessages.removeWhere((m) => m.id == id);
      }
      
      notifyListeners();
    });

    _chatRealtimeChannels[chatId] = channel;
  }

  void _subscribeToChatListRealtime() {
    if (!Features.useSupabaseChats || _currentUser == null) return;

    unawaited(_unsubscribeFromChatListRealtime());

    _chatListRealtimeChannel = _supabaseChatService.subscribeToChatList(
      _currentUser!.id,
      (record) async {
        final chatId = record['id'] as String?;
        if (chatId == null) return;
        final chatData = await _supabaseChatService.getChatById(chatId);
        if (chatData == null) return;
        _upsertChatPreview(chatData);
        await _saveChatsToCache();
        await _refreshUnreadMessagesCount();
        notifyListeners();
      },
    );
  }

  Future<void> _unsubscribeFromChatListRealtime() async {
    if (_chatListRealtimeChannel != null) {
      await _supabaseChatService.unsubscribe(_chatListRealtimeChannel!);
      _chatListRealtimeChannel = null;
    }
  }

  /// Подписка на обновления статусов исходящих сообщений (доставлено/прочитано)
  void _subscribeToOutgoingMessagesRealtime() {
    if (!Features.useSupabaseChats || _currentUser == null) return;

    unawaited(_unsubscribeFromOutgoingMessagesRealtime());

    _outgoingMessagesRealtimeChannel = _supabaseChatService.subscribeToOutgoingMessages(
      _currentUser!.id,
      (record) {
        final messageId = record['id'] as String?;
        final chatId = record['chat_id'] as String?;
        final isDelivered = record['is_delivered'] as bool? ?? false;
        final isRead = record['is_read'] as bool? ?? false;
        
        
        if (messageId == null || chatId == null) return;

        bool changed = false;

        // Обновляем в основном списке
        final index = _chatMessages.indexWhere((m) => m.id == messageId);
        if (index != -1) {
          final msg = _chatMessages[index];
          if (msg.isDelivered != isDelivered || msg.isRead != isRead) {
            _chatMessages[index] = msg.copyWith(isDelivered: isDelivered, isRead: isRead);
            changed = true;
          }
        }

        // Обновляем в кеше
        final cachedMessages = _chatMessagesCache[chatId];
        if (cachedMessages != null) {
          final cacheIndex = cachedMessages.indexWhere((m) => m.id == messageId);
          if (cacheIndex != -1) {
            final msg = cachedMessages[cacheIndex];
            if (msg.isDelivered != isDelivered || msg.isRead != isRead) {
              cachedMessages[cacheIndex] = msg.copyWith(isDelivered: isDelivered, isRead: isRead);
              changed = true;
            }
          }
        }

        if (changed) {
          unawaited(_saveChatsToCache());
          notifyListeners();
        }
      },
    );
  }

  Future<void> _unsubscribeFromOutgoingMessagesRealtime() async {
    if (_outgoingMessagesRealtimeChannel != null) {
      await _supabaseChatService.unsubscribe(_outgoingMessagesRealtimeChannel!);
      _outgoingMessagesRealtimeChannel = null;
    }
  }

  void _upsertChatPreview(Map<String, dynamic> chat) {
    final chatId = chat['id'] as String;

    // Нормализуем last_message_at к одному формату (UTC ISO), чтобы порядок чатов не прыгал
    final normalized = Map<String, dynamic>.from(chat);
    final lastMessageAtRaw = normalized['last_message_at'] as String?;
    if (lastMessageAtRaw != null) {
      try {
        normalized['last_message_at'] = _parseSupabaseTimestamp(lastMessageAtRaw).toUtc().toIso8601String();
      } catch (_) {
        // Если парсинг не удался — оставляем как есть
      }
    }

    _chatPreviewCache[chatId] = normalized;

    final user1 = normalized['user1'] as Map<String, dynamic>?;
    final user2 = normalized['user2'] as Map<String, dynamic>?;
    Map<String, dynamic>? otherUserData;
    if (user1 != null && user1['id'] != _currentUser?.id) {
      otherUserData = user1;
    } else if (user2 != null && user2['id'] != _currentUser?.id) {
      otherUserData = user2;
    }

    if (otherUserData != null) {
      final otherUser = _mapSupabaseUserToUser(otherUserData);
      _chatUsersCache[chatId] = otherUser;
      _userIdToChatId[otherUser.id] = chatId;
    }
  }

  Future<void> _subscribeToNotificationsRealtime() async {
    if (!Features.useSupabaseNotifications || !Features.useSupabaseUsers) return;
    final userId = _currentUser?.id;
    if (userId == null) return;

    // Если канал уже есть для того же userId — не пересоздаём
    if (_notificationsRealtimeChannel != null) {
      return;
    }

    AppLogger.info('[REALTIME] Подписываемся на уведомления userId=$userId', tag: _logTag);
    _notificationsRealtimeChannel = await _supabaseNotificationService.subscribeToNotifications(
      userId,
      (newRecord) {
        AppLogger.info('[REALTIME] Получено новое уведомление: ${newRecord["type"]}', tag: _logTag);
        unawaited(_handleRealtimeNotification(newRecord));
      },
      onUpdate: (updatedRecord) {
        // Обновляем is_read в локальном списке
        final id = updatedRecord['id'] as String?;
        if (id == null) return;
        final idx = _notifications.indexWhere((n) => n.id == id);
        if (idx != -1) {
          final isRead = updatedRecord['is_read'] as bool? ?? _notifications[idx].isRead;
          _notifications[idx] = _notifications[idx].copyWith(isRead: isRead);
          notifyListeners();
        }
      },
    );
    AppLogger.success('[REALTIME] Подписка на уведомления активна', tag: _logTag);
  }

  Future<void> _handleRealtimeNotification(Map<String, dynamic> newRecord) async {
    try {
      if (!Features.useSupabaseNotifications || !Features.useSupabaseUsers) return;
      final notificationId = newRecord['id'] as String?;
      if (notificationId == null) return;

      AppLogger.info('[REALTIME] Новое уведомление id=$notificationId type=${newRecord["type"]}', tag: _logTag);

      final fullData = await _supabaseNotificationService.getNotificationById(notificationId);
      if (fullData == null) return;

      final notification = _mapSupabaseNotification(fullData);

      _notifications.removeWhere((n) => n.id == notification.id);
      _notifications.insert(0, notification);
      if (_notifications.length > 100) {
        _notifications.removeLast();
      }

      // Обновляем локальный счётчик сразу (чтобы бейдж работал без лагов)
      _updateBadgeCount(_notifications.where((n) => !n.isRead).length);

      // Синхронизируем с БД только если есть userId (на старте может быть null)
      if (!notification.isRead) {
        final userId = effectiveCurrentUserId;
        if (userId != null && userId.isNotEmpty) {
          _updateBadgeCount(await _supabaseNotificationService.getUnreadCount(userId));
        }
      }

      await _saveNotifications();
      notifyListeners();
      
      // Показываем In-App уведомление только для НОВЫХ (непрочитанных) уведомлений
      if (!notification.isRead) {
        await _showInAppNotification(notification);
      }
    } catch (e, st) {
      AppLogger.error('Ошибка realtime уведомления', tag: _logTag, error: e, stackTrace: st);
    }
  }

  Future<void> _showInAppNotification(AppNotification notification) async {
    try {
      AppLogger.info('[IN-APP] type=${notification.type} relatedId=${notification.relatedId} from=${notification.fromUser?.name}', tag: _logTag);
      final service = InAppNotificationService();
      final user = notification.fromUser;
      
      // Для системных уведомлений показываем системный баннер
      if (user == null) {
        if (notification.type == NotificationType.system || 
            notification.type == NotificationType.premium ||
            notification.type == NotificationType.community) {
          service.showSystemNotification(
            title: notification.title,
            body: notification.message,
          );
        }
        return;
      }
      
      // Почти все уведомления должны быть системными (в шторке Android)
      // In-App только для системных сообщений типа "пост опубликован"
      final notificationService = NotificationService();
      
      switch (notification.type) {
        case NotificationType.like:
          // СИСТЕМНОЕ уведомление о лайке
          String title = 'Новый лайк';
          String body = '${user.name} лайкнул(а) ваш пост';
          if (notification.message.toLowerCase().contains('комментарий')) {
            title = 'Лайк на комментарий';
            body = '${user.name} лайкнул(а) ваш комментарий';
          }
          await notificationService.showLocalNotification(
            title: title,
            body: body,
            payload: jsonEncode({
              'type': 'like',
              'post_id': notification.relatedId,
              'actor_id': user.id,
              if (notification.commentId != null) 'comment_id': notification.commentId,
            }),
          );
          break;
        case NotificationType.commentLike:
          // СИСТЕМНОЕ уведомление о лайке комментария
          await notificationService.showLocalNotification(
            title: 'Лайк на комментарий',
            body: '${user.name} лайкнул(а) ваш комментарий',
            payload: jsonEncode({
              'type': 'comment_like',
              'post_id': notification.relatedId,
              'actor_id': user.id,
              if (notification.commentId != null) 'comment_id': notification.commentId,
            }),
          );
          break;
          
        case NotificationType.comment:
          // СИСТЕМНОЕ уведомление о комментарии
          await notificationService.showLocalNotification(
            title: 'Новый комментарий',
            body: '${user.name} прокомментировал(а) ваш пост',
            payload: jsonEncode({
              'type': 'comment',
              'post_id': notification.relatedId,
              'actor_id': user.id,
              if (notification.commentId != null) 'comment_id': notification.commentId,
            }),
          );
          break;
          
        case NotificationType.reply:
          // СИСТЕМНОЕ уведомление об ответе
          await notificationService.showLocalNotification(
            title: 'Ответ на комментарий',
            body: '${user.name} ответил(а) на ваш комментарий',
            payload: jsonEncode({
              'type': 'reply',
              'post_id': notification.relatedId,
              'actor_id': user.id,
              if (notification.commentId != null) 'comment_id': notification.commentId,
            }),
          );
          break;
          
        case NotificationType.follow:
          // СИСТЕМНОЕ уведомление о подписке
          await notificationService.showLocalNotification(
            title: 'Новый подписчик',
            body: '${user.name} подписался(ась) на вас',
            payload: jsonEncode({
              'type': 'follow',
              'from_user_id': user.id,
              'actor_id': user.id,
            }),
          );
          break;
          
        case NotificationType.mention:
          // СИСТЕМНОЕ уведомление об упоминании
          await notificationService.showLocalNotification(
            title: '${user.name} упомянул(а) вас',
            body: notification.message,
            payload: jsonEncode({
              'type': 'mention',
              'post_id': notification.relatedId,
              'actor_id': user.id,
            }),
          );
          break;
          
        case NotificationType.repost:
          // СИСТЕМНОЕ уведомление о репосте
          await notificationService.showLocalNotification(
            title: 'Новый репост',
            body: '${user.name} сделал(а) репост вашего поста',
            payload: jsonEncode({
              'type': 'repost',
              'post_id': notification.relatedId,
              'actor_id': user.id,
            }),
          );
          break;
          
        case NotificationType.system:
        case NotificationType.premium:
        case NotificationType.community:
          // In-App уведомления только для системных сообщений
          service.showSystemNotification(
            title: notification.title,
            body: notification.message,
          );
          break;
          
        // Уведомления для дебатов - тоже СИСТЕМНЫЕ
        case NotificationType.debateComment:
          await notificationService.showLocalNotification(
            title: '💬 Комментарий в дебате',
            body: '${user.name} прокомментировал(а) ваш дебат',
            payload: jsonEncode({
              'type': 'debate_comment',
              'discussion_id': notification.relatedId,
              'actor_id': user.id,
              if (notification.commentId != null) 'comment_id': notification.commentId,
            }),
          );
          break;
          
        case NotificationType.debateReply:
          await notificationService.showLocalNotification(
            title: '↩️ Ответ в дебате',
            body: '${user.name} ответил(а) на ваш комментарий в дебате',
            payload: jsonEncode({
              'type': 'debate_reply',
              'discussion_id': notification.relatedId,
              'actor_id': user.id,
              if (notification.commentId != null) 'comment_id': notification.commentId,
            }),
          );
          break;
          
        case NotificationType.debateLike:
          await notificationService.showLocalNotification(
            title: '❤️ Лайк в дебате',
            body: '${user.name} лайкнул(а) ваш комментарий в дебате',
            payload: jsonEncode({
              'type': 'debate_like',
              'discussion_id': notification.relatedId,
              'actor_id': user.id,
              if (notification.commentId != null) 'comment_id': notification.commentId,
            }),
          );
          break;

        case NotificationType.debateVote:
          await notificationService.showLocalNotification(
            title: '🗳️ Голос в дебате',
            body: '${user.name} проголосовал(а) в вашем дебате',
            payload: jsonEncode({
              'type': 'debate_vote',
              'discussion_id': notification.relatedId,
              'actor_id': user.id,
            }),
          );
          break;
          
        case NotificationType.emailChange:
          // Системное уведомление о смене email
          await notificationService.showLocalNotification(
            title: '📧 Смена email',
            body: notification.message,
            payload: jsonEncode({
              'type': 'email_change',
            }),
          );
          break;
      }
    } catch (e, st) {
      AppLogger.error('Ошибка показа in-app уведомления', tag: _logTag, error: e, stackTrace: st);
    }
  }

  AppNotification _mapSupabaseNotification(Map<String, dynamic> item) {
    final actorData = item['actor'] as Map<String, dynamic>?;
    final roleString = actorData?['role'] as String?;
    final isPremium = roleString == 'premium';
    // Используем actor из загруженных данных, или fallback через from_user_id, или actor_id
    final actorId = (actorData?['id'] as String?) ?? 
                    (item['from_user_id'] as String?) ?? 
                    (item['actor_id'] as String?) ?? '';
    final actor = actorData != null
        ? User(
            id: actorData['id'] as String? ?? actorId,
            name: actorData['full_name'] as String? ?? 'Пользователь',
            username: actorData['username'] as String? ?? 'user',
            avatar: actorData['avatar_url'] as String? ?? '',
            isPremium: isPremium,
            karma: 0,
          )
        : User(
            id: actorId,
            name: 'Пользователь',
            username: 'user',
            avatar: '',
            isPremium: false,
            karma: 0,
          );

    // Получаем commentText из data или из comment_text напрямую
    final dataField = item['data'] as Map<String, dynamic>?;
    String? commentText = dataField?['comment_text'] as String?;
    
    // Если commentText пустой, попробуем получить из comment_text напрямую (для старых уведомлений)
    commentText ??= item['comment_text'] as String?;
    
    // Проверяем, это сгруппированное уведомление
    final isGrouped = item['is_grouped'] as bool? ?? false;
    final groupCount = item['group_count'] as int?;
    
    // Парсим список акторов для сгруппированных уведомлений
    List<User>? actors;
    if (isGrouped && item['actors'] != null) {
      final actorsList = item['actors'] as List;
      actors = actorsList.map((actorData) {
        return User(
          id: actorData['id'] as String? ?? '',
          name: actorData['full_name'] as String? ?? 'Пользователь',
          username: actorData['username'] as String? ?? 'user',
          avatar: actorData['avatar_url'] as String? ?? '',
          isPremium: false,
          role: _mapSupabaseRole(actorData['role'] as String? ?? 'free'),
        );
      }).toList();
    }
    
    // Используем заголовок из сгруппированного уведомления или генерируем стандартный
    final title = item['title'] as String? ?? _getNotificationTitle(item['type'] as String);
    
    final messageText = (item['body'] as String?) ?? (item['text'] as String?);
    
    final notificationType = item['type'] as String;
    final relatedId = notificationType.startsWith('debate_')
        ? (item['discussion_id'] as String? ?? item['post_id'] as String? ?? '')
        : (item['post_id'] as String? ?? '');
    
    return AppNotification(
      id: item['id'] as String,
      type: _mapNotificationType(notificationType),
      fromUser: actor,
      title: title,
      message: _getNotificationMessage(notificationType, messageText, commentText: commentText),
      createdAt: DateTime.parse(item['created_at'] as String).toLocal(),
      isRead: item['is_read'] as bool? ?? false,
      relatedId: relatedId,
      imageUrl: actor.avatar,
      commentId: item['comment_id'] as String?,
      commentText: commentText,
      isGrouped: isGrouped,
      groupCount: groupCount,
      actors: actors,
    );
  }

  Future<void> unsubscribeFromAllChats() async {
    for (final channel in _chatRealtimeChannels.values) {
      await _supabaseChatService.unsubscribe(channel);
    }
    _chatRealtimeChannels.clear();
  }

  /// Добавить оптимистичное сообщение с локальным медиа (показывается мгновенно)
  void addOptimisticMediaMessage({
    required String tempId,
    required String chatId,
    required User otherUser,
    required String text,
    required String localMediaPath,
    required String mediaType,
    String? replyToId,
  }) {
    if (_currentUser == null) return;
    
    final optimisticMessage = ChatMessage(
      id: tempId,
      chatId: chatId,
      sender: _currentUser!,
      text: text,
      createdAt: DateTime.now(),
      isRead: false,
      isSending: true,
      mediaUrl: localMediaPath, // Используем локальный путь
      mediaType: mediaType,
      replyToId: replyToId,
    );
    
    _chatMessages.add(optimisticMessage);
    if (_chatMessagesCache.containsKey(chatId)) {
      _chatMessagesCache[chatId]!.add(optimisticMessage);
    }
    notifyListeners();
  }

  /// Обновить оптимистичное сообщение с реальным URL
  void updateOptimisticMediaMessage(String tempId, String realMediaUrl) {
    final index = _chatMessages.indexWhere((m) => m.id == tempId);
    if (index != -1) {
      _chatMessages[index] = _chatMessages[index].copyWith(
        mediaUrl: realMediaUrl,
        isSending: false,
      );
      
      final chatId = _chatMessages[index].chatId;
      if (_chatMessagesCache.containsKey(chatId)) {
        final cacheIndex = _chatMessagesCache[chatId]!.indexWhere((m) => m.id == tempId);
        if (cacheIndex != -1) {
          _chatMessagesCache[chatId]![cacheIndex] = _chatMessages[index];
        }
      }
      notifyListeners();
    }
  }

  /// Удалить оптимистичное сообщение при ошибке
  void removeOptimisticMessage(String tempId) {
    final index = _chatMessages.indexWhere((m) => m.id == tempId);
    if (index != -1) {
      final chatId = _chatMessages[index].chatId;
      _chatMessages.removeAt(index);
      
      if (_chatMessagesCache.containsKey(chatId)) {
        _chatMessagesCache[chatId]!.removeWhere((m) => m.id == tempId);
      }
      notifyListeners();
    }
  }

  /// Отправить сообщение с существующим temp ID (для медиа)
  Future<void> sendChatMessageWithTempId({
    required String tempId,
    required String otherUserId,
    required String text,
    String? mediaUrl,
    String? mediaType,
    String? videoThumbnail,
    String? replyToId,
  }) async {
    if (_currentUser == null) return;

    final chatData = await ensureSupabaseChat(otherUserId);
    if (chatData == null) return;

    final chatId = chatData['id'] as String;
    
    final validReplyToId = replyToId?.startsWith('temp_') == true ? null : replyToId;
    
    final messageData = await _supabaseChatService.sendMessage(
      chatId: chatId,
      senderId: _currentUser!.id,
      text: text,
      mediaUrl: mediaUrl,
      mediaType: mediaType,
      videoThumbnail: videoThumbnail,
      replyToId: validReplyToId,
    );

    if (messageData != null) {
      // Воспроизводим звук успешной отправки
      AudioService.playSuccessSound();
      
      // Заменяем временное сообщение на реальное
      final realMessage = _mapSupabaseMessageToChatMessage(messageData);
      final index = _chatMessages.indexWhere((m) => m.id == tempId);
      if (index != -1) {
        _chatMessages[index] = realMessage;
      }
      
      if (_chatMessagesCache.containsKey(chatId)) {
        final cacheIndex = _chatMessagesCache[chatId]!.indexWhere((m) => m.id == tempId);
        if (cacheIndex != -1) {
          _chatMessagesCache[chatId]![cacheIndex] = realMessage;
        }
      }

      // Обновляем превью чата (last_message/last_message_at) чтобы список чатов показывал актуальную дату
      if (_chatPreviewCache.containsKey(chatId)) {
        final chatPreview = Map<String, dynamic>.from(_chatPreviewCache[chatId]!);
        chatPreview['last_message'] = realMessage.text;
        chatPreview['last_message_at'] = realMessage.createdAt.toUtc().toIso8601String();
        chatPreview['last_message_sender_id'] = realMessage.sender.id;

        _chatPreviewCache[chatId] = chatPreview;
      }
      notifyListeners();
    } else {
      // Ошибка - помечаем как неотправленное
      final index = _chatMessages.indexWhere((m) => m.id == tempId);
      if (index != -1) {
        _chatMessages[index] = _chatMessages[index].copyWith(
          isSending: false,
          sendFailed: true,
        );
        notifyListeners();
      }
    }
  }

  Future<void> sendChatMessage({
    required String otherUserId,
    required String text,
    String? mediaUrl,
    String? mediaType,
    String? videoThumbnail,
    String? replyToId,
  }) async {
    if (_currentUser == null) return;

    // Проверка rate limit
    final rateLimitService = RateLimitService();
    if (!rateLimitService.canSendMessage(_currentUser!.id)) {
      AppLogger.warning('Rate limit: слишком много сообщений', tag: _logTag);
      throw Exception('Слишком много сообщений. Подождите минуту.');
    }

    final chatData = await ensureSupabaseChat(otherUserId);
    if (chatData == null) {
      AppLogger.error('Не удалось получить/создать чат', tag: _logTag);
      return;
    }

    final chatId = chatData['id'] as String;
    
    // 🔥 OPTIMISTIC UI: Создаём временное сообщение и показываем МГНОВЕННО
    final tempId = 'temp_${DateTime.now().millisecondsSinceEpoch}';
    final optimisticMessage = ChatMessage(
      id: tempId,
      chatId: chatId,
      sender: _currentUser!,
      text: text,
      createdAt: DateTime.now(),
      isRead: false,
      replyToId: replyToId,
      mediaUrl: mediaUrl,
      mediaType: mediaType,
      videoThumbnail: videoThumbnail,
      isSending: false, // Сразу показываем одну галочку (отправлено)
    );
    
    // Добавляем в UI мгновенно
    addChatMessage(optimisticMessage);
    
    // Воспроизводим звук отправки сообщения
    AudioService.playSendSound();
    
    notifyListeners();

    // Отправляем сообщение в Supabase в фоне
    // Проверяем что replyToId не временный
    final validReplyToId = replyToId?.startsWith('temp_') == true ? null : replyToId;
    
    final messageData = await _supabaseChatService.sendMessage(
      chatId: chatId,
      senderId: _currentUser!.id,
      text: text,
      mediaUrl: mediaUrl,
      mediaType: mediaType,
      videoThumbnail: videoThumbnail,
      replyToId: validReplyToId,
    );

    if (messageData != null) {
      // Заменяем временное сообщение на реальное
      final realMessage = _mapSupabaseMessageToChatMessage(messageData);
      final index = _chatMessages.indexWhere((m) => m.id == tempId);
      if (index != -1) {
        _chatMessages[index] = realMessage;
      }
      
      // Обновляем кеш сообщений
      if (_chatMessagesCache.containsKey(chatId)) {
        final cacheIndex = _chatMessagesCache[chatId]!.indexWhere((m) => m.id == tempId);
        if (cacheIndex != -1) {
          _chatMessagesCache[chatId]![cacheIndex] = realMessage;
          // Пересортируем от новых к старым
          _chatMessagesCache[chatId]!.sort((a, b) => b.createdAt.compareTo(a.createdAt));
        }
      }

      // Обновляем last_message в кеше чата
      if (_chatPreviewCache.containsKey(chatId)) {
        final chatPreview = Map<String, dynamic>.from(_chatPreviewCache[chatId]!);
        chatPreview['last_message'] = messageData['text'] as String? ?? '';
        chatPreview['last_message_at'] = realMessage.createdAt.toUtc().toIso8601String();
        chatPreview['last_message_sender_id'] = realMessage.sender.id;

        _chatPreviewCache[chatId] = chatPreview;
      }

      unawaited(PushNotificationService().sendChatNotification(
        recipientId: otherUserId,
        senderName: _currentUser!.name,
        messageText: realMessage.text,
        chatId: chatId,
        otherUserId: _currentUser!.id,
      ));

      notifyListeners();
    } else {
      // Ошибка отправки - помечаем сообщение как неотправленное
      final index = _chatMessages.indexWhere((m) => m.id == tempId);
      if (index != -1) {
        _chatMessages[index] = _chatMessages[index].copyWith(
          isSending: false,
          sendFailed: true,
        );
        notifyListeners();
      }
    }
  }

  Future<void> sendChatMessageToChatId({
    required String chatId,
    required String otherUserId,
    required String text,
    String? mediaUrl,
    String? mediaType,
    String? videoThumbnail,
    String? replyToId,
  }) async {
    if (_currentUser == null) return;

    final tempId = 'temp_${DateTime.now().millisecondsSinceEpoch}';
    final optimisticMessage = ChatMessage(
      id: tempId,
      chatId: chatId,
      sender: _currentUser!,
      text: text,
      createdAt: DateTime.now(),
      isRead: false,
      isSending: true,
      mediaUrl: mediaUrl,
      mediaType: mediaType,
      videoThumbnail: videoThumbnail,
      replyToId: replyToId,
    );

    _chatMessages.add(optimisticMessage);
    if (_chatMessagesCache.containsKey(chatId)) {
      _chatMessagesCache[chatId]!.add(optimisticMessage);
      _chatMessagesCache[chatId]!.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    }
    notifyListeners();

    final validReplyToId = replyToId?.startsWith('temp_') == true ? null : replyToId;
    try {
      final messageData = await _supabaseChatService.sendMessage(
        chatId: chatId,
        senderId: _currentUser!.id,
        text: text,
        mediaUrl: mediaUrl,
        mediaType: mediaType,
        videoThumbnail: videoThumbnail,
        replyToId: validReplyToId,
      );

      if (messageData != null) {
        AudioService.playSuccessSound();
        final realMessage = _mapSupabaseMessageToChatMessage(messageData);
        final index = _chatMessages.indexWhere((m) => m.id == tempId);
        if (index != -1) {
          _chatMessages[index] = realMessage;
        }
        if (_chatMessagesCache.containsKey(chatId)) {
          final cacheIndex = _chatMessagesCache[chatId]!.indexWhere((m) => m.id == tempId);
          if (cacheIndex != -1) {
            _chatMessagesCache[chatId]![cacheIndex] = realMessage;
            _chatMessagesCache[chatId]!.sort((a, b) => b.createdAt.compareTo(a.createdAt));
          }
        }

        if (_chatPreviewCache.containsKey(chatId)) {
          final chatPreview = Map<String, dynamic>.from(_chatPreviewCache[chatId]!);
          chatPreview['last_message'] = realMessage.text.isNotEmpty
              ? realMessage.text
              : (realMessage.mediaType == 'image' ? '📷 Фото' : (realMessage.mediaType == 'video' ? '🎥 Видео' : ''));
          chatPreview['last_message_at'] = realMessage.createdAt.toUtc().toIso8601String();
          chatPreview['last_message_sender_id'] = realMessage.sender.id;
          _chatPreviewCache[chatId] = chatPreview;
        }

        unawaited(PushNotificationService().sendChatNotification(
          recipientId: otherUserId,
          senderName: _currentUser!.name,
          messageText: realMessage.text,
          chatId: chatId,
          otherUserId: _currentUser!.id,
        ));

        notifyListeners();
      } else {
        markOptimisticMessageFailed(tempId);
      }
    } catch (e) {
      markOptimisticMessageFailed(tempId);
    }
  }

  Future<void> markChatAsReadSupabase(String chatId) async {
    if (_currentUser == null) return;

    // Обновляем локальные входящие сообщения как прочитанные
    bool messagesUpdated = false;
    for (int i = 0; i < _chatMessages.length; i++) {
      final msg = _chatMessages[i];
      if (msg.chatId == chatId && 
          msg.sender.id != _currentUser!.id &&  // ❌ ВХОДЯЩИЕ сообщения
          !msg.isRead) {
        _chatMessages[i] = msg.copyWith(isRead: true);
        messagesUpdated = true;
      }
    }
    
    // Обновляем в кеше сообщений
    final cachedMessages = _chatMessagesCache[chatId];
    if (cachedMessages != null) {
      for (int i = 0; i < cachedMessages.length; i++) {
        final msg = cachedMessages[i];
        if (msg.sender.id != _currentUser!.id && !msg.isRead) {
          cachedMessages[i] = msg.copyWith(isRead: true);
          messagesUpdated = true;
        }
      }
    }

    // Обновляем в БД через markAsRead (только входящие)
    await _supabaseChatService.markAsRead(chatId, _currentUser!.id);

    final chatPreviewRaw = _chatPreviewCache[chatId];
    if (chatPreviewRaw != null) {
      final chatData = Map<String, dynamic>.from(chatPreviewRaw);
      final user1Id = chatData['user1_id'] as String?;
      final user2Id = chatData['user2_id'] as String?;
      if (user1Id == _currentUser!.id) {
        chatData['unread_count_user1'] = 0;
      } else if (user2Id == _currentUser!.id) {
        chatData['unread_count_user2'] = 0;
      }

      final cachedMessages = _chatMessagesCache[chatId];
      if (cachedMessages != null && cachedMessages.isNotEmpty) {
        final lastMessage = cachedMessages.first; // Первый = самый новый
        chatData['last_message'] = lastMessage.text;
        chatData['last_message_at'] = lastMessage.createdAt.toUtc().toIso8601String();
        chatData['last_message_sender_id'] = lastMessage.sender.id;
      }

      _chatPreviewCache[chatId] = chatData;
      unawaited(_saveChatsToCache());
    }

    if (messagesUpdated) {
      unawaited(_saveChatsToCache());
    }

    await _refreshUnreadMessagesCount();
    notifyListeners();
  }

  // Получить chatId по userId
  String? getChatIdByUserId(String userId) {
    return _userIdToChatId[userId];
  }

  Future<int> getUnreadChatCount() async {
    if (_currentUser == null) return 0;
    return _supabaseChatService.getUnreadCount(_currentUser!.id);
  }

  // ===== PRESENCE / ОНЛАЙН-СТАТУС =====
  
  /// Проверить онлайн ли пользователь
  bool isUserOnline(String userId) {
    return PresenceService().isUserOnline(userId);
  }
  
  /// Получить время последнего онлайна
  DateTime? getUserLastSeen(String userId) {
    return PresenceService().getLastSeen(userId);
  }
  
  /// Отправить статус "печатает"
  Future<void> sendTypingStatus(String chatId, bool isTyping) async {
    await PresenceService().sendTypingStatus(chatId, isTyping);
  }
  
  /// Получить кто печатает в чате
  String? getTypingUser(String chatId) {
    return PresenceService().getTypingUser(chatId);
  }

  User _mapSupabaseUserToUser(Map<String, dynamic> data) {
    final avatarUrl = data['avatar_url'] as String?;
    final website = data['website'] as String?;
    final List<String> links = [];
    if (website != null && website.isNotEmpty) {
      links.add(website);
    }

    return User(
      id: data['id'] as String,
      name: data['full_name'] as String? ?? 'Пользователь',
      username: data['username'] as String? ?? 'user',
      avatar: avatarUrl ?? '',
      bio: data['bio'] as String?,
      website: website,
      links: links,
      location: data['location'] as String?,
      city: data['city'] as String?,
      isPremium: (data['role'] as String?) == 'premium',
      karma: data['karma'] as int? ?? 0,
      followersCount: data['followers_count'] as int? ?? 0,
      followingCount: data['following_count'] as int? ?? 0,
      isFollowed: false,
      isOnline: false,
      lastSeen: null,
      isVerified: data['is_verified'] as bool? ?? false,
      isPrivate: data['is_private'] as bool? ?? false,
    );
  }

  DateTime _parseSupabaseTimestamp(String value) {
    final trimmed = value.trim();
    DateTime parsed = DateTime.parse(trimmed);
    
    // Supabase возвращает время в UTC, но иногда без +00:00
    // Если нет timezone info, считаем что это UTC
    if (!trimmed.contains('+') && !trimmed.contains('Z') && !trimmed.endsWith('00:00')) {
      parsed = DateTime.utc(
        parsed.year, parsed.month, parsed.day,
        parsed.hour, parsed.minute, parsed.second, parsed.millisecond, parsed.microsecond
      );
    }
    
    return parsed.isUtc ? parsed.toLocal() : parsed;
  }

  ChatMessage _mapSupabaseMessageToChatMessage(Map<String, dynamic> data) {
    final senderData = data['sender'] as Map<String, dynamic>?;
    final sender = senderData != null
        ? _mapSupabaseUserToUser(senderData)
        : (_currentUser != null && data['sender_id'] == _currentUser!.id
            ? _currentUser!
            : User(
                id: data['sender_id'] as String,
                name: 'Пользователь',
                username: 'user',
                avatar: '',
                isPremium: false,
                karma: 0,
              ));

    // Загружаем ответное сообщение если есть reply_to
    ChatMessage? replyToMessage;
    final replyToId = data['reply_to_id'] as String?;
    final replyToRaw = data['reply_to'];
    Map<String, dynamic>? replyToData;
    if (replyToRaw is Map<String, dynamic>) {
      replyToData = replyToRaw;
    } else if (replyToRaw is List && replyToRaw.isNotEmpty) {
      final first = replyToRaw.first;
      if (first is Map) {
        replyToData = Map<String, dynamic>.from(first);
      }
    }
    
    if (replyToId != null && replyToData != null) {
      // Используем данные из Supabase
      final replySenderData = replyToData['sender'] as Map<String, dynamic>?;
      final replySender = replySenderData != null
          ? _mapSupabaseUserToUser(replySenderData)
          : User(id: 'unknown', name: 'Пользователь', username: 'user', avatar: '', isPremium: false, karma: 0);
      
      replyToMessage = ChatMessage(
        id: replyToData['id'] as String,
        chatId: data['chat_id'] as String,
        sender: replySender,
        text: replyToData['text'] as String? ?? '',
        createdAt: DateTime.now(),
      );
    } else if (replyToId != null) {
      // Fallback: ищем в кеше
      try {
        replyToMessage = _chatMessages.firstWhere((msg) => msg.id == replyToId);
      } catch (e) {
        // Если не нашли, создаем placeholder
        replyToMessage = ChatMessage(
          id: replyToId,
          chatId: data['chat_id'] as String,
          sender: User(id: 'unknown', name: 'Пользователь', username: 'user', avatar: '', isPremium: false, karma: 0),
          text: 'Загрузка...',
          createdAt: DateTime.now(),
        );
      }
    }

    return ChatMessage(
      id: data['id'] as String,
      chatId: data['chat_id'] as String,
      sender: sender,
      text: data['text'] as String? ?? '',
      createdAt: _parseSupabaseTimestamp(data['created_at'] as String),
      isRead: data['is_read'] as bool? ?? false,
      isDelivered: data['is_delivered'] as bool? ?? true, // По умолчанию true для существующих сообщений
      isEdited: data['is_edited'] as bool? ?? false,
      editedAt: data['updated_at'] != null ? _parseSupabaseTimestamp(data['updated_at'] as String) : null,
      replyToId: replyToId,
      replyToMessage: replyToMessage,
      reactions: _parseReactions(data['reactions']),
      images: data['media_url'] != null ? [data['media_url'] as String] : const [],
      videoThumbnail: data['video_thumbnail'] as String?,
      isPinned: data['is_pinned'] as bool? ?? false,
      isBookmarked: data['is_bookmarked'] as bool? ?? false,
      isDeletedForMe: (() {
        final chatId = data['chat_id'] as String;
        final chat = _chatPreviewCache[chatId];
        if (_currentUser != null && chat != null) {
          final isUser1 = chat['user1_id'] == _currentUser!.id;
          return isUser1
              ? (data['deleted_for_user1'] as bool? ?? false)
              : (data['deleted_for_user2'] as bool? ?? false);
        }
        // если не знаем сторону, полагаемся на бекендовый фильтр SELECT и считаем не удалено
        return false;
      })(),
      isDeletedForEveryone: data['is_deleted'] as bool? ?? false,
      forwardedFromId: data['forwarded_from_id'] as String?,
      forwardedFromName: data['forwarded_from_name'] as String?,
      mediaUrl: data['media_url'] as String?,
      mediaType: data['media_type'] as String?,
    );
  }

  // Парсинг реакций из JSON
  Map<String, ReactionType> _parseReactions(dynamic reactionsData) {
    if (reactionsData == null) return {};
    if (reactionsData is! Map) return {};
    
    final result = <String, ReactionType>{};
    for (final entry in reactionsData.entries) {
      final userId = entry.key.toString();
      final reactionName = entry.value?.toString();
      if (reactionName != null) {
        try {
          result[userId] = ReactionType.values.firstWhere(
            (r) => r.name == reactionName,
            orElse: () => ReactionType.like,
          );
        } catch (e) {
          // Ignore invalid reactions
        }
      }
    }
    return result;
  }

  // Получить количество непрочитанных сообщений в чате
  int getUnreadCount(String userIdOrChatId) {
    final currentUserId = _currentUser?.id;
    if (currentUserId == null) return 0;
    
    if (!Features.useSupabaseChats) {
      // Локальный режим: считаем по сообщениям
      final chatId = 'chat_$userIdOrChatId';
      return _chatMessages
          .where((m) => m.chatId == chatId && !m.isRead && m.sender.id != currentUserId)
          .length;
    }
    
    // Supabase режим: берем из кеша чата
    String chatId = userIdOrChatId;
    if (_userIdToChatId.containsKey(userIdOrChatId)) {
      chatId = _userIdToChatId[userIdOrChatId]!;
    }
    
    final chatData = _chatPreviewCache[chatId];
    if (chatData == null) return 0;
    
    // Определяем, какое поле unread_count использовать
    final user1Id = chatData['user1_id'] as String?;
    final user2Id = chatData['user2_id'] as String?;
    
    if (user1Id == currentUserId) {
      return (chatData['unread_count_user1'] as int?) ?? 0;
    } else if (user2Id == currentUserId) {
      return (chatData['unread_count_user2'] as int?) ?? 0;
    }
    
    return 0;
  }

  // Пометить все сообщения чата как прочитанные
  void markChatAsRead(String chatId) {
    bool hasChanges = false;
    for (int i = 0; i < _chatMessages.length; i++) {
      if (_chatMessages[i].chatId == chatId && 
          !_chatMessages[i].isRead && 
          _chatMessages[i].sender.id != currentUser?.id) {
        _chatMessages[i] = _chatMessages[i].copyWith(isRead: true);
        hasChanges = true;
      }
    }

    final cachedMessages = _chatMessagesCache[chatId];
    if (cachedMessages != null) {
      for (int i = 0; i < cachedMessages.length; i++) {
        if (!cachedMessages[i].isRead && cachedMessages[i].sender.id != currentUser?.id) {
          cachedMessages[i] = cachedMessages[i].copyWith(isRead: true);
          hasChanges = true;
        }
      }
    }

    if (hasChanges) {
      unawaited(_saveChatsToCache());
      notifyListeners();
    }
  }

  // Очистить историю чата (только у себя - помечаем как удаленные)
  void clearChatHistory(String chatId) {
    for (int i = 0; i < _chatMessages.length; i++) {
      if (_chatMessages[i].chatId == chatId) {
        _chatMessages[i] = _chatMessages[i].copyWith(isDeletedForMe: true);
      }
    }
    unawaited(_saveChatsToCache());
    notifyListeners();
  }

  // Проверка возможности изменения имени
  Map<String, dynamic> canChangeName() {
    if (_currentUser == null) return {'canChange': true, 'message': ''};
    
    final lastChanged = _currentUser!.nameChangedAt;
    if (lastChanged == null) {
      return {'canChange': true, 'message': 'name_change_allowed'};
    }
    
    final daysSinceChange = DateTime.now().difference(lastChanged).inDays;
    if (daysSinceChange >= 1) {
      return {'canChange': true, 'message': 'name_change_allowed'};
    }
    
    final hoursLeft = 24 - DateTime.now().difference(lastChanged).inHours;
    return {
      'canChange': false,
      'message': 'name_change_in_hours',
      'hours': hoursLeft
    };
  }

  // Проверка возможности изменения username
  Map<String, dynamic> canChangeUsername() {
    if (_currentUser == null) return {'canChange': true, 'message': ''};
    
    final lastChanged = _currentUser!.usernameChangedAt;
    final changeCount = _currentUser!.usernameChangeCount;
    
    if (lastChanged == null) {
      return {'canChange': true, 'message': 'username_change_allowed'};
    }
    
    final daysSinceChange = DateTime.now().difference(lastChanged).inDays;
    
    // Первое изменение - через 1 день
    if (changeCount == 1 && daysSinceChange >= 1) {
      return {'canChange': true, 'message': 'username_change_allowed'};
    }
    
    // Второе и последующие - через 14 дней
    if (changeCount >= 2 && daysSinceChange >= 14) {
      return {'canChange': true, 'message': 'username_change_allowed'};
    }
    
    // Не прошло достаточно времени
    final requiredDays = changeCount >= 2 ? 14 : 1;
    final daysLeft = requiredDays - daysSinceChange;
    return {
      'canChange': false,
      'message': 'username_change_in_days',
      'days': daysLeft,
    };
  }

  // Обновить профиль текущего пользователя
  Future<Map<String, dynamic>> updateCurrentUserProfile({
    String? name,
    String? username,
    String? bio,
    String? avatarPath,
    String? email,
    String? phone,
    String? gender,
    DateTime? birthDate,
    String? city,
    String? website,
    String? websiteText,
    String? location,
    String? profileColor,
    bool updateUsernameChangeCount = false,
  }) async {
    if (_currentUser == null) {
      return {'success': false, 'error': 'Пользователь не найден'};
    }

    // Проверяем изменение имени
    if (name != null && name != _currentUser!.name) {
      final nameCheck = canChangeName();
      if (!nameCheck['canChange']) {
        return {'success': false, 'error': nameCheck['message']};
      }
    }

    // Проверяем изменение username
    if (username != null && username != _currentUser!.username) {
      final usernameCheck = canChangeUsername();
      if (usernameCheck['canChange'] != true) {
        return {'success': false, 'error': usernameCheck['message'] ?? 'Нельзя изменить username'};
      }
      bool isAvailable;
      if (Features.useSupabaseAuth || Features.useSupabaseUsers) {
        final service = SupabaseUserService();
        isAvailable = await service.isUsernameAvailable(username);
      } else {
        isAvailable = !_registeredUsernames.contains(username.toLowerCase());
      }
      if (!isAvailable) {
        return {'success': false, 'error': 'Username уже занят'};
      }
    }

    // Обновляем старый username в индексе если меняется
    if (username != null && username != _currentUser!.username) {
      _registeredUsernames.remove(_normalizeUsername(_currentUser!.username));
      _registeredUsernames.add(_normalizeUsername(username));
      await _saveRegistrationIndex();
    }

    // Определяем финальный URL аватара
    String finalAvatar = _currentUser!.avatar;
    if (avatarPath != null && avatarPath.isNotEmpty) {
      if (Features.useSupabaseUsers) {
        final isNetworkUrl = avatarPath.startsWith('http://') || avatarPath.startsWith('https://');
        if (isNetworkUrl) {
          // Уже готовый URL (например, пришёл из Supabase) — просто используем его
          finalAvatar = avatarPath;
        } else {
          // Локальный путь файла — загружаем в Supabase Storage и сохраняем публичный URL
          try {
            final storageService = SupabaseStorageService();
            final file = File(avatarPath);
            final uploadedUrl = await storageService.uploadAvatar(_currentUser!.id, file);
            if (uploadedUrl != null && uploadedUrl.isNotEmpty) {
              finalAvatar = uploadedUrl;
            }
          } catch (e) {
            AppLogger.error('Ошибка загрузки аватара в Supabase Storage', tag: _logTag, error: e);
          }
        }
      } else {
        // Локальный режим — можно хранить путь как есть
        finalAvatar = avatarPath;
      }
    }

    final normalizedBio = bio?.trim();
    final normalizedEmail = email?.trim();
    final normalizedPhone = phone?.trim();
    final normalizedGender = gender?.trim();
    final normalizedCity = city?.trim();
    final normalizedWebsite = website?.trim();
    final normalizedWebsiteText = websiteText?.trim();
    final normalizedLocation = location?.trim();
    final normalizedProfileColor = profileColor?.trim();

    final now = DateTime.now();
    final updatedUser = User(
      id: _currentUser!.id,
      name: name ?? _currentUser!.name,
      username: username ?? _currentUser!.username,
      avatar: finalAvatar,
      bio: normalizedBio != null ? (normalizedBio.isNotEmpty ? normalizedBio : null) : _currentUser!.bio,
      email: normalizedEmail != null ? (normalizedEmail.isNotEmpty ? normalizedEmail : null) : _currentUser!.email,
      phone: normalizedPhone != null ? (normalizedPhone.isNotEmpty ? normalizedPhone : null) : _currentUser!.phone,
      gender: normalizedGender != null ? (normalizedGender.isNotEmpty ? normalizedGender : null) : _currentUser!.gender,
      birthDate: birthDate ?? _currentUser!.birthDate,
      city: normalizedCity != null ? (normalizedCity.isNotEmpty ? normalizedCity : null) : _currentUser!.city,
      website: normalizedWebsite != null ? (normalizedWebsite.isNotEmpty ? normalizedWebsite : null) : _currentUser!.website,
      websiteText: normalizedWebsiteText != null ? (normalizedWebsiteText.isNotEmpty ? normalizedWebsiteText : null) : _currentUser!.websiteText,
      location: normalizedLocation != null ? (normalizedLocation.isNotEmpty ? normalizedLocation : null) : _currentUser!.location,
      isPremium: _currentUser!.isPremium,
      karma: _currentUser!.karma,
      badges: _currentUser!.badges,
      role: _currentUser!.role,
      followersCount: _currentUser!.followersCount,
      followingCount: _currentUser!.followingCount,
      isFollowed: _currentUser!.isFollowed,
      isOnline: _currentUser!.isOnline,
      lastSeen: _currentUser!.lastSeen,
      isVerified: _currentUser!.isVerified,
      isBlocked: _currentUser!.isBlocked,
      isPrivate: _currentUser!.isPrivate,
      nameChangedAt: (name != null && name != _currentUser!.name) ? now : _currentUser!.nameChangedAt,
      usernameChangedAt: (username != null && username != _currentUser!.username) ? now : _currentUser!.usernameChangedAt,
      usernameChangeCount: (username != null && username != _currentUser!.username) 
          ? _currentUser!.usernameChangeCount + 1 
          : _currentUser!.usernameChangeCount,
      profileColor: normalizedProfileColor != null ? (normalizedProfileColor.isNotEmpty ? normalizedProfileColor : null) : _currentUser!.profileColor,
    );
    
    // Сохраняем в Supabase если включено
    if (Features.useSupabaseUsers) {
      try {
        final userService = SupabaseUserService();
        await userService.updateProfile(
          userId: _currentUser!.id,
          fullName: updatedUser.name,
          username: updatedUser.username,
          bio: updatedUser.bio,
          website: updatedUser.website,
          websiteText: updatedUser.websiteText,
          location: updatedUser.location,
          city: updatedUser.city,
          avatarUrl: finalAvatar,
          phone: updatedUser.phone,
          gender: updatedUser.gender,
          birthDate: updatedUser.birthDate,
          profileColor: updatedUser.profileColor,
        );
        AppLogger.success('Профиль сохранен в Supabase', tag: _logTag);

        await _saveProfileFieldsLocally(
          gender: updatedUser.gender,
          birthDate: updatedUser.birthDate,
          profileColor: updatedUser.profileColor,
          city: updatedUser.city,
          bio: updatedUser.bio,
          website: updatedUser.website,
          websiteText: updatedUser.websiteText,
        );
        
        // Сбрасываем флаг кеша чтобы при следующем loadSupabaseCurrentUser профиль перезагрузился
        resetSupabaseProfile();
        
        // Перезагружаем профиль из Supabase чтобы получить актуальные данные
        final freshProfile = await userService.getProfile(_currentUser!.id);
        if (freshProfile != null) {
          _currentUser = await _mapSupabaseProfileMapToUserWithLocal(freshProfile);
        } else {
          _currentUser = updatedUser;
        }
        
        // Обновляем аватар во всех постах пользователя в кеше
        if (finalAvatar.isNotEmpty) {
          int updatedCount = 0;
          for (int i = 0; i < _stories.length; i++) {
            if (_stories[i].author.id == _currentUser!.id) {
              _stories[i] = _stories[i].copyWith(
                author: _stories[i].author.copyWith(avatar: finalAvatar),
              );
              updatedCount++;
            }
          }
          AppLogger.success('Обновлено постов: $updatedCount', tag: _logTag);
        }
      } catch (e) {
        AppLogger.error('Ошибка сохранения в Supabase', tag: _logTag, error: e);
        return {'success': false, 'error': 'Ошибка сохранения в Supabase: $e'};
      }
    } else {
      // Обновляем current user (если не Supabase)
      _currentUser = updatedUser;

      await _saveProfileFieldsLocally(
        gender: updatedUser.gender,
        birthDate: updatedUser.birthDate,
        profileColor: updatedUser.profileColor,
        city: updatedUser.city,
        bio: updatedUser.bio,
        website: updatedUser.website,
        websiteText: updatedUser.websiteText,
      );
    }
    
    // Обновляем в списке пользователей
    final userIndex = _users.indexWhere((u) => u.id == 'current_user');
    if (userIndex != -1) {
      _users[userIndex] = _currentUser!;
    }
    
    // ВАЖНО: Обновляем автора во всех постах текущего пользователя (только для локального режима)
    if (!Features.useSupabasePosts) {
      for (var i = 0; i < _stories.length; i++) {
        if (_stories[i].author.id == 'current_user') {
          _stories[i] = _stories[i].copyWith(author: _currentUser!);
        }
      }
    }
    
    notifyListeners();
    
    return {'success': true};
  }
  // БЛОКИРОВКА ПОЛЬЗОВАТЕЛЕЙ
  // ============================================

  // Заблокировать пользователя
  Future<bool> blockUser(String userId) async {
    if (_currentUser != null && userId == _currentUser!.id) return false; // Нельзя заблокировать себя
    
    final wasAdded = _blockedUsers.add(userId);
    
    // Обновляем статус блокировки у пользователя
    final userIndex = _users.indexWhere((u) => u.id == userId);
    User? previousUser;
    if (userIndex != -1) {
      previousUser = _users[userIndex];
      _users[userIndex] = _users[userIndex].copyWith(isBlocked: true);
    }
    
    notifyListeners();
    
    // Сохраняем заблокированных локально
    _saveBlockedUsers();
    
    // Синхронизируем с Supabase
    if (Features.useSupabaseUsers && _currentUser != null) {
      try {
        final success = await _supabaseBlockService.blockUser(_currentUser!.id, userId);
        if (!success) {
          if (wasAdded) {
            _blockedUsers.remove(userId);
          }
          if (userIndex != -1 && previousUser != null) {
            _users[userIndex] = previousUser;
          }
          notifyListeners();
          return false;
        }
      } catch (e) {
        AppLogger.warning('Ошибка блокировки пользователя в Supabase', tag: _logTag, error: e);
        if (wasAdded) {
          _blockedUsers.remove(userId);
        }
        if (userIndex != -1 && previousUser != null) {
          _users[userIndex] = previousUser;
        }
        notifyListeners();
        return false;
      }
    }
    
    // Автоматически отписываемся (асинхронно, после обновления UI)
    if (_followedUsers.contains(userId)) {
      Future.microtask(() => toggleFollow(userId));
    }
    return true;
  }
  
  // Сохранить заблокированных пользователей
  Future<void> _saveBlockedUsers() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('blocked_users', _blockedUsers.toList());
    } catch (e) {
      AppLogger.warning('Ошибка сохранения заблокированных', tag: _logTag, error: e);
    }
  }
  
  // Загрузить заблокированных пользователей
  Future<void> _loadBlockedUsers() async {
    // Сначала загружаем из локального хранилища
    try {
      final prefs = await SharedPreferences.getInstance();
      final blocked = prefs.getStringList('blocked_users') ?? [];
      _blockedUsers = blocked.toSet();
    } catch (e) {
      AppLogger.warning('Ошибка загрузки заблокированных', tag: _logTag, error: e);
    }
    
    // Потом мержим с Supabase
    if (Features.useSupabaseUsers && _currentUser != null) {
      try {
        final blocked = await _supabaseBlockService.getBlockedUsers(_currentUser!.id);
        _blockedUsers.addAll(blocked);
        await _saveBlockedUsers();
      } catch (e) {
        AppLogger.warning('Ошибка загрузки заблокированных из Supabase', tag: _logTag, error: e);
      }
    }
  }

  // Разблокировать пользователя
  Future<bool> unblockUser(String userId) async {
    final removed = _blockedUsers.remove(userId);
    
    // Обновляем статус блокировки у пользователя
    final userIndex = _users.indexWhere((u) => u.id == userId);
    User? previousUser;
    if (userIndex != -1) {
      previousUser = _users[userIndex];
      _users[userIndex] = _users[userIndex].copyWith(isBlocked: false);
    }
    
    notifyListeners();

    if (Features.useSupabaseUsers && _currentUser != null) {
      try {
        final success = await _supabaseBlockService.unblockUser(_currentUser!.id, userId);
        if (!success) {
          if (removed) {
            _blockedUsers.add(userId);
          }
          if (userIndex != -1 && previousUser != null) {
            _users[userIndex] = previousUser;
          }
          notifyListeners();
          return false;
        }
      } catch (e) {
        AppLogger.warning('Ошибка разблокировки пользователя', tag: _logTag, error: e);
        if (removed) {
          _blockedUsers.add(userId);
        }
        if (userIndex != -1 && previousUser != null) {
          _users[userIndex] = previousUser;
        }
        notifyListeners();
        return false;
      }
    }

    await _saveBlockedUsers();
    return true;
  }

  // Проверить, заблокирован ли пользователь
  bool isUserBlocked(String userId) {
    return _blockedUsers.contains(userId);
  }

  // ============================================
  // НАСТРОЙКИ
  // ============================================

  // Изменить приватность аккаунта
  void setPrivateAccount(bool value) {
    _privateAccount = value;
    
    // Обновляем текущего пользователя
    if (_currentUser != null) {
      _currentUser = _currentUser!.copyWith(isPrivate: value);
      
      // Обновляем в Supabase
      if (Features.useSupabaseUsers) {
        final userService = SupabaseUserService();
        userService.updateProfile(
          userId: _currentUser!.id,
          isPrivate: value,
        ).catchError((e) {
          AppLogger.error('Ошибка обновления isPrivate в Supabase', tag: _logTag, error: e);
        });
      }
    }
    
    _saveSettings();
    notifyListeners();
  }

  // Изменить показ онлайн-статуса
  void setShowOnlineStatus(bool value) {
    _showOnlineStatus = value;
    _saveSettings();
    notifyListeners();
    if (_currentUser != null) {
      _supabaseSettingsService.updatePrivacySettings(userId: _currentUser!.id, showOnlineStatus: value);
      unawaited(PresenceService().updateOnlineVisibility(
        _currentUser!.id,
        showOnlineStatus: value,
      ));
    }
  }

  // Изменить показ историй
  void setShowStories(bool value) {
    _showStories = value;
    _saveSettings();
    notifyListeners();
    if (_currentUser != null) {
      _supabaseSettingsService.updatePrivacySettings(userId: _currentUser!.id, showStories: value);
    }
  }

  // Изменить разрешение сообщений
  void setAllowMessages(bool value) {
    _allowMessages = value;
    _saveSettings();
    notifyListeners();
    if (_currentUser != null) {
      _supabaseSettingsService.updatePrivacySettings(userId: _currentUser!.id, allowMessages: value);
    }
  }

  // Изменить кто видит посты
  void setWhoCanSeeMyPosts(String value) {
    _whoCanSeeMyPosts = value;
    _saveSettings();
    notifyListeners();
    if (_currentUser != null) {
      _supabaseSettingsService.updatePrivacySettings(userId: _currentUser!.id, whoCanSeePosts: value);
    }
  }

  // Изменить кто может писать
  void setWhoCanMessageMe(String value) {
    _whoCanMessageMe = value;
    _saveSettings();
    notifyListeners();
    if (_currentUser != null) {
      _supabaseSettingsService.updatePrivacySettings(userId: _currentUser!.id, whoCanMessage: value);
    }
  }

  // Изменить push-уведомления
  void setPushNotifications(bool value) {
    _pushNotifications = value;
    _saveSettings();
    notifyListeners();
    if (_currentUser != null) {
      _supabaseSettingsService.updateNotificationSettings(userId: _currentUser!.id, pushNotifications: value);
    }
  }

  // Изменить email-уведомления
  void setEmailNotifications(bool value) {
    _emailNotifications = value;
    _saveSettings();
    notifyListeners();
    if (_currentUser != null) {
      _supabaseSettingsService.updateNotificationSettings(userId: _currentUser!.id, emailNotifications: value);
    }
  }

  // Изменить уведомления о лайках
  void setLikesNotifications(bool value) {
    _likesNotifications = value;
    _saveSettings();
    notifyListeners();
    if (_currentUser != null) {
      _supabaseSettingsService.updateNotificationSettings(userId: _currentUser!.id, likesNotifications: value);
    }
  }

  // Изменить уведомления о комментариях
  void setCommentsNotifications(bool value) {
    _commentsNotifications = value;
    _saveSettings();
    notifyListeners();
    if (_currentUser != null) {
      _supabaseSettingsService.updateNotificationSettings(userId: _currentUser!.id, commentsNotifications: value);
    }
  }

  // Изменить уведомления о подписках
  void setFollowsNotifications(bool value) {
    _followsNotifications = value;
    _saveSettings();
    notifyListeners();
    if (_currentUser != null) {
      _supabaseSettingsService.updateNotificationSettings(userId: _currentUser!.id, followsNotifications: value);
    }
  }

  // Изменить уведомления о сообщениях
  void setMessagesNotifications(bool value) {
    _messagesNotifications = value;
    _saveSettings();
    notifyListeners();
    if (_currentUser != null) {
      _supabaseSettingsService.updateNotificationSettings(userId: _currentUser!.id, messagesNotifications: value);
    }
  }

  // Изменить показ подписчиков
  void setShowFollowers(bool value) {
    _showFollowers = value;
    _saveSettings();
    notifyListeners();
    if (_currentUser != null) {
      _supabaseSettingsService.updatePrivacySettings(userId: _currentUser!.id, showFollowers: value);
    }
  }

  // Изменить показ подписок
  void setShowFollowing(bool value) {
    _showFollowing = value;
    _saveSettings();
    notifyListeners();
    if (_currentUser != null) {
      _supabaseSettingsService.updatePrivacySettings(userId: _currentUser!.id, showFollowing: value);
    }
  }

  // ============================================
  // РЕКОМЕНДАЦИИ
  // ============================================

  // Получить рекомендованных пользователей
  List<User> getRecommendedUsers() {
    if (_currentUser == null) return [];
    
    if (Features.useSupabaseUsers) {
      // В Supabase-режиме возвращаем кэшированных рекомендованных пользователей
      return _recommendedUsers;
    }
    
    // Локальный режим: исключаем текущего пользователя и заблокированных
    final candidates = _users.where((u) => 
      u.id != _currentUser!.id && 
      !_blockedUsers.contains(u.id) &&
      true
    ).toList();
    
    // Сортируем по карме и количеству подписчиков
    candidates.sort((a, b) {
      final scoreA = a.karma + (a.followersCount * 2);
      final scoreB = b.karma + (b.followersCount * 2);
      return scoreB.compareTo(scoreA);
    });
    
    // Возвращаем топ-10
    return candidates.take(10).toList();
  }

  // Флаг для предотвращения повторных вызовов
  bool _isLoadingRecommendations = false;
  
  // Загрузить рекомендованных пользователей из Supabase
  Future<void> loadRecommendedUsers() async {
    // Защита от повторных вызовов
    if (_isLoadingRecommendations) return;
    
    if (!Features.useSupabaseUsers) {
      AppLogger.warning('Рекомендации отключены (useSupabaseUsers=false)', tag: _logTag);
      return;
    }
    if (_currentUser == null) {
      AppLogger.warning('Рекомендации: _currentUser == null, пропускаем загрузку', tag: _logTag);
      return;
    }
    
    _isLoadingRecommendations = true;
    
    try {
      final userService = SupabaseUserService();
      final usersData = await userService.getTopUsers(limit: 100);
      
      // Сначала фильтруем: исключаем себя, заблокированных и уже подписанных
      var filtered = usersData
          .where((data) {
            final userId = data['id'] as String;
            return userId != _currentUser!.id &&
                   !_blockedUsers.contains(userId) &&
                   !_followedUsers.contains(userId);
          })
          .toList();
      
      
      // Если после фильтрации никого нет, показываем хотя бы пару пользователей (исключая себя и заблокированных)
      if (filtered.isEmpty) {
        AppLogger.warning('Рекомендации пусты после фильтрации. _followedUsers: ${_followedUsers.length}, _blockedUsers: ${_blockedUsers.length}. Показываем fallback.', tag: _logTag);
        // Fallback: показываем любых пользователей, кроме себя и заблокированных
        filtered = usersData
            .where((data) {
              final userId = data['id'] as String;
              return userId != _currentUser!.id && !_blockedUsers.contains(userId);
            })
            .toList();
      }
      
      _recommendedUsers = filtered
          .take(10)
          .map((data) {
            final userId = data['id'] as String;
            return User(
              id: userId,
              name: data['full_name'] as String? ?? 'Пользователь',
              username: data['username'] as String? ?? 'user',
              avatar: data['avatar_url'] as String? ?? '',
              bio: data['bio'] as String?,
              isPremium: (data['role'] as String?) == 'premium',
              karma: data['karma'] as int? ?? 0,
              followersCount: data['followers_count'] as int? ?? 0,
              followingCount: data['following_count'] as int? ?? 0,
              isVerified: data['is_verified'] as bool? ?? false,
              isFollowed: _followedUsers.contains(userId),
            );
          })
          .toList();
      notifyListeners();
    } catch (e) {
      AppLogger.error('Ошибка загрузки рекомендаций', tag: _logTag, error: e);
    } finally {
      _isLoadingRecommendations = false;
    }
  }

  // Получить рекомендованные посты (на основе лайков)
  List<Story> getRecommendedStories() {
    if (_currentUser == null) return [];
    
    // Получаем посты, которые пользователь лайкнул
    final likedStories = _stories.where((s) => s.isLiked).toList();
    
    // Если нет лайкнутых постов, возвращаем популярные
    if (likedStories.isEmpty) {
      return _stories
        .where((s) => 
          s.author.id != 'current_user' && 
          !_notInterestedPosts.contains(s.id)
        )
        .toList()
        ..sort((a, b) => b.likes.compareTo(a.likes))
        ..take(5).toList();
    }
    
    // Находим авторов лайкнутых постов
    final likedAuthors = likedStories.map((s) => s.author.id).toSet();
    
    // Рекомендуем посты от этих авторов, которые пользователь ещё не видел
    final recommendations = _stories.where((s) =>
      likedAuthors.contains(s.author.id) &&
      s.author.id != 'current_user' &&
      !s.isLiked &&
      !_notInterestedPosts.contains(s.id)
    ).toList();
    
    // Сортируем по популярности
    recommendations.sort((a, b) => b.likes.compareTo(a.likes));
    
    return recommendations.take(5).toList();
  }
  // ============================================
  // ЖАЛОБЫ НА КОНТЕНТ
  // ============================================

  // Подать жалобу
  Future<bool> reportContent({
    required ReportType type,
    required ReportContentType contentType,
    required String contentId,
    String? description,
  }) async {
    if (_currentUser == null) return false;

    final report = Report(
      id: 'report_${DateTime.now().millisecondsSinceEpoch}',
      type: type,
      contentType: contentType,
      contentId: contentId,
      reporter: _currentUser!,
      description: description,
      createdAt: DateTime.now(),
    );
    
    _reports.add(report);
    notifyListeners();
    
    if (Features.useSupabaseUsers) {
      try {
        final created = await _supabaseReportService.createReport(
          reporterId: _currentUser!.id,
          contentType: _mapReportContentType(contentType),
          contentId: contentId,
          reportType: _mapReportType(type),
          description: description,
        );
        if (!created) {
          _reports.removeWhere((r) => r.id == report.id);
          notifyListeners();
          return false;
        }
      } catch (e) {
        AppLogger.warning('Ошибка отправки жалобы в Supabase', tag: _logTag, error: e);
        _reports.removeWhere((r) => r.id == report.id);
        notifyListeners();
        return false;
      }
    }
    
    await _saveReports();
    return true;
  }

  // Получить жалобы на контент
  List<Report> getReportsForContent(String contentId) {
    return _reports.where((r) => r.contentId == contentId).toList();
  }

  // Проверить, жаловался ли пользователь на контент
  bool hasReported(String contentId) {
    if (_currentUser == null) return false;
    return _reports.any((r) => 
      r.contentId == contentId && 
      r.reporter.id == _currentUser!.id
    );
  }

  Future<void> joinCommunity(String communityId) async {
    if (_currentUser == null) return;
    if (_joinedCommunities.contains(communityId)) return;

    final index = _communities.indexWhere((c) => c.id == communityId);
    Community? previous;

    if (index != -1) {
      previous = _communities[index];
      _communities[index] = previous.copyWith(
        isJoined: true,
        membersCount: previous.membersCount + 1,
      );
    }

    _joinedCommunities.add(communityId);
    notifyListeners();

    try {
      await _supabaseCommunityService.joinCommunity(_currentUser!.id, communityId);
      await _saveJoinedCommunities();
      await _saveCommunitiesToCache();
    } catch (e) {
      AppLogger.warning('Ошибка вступления в сообщество', tag: _logTag, error: e);
      if (index != -1 && previous != null) {
        _communities[index] = previous;
      }
      _joinedCommunities.remove(communityId);
      notifyListeners();
    }
  }

  Future<void> leaveCommunity(String communityId) async {
    if (_currentUser == null) return;
    if (!_joinedCommunities.contains(communityId)) return;

    final index = _communities.indexWhere((c) => c.id == communityId);
    Community? previous;

    if (index != -1) {
      previous = _communities[index];
      final newCount = previous.membersCount > 0 ? previous.membersCount - 1 : 0;
      _communities[index] = previous.copyWith(
        isJoined: false,
        membersCount: newCount,
      );
    }

    _joinedCommunities.remove(communityId);
    notifyListeners();

    try {
      await _supabaseCommunityService.leaveCommunity(_currentUser!.id, communityId);
      await _saveJoinedCommunities();
      await _saveCommunitiesToCache();
    } catch (e) {
      AppLogger.warning('Ошибка выхода из сообщества', tag: _logTag, error: e);
      if (index != -1 && previous != null) {
        _communities[index] = previous;
      }
      _joinedCommunities.add(communityId);
      notifyListeners();
    }
  }

  String _mapReportContentType(ReportContentType type) {
    switch (type) {
      case ReportContentType.story:
        return 'post'; // БД constraint: 'post', не 'story'
      case ReportContentType.comment:
        return 'comment';
      case ReportContentType.user:
        return 'user';
      case ReportContentType.community:
        return 'community';
    }
  }

  String _mapReportType(ReportType type) {
    switch (type) {
      case ReportType.spam:
        return 'spam';
      case ReportType.harassment:
        return 'harassment';
      case ReportType.inappropriate:
        return 'inappropriate';
      case ReportType.adult:
        return 'adult';
      case ReportType.fake:
        return 'fake';
      case ReportType.violence:
        return 'violence';
      case ReportType.copyright:
        return 'copyright';
      case ReportType.other:
        return 'other';
    }
  }

  Future<void> _saveReports() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = _reports.map((r) => r.toJson()).toList();
      await prefs.setString('reports', jsonEncode(encoded));
    } catch (e) {
      AppLogger.warning('Ошибка сохранения жалоб локально', tag: _logTag, error: e);
    }
  }

  Future<void> _loadReports() async {
    if (Features.useSupabaseUsers && _currentUser != null) {
      try {
        final reports = await _supabaseReportService.getUserReports(_currentUser!.id);
        _reports = reports.map((item) {
          final reporterData = item['reporter'] as Map<String, dynamic>?;
          final reporter = reporterData != null
              ? User(
                  id: reporterData['id'] as String,
                  name: reporterData['full_name'] as String? ?? 'Пользователь',
                  username: reporterData['username'] as String? ?? 'user',
                  avatar: reporterData['avatar_url'] as String? ?? '',
                  isPremium: false,
                  karma: 0,
                )
              : _currentUser!;

          return Report(
            id: item['id'] as String,
            type: _mapReportTypeFromDb(item['report_type'] as String? ?? 'other'),
            contentType: _mapReportContentTypeFromDb(item['content_type'] as String? ?? 'post'),
            contentId: item['content_id'] as String,
            reporter: reporter,
            description: item['description'] as String?,
            createdAt: DateTime.parse(item['created_at'] as String).toLocal(),
            isResolved: item['is_resolved'] as bool? ?? false,
            resolvedBy: item['resolved_by'] as String?,
          );
        }).toList();
      } catch (e) {
        AppLogger.warning('Ошибка загрузки жалоб из Supabase', tag: _logTag, error: e);
      }
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      final data = prefs.getString('reports');
      if (data != null && data.isNotEmpty) {
        final decoded = jsonDecode(data) as List<dynamic>;
        final localReports = decoded.map((item) => Report.fromJson(item as Map<String, dynamic>)).toList();
        if (_reports.isEmpty) {
          _reports = localReports;
        } else {
          _reports.addAll(localReports.where((local) => !_reports.any((r) => r.id == local.id)));
        }
      }
    } catch (e) {
      AppLogger.warning('Ошибка загрузки жалоб локально', tag: _logTag, error: e);
    }
  }

  ReportType _mapReportTypeFromDb(String value) {
    switch (value) {
      case 'spam':
        return ReportType.spam;
      case 'harassment':
        return ReportType.harassment;
      case 'inappropriate':
        return ReportType.inappropriate;
      case 'adult':
        return ReportType.adult;
      case 'fake':
        return ReportType.fake;
      case 'violence':
        return ReportType.violence;
      case 'copyright':
        return ReportType.copyright;
      default:
        return ReportType.other;
    }
  }

  ReportContentType _mapReportContentTypeFromDb(String value) {
    switch (value) {
      case 'post': // БД хранит 'post'
      case 'story':
        return ReportContentType.story;
      case 'comment':
        return ReportContentType.comment;
      case 'user':
        return ReportContentType.user;
      case 'community':
        return ReportContentType.community;
      default:
        return ReportContentType.story;
    }
  }

  Future<void> _loadCommunities() async {
    if (!Features.useSupabaseUsers) {
      if (_communities.isEmpty) {
        _initializeCommunities();
      }
      return;
    }

    try {
      final userId = _currentUser?.id;
      final data = await _supabaseCommunityService.getCommunities();
      Set<String> joined = _joinedCommunities;

      if (userId != null && userId.isNotEmpty) {
        try {
          final userCommunities = await _supabaseCommunityService.getUserCommunities(userId);
          joined = userCommunities
              .map((item) => item['community_id'] as String?)
              .whereType<String>()
              .toSet();
        } catch (e) {
          AppLogger.warning('Ошибка загрузки вступленных сообществ', tag: _logTag, error: e);
        }
      }

      _communities = data.map((item) {
        final community = _mapSupabaseCommunity(item);
        return community.copyWith(isJoined: joined.contains(community.id));
      }).toList();

      _joinedCommunities = joined;
      await _saveJoinedCommunities();
      await _saveCommunitiesToCache();
      notifyListeners();
    } catch (e) {
      AppLogger.warning('Ошибка загрузки сообществ', tag: _logTag, error: e);
      await _loadCommunitiesFromCache();
      notifyListeners();
    }
  }

  Community _mapSupabaseCommunity(Map<String, dynamic> data) {
    final tagsData = data['tags'];
    final List<String> tags = tagsData is List
        ? tagsData.map((tag) => tag?.toString() ?? '').where((tag) => tag.isNotEmpty).toList()
        : const [];

    return Community(
      id: data['id'] as String? ?? '',
      name: data['name'] as String? ?? '',
      description: data['description'] as String? ?? '',
      avatar: data['avatar_url'] as String? ?? '',
      coverImage: data['cover_image_url'] as String? ?? '',
      membersCount: data['members_count'] as int? ?? 0,
      postsCount: data['posts_count'] as int? ?? 0,
      tags: tags,
    );
  }

  Future<void> _saveCommunitiesToCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = _communities
          .map((c) => {
                'id': c.id,
                'name': c.name,
                'description': c.description,
                'avatar': c.avatar,
                'cover_image': c.coverImage,
                'members_count': c.membersCount,
                'posts_count': c.postsCount,
                'is_joined': c.isJoined,
                'tags': c.tags,
              })
          .toList();
      await prefs.setString('communities', jsonEncode(encoded));
    } catch (e) {
      AppLogger.warning('Ошибка сохранения сообществ локально', tag: _logTag, error: e);
    }
  }

  Future<void> _loadCommunitiesFromCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final data = prefs.getString('communities');
      if (data == null || data.isEmpty) {
        return;
      }

      final decoded = jsonDecode(data) as List<dynamic>;
      _communities = decoded.map((item) {
        final map = item as Map<String, dynamic>;
        return Community(
          id: map['id'] as String? ?? '',
          name: map['name'] as String? ?? '',
          description: map['description'] as String? ?? '',
          avatar: map['avatar'] as String? ?? '',
          coverImage: map['cover_image'] as String? ?? '',
          membersCount: map['members_count'] as int? ?? 0,
          postsCount: map['posts_count'] as int? ?? 0,
          isJoined: map['is_joined'] as bool? ?? false,
          tags: (map['tags'] as List<dynamic>? ?? []).map((t) => t.toString()).toList(),
        );
      }).toList();
    } catch (e) {
      AppLogger.warning('Ошибка загрузки сообществ из кеша', tag: _logTag, error: e);
    }
  }

  Future<void> _saveJoinedCommunities() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('joined_communities', _joinedCommunities.toList());
    } catch (e) {
      AppLogger.warning('Ошибка сохранения списка вступленных сообществ', tag: _logTag, error: e);
    }
  }

  Future<void> _loadJoinedCommunities() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final joined = prefs.getStringList('joined_communities') ?? [];
      if (_joinedCommunities.isEmpty) {
        _joinedCommunities = joined.toSet();
      } else {
        _joinedCommunities.addAll(joined);
      }
    } catch (e) {
      AppLogger.warning('Ошибка загрузки вступленных сообществ', tag: _logTag, error: e);
    }
  }

  // ============================================
  // РЕГИСТРАЦИЯ И ПРОВЕРКА УНИКАЛЬНОСТИ
  // ============================================

  // Нормализация
  String _normalizeEmail(String email) => email.trim().toLowerCase();
  String _normalizeUsername(String username) => username.trim().toLowerCase();
  String _normalizePhone(String phone) {
    final digits = phone.replaceAll(RegExp(r'\D'), '');
    if (digits.isEmpty) return '';
    // Приводим к формату 7XXXXXXXXXX (11 цифр)
    if (digits.length == 11 && digits.startsWith('8')) {
      return '7${digits.substring(1)}';
    }
    if (digits.length == 10) {
      return '7$digits';
    }
    return digits;
  }

  Future<void> _saveRegistrationIndex() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('reg_emails', _registeredEmails.toList());
    await prefs.setStringList('reg_phones', _registeredPhones.toList());
    await prefs.setStringList('reg_usernames', _registeredUsernames.toList());
  }

  // Сохранение подписок
  Future<void> _saveFollowedUsers() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('followed_users', _followedUsers.toList());
  }
  
  // Загрузка подписок
  Future<void> _loadFollowedUsers() async {
    final prefs = await SharedPreferences.getInstance();
    final followed = prefs.getStringList('followed_users') ?? [];
    _followedUsers = followed.toSet();
  }
  
  // Сохранение настроек
  Future<void> _saveSettings() async {
    if (Features.useSupabaseUsers && _currentUser != null) {
      try {
        final userId = _currentUser!.id;

        // Сохраняем настройки приватности в Supabase
        await _supabaseSettingsService.updatePrivacySettings(
          userId: userId,
          isPrivateAccount: _privateAccount,
          showOnlineStatus: _showOnlineStatus,
          showStories: _showStories,
          allowMessages: _allowMessages,
          showFollowers: _showFollowers,
          showFollowing: _showFollowing,
          whoCanSeePosts: _mapVisibilityToDb(_whoCanSeeMyPosts),
          whoCanMessage: _mapVisibilityToDb(_whoCanMessageMe),
        );

        // Сохраняем настройки уведомлений в Supabase
        await _supabaseSettingsService.updateNotificationSettings(
          userId: userId,
          pushNotifications: _pushNotifications,
          emailNotifications: _emailNotifications,
          likesNotifications: _likesNotifications,
          commentsNotifications: _commentsNotifications,
          followsNotifications: _followsNotifications,
          messagesNotifications: _messagesNotifications,
        );
        
        AppLogger.success('Настройки сохранены в Supabase', tag: _logTag);
      } catch (e) {
        AppLogger.warning('Ошибка сохранения настроек в Supabase', tag: _logTag, error: e);
      }
    }

    await _saveSettingsToPrefs();
  }

  // Загрузка настроек
  Future<void> _loadSettings({bool forceSupabase = false}) async {
    bool loadedFromSupabase = false;

    if (Features.useSupabaseUsers && (_currentUser != null || forceSupabase)) {
      final userId = _currentUser?.id;
      if (userId != null && userId.isNotEmpty) {
        try {
          // Загружаем настройки из Supabase
          final settings = await _supabaseSettingsService.getSettings(userId);
          if (settings != null) {
            _privateAccount = settings['is_private_account'] as bool? ?? false;
            _showOnlineStatus = settings['show_online_status'] as bool? ?? true;
            _showStories = settings['show_stories'] as bool? ?? true;
            _allowMessages = settings['allow_messages'] as bool? ?? true;
            _showFollowers = settings['show_followers'] as bool? ?? true;
            _showFollowing = settings['show_following'] as bool? ?? true;
            _pushNotifications = settings['push_notifications'] as bool? ?? true;
            _emailNotifications = settings['email_notifications'] as bool? ?? false;
            _likesNotifications = settings['likes_notifications'] as bool? ?? true;
            _commentsNotifications = settings['comments_notifications'] as bool? ?? true;
            _followsNotifications = settings['follows_notifications'] as bool? ?? true;
            _messagesNotifications = settings['messages_notifications'] as bool? ?? true;
            _whoCanSeeMyPosts = _mapVisibilityFromDb(settings['who_can_see_posts'] as String?);
            _whoCanMessageMe = _mapVisibilityFromDb(settings['who_can_message'] as String?);
            loadedFromSupabase = true;
            // Сохраняем в локальный кэш
            await _saveSettingsToPrefs();
            AppLogger.success('Настройки загружены из Supabase', tag: _logTag);
          }
        } catch (e) {
          AppLogger.warning('Ошибка загрузки настроек из Supabase', tag: _logTag, error: e);
        }
      }
    }

    if (!loadedFromSupabase) {
      await _loadSettingsFromPrefs();
    } else {
      await _loadSettingsFromPrefs(localeOnly: true);
    }

    notifyListeners();
  }

  Future<void> _saveSettingsToPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('private_account', _privateAccount);
      await prefs.setBool('show_online_status', _showOnlineStatus);
      await prefs.setBool('show_stories', _showStories);
      await prefs.setBool('allow_messages', _allowMessages);
      await prefs.setBool('show_followers', _showFollowers);
      await prefs.setBool('show_following', _showFollowing);
      await prefs.setBool('push_notifications', _pushNotifications);
      await prefs.setBool('email_notifications', _emailNotifications);
      await prefs.setBool('likes_notifications', _likesNotifications);
      await prefs.setBool('comments_notifications', _commentsNotifications);
      await prefs.setBool('follows_notifications', _followsNotifications);
      await prefs.setBool('messages_notifications', _messagesNotifications);
      await prefs.setString('who_can_see_posts', _whoCanSeeMyPosts);
      await prefs.setString('who_can_message', _whoCanMessageMe);
      await prefs.setString('locale', _currentLocale.languageCode);
    } catch (e) {
      AppLogger.warning('Ошибка сохранения настроек локально', tag: _logTag, error: e);
    }
  }

  Future<void> _loadSettingsFromPrefs({bool localeOnly = false}) async {
    try {
      final prefs = await SharedPreferences.getInstance();

      if (!localeOnly) {
        _privateAccount = prefs.getBool('private_account') ?? _privateAccount;
        _showOnlineStatus = prefs.getBool('show_online_status') ?? _showOnlineStatus;
        _showStories = prefs.getBool('show_stories') ?? _showStories;
        _allowMessages = prefs.getBool('allow_messages') ?? _allowMessages;
        _showFollowers = prefs.getBool('show_followers') ?? _showFollowers;
        _showFollowing = prefs.getBool('show_following') ?? _showFollowing;
        _pushNotifications = prefs.getBool('push_notifications') ?? _pushNotifications;
        _emailNotifications = prefs.getBool('email_notifications') ?? _emailNotifications;
        _likesNotifications = prefs.getBool('likes_notifications') ?? _likesNotifications;
        _commentsNotifications = prefs.getBool('comments_notifications') ?? _commentsNotifications;
        _followsNotifications = prefs.getBool('follows_notifications') ?? _followsNotifications;
        _messagesNotifications = prefs.getBool('messages_notifications') ?? _messagesNotifications;
        _whoCanSeeMyPosts = prefs.getString('who_can_see_posts') ?? _whoCanSeeMyPosts;
        _whoCanMessageMe = prefs.getString('who_can_message') ?? _whoCanMessageMe;
      }

      final localeCode = prefs.getString('locale');
      if (localeCode != null) {
        _currentLocale = Locale(
          localeCode,
          localeCode == 'ru'
              ? 'RU'
              : localeCode == 'kk'
                  ? 'KZ'
                  : 'US',
        );
      }
    } catch (e) {
      AppLogger.warning('Ошибка загрузки настроек локально', tag: _logTag, error: e);
    }
  }

  // BUG-030: храним как код (everyone/followers/nobody)
  String _mapVisibilityFromDb(String? value) {
    switch (value) {
      case 'followers':
        return 'followers';
      case 'none':
      case 'nobody':
        return 'nobody';
      // Легаси: локализованные строки — мигрируем
      case 'Подписчики':
        return 'followers';
      case 'Никто':
        return 'nobody';
      default:
        return 'everyone';
    }
  }

  String _mapVisibilityToDb(String value) {
    switch (value) {
      case 'followers':
        return 'followers';
      case 'nobody':
      case 'none':
        return 'none';
      default:
        return 'all';
    }
  }

  Future<void> _syncFcmToken() async {
    if (!Features.useSupabaseUsers || _currentUser == null) {
      return;
    }

    try {
      // FCM токен синхронизируется через FirebaseNotificationService
      // который вызывает _supabaseSettingsService.updateFcmToken напрямую
    } catch (e) {
      AppLogger.warning('Ошибка синхронизации FCM токена', tag: _logTag, error: e);
    }
  }
  
  // Сохранение лайкнутых постов
  Future<void> _saveLikedPosts() async {
    final prefs = await SharedPreferences.getInstance();
    final likedIds = _stories.where((s) => s.isLiked).map((s) => s.id).toList();
    final userId = Supabase.instance.client.auth.currentUser?.id ?? _currentUser?.id;
    if (userId == null || userId.isEmpty) {
      await prefs.setStringList('liked_posts', likedIds);
      return;
    }
    await prefs.setStringList('liked_posts_$userId', likedIds);
  }
  
  // Загрузка лайкнутых постов
  Future<void> _loadLikedPosts() async {
    final prefs = await SharedPreferences.getInstance();
    final userId = Supabase.instance.client.auth.currentUser?.id ?? _currentUser?.id;
    final likedIds = (userId == null || userId.isEmpty)
        ? (prefs.getStringList('liked_posts') ?? [])
        : (prefs.getStringList('liked_posts_$userId') ?? []);

    // Поддерживаем согласованность с toggleLike(): источник истины для wasLiked
    // при !_hasLoadedLikes.
    _likedPostIds = likedIds.toSet();
    for (final id in likedIds) {
      final index = _stories.indexWhere((s) => s.id == id);
      if (index != -1 && !_stories[index].isLiked) {
        _stories[index] = _stories[index].copyWith(isLiked: true);
      }
    }
  }

  // =============================
  // Загрузка/скелетоны списков
  // =============================

  Future<void> loadChats({bool force = false}) async {
    if (_isChatsLoading) return;

    await _loadChatsFromCache(force: force);

    if (!Features.useSupabaseChats) {
      if (!_hasLoadedChats || force) {
        _hasLoadedChats = true;
        notifyListeners();
      }
      return;
    }
    
    // Если пользователь ещё не загружен - ждём или выходим
    if (_currentUser == null) {
      // Пробуем получить userId из Supabase Auth напрямую
      final authUserId = Supabase.instance.client.auth.currentUser?.id;
      if (authUserId == null) {
        _hasLoadedChats = true;
        _isChatsLoading = false;
        notifyListeners();
        return;
      }
    }

    _isChatsLoading = true;
    notifyListeners();

    try {
      await _loadSupabaseChats();
      _markAllChatsAsDelivered(); // Помечаем все сообщения как доставленные
      _subscribeToOutgoingMessagesRealtime(); // Подписка на статусы исходящих сообщений
      await _refreshUnreadMessagesCount();
      _hasLoadedChats = true;
      _isOffline = false;
    } catch (e) {
      AppLogger.error('Ошибка загрузки чатов', tag: _logTag, error: e);
      _isOffline = true;
      // Важно: не очищаем локальные кеши при оффлайне.
      // Если чаты уже есть из кеша — UI должен продолжать их показывать.
      _hasLoadedChats = true;
    } finally {
      _isChatsLoading = false;
      notifyListeners();
    }
  }

  /// Помечает все входящие сообщения во всех чатах как доставленные
  Future<void> _markAllChatsAsDelivered() async {
    if (_currentUser == null) return;

    for (final chatId in _chatPreviewCache.keys) {
      unawaited(_markChatAsDelivered(chatId));
    }
  }

  // Флаг для предотвращения повторных вызовов markAsDelivered
  final Set<String> _deliveryInProgress = {};

  Future<void> _markChatAsDelivered(String chatId) async {
    if (_currentUser == null) return;
    
    // Предотвращаем повторные вызовы
    if (_deliveryInProgress.contains(chatId)) return;
    _deliveryInProgress.add(chatId);

    try {
      await _supabaseChatService.markAsDelivered(chatId, _currentUser!.id);
    } catch (e) {
      AppLogger.warning('Не удалось отметить доставку чата $chatId: $e', tag: _logTag);
    } finally {
      _deliveryInProgress.remove(chatId);
    }

    bool changed = false;

    void markList(List<ChatMessage>? list) {
      if (list == null) return;
      for (int i = 0; i < list.length; i++) {
        final msg = list[i];
        if (msg.chatId == chatId &&
            _currentUser != null &&
            msg.sender.id != _currentUser!.id &&
            !msg.isDelivered) {
          list[i] = msg.copyWith(isDelivered: true);
          changed = true;
        }
      }
    }

    markList(_chatMessages);
    markList(_chatMessagesCache[chatId]);

    if (changed) {
      unawaited(_saveChatsToCache());
      notifyListeners();
    }
  }

  // =============================
  // Индикатор "печатает..."
  // =============================
  void setChatTyping(String chatId, bool typing) {
    if (typing) {
      if (_typingChats.add(chatId)) notifyListeners();
    } else {
      if (_typingChats.remove(chatId)) notifyListeners();
    }
  }

  // =============================
  // Функции для работы с сообщениями
  // =============================
  
  // Ответить на сообщение
  Future<void> replyToMessage(String chatId, ChatMessage replyTo, String text) async {
    if (!Features.useSupabaseChats) {
      AppLogger.warning('Ответы на сообщения доступны только в Supabase режиме', tag: _logTag);
      return;
    }

    try {
      await _supabaseChatService.sendMessage(
        chatId: chatId,
        senderId: _currentUser!.id,
        text: text,
        replyToId: replyTo.id,
      );
      AppLogger.success('Ответ на сообщение отправлен', tag: _logTag);
    } catch (e) {
      AppLogger.error('Ошибка при ответе на сообщение', tag: _logTag, error: e);
    }
  }

  // Переслать сообщение
  Future<bool> forwardMessage(ChatMessage message, String targetChatId) async {
    if (!Features.useSupabaseChats) {
      AppLogger.warning('Пересылка сообщений доступна только в Supabase режиме', tag: _logTag);
      return false;
    }

    try {
      // Для временных сообщений пересылаем без forwardedFromId
      final forwardedFromId = message.id.startsWith('temp_') ? null : message.id;
      
      await _supabaseChatService.sendMessage(
        chatId: targetChatId,
        senderId: _currentUser!.id,
        text: message.text,
        mediaUrl: message.mediaUrl ?? (message.images.isNotEmpty ? message.images.first : null),
        mediaType: message.mediaType ?? (message.images.isNotEmpty ? 'image' : null),
        forwardedFromId: forwardedFromId,
        forwardedFromName: forwardedFromId != null ? message.sender.name : null,
      );
      AppLogger.success('Сообщение переслано в чат: $targetChatId', tag: _logTag);
      return true;
    } catch (e) {
      AppLogger.error('Ошибка при пересылке сообщения', tag: _logTag, error: e);
      return false;
    }
  }

  // Закрепить сообщение
  Future<void> pinMessage(String messageId, bool pin) async {
    if (!Features.useSupabaseChats) {
      return;
    }
    
    // Для временных сообщений обновляем только локально
    if (messageId.startsWith('temp_')) {
      final idx = _chatMessages.indexWhere((m) => m.id == messageId);
      if (idx != -1) {
        _chatMessages[idx] = _chatMessages[idx].copyWith(isPinned: pin);
        notifyListeners();
      }
      return;
    }

    try {
      // Находим chatId по messageId
      String? chatId;
      final idx = _chatMessages.indexWhere((m) => m.id == messageId);
      if (idx != -1) chatId = _chatMessages[idx].chatId;
      
      if (chatId == null) {
        for (final entry in _chatMessagesCache.entries) {
          if (entry.value.any((m) => m.id == messageId)) {
            chatId = entry.key;
            break;
          }
        }
      }

      if (_currentUser == null) return;
      
      // Сначала обновляем в базе данных
      await _supabaseChatService.togglePinMessage(messageId, pin, _currentUser!.id);

      // Обновляем локальный кеш только после успешного обновления в БД
      if (chatId != null) {
        // Если закрепляем - снимаем флаг со всех других сообщений чата
        if (pin) {
          for (int i = 0; i < _chatMessages.length; i++) {
            if (_chatMessages[i].chatId == chatId && _chatMessages[i].isPinned && _chatMessages[i].id != messageId) {
              _chatMessages[i] = _chatMessages[i].copyWith(isPinned: false);
            }
          }
          if (_chatMessagesCache.containsKey(chatId)) {
            for (int i = 0; i < _chatMessagesCache[chatId]!.length; i++) {
              if (_chatMessagesCache[chatId]![i].isPinned && _chatMessagesCache[chatId]![i].id != messageId) {
                _chatMessagesCache[chatId]![i] = _chatMessagesCache[chatId]![i].copyWith(isPinned: false);
              }
            }
          }
        }
      }

      // Устанавливаем/снимаем флаг выбранному сообщению
      final messageIndex = _chatMessages.indexWhere((msg) => msg.id == messageId);
      if (messageIndex != -1) {
        _chatMessages[messageIndex] = _chatMessages[messageIndex].copyWith(isPinned: pin);
        final cid = _chatMessages[messageIndex].chatId;
        if (_chatMessagesCache.containsKey(cid)) {
          final cacheIndex = _chatMessagesCache[cid]!.indexWhere((msg) => msg.id == messageId);
          if (cacheIndex != -1) {
            _chatMessagesCache[cid]![cacheIndex] = _chatMessagesCache[cid]![cacheIndex].copyWith(isPinned: pin);
          }
        }
      }
      
      // Сохраняем в локальный кеш
      await _saveChatsToCache();
      notifyListeners();
    } catch (e) {
      AppLogger.error('Ошибка при закреплении сообщения', tag: _logTag, error: e);
      rethrow;
    }
  }

  // Добавить в избранное
  Future<bool> bookmarkMessage(String messageId, bool bookmark) async {
    if (!Features.useSupabaseChats) {
      AppLogger.warning('Избранное доступно только в Supabase режиме', tag: _logTag);
      return false;
    }
    
    // Для временных сообщений обновляем только локально
    if (messageId.startsWith('temp_')) {
      AppLogger.warning('Избранное временного сообщения (только локально)', tag: _logTag);
      final idx = _chatMessages.indexWhere((m) => m.id == messageId);
      if (idx != -1) {
        _chatMessages[idx] = _chatMessages[idx].copyWith(isBookmarked: bookmark);
        notifyListeners();
      }
      return true;
    }

    try {
      if (_currentUser == null) return false;
      
      // Сначала обновляем в базе данных
      await _supabaseChatService.toggleBookmarkMessage(messageId, bookmark, _currentUser!.id);

      // Обновляем локальный кеш только после успешного обновления в БД
      final messageIndex = _chatMessages.indexWhere((msg) => msg.id == messageId);
      if (messageIndex != -1) {
        _chatMessages[messageIndex] = _chatMessages[messageIndex].copyWith(isBookmarked: bookmark);
        
        // Обновляем кеш чата
        final chatId = _chatMessages[messageIndex].chatId;
        if (_chatMessagesCache.containsKey(chatId)) {
          final cacheIndex = _chatMessagesCache[chatId]!.indexWhere((msg) => msg.id == messageId);
          if (cacheIndex != -1) {
            _chatMessagesCache[chatId]![cacheIndex] = _chatMessagesCache[chatId]![cacheIndex].copyWith(isBookmarked: bookmark);
          }
        }
        await _saveChatsToCache();
        notifyListeners();
      }
      
      AppLogger.success('Сообщение ${bookmark ? 'добавлено в' : 'удалено из'} избранное', tag: _logTag);
      return true;
    } catch (e) {
      AppLogger.error('Ошибка при добавлении в избранное', tag: _logTag, error: e);
      return false;
    }
  }

  // Редактировать сообщение
  Future<void> editMessage(String messageId, String newText) async {
    if (!Features.useSupabaseChats) {
      AppLogger.warning('Редактирование сообщений доступно только в Supabase режиме', tag: _logTag);
      return;
    }
    
    // Нельзя редактировать временные сообщения
    if (messageId.startsWith('temp_')) {
      AppLogger.warning('Нельзя редактировать временное сообщение', tag: _logTag);
      return;
    }

    try {
      await _supabaseChatService.editMessage(messageId, newText);
      
      // Обновляем локальный кеш
      final index = _chatMessages.indexWhere((msg) => msg.id == messageId);
      if (index != -1) {
        _chatMessages[index] = _chatMessages[index].copyWith(
          text: newText,
          isEdited: true,
        );
        
        // Обновляем в кеше чата
        if (_chatMessagesCache.containsKey(_chatMessages[index].chatId)) {
          final cacheIndex = _chatMessagesCache[_chatMessages[index].chatId]!.indexWhere((msg) => msg.id == messageId);
          if (cacheIndex != -1) {
            _chatMessagesCache[_chatMessages[index].chatId]![cacheIndex] = _chatMessages[index];
          }
        }
        notifyListeners();
      }
      
      AppLogger.success('Сообщение отредактировано', tag: _logTag);
    } catch (e) {
      AppLogger.error('Ошибка при редактировании сообщения', tag: _logTag, error: e);
      rethrow;
    }
  }

  Map<String, dynamic> _userToCacheMap(User user) {
    return {
      'id': user.id,
      'name': user.name,
      'username': user.username,
      'avatar': user.avatar,
      'isPremium': user.isPremium,
      'karma': user.karma,
    };
  }

  User _userFromCacheMap(Map<String, dynamic> data) {
    return User(
      id: data['id'] as String,
      name: data['name'] as String? ?? 'Пользователь',
      username: data['username'] as String? ?? 'user',
      avatar: data['avatar'] as String? ?? '',
      isPremium: data['isPremium'] as bool? ?? false,
      karma: data['karma'] as int? ?? 0,
    );
  }

  Map<String, dynamic> _chatMessageToCacheMap(ChatMessage message) {
    return {
      'id': message.id,
      'chat_id': message.chatId,
      'text': message.text,
      'created_at': message.createdAt.toIso8601String(),
      'is_read': message.isRead,
      'is_delivered': message.isDelivered,
      'is_edited': message.isEdited,
      'edited_at': message.editedAt?.toIso8601String(),
      'reply_to_id': message.replyToId,
      'images': message.images,
      'video_thumbnail': message.videoThumbnail,
      'is_pinned': message.isPinned,
      'is_bookmarked': message.isBookmarked,
      'is_deleted_for_me': message.isDeletedForMe,
      'is_deleted_for_everyone': message.isDeletedForEveryone,
      'sender': _userToCacheMap(message.sender),
      'reactions': message.reactions.map((key, value) => MapEntry(key, value.name)),
    };
  }

  ChatMessage _chatMessageFromCacheMap(Map<String, dynamic> map) {
    final sender = _userFromCacheMap(Map<String, dynamic>.from(map['sender'] as Map));
    final reactionsRaw = Map<String, dynamic>.from(map['reactions'] as Map? ?? {});
    final reactions = reactionsRaw.map((key, value) {
      try {
        final type = ReactionType.values.firstWhere((t) => t.name == value);
        return MapEntry(key, type);
      } catch (_) {
        return MapEntry(key, ReactionType.like);
      }
    });

    return ChatMessage(
      id: map['id'] as String,
      chatId: map['chat_id'] as String,
      sender: sender,
      text: map['text'] as String? ?? '',
      createdAt: DateTime.parse(map['created_at'] as String).toLocal(),
      isRead: map['is_read'] as bool? ?? false,
      isDelivered: map['is_delivered'] as bool? ?? true,
      isEdited: map['is_edited'] as bool? ?? false,
      editedAt: map['edited_at'] != null ? DateTime.parse(map['edited_at'] as String).toLocal() : null,
      replyToId: map['reply_to_id'] as String?,
      replyToMessage: null,
      reactions: reactions,
      images: (map['images'] as List?)?.map((e) => e.toString()).toList() ?? const [],
      videoThumbnail: map['video_thumbnail'] as String?,
      isPinned: map['is_pinned'] as bool? ?? false,
      isBookmarked: map['is_bookmarked'] as bool? ?? false,
      isDeletedForMe: map['is_deleted_for_me'] as bool? ?? false,
      isDeletedForEveryone: map['is_deleted_for_everyone'] as bool? ?? false,
    );
  }

  Future<void> _saveChatsToCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      await prefs.setString('chat_previews', jsonEncode(_chatPreviewCache));

      final usersMap = _chatUsersCache.map((chatId, user) => MapEntry(chatId, _userToCacheMap(user)));
      await prefs.setString('chat_users', jsonEncode(usersMap));

      final messagesMap = <String, dynamic>{};
      _chatMessagesCache.forEach((chatId, messages) {
        // Сортируем от новых к старым и берем первые 50 (самые новые)
        final sorted = List<ChatMessage>.from(messages)..sort((a, b) => b.createdAt.compareTo(a.createdAt));
        final limited = sorted.length > 50 ? sorted.sublist(0, 50) : sorted;
        messagesMap[chatId] = limited.map(_chatMessageToCacheMap).toList();
      });
      await prefs.setString('chat_messages', jsonEncode(messagesMap));

      await prefs.setString('chat_user_map', jsonEncode(_userIdToChatId));
    } catch (e) {
      AppLogger.warning('Ошибка сохранения чатов', tag: _logTag, error: e);
    }
  }

  Future<void> _loadChatsFromCache({bool force = false}) async {
    if (_hasLoadedChatCache && !force) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      final previewsRaw = prefs.getString('chat_previews');
      final usersRaw = prefs.getString('chat_users');
      final messagesRaw = prefs.getString('chat_messages');
      final userMapRaw = prefs.getString('chat_user_map');

      if (previewsRaw != null) {
        final decoded = Map<String, dynamic>.from(jsonDecode(previewsRaw) as Map);
        _chatPreviewCache
          ..clear()
          ..addAll(decoded.map((key, value) => MapEntry(key, Map<String, dynamic>.from(value as Map))));
      }

      if (usersRaw != null) {
        final decodedUsers = Map<String, dynamic>.from(jsonDecode(usersRaw) as Map);
        _chatUsersCache
          ..clear()
          ..addAll(decodedUsers.map((key, value) => MapEntry(key, _userFromCacheMap(Map<String, dynamic>.from(value as Map)))));
      }

      if (userMapRaw != null) {
        final decodedMap = Map<String, dynamic>.from(jsonDecode(userMapRaw) as Map);
        _userIdToChatId
          ..clear()
          ..addAll(decodedMap.map((key, value) => MapEntry(key, value as String)));
      } else {
        _userIdToChatId
          ..clear()
          ..addAll(_chatUsersCache.map((chatId, user) => MapEntry(user.id, chatId)));
      }

      if (messagesRaw != null) {
        final decodedMessages = Map<String, dynamic>.from(jsonDecode(messagesRaw) as Map);
        _chatMessagesCache.clear();
        for (final entry in decodedMessages.entries) {
          final chatId = entry.key;
          final list = (entry.value as List)
              .map((item) => _chatMessageFromCacheMap(Map<String, dynamic>.from(item as Map)))
              .toList();
          // Сортируем от новых к старым для reverse ListView
          list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
          _chatMessagesCache[chatId] = list;
        }
        _chatMessages = _chatMessagesCache.values.expand((list) => list).toList();
      }

      if (_chatPreviewCache.isNotEmpty || _chatMessages.isNotEmpty) {
        _hasLoadedChats = true;
        // Восстанавливаем счётчик непрочитанных из кэша чтобы badge показывался сразу
        final userId = _currentUser?.id ?? Supabase.instance.client.auth.currentUser?.id;
        if (userId != null) {
          int unread = 0;
          for (final chat in _chatPreviewCache.values) {
            final u1 = chat['user1_id'] as String?;
            if (u1 == userId) {
              unread += (chat['unread_count_user1'] as int?) ?? 0;
            } else {
              unread += (chat['unread_count_user2'] as int?) ?? 0;
            }
          }
          if (unread != _cachedUnreadMessagesCount) {
            _cachedUnreadMessagesCount = unread;
          }
        }
        notifyListeners();
      }

      _hasLoadedChatCache = true;
    } catch (e) {
      AppLogger.warning('Ошибка загрузки чатов из кеша', tag: _logTag, error: e);
    }
  }

  /// Удалить чат для пользователя
  Future<void> deleteChat(String chatId) async {
    try {
      final userId = _currentUser?.id;
      if (userId == null) return;
      
      await _supabaseChatService.deleteChat(chatId, userId);
      
      // Удаляем из кеша
      _chatPreviewCache.remove(chatId);
      _chatUsersCache.remove(chatId);
      _chatMessagesCache.remove(chatId);
      _userIdToChatId.removeWhere((key, value) => value == chatId);
      
      // Обновляем списки
      _chatMessages = _chatMessagesCache.values.expand((list) => list).toList();
      
      notifyListeners();
    } catch (e) {
      AppLogger.error('Ошибка удаления чата', tag: _logTag, error: e);
      rethrow;
    }
  }

  /// Переключить статус mute для чата
  Future<bool> toggleChatMute(String chatId) async {
    try {
      final userId = _currentUser?.id;
      if (userId == null) return false;
      
      final newMuteStatus = await _supabaseChatService.toggleChatMute(chatId, userId);
      
      // Обновляем в кеше
      final preview = _chatPreviewCache[chatId];
      if (preview != null) {
        final updatedPreview = Map<String, dynamic>.from(preview);
        updatedPreview['is_muted'] = newMuteStatus;
        _chatPreviewCache[chatId] = updatedPreview;
      }
      
      notifyListeners();
      return newMuteStatus;
    } catch (e) {
      AppLogger.error('Ошибка переключения mute статуса', tag: _logTag, error: e);
      rethrow;
    }
  }

  Future<void> _clearChatCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('chat_previews');
      await prefs.remove('chat_users');
      await prefs.remove('chat_messages');
      await prefs.remove('chat_user_map');
    } catch (e) {
      AppLogger.warning('Ошибка очистки кеша чатов', tag: _logTag, error: e);
    }
  }

  // Удалить сообщение у себя
  Future<void> deleteMessageForMe(String messageId, String chatId) async {
    if (!Features.useSupabaseChats) {
      AppLogger.warning('Удаление сообщений доступно только в Supabase режиме', tag: _logTag);
      return;
    }
    
    // Нельзя удалять временные сообщения через БД
    if (messageId.startsWith('temp_')) {
      // Просто удаляем из локального кеша
      _chatMessages.removeWhere((msg) => msg.id == messageId);
      if (_chatMessagesCache.containsKey(chatId)) {
        _chatMessagesCache[chatId]!.removeWhere((msg) => msg.id == messageId);
      }
      notifyListeners();
      return;
    }

    try {
      final currentUserId = _currentUser?.id;
      if (currentUserId == null) return;
      
      await _supabaseChatService.deleteMessageForMe(messageId, chatId, currentUserId);
      
      // Помечаем как удаленное в локальном кеше
      final index = _chatMessages.indexWhere((msg) => msg.id == messageId);
      if (index != -1) {
        _chatMessages[index] = _chatMessages[index].copyWith(isDeletedForMe: true);
      }
      if (_chatMessagesCache.containsKey(chatId)) {
        final cacheIndex = _chatMessagesCache[chatId]!.indexWhere((msg) => msg.id == messageId);
        if (cacheIndex != -1) {
          _chatMessagesCache[chatId]![cacheIndex] = _chatMessagesCache[chatId]![cacheIndex].copyWith(isDeletedForMe: true);
        }
      }
      notifyListeners();
      
      AppLogger.success('Сообщение удалено у вас', tag: _logTag);
    } catch (e) {
      AppLogger.error('Ошибка при удалении сообщения', tag: _logTag, error: e);
      rethrow;
    }
  }

  // Удалить сообщение у всех
  Future<void> deleteMessageForEveryone(String messageId) async {
    if (!Features.useSupabaseChats) {
      AppLogger.warning('Удаление сообщений доступно только в Supabase режиме', tag: _logTag);
      return;
    }
    
    // Нельзя удалять временные сообщения у всех
    if (messageId.startsWith('temp_')) {
      AppLogger.warning('Нельзя удалить временное сообщение у всех', tag: _logTag);
      return;
    }

    try {
      await _supabaseChatService.deleteMessageForEveryone(messageId);

      // Помечаем как удаленное в локальном кеше
      final index = _chatMessages.indexWhere((msg) => msg.id == messageId);
      if (index != -1) {
        _chatMessages[index] = _chatMessages[index].copyWith(
          isDeletedForEveryone: true,
          text: 'Сообщение удалено',
        );
      }
      for (var chatId in _chatMessagesCache.keys) {
        final cacheIndex = _chatMessagesCache[chatId]!.indexWhere((msg) => msg.id == messageId);
        if (cacheIndex != -1) {
          _chatMessagesCache[chatId]![cacheIndex] = _chatMessagesCache[chatId]![cacheIndex].copyWith(
            isDeletedForEveryone: true,
            text: 'Сообщение удалено',
          );
        }
      }
      notifyListeners();

      AppLogger.success('Сообщение удалено у всех', tag: _logTag);
    } catch (e) {
      AppLogger.error('Ошибка при удалении сообщения у всех', tag: _logTag, error: e);
      rethrow;
    }
  }

  // Получить закреплённые сообщения
  Future<List<ChatMessage>> getPinnedMessagesNew(String chatId) async {
    if (!Features.useSupabaseChats) {
      return [];
    }

    try {
      final response = await Supabase.instance.client
          .from('messages')
          .select('*, sender:users!messages_sender_id_fkey(id, username, full_name, avatar_url)')
          .eq('chat_id', chatId)
          .eq('is_pinned', true)
          .eq('is_deleted', false)
          .order('created_at', ascending: false);

      final messages = <ChatMessage>[];
      for (final data in response) {
        final message = _mapSupabaseMessageToChatMessage(data);
        messages.add(message);
      }
      return messages;
    } catch (e) {
      AppLogger.error('Ошибка при загрузке закреплённых сообщений', tag: _logTag, error: e);
      return [];
    }
  }

  // Получить избранные сообщения
  Future<List<ChatMessage>> getBookmarkedMessagesNew(String chatId) async {
    if (!Features.useSupabaseChats) {
      return [];
    }

    try {
      final response = await Supabase.instance.client
          .from('messages')
          .select('*, sender:users!messages_sender_id_fkey(id, username, full_name, avatar_url)')
          .eq('chat_id', chatId)
          .eq('is_bookmarked', true)
          .eq('is_deleted', false)
          .order('created_at', ascending: false);

      final messages = <ChatMessage>[];
      for (final data in response) {
        final message = _mapSupabaseMessageToChatMessage(data);
        messages.add(message);
      }
      return messages;
    } catch (e) {
      AppLogger.error('Ошибка при загрузке избранных сообщений', tag: _logTag, error: e);
      return [];
    }
  }

  // Очистить историю чата
  Future<void> clearChatHistoryNew(String chatId) async {
    if (!Features.useSupabaseChats) {
      return;
    }

    try {
      final currentUserId = _currentUser?.id;
      if (currentUserId == null) return;

      await _supabaseChatService.clearChatHistory(chatId, currentUserId);

      // Удаляем все сообщения из локального кеша (не помечаем, а удаляем)
      _chatMessages.removeWhere((m) => m.chatId == chatId);
      _chatMessagesCache.remove(chatId);
      
      // Удаляем превью чата чтобы убрать "вчера" и "сегодня"
      _chatPreviewCache.remove(chatId);
      
      await _saveChatsToCache();
      notifyListeners();

      AppLogger.success('История чата очищена', tag: _logTag);
    } catch (e) {
      AppLogger.error('Ошибка при очистке истории', tag: _logTag, error: e);
      rethrow;
    }
  }

  // =============================
  // История поиска (persist)
  // =============================
  Future<void> _loadSearchHistory() async {
    final prefs = await SharedPreferences.getInstance();
    _searchHistory = prefs.getStringList('search_history') ?? [];
  }

  Future<void> addSearchQuery(String query) async {
    final q = query.trim();
    if (q.isEmpty) return;
    _searchHistory.removeWhere((e) => e.toLowerCase() == q.toLowerCase());
    _searchHistory.insert(0, q);
    if (_searchHistory.length > 10) {
      _searchHistory = _searchHistory.take(10).toList();
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('search_history', _searchHistory);
    notifyListeners();
  }

  Future<void> clearSearchHistory() async {
    _searchHistory.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('search_history', _searchHistory);
    notifyListeners();
  }

  Future<List<User>> searchUsersRemote(String query) async {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return [];

    List<User> localFallback() {
      return _users
          .where((u) => u.name.toLowerCase().contains(q) || u.username.toLowerCase().contains(q))
          .toList();
    }

    try {
      final service = SupabaseUserService();
      final data = await service.searchUsers(query);
      final mapped = data.map((row) {
        final m = Map<String, dynamic>.from(row);
        return User(
          id: m['id']?.toString() ?? '',
          name: (m['full_name'] ?? m['name'] ?? '').toString(),
          username: (m['username'] ?? 'user').toString(),
          avatar: (m['avatar_url'] ?? m['avatar'] ?? '').toString(),
          isPremium: (m['role']?.toString() ?? '') == 'premium',
          isVerified: m['is_verified'] as bool?,
          followersCount: (m['followers_count'] as int?) ?? 0,
          followingCount: (m['following_count'] as int?) ?? 0,
          postsCount: (m['posts_count'] as int?) ?? 0,
        );
      }).toList();

      final local = localFallback();
      final unique = <String, User>{};
      for (final u in mapped) {
        if (u.id.isEmpty) continue;
        unique[u.id] = u;
      }
      for (final u in local) {
        if (u.id.isEmpty) continue;
        unique.putIfAbsent(u.id, () => u);
      }

      _isOffline = false;
      return unique.values.toList();
    } catch (e, st) {
      AppLogger.error('Ошибка searchUsersRemote', tag: 'AppState', error: e, stackTrace: st);
      _isOffline = true;
      return localFallback();
    }
  }

  Future<List<Story>> searchStoriesRemote(String query, {int limit = 20, int offset = 0}) async {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return [];

    List<Story> localFallback() {
      return _stories.where((s) => s.text.toLowerCase().contains(q)).take(limit).toList();
    }

    try {
      await _ensureInteractionSetsLoaded();
      final service = SupabasePostService();
      final data = await service.searchPosts(query: query, limit: limit, offset: offset);
      final mapped = <Story>[];
      for (final post in data) {
        mapped.add(await _mapSupabasePostToStoryWithLikes(post, _likedPostIds, _bookmarkedPostIds));
      }

      final local = localFallback();
      final unique = <String, Story>{};
      for (final s in mapped) {
        unique[s.id] = s;
      }
      for (final s in local) {
        unique.putIfAbsent(s.id, () => s);
      }

      _isOffline = false;
      return unique.values.toList();
    } catch (e, st) {
      AppLogger.error('Ошибка searchStoriesRemote', tag: 'AppState', error: e, stackTrace: st);
      _isOffline = true;
      return localFallback();
    }
  }

  // =============================
  // Закладки (persist)
  // =============================
  Future<void> _loadBookmarks() async {
    final prefs = await SharedPreferences.getInstance();
    final ids = prefs.getStringList('bookmarks') ?? [];
    bool changed = false;
    for (final id in ids) {
      final index = _stories.indexWhere((s) => s.id == id);
      if (index != -1 && !_stories[index].isBookmarked) {
        _stories[index] = _stories[index].copyWith(isBookmarked: true);
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  // Проверка валидности и доступности username
  Future<Map<String, dynamic>> validateUsername(String username) async {
    try {
      if (Features.useSupabaseAuth || Features.useSupabaseUsers) {
        // Используем новую SQL функцию валидации
        final response = await Supabase.instance.client.rpc('validate_username', params: {
          'p_username': username,
          'p_user_id': _currentUser?.id,
        });
        
        if (response is List && response.isNotEmpty) {
          final result = response.first;
          return {
            'isValid': result['is_valid'] ?? false,
            'message': result['error_message'] ?? '',
          };
        }
      } else {
        // Fallback на локальную проверку
        await Future.delayed(const Duration(milliseconds: 300));
        
        // Базовая валидация
        if (username.length < 3) {
          return {'isValid': false, 'message': 'Username должен содержать минимум 3 символа'};
        }
        if (username.length > 30) {
          return {'isValid': false, 'message': 'Username должен содержать максимум 30 символов'};
        }
        if (!RegExp(r'^[a-zA-Z0-9_]+$').hasMatch(username)) {
          return {'isValid': false, 'message': 'Username может содержать только буквы, цифры и подчеркивания'};
        }
        
        final isAvailable = !_registeredUsernames.contains(username.toLowerCase());
        if (!isAvailable) {
          return {'isValid': false, 'message': 'Этот username уже занят'};
        }
      }
      
      return {'isValid': true, 'message': 'Username доступен'};
    } catch (e, st) {
      AppLogger.error('Ошибка валидации username', tag: _logTag, error: e, stackTrace: st);
      return {'isValid': false, 'message': 'Ошибка проверки username'};
    }
  }

  // Проверка уникальности username (deprecated - используйте validateUsername)
  Future<bool> checkUsernameAvailability(String username) async {
    final result = await validateUsername(username);
    return result['isValid'] ?? false;
  }

  // Обновление аватара с обрезкой
  Future<String?> updateAvatarWithCrop(BuildContext context) async {
    if (_currentUser == null) {
      AppLogger.error('Пользователь не авторизован', tag: _logTag);
      return null;
    }

    try {
      final avatarCropService = AvatarCropService();
      final newAvatarUrl = await avatarCropService.updateAvatarWithCleanup(
        context, 
        _currentUser!.avatar
      );

      if (newAvatarUrl != null) {
        // Обновляем локально
        final updatedUser = _currentUser!.copyWith(avatar: newAvatarUrl);
        _currentUser = updatedUser;
        
        // Обновляем в списке пользователей
        final userIndex = _users.indexWhere((u) => u.id == _currentUser!.id);
        if (userIndex != -1) {
          _users[userIndex] = updatedUser;
        }

        // Сохраняем в Supabase
        if (Features.useSupabaseUsers) {
          final userService = SupabaseUserService();
          await userService.updateProfile(
            userId: _currentUser!.id,
            avatarUrl: newAvatarUrl,
          );
        }

        notifyListeners();
        AppLogger.success('Аватар успешно обновлен', tag: _logTag);
      }

      return newAvatarUrl;
    } catch (e, st) {
      AppLogger.error('Ошибка обновления аватара', tag: _logTag, error: e, stackTrace: st);
      return null;
    }
  }

  // Проверка уникальности email
  Future<bool> checkEmailAvailability(String email) async {
    // Проверяем в списке пользователей + индекс
    bool isAvailable;
    if (Features.useSupabaseAuth || Features.useSupabaseUsers) {
      final service = SupabaseUserService();
      isAvailable = await service.isEmailAvailable(email);
    } else {
      isAvailable = !_registeredEmails.contains(email.toLowerCase());
    }
    return isAvailable;
  }

  // Проверка уникальности телефона
  Future<bool> checkPhoneAvailability(String phone) async {
    // Проверяем в списке пользователей + индекс
    bool isAvailable;
    if (Features.useSupabaseAuth || Features.useSupabaseUsers) {
      final service = SupabaseUserService();
      isAvailable = await service.isPhoneAvailable(phone);
    } else {
      isAvailable = !_registeredPhones.contains(phone);
    }
    return isAvailable;
  }

  // Регистрация нового пользователя
  Future<bool> registerUser({
    required String name,
    required String username,
    required String phone,
    required String email,
    required String password,
  }) async {
    // Имитация API запроса
    await Future.delayed(const Duration(seconds: 1));

    // Проверяем уникальность
    final uname = _normalizeUsername(username);
    final em = _normalizeEmail(email);
    final ph = _normalizePhone(phone);
    bool isUsernameAvailable;
    bool isEmailAvailable;
    bool isPhoneAvailable;
    if (Features.useSupabaseAuth || Features.useSupabaseUsers) {
      final service = SupabaseUserService();
      isUsernameAvailable = await service.isUsernameAvailable(username);
      isEmailAvailable = await service.isEmailAvailable(email);
      isPhoneAvailable = await service.isPhoneAvailable(phone);
    } else {
      isUsernameAvailable = !_registeredUsernames.contains(uname);
      isEmailAvailable = !_registeredEmails.contains(em);
      isPhoneAvailable = !_registeredPhones.contains(ph);
    }

    if (!isUsernameAvailable || !isEmailAvailable || !isPhoneAvailable) {
      return false;
    }

    // Создаем нового пользователя
    final now = DateTime.now();
    final newUser = User(
      id: 'user_${now.millisecondsSinceEpoch}',
      name: name,
      username: uname,
      avatar: '', // Пустой аватар
      email: em,
      phone: ph,
      isPremium: false,
      karma: 0,
      badges: [],
      role: UserRole.free,
      followersCount: 0,
      followingCount: 0,
      isFollowed: false,
      isOnline: true,
      isVerified: false,
      nameChangedAt: now, // Устанавливаем дату создания как первое изменение
      usernameChangedAt: now, // Устанавливаем дату создания
      usernameChangeCount: 0, // Первая установка username не считается изменением
    );
    
    // Добавляем в список пользователей
    _users.add(newUser);

    // Обновляем персистентный индекс
    _registeredUsernames.add(uname);
    if (em.isNotEmpty) _registeredEmails.add(em);
    if (ph.isNotEmpty) _registeredPhones.add(ph);
    _saveRegistrationIndex();

    // Устанавливаем как текущего пользователя
    _currentUser = newUser;

    // Обновляем current_user в списке
    final currentUserIndex = _users.indexWhere((u) => u.id == 'current_user');
    if (currentUserIndex != -1) {
      _users[currentUserIndex] = newUser.copyWith(id: 'current_user');
      _currentUser = _users[currentUserIndex];
    }

    return true;
  }

  Future<Map<String, dynamic>> deleteAccount({required String password}) async {
    if (_currentUser == null) {
      return {'success': false, 'error': 'Пользователь не найден'};
    }

    final userId = _currentUser!.id;
    var serverDeletionFailed = false;
    String? serverDeletionError;

    // Проверяем пароль через Supabase Auth (повторный вход)
    if (Features.useSupabaseAuth) {
      try {
        final email = Supabase.instance.client.auth.currentUser?.email;
        if (email == null || email.isEmpty) {
          return {'success': false, 'error': 'Email не найден'};
        }
        await Supabase.instance.client.auth.signInWithPassword(
          email: email,
          password: password,
        );
      } on AuthException catch (e) {
        AppLogger.error('Неверный пароль при удалении аккаунта', tag: _logTag, error: e);
        return {'success': false, 'error': 'Неверный пароль'};
      } catch (e) {
        AppLogger.error('Ошибка проверки пароля', tag: _logTag, error: e);
        return {'success': false, 'error': 'Ошибка проверки пароля'};
      }
    }

    try {
      // Удаляем данные из Supabase
      if (Features.useSupabaseUsers) {
        try {
          final supabase = Supabase.instance.client;
          // BUG-007: Очищаем FCM токен перед удалением — push не должны приходить после удаления
          try {
            await supabase.from('users').update({'fcm_token': null}).eq('id', userId);
          } catch (_) {}
          // Удаляем посты пользователя
          await supabase.from('posts').delete().eq('user_id', userId);
          // Удаляем комментарии
          await supabase.from('comments').delete().eq('user_id', userId);
          // Удаляем профиль
          await supabase.from('users').delete().eq('id', userId);
          AppLogger.info('Данные пользователя удалены из Supabase', tag: _logTag);
        } catch (e) {
          AppLogger.error('Ошибка удаления данных из Supabase', tag: _logTag, error: e);
          serverDeletionFailed = true;
          serverDeletionError = 'Не удалось удалить данные аккаунта на сервере';
        }
        // Удаляем auth запись через Edge Function (требует service_role)
        try {
          await Supabase.instance.client.functions.invoke(
            'admin-delete-user',
            body: {'user_id': userId},
          );
          AppLogger.info('Auth запись пользователя удалена', tag: _logTag);
        } catch (e) {
          // Если Edge Function недоступна — выходим из аккаунта
          AppLogger.warning('Не удалось удалить auth запись, выполняем signOut', tag: _logTag, error: e);
          serverDeletionFailed = true;
          serverDeletionError ??= 'Не удалось полностью удалить аккаунт на сервере';
          try {
            await Supabase.instance.client.auth.signOut();
          } catch (_) {}
        }
      }

      if (serverDeletionFailed) {
        return {'success': false, 'error': serverDeletionError ?? 'Не удалось удалить аккаунт на сервере'};
      }

      // Очищаем локальные данные
      _stories.removeWhere((story) => story.author.id == userId);
      _comments.removeWhere((comment) => comment.author.id == userId);
      _notifications.removeWhere((notif) => notif.fromUser?.id == userId);
      
      if (_currentUser!.username.isNotEmpty) {
        _registeredUsernames.remove(_normalizeUsername(_currentUser!.username));
      }
      if (_currentUser!.email != null && _currentUser!.email!.isNotEmpty) {
        _registeredEmails.remove(_normalizeEmail(_currentUser!.email!));
      }
      if (_currentUser!.phone != null && _currentUser!.phone!.isNotEmpty) {
        _registeredPhones.remove(_normalizePhone(_currentUser!.phone!));
      }
      
      _users.removeWhere((user) => user.id == userId);
      _searchHistory.clear();
      await _saveRegistrationIndex();
      
      // Очищаем ВСЕ SharedPreferences — полная очистка данных аккаунта
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.clear(); // Удаляем все данные, включая токены и офлайн-очередь
      } catch (_) {}

      // Очищаем офлайн-очередь
      try {
        await OfflineQueueService().clearQueue();
      } catch (_) {}

      clearUserData();
      _currentUser = null;
      notifyListeners();
      
      return {'success': true, 'message': 'Аккаунт успешно удален'};
    } catch (e) {
      return {'success': false, 'error': 'Ошибка при удалении аккаунта: $e'};
    }
  }

  // ============================================
  // СМЕНА ПАРОЛЯ
  // ============================================

  // Изменить пароль через Supabase Auth
  Future<Map<String, dynamic>> changePassword({
    required String oldPassword,
    required String newPassword,
  }) async {
    try {
      if (_currentUser == null) {
        return {'success': false, 'error': 'Пользователь не авторизован'};
      }

      if (oldPassword == newPassword) {
        return {'success': false, 'error': 'Новый пароль должен отличаться от текущего'};
      }

      if (newPassword.length < 6) {
        return {'success': false, 'error': 'Пароль должен содержать минимум 6 символов'};
      }

      final supabase = Supabase.instance.client;
      final email = supabase.auth.currentUser?.email;
      if (email == null) {
        return {'success': false, 'error': 'Email не найден'};
      }

      // Верифицируем старый пароль через повторный вход
      try {
        await supabase.auth.signInWithPassword(
          email: email,
          password: oldPassword,
        );
      } on AuthException catch (e) {
        AppLogger.warning('Неверный текущий пароль: ${e.message}', tag: _logTag);
        return {'success': false, 'error': 'Неверный текущий пароль'};
      }

      // Обновляем пароль через Supabase Auth
      await supabase.auth.updateUser(
        UserAttributes(password: newPassword),
      );

      AppLogger.success('Пароль успешно изменён через Supabase Auth', tag: _logTag);
      return {'success': true, 'message': 'Пароль успешно изменен'};
    } on AuthException catch (e) {
      AppLogger.error('Ошибка смены пароля', tag: _logTag, error: e);
      return {'success': false, 'error': 'Ошибка: ${e.message}'};
    } catch (e) {
      AppLogger.error('Ошибка при смене пароля', tag: _logTag, error: e);
      return {'success': false, 'error': 'Ошибка при смене пароля: $e'};
    }
  }

  // Изменить email через Supabase Auth
  Future<Map<String, dynamic>> changeEmail({required String newEmail}) async {
    try {
      if (_currentUser == null) {
        return {'success': false, 'error': 'Пользователь не авторизован'};
      }
      if (!newEmail.contains('@') || newEmail.trim().isEmpty) {
        return {'success': false, 'error': 'Некорректный email'};
      }
      
      final oldEmail = _currentUser!.email;
      final supabase = Supabase.instance.client;
      
      // Отправляем запрос на смену email
      await supabase.auth.updateUser(UserAttributes(email: newEmail));
      
      AppLogger.success('Email изменён: запрос подтверждения отправлен', tag: _logTag);
      
      // Создаем уведомление о смене email
      if (Features.useSupabaseNotifications) {
        try {
          await supabase.from('notifications').insert({
            'user_id': _currentUser!.id,
            'type': 'email_change',
            'title': '📧 Смена email адреса',
            'message': 'Запрошена смена email с $oldEmail на $newEmail. Проверьте почту для подтверждения.',
            'data': {
              'old_email': oldEmail,
              'new_email': newEmail,
              'requires_confirmation': true,
            }.toString(),
            'created_at': DateTime.now().toIso8601String(),
          });
        } catch (e) {
          AppLogger.warning('Не удалось создать уведомление о смене email', tag: _logTag, error: e);
        }
      }
      
      return {
        'success': true, 
        'message': 'Запрос на смену email отправлен. Проверьте почту $newEmail для подтверждения.'
      };
    } on AuthException catch (e) {
      AppLogger.error('Ошибка смены email', tag: _logTag, error: e);
      String errorMessage = e.message;
      
      // Улучшаем сообщения об ошибках
      if (e.message.contains('email already registered')) {
        errorMessage = 'Этот email уже зарегистрирован. Используйте другой адрес.';
      } else if (e.message.contains('rate limit')) {
        errorMessage = 'Слишком много запросов. Подождите немного и попробуйте снова.';
      }
      
      return {'success': false, 'error': errorMessage};
    } catch (e) {
      AppLogger.error('Ошибка при смене email', tag: _logTag, error: e);
      return {'success': false, 'error': 'Произошла ошибка. Проверьте подключение к интернету.'};
    }
  }

  // ============================================
  // КЕШИРОВАНИЕ (НЕДОСТАЮЩИЕ МЕТОДЫ)
  // ============================================

  Future<void> _saveNotifications() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = _notifications.map((n) => {
        'id': n.id,
        'type': n.type.name,
        'title': n.title,
        'message': n.message,
        'created_at': n.createdAt.toIso8601String(),
        'is_read': n.isRead,
        'related_id': n.relatedId,
      }).toList();
      await prefs.setString('notifications', jsonEncode(encoded));
    } catch (e) {
      AppLogger.warning('Ошибка сохранения уведомлений', tag: 'AppState', error: e);
    }
  }

  Future<void> _loadNotificationsFromCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final data = prefs.getString('notifications');
      if (data != null && data.isNotEmpty) {
        final decoded = jsonDecode(data) as List<dynamic>;
        final cached = decoded.map((item) {
          final m = Map<String, dynamic>.from(item as Map);
          return _mapSupabaseNotification(m);
        }).toList();
        if (cached.isNotEmpty) {
          _notifications = cached;
          final unread = cached.where((n) => !n.isRead).length;
          _updateBadgeCount(unread);
          notifyListeners();
        }
      }
    } catch (e) {
      AppLogger.warning('Ошибка загрузки уведомлений из кеша', tag: 'AppState', error: e);
    }
  }

  Future<void> _saveStoriesToCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      
      // BUG-010: Сохраняем hasEverLoadedPosts в SharedPreferences
      await prefs.setBool('has_ever_loaded_posts', _hasEverLoadedPosts);
      
      final encoded = _stories
          .take(50)
          .map((s) => s.toJson())
          .toList();
      await prefs.setString('stories_cache', jsonEncode(encoded));
    } catch (e) {
      AppLogger.warning('Ошибка сохранения постов в кеш', tag: 'AppState', error: e);
    }
  }

  Future<void> _loadStoriesFromCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      
      // BUG-010: Загружаем hasEverLoadedPosts из SharedPreferences
      _hasEverLoadedPosts = prefs.getBool('has_ever_loaded_posts') ?? false;
      
      final data = prefs.getString('stories_cache');
      if (data != null && data.isNotEmpty) {
        final decoded = jsonDecode(data) as List<dynamic>;
        final cachedStories = decoded.map((item) => Story.fromJson(Map<String, dynamic>.from(item as Map)))
            // Важно: isLiked/isBookmarked зависят от текущего пользователя.
            // Если лайки уже загружены — применяем их, иначе сбрасываем.
            .map((s) => s.copyWith(
              isLiked: _hasLoadedLikes ? _likedPostIds.contains(s.id) : false,
              isBookmarked: _hasLoadedLikes ? _bookmarkedPostIds.contains(s.id) : false,
            ))
            .toList();

        if (cachedStories.isNotEmpty) {
          _stories = cachedStories;
          _hasMoreData = true;
          notifyListeners();
        }
      }
    } catch (e) {
      AppLogger.warning('Ошибка загрузки постов из кеша', tag: 'AppState', error: e);
    }
  }

  Future<void> _loadHiddenUsers() async {
    // Сначала загружаем из локального хранилища
    try {
      final prefs = await SharedPreferences.getInstance();
      final localHidden = prefs.getStringList('hidden_users') ?? [];
      _hiddenUsers = localHidden.toSet();
    } catch (e) {
      AppLogger.warning('Ошибка загрузки локальных скрытых пользователей', tag: 'AppState', error: e);
    }
    
    // Потом мержим с Supabase
    if (Features.useSupabaseUsers && _currentUser != null) {
      try {
        final hidden = await _supabaseBlockService.getHiddenUsers(_currentUser!.id);
        _hiddenUsers.addAll(hidden);
        await _saveHiddenUsers();
      } catch (e) {
        AppLogger.warning('Ошибка загрузки скрытых пользователей из Supabase', tag: 'AppState', error: e);
      }
    }
  }

  Future<void> _loadHiddenPosts() async {
    // Сначала загружаем из локального хранилища
    try {
      final prefs = await SharedPreferences.getInstance();
      final localHidden = prefs.getStringList('hidden_posts') ?? [];
      _notInterestedPosts = localHidden.toSet();
    } catch (e) {
      AppLogger.warning('Ошибка загрузки локальных скрытых постов', tag: 'AppState', error: e);
    }
    
    // Потом мержим с Supabase
    if (Features.useSupabasePosts && _currentUser != null) {
      try {
        final hidden = await _supabaseBlockService.getHiddenPosts(_currentUser!.id);
        _notInterestedPosts.addAll(hidden);
        await _saveHiddenPosts();
      } catch (e) {
        AppLogger.warning('Ошибка загрузки скрытых постов из Supabase', tag: 'AppState', error: e);
      }
    }
  }

  Future<void> _saveHiddenUsers() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('hidden_users', _hiddenUsers.toList());
    } catch (e) {
      AppLogger.warning('Ошибка сохранения скрытых пользователей', tag: 'AppState', error: e);
    }
  }

  Future<void> _saveHiddenPosts() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('hidden_posts', _notInterestedPosts.toList());
    } catch (e) {
      AppLogger.warning('Ошибка сохранения скрытых постов', tag: 'AppState', error: e);
    }
  }

  // ============================================================================
  // ДЕБАТЫ (DISCUSSIONS) - Создание, голосование, комментарии
  // ============================================================================

  List<Discussion> _discussions = [];
  List<Discussion> _allDiscussions = []; // Оригинальный список для фильтрации
  final Map<String, List<DiscussionComment>> _discussionComments = {};
  final Set<String> _savedDiscussionIds = {};
  final Set<String> _commentedDiscussionIds = {};
  final Map<String, List<DiscussionComment>> _userComments = {}; // discussionId -> user's comments
  
  // Локальное хранилище голосов для демо-данных
  final Map<String, DebateSide> _localVotes = {};
  // Количество изменений голоса (разрешаем только одну смену)
  final Map<String, int> _localVoteChangeCount = {};
  
  List<Discussion> get discussions => _discussions;
  List<Discussion> get allDiscussions => _allDiscussions;
  List<Discussion> get savedDiscussions =>
      _discussions.where((d) => _savedDiscussionIds.contains(d.id)).toList();

  /// Загрузить дебат из БД по ID (для deep links и уведомлений)
  Future<Discussion?> fetchDiscussionById(String discussionId) async {
    try {
      final result = await _supabaseDiscussionService.getDiscussionById(
        discussionId,
        userId: _currentUser?.id,
      );
      if (result == null) return null;
      return _mapSupabaseDiscussion(result);
    } catch (e) {
      AppLogger.error('Ошибка загрузки дебата по ID', tag: _logTag, error: e);
      return null;
    }
  }

  List<Discussion> get commentedDiscussions =>
      _discussions.where((d) => _commentedDiscussionIds.contains(d.id)).toList();

  List<DiscussionComment> getUserCommentsForDiscussion(String discussionId) {
    return _userComments[discussionId] ?? [];
  }

  Map<String, List<DiscussionComment>> get allUserComments => _userComments;

  bool isDiscussionSaved(String discussionId) => _savedDiscussionIds.contains(discussionId);

  void toggleSaveDiscussion(String discussionId) {
    final wasSaved = _savedDiscussionIds.contains(discussionId);
    if (wasSaved) {
      _savedDiscussionIds.remove(discussionId);
    } else {
      _savedDiscussionIds.add(discussionId);
    }
    notifyListeners();

    // Синхронизация с Supabase в фоне
    if (_currentUser != null) {
      Supabase.instance.client
          .rpc('toggle_save_discussion', params: {'p_discussion_id': discussionId})
          .catchError((e) {
        AppLogger.warning('Ошибка синхронизации сохранения дебата', tag: _logTag, error: e);
        // Откат при ошибке
        if (wasSaved) {
          _savedDiscussionIds.add(discussionId);
        } else {
          _savedDiscussionIds.remove(discussionId);
        }
        notifyListeners();
      });
    }
  }


  /// Загрузить сохранённые дебаты из Supabase
  Future<void> _loadSavedDiscussionIds() async {
    if (_currentUser == null) return;
    try {
      final response = await Supabase.instance.client
          .from('saved_discussions')
          .select('discussion_id')
          .eq('user_id', _currentUser!.id);
      final ids = (response as List).map((r) => r['discussion_id'] as String).toSet();
      _savedDiscussionIds.addAll(ids);
    } catch (e) {
      AppLogger.warning('Ошибка загрузки сохранённых дебатов', tag: _logTag, error: e);
    }
  }

  /// Создать дебат/обсуждение
  Future<bool> createDiscussion({
    required DiscussionType type,
    required String question,
    String? description,
    String? imageUrl,
    required DiscussionCategory category,
    bool hasTimer = false,
    bool isAnonymous = false,
  }) async {
    // Полностью локальный режим без Supabase
    if (!Features.useSupabasePosts) {
      final author = _currentUser ??
          (_users.isNotEmpty
              ? _users.first
              : User(
                  id: 'local_user',
                  name: 'Вы',
                  username: 'you',
                  avatar: '',
                  isPremium: false,
                  karma: 0,
                ));

      final discussion = Discussion(
        id: 'local_${DateTime.now().millisecondsSinceEpoch}',
        type: type,
        question: question,
        description: description,
        imageUrl: imageUrl,
        category: category,
        author: author,
        createdAt: DateTime.now(),
        hasTimer: false,
        viewsCount: 0,
        commentsCount: 0,
        votesFor: 0,
        votesAgainst: 0,
        votesUnsure: 0,
        isAnonymous: isAnonymous,
      );

      _discussions.insert(0, discussion);
      notifyListeners();

      AppLogger.success('Дебат создан локально: $question', tag: _logTag);
      return true;
    }

    if (_currentUser == null) {
      AppLogger.warning('Пользователь не авторизован', tag: _logTag);
      return false;
    }

    Discussion _buildLocalDiscussionFallback() {
      final author = _currentUser ??
          (_users.isNotEmpty
              ? _users.first
              : User(
                  id: 'local_user',
                  name: 'Вы',
                  username: 'you',
                  avatar: '',
                  isPremium: false,
                  karma: 0,
                ));

      return Discussion(
        id: 'local_${DateTime.now().millisecondsSinceEpoch}',
        type: type,
        question: question,
        description: description,
        imageUrl: imageUrl,
        category: category,
        author: author,
        createdAt: DateTime.now(),
        hasTimer: false,
        viewsCount: 0,
        commentsCount: 0,
        votesFor: 0,
        votesAgainst: 0,
        votesUnsure: 0,
        isAnonymous: isAnonymous,
      );
    }

    String _normalizeDiscussionText(String value) {
      // Запрещаем переносы строк/табы/"отступы" и схлопываем пробелы
      final noBreaks = value.replaceAll(RegExp(r'[\n\r\t]+'), ' ');
      return noBreaks.replaceAll(RegExp(r'\s{2,}'), ' ').trim();
    }

    String? normalizedDescription;
    if (description != null) {
      final d = _normalizeDiscussionText(description);
      normalizedDescription = d.isEmpty ? null : d;
    }

    final normalizedQuestion = _normalizeDiscussionText(question);

    try {
      String? persistedImageUrl;
      if (imageUrl != null && imageUrl.isNotEmpty) {
        try {
          final file = File(imageUrl);
          if (await file.exists()) {
            final storage = SupabaseStorageService();
            persistedImageUrl = await storage.uploadPostImage(_currentUser!.id, file);
          }
        } catch (_) {
          persistedImageUrl = null;
        }
      }

      final result = await _supabaseDiscussionService.createDiscussion(
        authorId: _currentUser!.id,
        type: type,
        question: normalizedQuestion,
        description: normalizedDescription,
        imageUrl: persistedImageUrl,
        category: category,
        hasTimer: false,
        isAnonymous: isAnonymous,
      );

      if (result != null) {
        // Добавляем в локальный список
        final discussion = _mapSupabaseDiscussion(result);
        _discussions.insert(0, discussion);
        notifyListeners();
        
        AppLogger.success('Дебат создан: $question', tag: _logTag);
        return true;
      }
      
      return false;
    } catch (e) {
      // При любой ошибке Supabase создаём дебат локально, чтобы не блокировать UX
      AppLogger.error('Ошибка создания дебата, создаём локально', tag: _logTag, error: e);

      final discussion = _buildLocalDiscussionFallback();
      _discussions.insert(0, discussion);
      notifyListeners();

      return false;
    }
  }

  /// Репостнуть дебат в ленту с текстом
  Future<bool> repostDebate(Discussion debate, String userText) async {
    if (_currentUser == null) return false;
    try {
      // Сохраняем ID дебата в специальном формате для парсинга в UI
      final text = userText.trim().isNotEmpty
          ? '${userText.trim()}\n\n[DEBATE:${debate.id}]'
          : '[DEBATE:${debate.id}]';

      final svc = SupabasePostService();
      final postData = await svc.createPost(
        userId: _currentUser!.id,
        text: text,
        isAnonymous: false,
        isAdult: false,
      );

      if (postData != null) {
        // Создаем Story с данными дебата для интерактивного отображения
        final newStory = Story(
          id: postData['id'] as String,
          author: _currentUser!,
          text: text,
          images: [],
          createdAt: DateTime.parse(postData['created_at'] as String).toLocal(),
          likes: 0,
          comments: 0,
          reposts: 0,
          views: 0,
          isLiked: false,
          isBookmarked: false,
          isAdult: false,
          isAnonymous: false,
          // ДОБАВЛЯЕМ ДАННЫЕ ДЕБАТА для интерактивного отображения
          debateId: debate.id,
          debateQuestion: debate.question,
          debateOptions: ['За', 'Против', 'Не уверен'], // Фиксированные варианты для дебатов
          debateTotalVotes: debate.votesFor + debate.votesAgainst + debate.votesUnsure,
          debateIsActive: debate.endsAt == null || DateTime.now().isBefore(debate.endsAt!),
          debateEndsAt: debate.endsAt,
          debateUserVote: debate.userVote?.name, // Конвертируем DebateSide в строку
        );
        _stories = List<Story>.from(_stories)..insert(0, newStory);
        notifyListeners();
        return true;
      }
      return false;
    } catch (e) {
      AppLogger.error('Ошибка репоста дебата', tag: _logTag, error: e);
      return false;
    }
  }

  /// Инкрементировать просмотры дебата
  Future<void> incrementDebateViews(String discussionId) async {
    try {
      await _supabaseDiscussionService.incrementViews(discussionId);
      final idx = _discussions.indexWhere((d) => d.id == discussionId);
      if (idx != -1) {
        final d = _discussions[idx];
        _discussions[idx] = Discussion(
          id: d.id,
          type: d.type,
          question: d.question,
          description: d.description,
          imageUrl: d.imageUrl,
          category: d.category,
          author: d.author,
          createdAt: d.createdAt,
          hasTimer: d.hasTimer,
          endsAt: d.endsAt,
          viewsCount: d.viewsCount + 1,
          commentsCount: d.commentsCount,
          votesFor: d.votesFor,
          votesAgainst: d.votesAgainst,
          votesUnsure: d.votesUnsure,
          userVote: d.userVote,
          isAnonymous: d.isAnonymous,
        );
        notifyListeners();
      }
    } catch (_) {}
  }

  /// Обновить счётчик комментариев в локальном состоянии
  void _updateDiscussionCommentsCount(String discussionId, int delta) {
    final idx = _discussions.indexWhere((d) => d.id == discussionId);
    if (idx != -1) {
      final d = _discussions[idx];
      _discussions[idx] = d.copyWith(
        commentsCount: (d.commentsCount + delta).clamp(0, double.infinity).toInt(),
      );
      notifyListeners();
    }
  }

  bool _isLoadingDiscussions = false;
  
  /// Загрузить дебаты с серверной пагинацией
  Future<void> loadDiscussions({
    DiscussionType? type,
    DiscussionCategory? category,
    bool? onlyActive,
    String? sortBy,
    String? searchQuery, // Серверный поиск
    bool force = false,
    int limit = 50,
    int offset = 0,
    bool append = false, // true = добавить к существующим, false = заменить
  }) async {
    // Защита от повторной загрузки
    if (_isLoadingDiscussions && !force) return;
    
    // Если данные уже загружены и нет фильтров и не append - пропускаем
    final hasSearch = searchQuery != null && searchQuery.trim().isNotEmpty;
    if (!force && !append && !hasSearch && _discussions.isNotEmpty && type == null && category == null && onlyActive == null && sortBy == null) {
      return;
    }
    
    _isLoadingDiscussions = true;
    
    try {
      // Если не используем Supabase — пустой список
      if (!Features.useSupabasePosts) {
        _discussions = [];
        _allDiscussions = [];
        return;
      }

      final results = await _supabaseDiscussionService.getDiscussions(
        type: type,
        category: category,
        onlyActive: onlyActive,
        sortBy: sortBy,
        searchQuery: searchQuery,
        userId: _currentUser?.id,
        limit: limit,
        offset: offset,
      );

      if (results.isEmpty && offset == 0) {
        // Пустой список — нет дебатов
        _discussions = [];
        _allDiscussions = [];
      } else {
        final newDiscussions = results.map(_mapSupabaseDiscussion).toList();
        
        // ОПТИМИЗАЦИЯ: получаем реальные счетчики комментариев одним запросом
        try {
          final discussionIds = newDiscussions.map((d) => d.id).toList();
          final counts = await _supabaseDiscussionService.getCommentsCountBatch(discussionIds);
          
          for (int i = 0; i < newDiscussions.length; i++) {
            final realCount = counts[newDiscussions[i].id] ?? newDiscussions[i].commentsCount;
            if (realCount != newDiscussions[i].commentsCount) {
              newDiscussions[i] = newDiscussions[i].copyWith(commentsCount: realCount);
            }
          }
        } catch (e) {
          AppLogger.warning('Ошибка получения счетчиков комментариев (batch)', tag: _logTag, error: e);
        }
        
        if (append && offset > 0) {
          // Добавляем к существующим (пагинация)
          _discussions.addAll(newDiscussions);
          _allDiscussions.addAll(newDiscussions);
        } else {
          // Заменяем (первая загрузка или refresh)
          _discussions = newDiscussions;
          _allDiscussions = List<Discussion>.from(_discussions);
        }
      }
      
      _isOffline = false;
      notifyListeners();

      // Кэшируем первую страницу без фильтров для офлайн-режима
      if (offset == 0 && !append && !hasSearch && type == null && category == null) {
        unawaited(_saveDiscussionsToCache(_discussions));
      }

      AppLogger.success('Загружено дебатов: ${_discussions.length}', tag: _logTag);
    } catch (e) {
      AppLogger.error('Ошибка загрузки дебатов', tag: _logTag, error: e);
      _isOffline = true;

      // Офлайн-режим: загружаем из кэша если список пустой
      if (_discussions.isEmpty && offset == 0) {
        await _loadDiscussionsFromCache();
      }

      notifyListeners();
    } finally {
      _isLoadingDiscussions = false;
    }
  }

  static const String _discussionsCacheKey = 'cached_discussions';

  Future<void> _saveDiscussionsToCache(List<Discussion> discussions) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final limited = discussions.length > 50 ? discussions.sublist(0, 50) : discussions;
      final encoded = jsonEncode(limited.map((d) => {
        'id': d.id,
        'question': d.question,
        'description': d.description,
        'type': d.type.name,
        'category': d.category.name,
        'is_active': d.isActive,
        'votes_for': d.votesFor,
        'votes_against': d.votesAgainst,
        'votes_unsure': d.votesUnsure,
        'comments_count': d.commentsCount,
        'views_count': d.viewsCount,
        'created_at': d.createdAt.toIso8601String(),
        'ends_at': d.endsAt?.toIso8601String(),
        'image_url': d.imageUrl,
        'is_anonymous': d.isAnonymous,
        'author_id': d.author.id,
        'author_name': d.author.name,
        'author_username': d.author.username,
        'author_avatar': d.author.avatar,
        'author_verified': d.author.isVerified,
      }).toList());
      await prefs.setString(_discussionsCacheKey, encoded);
    } catch (e) {
      AppLogger.warning('Ошибка сохранения дебатов в кэш', tag: _logTag, error: e);
    }
  }

  Future<void> _loadDiscussionsFromCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_discussionsCacheKey);
      if (raw == null) return;

      final list = List<Map<String, dynamic>>.from(jsonDecode(raw) as List);
      final cached = list.map((d) {
        final author = User(
          id: d['author_id'] as String? ?? '',
          name: d['author_name'] as String? ?? '',
          username: d['author_username'] as String? ?? '',
          avatar: d['author_avatar'] as String? ?? '',
          isVerified: d['author_verified'] as bool? ?? false,
        );
        return Discussion(
          id: d['id'] as String,
          question: d['question'] as String,
          description: d['description'] as String?,
          type: DiscussionType.values.firstWhere(
            (t) => t.name == d['type'],
            orElse: () => DiscussionType.debate,
          ),
          category: DiscussionCategory.values.firstWhere(
                  (c) => c.name == (d['category'] as String? ?? ''),
                  orElse: () => DiscussionCategory.kazakhstan,
                ),
          votesFor: d['votes_for'] as int? ?? 0,
          votesAgainst: d['votes_against'] as int? ?? 0,
          votesUnsure: d['votes_unsure'] as int? ?? 0,
          commentsCount: d['comments_count'] as int? ?? 0,
          viewsCount: d['views_count'] as int? ?? 0,
          createdAt: DateTime.parse(d['created_at'] as String).toLocal(),
          endsAt: d['ends_at'] != null ? DateTime.tryParse(d['ends_at'] as String) : null,
          imageUrl: d['image_url'] as String?,
          isAnonymous: d['is_anonymous'] as bool? ?? false,
          author: author,
        );
      }).toList();

      if (cached.isNotEmpty) {
        _discussions = cached;
        _allDiscussions = List<Discussion>.from(cached);
      }
    } catch (e) {
      AppLogger.warning('Ошибка загрузки дебатов из кэша', tag: _logTag, error: e);
    }
  }

  /// Проголосовать в дебате
  Future<bool> voteInDebate(String discussionId, DebateSide side) async {
    if (_currentUser == null) return false;

    // Защита от двойного нажатия — если голосование уже в процессе, игнорируем
    if (_votePending.contains(discussionId)) return false;
    _votePending.add(discussionId);

    try {
      bool success;

      if (!Features.useSupabasePosts) {
        // Имитируем голосование локально и обновляем счетчики
        final previousVote = _localVotes[discussionId];
        final changesMade = _localVoteChangeCount[discussionId] ?? 0;

        // ПО ТЗ: Разрешаем только ОДНО изменение голоса
        if (previousVote != null && previousVote != side && changesMade >= 1) {
          AppLogger.warning('Нельзя изменить голос более одного раза', tag: _logTag);
          return false;
        }

        _localVotes[discussionId] = side;

        // Обновляем только userVote локально, счётчики обновятся из БД
        // Триггер в БД автоматически обновит votes_for/against/unsure
        final index = _discussions.indexWhere((d) => d.id == discussionId);
        if (index != -1) {
          final discussion = _discussions[index];
          final updatedDiscussion = discussion.copyWith(
            userVote: side,
            userVotedAt: DateTime.now(),
          );
          _discussions[index] = updatedDiscussion;
          
          // Обновляем и в оригинальном списке
          final allIndex = _allDiscussions.indexWhere((d) => d.id == discussionId);
          if (allIndex != -1) {
            _allDiscussions[allIndex] = updatedDiscussion;
          }
        }

        // Обновляем счетчик изменений
        if (previousVote == null) {
          _localVoteChangeCount[discussionId] = 0;
        } else if (previousVote != side) {
          _localVoteChangeCount[discussionId] = changesMade + 1;
        }

        notifyListeners();
        success = true;
      } else {
        // Проверяем лимит смены голоса (макс. 1 смена) для Supabase
        final existingDiscussion = _discussions.cast<Discussion?>().firstWhere(
          (d) => d?.id == discussionId, orElse: () => null,
        );
        if (existingDiscussion != null && existingDiscussion.userVote != null && existingDiscussion.userVote != side) {
          final changesMade = _localVoteChangeCount[discussionId] ?? 0;
          if (changesMade >= 1) {
            AppLogger.warning('Нельзя изменить голос более одного раза', tag: _logTag);
            return false;
          }
          _localVoteChangeCount[discussionId] = changesMade + 1;
        } else if (existingDiscussion?.userVote == null) {
          _localVoteChangeCount[discussionId] = 0;
        }

        // Голосование через Supabase
        success = await _supabaseDiscussionService.vote(
          discussionId: discussionId,
          userId: _currentUser!.id,
          side: side,
        );
        
        if (success) {
          // Сразу обновляем локально userVote чтобы UI отобразил изменения
          final index = _discussions.indexWhere((d) => d.id == discussionId);
          if (index != -1) {
            final discussion = _discussions[index];
            final previousVote = discussion.userVote;
            
            // Обновляем счетчики локально
            int newVotesFor = discussion.votesFor;
            int newVotesAgainst = discussion.votesAgainst;
            int newVotesUnsure = discussion.votesUnsure;
            
            // Убираем старый голос
            if (previousVote == DebateSide.for_) newVotesFor--;
            if (previousVote == DebateSide.against) newVotesAgainst--;
            if (previousVote == DebateSide.unsure) newVotesUnsure--;
            
            // Добавляем новый голос
            if (side == DebateSide.for_) newVotesFor++;
            if (side == DebateSide.against) newVotesAgainst++;
            if (side == DebateSide.unsure) newVotesUnsure++;
            
            final updatedDiscussion = discussion.copyWith(
              userVote: side,
              userVotedAt: DateTime.now(),
              votesFor: newVotesFor,
              votesAgainst: newVotesAgainst,
              votesUnsure: newVotesUnsure,
            );
            _discussions[index] = updatedDiscussion;
            
            // Обновляем и в оригинальном списке
            final allIndex = _allDiscussions.indexWhere((d) => d.id == discussionId);
            if (allIndex != -1) {
              _allDiscussions[allIndex] = updatedDiscussion;
            }
          }
          notifyListeners();
        }
      }

      if (success) {
        AppLogger.success('Голос учтен', tag: _logTag);

        // Уведомляем автора дебата о новом голосе
        if (Features.useSupabaseNotifications && Features.useSupabaseUsers) {
          try {
            final currentUserId = _currentUser!.id;
            final discussion = _discussions.cast<Discussion?>().firstWhere(
              (d) => d?.id == discussionId, orElse: () => null,
            );
            if (discussion != null && discussion.author.id != currentUserId) {
              final notificationService = SupabaseNotificationService();
              await notificationService.createNotification(
                userId: discussion.author.id,
                type: 'debate_vote',
                actorId: currentUserId,
                postId: discussionId,
              );
            }
          } catch (e) {
            AppLogger.warning('Не удалось создать уведомление о голосе в дебате', tag: _logTag, error: e);
          }
        }
      }

      return success;
    } catch (e) {
      AppLogger.error('Ошибка голосования', tag: _logTag, error: e);
      return false;
    } finally {
      _votePending.remove(discussionId);
    }
  }

  /// Загрузить один дебат по ID (для репостов дебатов в ленте)
  Future<Discussion?> loadDiscussionById(String discussionId) async {
    try {
      // Сначала проверяем кэш
      final cached = _discussions.where((d) => d.id == discussionId).toList();
      if (cached.isNotEmpty) return cached.first;

      final result = await _supabaseDiscussionService.getDiscussionById(
        discussionId,
        userId: _currentUser?.id,
      );
      if (result != null) {
        var discussion = _mapSupabaseDiscussion(result);
        
        // Получаем реальное количество комментариев
        try {
          final realCount = await _supabaseDiscussionService.getCommentsCount(discussionId);
          if (realCount != discussion.commentsCount) {
            discussion = discussion.copyWith(commentsCount: realCount);
            AppLogger.info('✅ Реальный счетчик для дебата $discussionId: $realCount', tag: _logTag);
          }
        } catch (_) {}
        
        // Добавляем в кэш если ещё нет
        if (!_discussions.any((d) => d.id == discussionId)) {
          _discussions = [..._discussions, discussion];
          notifyListeners();
        }
        return discussion;
      }
      return null;
    } catch (e) {
      AppLogger.error('Ошибка загрузки дебата по ID', tag: _logTag, error: e);
      return null;
    }
  }

  /// Загрузить комментарии к дебату
  Future<bool> loadDiscussionComments(
    String discussionId, {
    DebateSide? filterBySide,
    String? sortBy,
    int limit = 20,
    int offset = 0,
    bool loadMore = false,
  }) async {
    try {
      final results = await _supabaseDiscussionService.getComments(
        discussionId: discussionId,
        filterBySide: filterBySide,
        sortBy: sortBy,
        limit: limit,
        offset: offset,
        currentUserId: _currentUser?.id,
      );

      var mapped = results.map(_mapSupabaseDiscussionComment).toList();

      // Если у нас уже есть локальные комментарии пользователя для этого дебата,
      // то обновляем side в загруженных комментариях
      final userComments = _userComments[discussionId];
      if (userComments != null && userComments.isNotEmpty) {
        for (final userComment in userComments) {
          final idx = mapped.indexWhere((c) => c.id == userComment.id);
          if (idx != -1) {
            mapped[idx] = mapped[idx].copyWith(side: userComment.side);
          }
        }
      }

      if (_currentUser != null) {
        final ownComments = mapped.where((c) => c.author.id == _currentUser!.id).toList();
        if (ownComments.isNotEmpty) {
          _userComments[discussionId] = ownComments;
          _commentedDiscussionIds.add(discussionId);
        } else if (!loadMore) {
          _userComments.remove(discussionId);
          _commentedDiscussionIds.remove(discussionId);
        }
      }

      if (loadMore) {
        // Добавляем только новые комментарии (без дубликатов)
        final existing = _discussionComments[discussionId] ?? [];
        final existingIds = existing.map((c) => c.id).toSet();
        final newComments = mapped.where((c) => !existingIds.contains(c.id)).toList();
        _discussionComments[discussionId] = [...existing, ...newComments];
        
        // Обновляем счетчик комментариев в списке дебатов при догрузке
        if (newComments.isNotEmpty) {
          _updateDiscussionCommentsCount(discussionId, newComments.length);
        }
      } else {
        _discussionComments[discussionId] = mapped;
        
        // Получаем РЕАЛЬНЫЙ счетчик из БД через count запрос
        try {
          final realCount = await _supabaseDiscussionService.getCommentsCount(discussionId);
          final discussionIdx = _discussions.indexWhere((d) => d.id == discussionId);
          if (discussionIdx != -1 && _discussions[discussionIdx].commentsCount != realCount) {
            _discussions[discussionIdx] = _discussions[discussionIdx].copyWith(commentsCount: realCount);
            AppLogger.info('✅ Реальный счетчик комментариев для дебата $discussionId: $realCount', tag: _logTag);
          }
        } catch (_) {}
      }
      notifyListeners();

      AppLogger.success('Загружено комментариев: ${mapped.length}', tag: _logTag);
      return mapped.length >= limit; // true = есть ещё страницы
    } catch (e) {
      AppLogger.error('Ошибка загрузки комментариев', tag: _logTag, error: e);
      // При ошибке не очищаем комментарии - оставляем как есть
      return false;
    }
  }

  /// Добавить комментарий локально (без отправки в Supabase)
  void addLocalComment(String discussionId, DiscussionComment comment) {
    if (!_discussionComments.containsKey(discussionId)) {
      _discussionComments[discussionId] = [];
    }
    _discussionComments[discussionId]!.add(comment);
    _commentedDiscussionIds.add(discussionId);
    
    // Track user's own comments
    if (!_userComments.containsKey(discussionId)) {
      _userComments[discussionId] = [];
    }
    _userComments[discussionId]!.add(comment);
    
    // Обновляем счётчик комментариев в дебате
    final discussionIndex = _discussions.indexWhere((d) => d.id == discussionId);
    if (discussionIndex != -1) {
      final discussion = _discussions[discussionIndex];
      final updatedDiscussion = discussion.copyWith(
        commentsCount: discussion.commentsCount + 1,
      );
      _discussions[discussionIndex] = updatedDiscussion;
      
      // Обновляем и в оригинальном списке
      final allIndex = _allDiscussions.indexWhere((d) => d.id == discussionId);
      if (allIndex != -1) {
        _allDiscussions[allIndex] = updatedDiscussion;
      }
    }
    
    notifyListeners();
    AppLogger.success('Локальный комментарий добавлен', tag: _logTag);
  }

  /// Обновить сторону всех комментариев пользователя при смене голоса
  ///
  /// Используем карту _userComments, где уже лежат только комментарии
  /// текущего пользователя для заданного обсуждения, и синхронизируем
  /// изменения с общим списком _discussionComments.
  Future<void> updateUserCommentsVote(String discussionId, DebateSide newSide) async {
    final comments = _discussionComments[discussionId];
    final userComments = _userComments[discussionId];
    final hasUserComments = userComments != null && userComments.isNotEmpty;

    // Обновляем в БД даже если локальный кэш пуст – после reload придут правильные цвета
    if (_currentUser != null) {
      await _supabaseDiscussionService.updateUserCommentsSide(
        discussionId: discussionId,
        userId: _currentUser!.id,
        newSide: newSide,
      );
    }

    if (!hasUserComments || comments == null) {
      return;
    }

    // Обновляем сторону во всех пользовательских комментариях локально
    for (var i = 0; i < userComments.length; i++) {
      final userComment = userComments[i];

      final updatedComment = DiscussionComment(
        id: userComment.id,
        discussionId: userComment.discussionId,
        author: userComment.author,
        text: userComment.text,
        side: newSide,
        createdAt: userComment.createdAt,
        likes: userComment.likes,
        isLiked: userComment.isLiked,
        supports: userComment.supports,
        contests: userComment.contests,
        isSupported: userComment.isSupported,
        isContested: userComment.isContested,
        replyToId: userComment.replyToId,
        replyToAuthor: userComment.replyToAuthor,
        isAnonymous: userComment.isAnonymous,
      );

      userComments[i] = updatedComment;

      final idxInAll = comments.indexWhere((c) => c.id == userComment.id);
      if (idxInAll != -1) {
        comments[idxInAll] = updatedComment;
      }
    }

    notifyListeners();
    AppLogger.success('Обновлены комментарии пользователя на сторону: ${newSide.name}', tag: _logTag);
  }

  void updateLocalComment(
    String discussionId,
    String commentId, {
    String? newText,
    DebateSide? newSide,
    int? newSupports,
    int? newContests,
    bool? newIsSupported,
    bool? newIsContested,
  }) {
    final comments = _discussionComments[discussionId];
    if (comments == null) return;

    final index = comments.indexWhere((c) => c.id == commentId);
    if (index == -1) return;

    final current = comments[index];
    comments[index] = current.copyWith(
      text: newText ?? current.text,
      side: newSide ?? current.side,
      supports: newSupports ?? current.supports,
      contests: newContests ?? current.contests,
      isSupported: newIsSupported ?? current.isSupported,
      isContested: newIsContested ?? current.isContested,
    );
    notifyListeners();
    AppLogger.info('Локальный комментарий обновлён', tag: _logTag);
  }

  /// Удалить комментарий локально
  void deleteLocalComment(String discussionId, String commentId) {
    final comments = _discussionComments[discussionId];
    if (comments == null) return;

    comments.removeWhere((c) => c.id == commentId);
    
    // Удаляем из пользовательских комментариев
    final userComments = _userComments[discussionId];
    if (userComments != null) {
      userComments.removeWhere((c) => c.id == commentId);
      if (userComments.isEmpty) {
        _userComments.remove(discussionId);
        _commentedDiscussionIds.remove(discussionId);
      }
    }
    
    // Обновляем счётчик комментариев в дебате
    final discussionIndex = _discussions.indexWhere((d) => d.id == discussionId);
    if (discussionIndex != -1) {
      final discussion = _discussions[discussionIndex];
      _discussions[discussionIndex] = discussion.copyWith(
        commentsCount: max(0, discussion.commentsCount - 1),
      );
    }
    
    notifyListeners();
    AppLogger.success('Комментарий удалён', tag: _logTag);
  }

  /// Добавить комментарий к дебату
  Future<bool> addDiscussionComment({
    required String discussionId,
    required String text,
    DebateSide side = DebateSide.neutral,
    String? replyToId,
    String? replyToAuthor,
    bool isAnonymous = false,
    String? mediaUrl,
    String? mediaType,
    int? mediaWidth,
    int? mediaHeight,
  }) async {
    if (_currentUser == null) return false;

    try {
      final result = await _supabaseDiscussionService.addComment(
        discussionId: discussionId,
        authorId: _currentUser!.id,
        text: text,
        side: side,
        replyToId: replyToId,
        replyToAuthor: replyToAuthor,
        isAnonymous: isAnonymous,
        mediaUrl: mediaUrl,
        mediaType: mediaType,
        mediaWidth: mediaWidth,
        mediaHeight: mediaHeight,
      );

      if (result != null) {
        await loadDiscussionComments(discussionId);
        _commentedDiscussionIds.add(discussionId);
        
        // Обновляем счётчик комментариев в списке дебатов
        _updateDiscussionCommentsCount(discussionId, 1);
        
        AppLogger.success('Комментарий добавлен', tag: _logTag);
        
        // Создаём уведомление для автора дебата или автора комментария (если ответ)
        if (Features.useSupabaseNotifications && Features.useSupabaseUsers) {
          try {
            final currentUserId = _currentUser!.id;
            final notificationService = SupabaseNotificationService();
            
            if (replyToId != null) {
              // Это ответ на комментарий в дебате - уведомляем автора комментария
              final parentComment = _discussionComments[discussionId]?.firstWhere(
                (c) => c.id == replyToId,
                orElse: () => throw Exception('Parent comment not found'),
              );
              if (parentComment != null && parentComment.author.id != currentUserId) {
                await notificationService.createNotification(
                  userId: parentComment.author.id,
                  type: 'debate_reply', // Тип для дебата
                  actorId: currentUserId,
                  postId: discussionId,
                  commentId: result['id'] as String?,
                  commentText: text,
                );
              }
            } else {
              // Это новый комментарий к дебату - уведомляем автора дебата
              final discussion = _discussions.firstWhere(
                (d) => d.id == discussionId,
                orElse: () => throw Exception('Discussion not found'),
              );
              if (discussion.author.id != currentUserId) {
                await notificationService.createNotification(
                  userId: discussion.author.id,
                  type: 'debate_comment', // Тип для дебата
                  actorId: currentUserId,
                  postId: discussionId,
                  commentId: result['id'] as String?,
                  commentText: text,
                );
              }
            }
          } catch (e) {
            AppLogger.warning('Не удалось создать уведомление о комментарии в дебате', tag: _logTag, error: e);
          }
        }
        
        return true;
      }

      return false;
    } catch (e) {
      AppLogger.error('Ошибка добавления комментария', tag: _logTag, error: e);
      return false;
    }
  }

  /// Лайкнуть комментарий дебата
  Future<bool> likeDiscussionComment(String discussionId, String commentId) async {
    if (_currentUser == null) return false;

    try {
      final success = await _supabaseDiscussionService.likeComment(
        commentId,
        _currentUser!.id,
      );

      if (success) {
        // НЕ перезагружаем комментарии - UI уже обновлен оптимистично
        AppLogger.success('Лайк обработан', tag: _logTag);
        
        // Создаём уведомление для автора комментария
        if (Features.useSupabaseNotifications && Features.useSupabaseUsers) {
          try {
            final currentUserId = _currentUser!.id;
            final comment = _discussionComments[discussionId]?.firstWhere(
              (c) => c.id == commentId,
              orElse: () => throw Exception('Comment not found'),
            );
            
            if (comment != null && comment.author.id != currentUserId) {
              final notificationService = SupabaseNotificationService();
              await notificationService.createNotification(
                userId: comment.author.id,
                type: 'debate_like', // Тип для дебата
                actorId: currentUserId,
                postId: discussionId,
                commentId: commentId,
              );
            }
          } catch (e) {
            AppLogger.warning('Не удалось создать уведомление о лайке комментария в дебате', tag: _logTag, error: e);
          }
        }
      }

      return success;
    } catch (e) {
      AppLogger.error('Ошибка лайка комментария', tag: _logTag, error: e);
      return false;
    }
  }

  Future<bool> contestDiscussionComment(String discussionId, String commentId) async {
    if (_currentUser == null) return false;

    try {
      final success = await _supabaseDiscussionService.contestComment(
        commentId,
        _currentUser!.id,
      );

      if (success) {
        // НЕ перезагружаем комментарии - UI уже обновлен оптимистично
        AppLogger.success('Оспаривание обработано', tag: _logTag);
      }

      return success;
    } catch (e) {
      AppLogger.error('Ошибка оспаривания комментария', tag: _logTag, error: e);
      return false;
    }
  }

  Future<bool> editDiscussionComment({
    required String discussionId,
    required String commentId,
    required String text,
  }) async {
    if (_currentUser == null) return false;

    try {
      final success = await _supabaseDiscussionService.updateComment(
        commentId: commentId,
        userId: _currentUser!.id,
        text: text,
      );

      if (success) {
        await loadDiscussionComments(discussionId);
        AppLogger.success('Комментарий обновлён', tag: _logTag);
      }

      return success;
    } catch (e) {
      AppLogger.error('Ошибка редактирования комментария', tag: _logTag, error: e);
      return false;
    }
  }

  Future<bool> deleteDiscussionComment(String discussionId, String commentId) async {
    if (_currentUser == null) return false;

    try {
      final success = await _supabaseDiscussionService.deleteComment(
        commentId: commentId,
        authorId: _currentUser!.id,
      );

      if (success) {
        await loadDiscussionComments(discussionId);
        
        // Обновляем счётчик комментариев в списке дебатов
        _updateDiscussionCommentsCount(discussionId, -1);
        
        AppLogger.success('Комментарий удалён', tag: _logTag);
      }

      return success;
    } catch (e) {
      AppLogger.error('Ошибка удаления комментария', tag: _logTag, error: e);
      return false;
    }
  }

  // Закрепить/открепить комментарий дебата (только автор дебата)
  Future<void> togglePinDiscussionComment(String commentId, String discussionId) async {
    final comments = _discussionComments[discussionId];
    if (comments == null || comments.isEmpty) return;

    final index = comments.indexWhere((c) => c.id == commentId);
    if (index == -1) return;

    final target = comments[index];
    final newPinState = !target.isPinned;

    if (newPinState) {
      for (var i = 0; i < comments.length; i++) {
        if (comments[i].isPinned) {
          comments[i] = comments[i].copyWith(isPinned: false);
        }
      }
    }

    comments[index] = target.copyWith(isPinned: newPinState);
    notifyListeners();

    try {
      await _supabaseDiscussionService.togglePinDiscussionComment(commentId, discussionId, newPinState);
    } catch (e) {
      comments[index] = target;
      notifyListeners();
      AppLogger.error('Ошибка закрепления комментария дебата', tag: _logTag, error: e);
    }
  }

  Discussion _mapSupabaseDiscussion(Map<String, dynamic> data) {
    final authorData = data['author'] as Map<String, dynamic>?;
    final premiumExpiresAtRaw = authorData?['premium_expires_at'];
    final premiumExpiresAt = premiumExpiresAtRaw is String
        ? DateTime.tryParse(premiumExpiresAtRaw)
        : null;
    final roleString = authorData?['role'] as String?;
    final author = authorData != null
        ? User(
            id: authorData['id'] as String? ?? '',
            name: authorData['full_name'] as String? ?? 'Пользователь',
            username: authorData['username'] as String? ?? 'user',
            avatar: authorData['avatar_url'] as String? ?? '',
            isPremium: roleString == 'premium' || (authorData['is_premium'] as bool? ?? false) || premiumExpiresAt != null,
            premiumExpiresAt: premiumExpiresAt,
            karma: 0,
            isVerified: authorData['is_verified'] as bool?,
          )
        : User(id: '', name: 'Пользователь', username: 'user', avatar: '', isPremium: false, karma: 0);

    final typeValue = data['type'] as String? ?? 'discussion';
    final categoryValue = data['category'] as String? ?? 'kazakhstan';
    final userVoteValue = data['user_vote'] as String?;

    return Discussion(
      id: data['id'] as String? ?? '',
      type: _mapDiscussionTypeEnum(typeValue),
      question: data['question'] as String? ?? '',
      description: data['description'] as String?,
      imageUrl: data['image_url'] as String?,
      category: _mapDiscussionCategoryEnum(categoryValue),
      author: author,
      createdAt: (DateTime.tryParse(data['created_at'] as String? ?? '') ?? DateTime.now()).toLocal(),
      hasTimer: data['has_timer'] as bool? ?? false,
      endsAt: data['ends_at'] != null ? DateTime.tryParse(data['ends_at'] as String) : null,
      viewsCount: (data['views_count'] as num?)?.toInt() ?? 0,
      commentsCount: (data['comments_count'] as num?)?.toInt() ?? 0,
      votesFor: (data['votes_for'] as num?)?.toInt() ?? 0,
      votesAgainst: (data['votes_against'] as num?)?.toInt() ?? 0,
      votesUnsure: (data['votes_unsure'] as num?)?.toInt() ?? 0,
      userVote: userVoteValue != null ? _mapDebateSideEnum(userVoteValue) : null,
      userVotedAt: data['user_voted_at'] != null ? DateTime.tryParse(data['user_voted_at'] as String) : null,
      isAnonymous: data['is_anonymous'] as bool? ?? false,
    );
  }

  DiscussionComment _mapSupabaseDiscussionComment(Map<String, dynamic> data) {
    final authorData = data['author'] as Map<String, dynamic>?;
    final premiumExpiresAtRaw = authorData?['premium_expires_at'];
    final premiumExpiresAt = premiumExpiresAtRaw is String
        ? DateTime.tryParse(premiumExpiresAtRaw)
        : null;
    final roleString = authorData?['role'] as String?;
    final author = authorData != null
        ? User(
            id: authorData['id'] as String? ?? '',
            name: authorData['full_name'] as String? ?? 'Пользователь',
            username: authorData['username'] as String? ?? 'user',
            avatar: authorData['avatar_url'] as String? ?? '',
            isPremium: roleString == 'premium' || (authorData['is_premium'] as bool? ?? false) || premiumExpiresAt != null,
            premiumExpiresAt: premiumExpiresAt,
            karma: 0,
            isVerified: authorData['is_verified'] as bool?,
          )
        : User(id: '', name: 'Пользователь', username: 'user', avatar: '', isPremium: false, karma: 0);

    return DiscussionComment(
      id: data['id'] as String? ?? '',
      discussionId: data['discussion_id'] as String? ?? '',
      author: author,
      text: data['text'] as String? ?? '',
      side: _mapDebateSideEnum(data['side'] as String? ?? 'neutral'),
      createdAt: (DateTime.tryParse(data['created_at'] as String? ?? '') ?? DateTime.now()).toLocal(),
      updatedAt: data['updated_at'] != null ? DateTime.tryParse(data['updated_at'] as String)?.toLocal() : null,
      likes: (data['likes_count'] as num?)?.toInt() ?? 0,
      isLiked: data['is_liked'] as bool? ?? false,
      supports: (data['supports'] as num?)?.toInt() ?? ((data['supports_count'] as num?)?.toInt() ?? 0),
      contests: (data['contests'] as num?)?.toInt() ?? ((data['contests_count'] as num?)?.toInt() ?? 0),
      isSupported: data['is_supported'] as bool? ?? false,
      isContested: data['is_contested'] as bool? ?? false,
      replyToId: data['reply_to_id'] as String?,
      replyToAuthor: data['reply_to_author'] as String?,
      isAnonymous: data['is_anonymous'] as bool? ?? false,
      mediaUrl: data['media_url'] as String?,
      mediaType: data['media_type'] as String?,
      mediaWidth: data['media_width'] as int?,
      mediaHeight: data['media_height'] as int?,
      isPinned: data['is_pinned'] as bool? ?? false,
    );
  }

  DiscussionType _mapDiscussionTypeEnum(String value) {
    switch (value) {
      case 'debate':
        return DiscussionType.debate;
      default:
        return DiscussionType.discussion;
    }
  }

  DiscussionCategory _mapDiscussionCategoryEnum(String value) {
    switch (value) {
      case 'family':
        return DiscussionCategory.family;
      case 'work':
        return DiscussionCategory.work;
      case 'education':
        return DiscussionCategory.education;
      case 'religion':
        return DiscussionCategory.religion;
      case 'economy':
        return DiscussionCategory.economy;
      case 'health':
        return DiscussionCategory.health;
      case 'entertainment':
        return DiscussionCategory.entertainment;
      case 'world':
        return DiscussionCategory.world;
      case 'science':
        return DiscussionCategory.science;
      default:
        return DiscussionCategory.kazakhstan;
    }
  }

  DebateSide _mapDebateSideEnum(String value) {
    switch (value) {
      case 'for':
        return DebateSide.for_;
      case 'against':
        return DebateSide.against;
      case 'unsure':
        return DebateSide.unsure;
      default:
        return DebateSide.neutral;
    }
  }

  // Сохранить gender и birthDate локально
  Future<void> _saveProfileFieldsLocally({String? gender, DateTime? birthDate, String? profileColor, String? city, String? bio, String? website, String? websiteText}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (gender != null) {
        await prefs.setString('user_gender', gender);
      }
      if (birthDate != null) {
        await prefs.setString('user_birth_date', birthDate.toIso8601String());
      }
      if (profileColor != null) {
        await prefs.setString('user_profile_color', profileColor);
      }
      if (city != null) {
        await prefs.setString('user_city', city);
      }
      if (bio != null) {
        await prefs.setString('user_bio', bio);
      }
      if (website != null) {
        await prefs.setString('user_website', website);
      }
      if (websiteText != null) {
        await prefs.setString('user_website_text', websiteText);
      }
    } catch (e) {
      AppLogger.error('Ошибка сохранения полей локально', tag: _logTag, error: e);
    }
  }

  // Загрузить gender и birthDate из локального хранилища
  Future<Map<String, dynamic>> _loadProfileFieldsLocally() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final gender = prefs.getString('user_gender');
      final birthDateStr = prefs.getString('user_birth_date');
      
      DateTime? birthDate;
      if (birthDateStr != null) {
        try {
          birthDate = DateTime.parse(birthDateStr);
        } catch (e) {
          AppLogger.error('Ошибка парсинга birthDate: $birthDateStr', tag: _logTag, error: e);
        }
      }
      
      final profileColor = prefs.getString('user_profile_color');
      final city = prefs.getString('user_city');
      final bio = prefs.getString('user_bio');
      final website = prefs.getString('user_website');
      final websiteText = prefs.getString('user_website_text');
      return {
        'gender': gender,
        'birthDate': birthDate,
        'profileColor': profileColor,
        'city': city,
        'bio': bio,
        'website': website,
        'websiteText': websiteText,
      };
    } catch (e) {
      AppLogger.error('Ошибка загрузки полей локально', tag: _logTag, error: e);
      return {};
    }
  }
}
