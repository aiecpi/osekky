import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'notification_service.dart';
import '../utils/logger.dart';
import '../main.dart' show navigatorKey;

/// Сервис для управления Firebase push-уведомлениями
class FirebaseNotificationService {
  static final FirebaseMessaging _firebaseMessaging = FirebaseMessaging.instance;
  static final FlutterLocalNotificationsPlugin _localNotifications = FlutterLocalNotificationsPlugin();
  
  static String? _fcmToken;
  static String get fcmToken => _fcmToken ?? '';
  
  static bool _isInitialized = false;
  static Timer? _tokenRefreshTimer;
  static const String _lastTokenSyncKey = 'fcm_token_last_sync';
  static final Map<String, DateTime> _recentNotificationKeys = <String, DateTime>{};

  /// Callback для обновления AppState при получении push в foreground
  /// Регистрируется из AppState после инициализации
  static void Function(Map<String, dynamic> data)? onPushReceived;

  /// Периодическая проверка актуальности FCM токена (раз в 7 дней)
  static void startPeriodicTokenRefresh() {
    _tokenRefreshTimer?.cancel();
    _tokenRefreshTimer = Timer.periodic(const Duration(days: 7), (_) async {
      AppLogger.info('Периодическая проверка FCM токена', tag: 'FirebaseNotification');
      await _refreshTokenIfNeeded();
    });
  }

  static void stopPeriodicTokenRefresh() {
    _tokenRefreshTimer?.cancel();
    _tokenRefreshTimer = null;
  }

  /// Обновить токен если он устарел или изменился
  static Future<void> _refreshTokenIfNeeded() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final lastSync = prefs.getString(_lastTokenSyncKey);
      final now = DateTime.now();

      // Проверяем прошло ли 7 дней с последней синхронизации
      if (lastSync != null) {
        final lastSyncDate = DateTime.tryParse(lastSync);
        if (lastSyncDate != null && now.difference(lastSyncDate).inDays < 7) {
          return; // Ещё рано обновлять
        }
      }

      // Получаем свежий токен от Firebase
      final freshToken = await _firebaseMessaging.getToken();
      if (freshToken == null) return;

      final storedToken = prefs.getString('fcm_token');

      // Синхронизируем если токен изменился или давно не обновлялся
      if (freshToken != storedToken || lastSync == null) {
        _fcmToken = freshToken;
        await prefs.setString('fcm_token', freshToken);
        await syncFCMToken();
      } else {
        // Токен не изменился — просто обновляем timestamp в Supabase
        await syncFCMToken();
      }

      await prefs.setString(_lastTokenSyncKey, now.toIso8601String());
      AppLogger.success('FCM токен проверен и актуален', tag: 'FirebaseNotification');
    } catch (e) {
      AppLogger.error('Ошибка периодической проверки FCM токена', tag: 'FirebaseNotification', error: e);
    }
  }

  /// Инициализация Firebase и push-уведомлений
  static Future<void> initialize() async {
    if (_isInitialized) return;
    
    try {
      // Инициализируем Firebase только если ещё не инициализирован
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp();
      }
      AppLogger.info('Firebase Core initialized', tag: 'FirebaseNotification');
      
      // Запрашиваем разрешения
      await _requestPermissions();
      
      // Получаем FCM токен
      await _getFCMToken();

      FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

      await _firebaseMessaging.setForegroundNotificationPresentationOptions(
        alert: true,
        badge: true,
        sound: true,
      );
      
      // Настраиваем обработчики сообщений
      await _setupMessageHandlers();
      
      // Инициализируем локальные уведомления
      await _initializeLocalNotifications();
      
      _isInitialized = true;
      AppLogger.success('Firebase Notification Service initialized', tag: 'FirebaseNotification');
      
      // Запускаем периодическую проверку актуальности токена
      startPeriodicTokenRefresh();
      
    } catch (e, stack) {
      AppLogger.error('Failed to initialize Firebase notifications', 
                      tag: 'FirebaseNotification', error: e, stackTrace: stack);
    }
  }
  
  /// Запрашиваем разрешения на уведомления
  static Future<void> _requestPermissions() async {
    if (Platform.isIOS) {
      final settings = await _firebaseMessaging.requestPermission(
        alert: true,
        announcement: false,
        badge: true,
        carPlay: false,
        criticalAlert: false,
        provisional: false,
        sound: true,
      );
      
      AppLogger.info('iOS notification permission: ${settings.authorizationStatus}', 
                     tag: 'FirebaseNotification');
    }
    
    if (Platform.isAndroid) {
      // Android 13+ требует разрешение на уведомления
      if (Platform.isAndroid) {
        final status = await Permission.notification.request();
        AppLogger.info('Android notification permission: $status', 
                       tag: 'FirebaseNotification');
      }
    }
  }
  
  /// Получаем FCM токен
  static Future<void> _getFCMToken() async {
    try {
      _fcmToken = await _firebaseMessaging.getToken();
      // Не логируем FCM токен для безопасности
      AppLogger.info('FCM Token получен', tag: 'FirebaseNotification');
      
      // Сохраняем токен в SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('fcm_token', _fcmToken!);
      
      // Обновляем токен в Supabase если пользователь авторизован
      syncFCMToken();
      
      // Слушаем обновления токена
      _firebaseMessaging.onTokenRefresh.listen((token) {
        _fcmToken = token;
        // Не логируем FCM токен для безопасности
        AppLogger.info('FCM Token обновлён', tag: 'FirebaseNotification');
        syncFCMToken();
      });
      
    } catch (e) {
      AppLogger.error('Failed to get FCM token', 
                      tag: 'FirebaseNotification', error: e);
    }
  }
  
  /// Обновляем FCM токен в Supabase (вызывать после входа пользователя)
  static Future<void> syncFCMToken() async {
    try {
      final userId = Supabase.instance.client.auth.currentUser?.id;
      
      // BUG-001: Детальное логирование для отладки
      if (userId == null) {
        AppLogger.warning('FCM sync skipped: user not authenticated', tag: 'FirebaseNotification');
        return;
      }
      
      if (_fcmToken == null) {
        AppLogger.warning('FCM sync skipped: token is null', tag: 'FirebaseNotification');
        return;
      }
      
      AppLogger.info('Syncing FCM token for user: $userId', tag: 'FirebaseNotification');

      final response = await Supabase.instance.client
          .from('users')
          .update({
            'fcm_token': _fcmToken,
            'updated_at': DateTime.now().toIso8601String()
          })
          .eq('id', userId)
          .select();

      await Supabase.instance.client
          .from('user_settings')
          .upsert({
            'user_id': userId,
            'fcm_token': _fcmToken,
          }, onConflict: 'user_id');
      
      if (response.isEmpty) {
        AppLogger.error('FCM token update failed: no rows affected', tag: 'FirebaseNotification');
      } else {
        AppLogger.success('FCM токен успешно обновлён в Supabase (user: $userId)', tag: 'FirebaseNotification');
      }
    } catch (e, st) {
      AppLogger.error('Failed to update FCM token in Supabase', 
                      tag: 'FirebaseNotification', error: e, stackTrace: st);
    }
  }
  
  /// Настраиваем обработчики сообщений
  static Future<void> _setupMessageHandlers() async {
    // Сообщение в foreground (приложение открыто)
    FirebaseMessaging.onMessage.listen(_handleForegroundMessage);
    
    // Сообщение при клике на уведомление (приложение в background)
    FirebaseMessaging.onMessageOpenedApp.listen(_handleMessageOpenedApp);
    
    // Сообщение при запуске приложения из уведомления
    final initialMessage = await _firebaseMessaging.getInitialMessage();
    if (initialMessage != null) {
      _handleMessageOpenedApp(initialMessage);
    }
  }
  
  /// Обработка сообщения в foreground
  static Future<void> _handleForegroundMessage(RemoteMessage message) async {
    AppLogger.info('[FCM] Foreground push: type=${message.data["type"]} id=${message.messageId}',
                   tag: 'FirebaseNotification');

    if (_isDuplicateMessage(message)) {
      AppLogger.warning('[FCM] Duplicate foreground push skipped: ${message.messageId}', tag: 'FirebaseNotification');
      return;
    }
    
    // Показываем локальное уведомление (шторка)
    await _showLocalNotification(message);
    
    // Обновляем чат с новым сообщением
    await _handleChatMessage(message);

    // Обновляем AppState через callback — UI обновляется без перезагрузки
    final type = message.data['type'] as String?;
    if (type != null && type != 'chat_message' && type != 'message') {
      AppLogger.info('[FCM] Вызываем onPushReceived для обновления UI', tag: 'FirebaseNotification');
      onPushReceived?.call(Map<String, dynamic>.from(message.data));
    }
  }
  
  /// Обработка клика на уведомление
  static Future<void> _handleMessageOpenedApp(RemoteMessage message) async {
    AppLogger.info('Message clicked: ${message.messageId}', 
                   tag: 'FirebaseNotification');

    if (_isDuplicateMessage(message)) {
      AppLogger.warning('Duplicate opened-app push skipped: ${message.messageId}', tag: 'FirebaseNotification');
      return;
    }
    
    // Навигация по типу уведомления
    _navigateByType(message.data);
  }

  static bool _isDuplicateMessage(RemoteMessage message) {
    final now = DateTime.now();
    _recentNotificationKeys.removeWhere(
      (_, timestamp) => now.difference(timestamp) > const Duration(minutes: 5),
    );

    final explicitId = message.data['notification_id'] as String? ??
        message.data['notificationId'] as String? ??
        message.messageId;
    final type = message.data['type'] as String? ?? 'unknown';
    final postId = message.data['post_id'] as String? ?? message.data['postId'] as String? ?? '';
    final commentId = message.data['comment_id'] as String? ?? message.data['commentId'] as String? ?? '';
    final chatId = message.data['chat_id'] as String? ?? message.data['chatId'] as String? ?? '';
    final dedupeKey = [explicitId ?? '', type, postId, commentId, chatId].join('|');

    if (_recentNotificationKeys.containsKey(dedupeKey)) {
      return true;
    }

    _recentNotificationKeys[dedupeKey] = now;
    return false;
  }
  
  /// Инициализация локальных уведомлений
  static Future<void> _initializeLocalNotifications() async {
    const androidSettings = AndroidInitializationSettings('@drawable/ic_notification');
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    
    const settings = InitializationSettings(android: androidSettings, iOS: iosSettings);
    
    await _localNotifications.initialize(
      settings,
      onDidReceiveNotificationResponse: _onNotificationTapped,
    );

    await _localNotifications
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(const AndroidNotificationChannel(
          'activity_notifications',
          'Activity Notifications',
          description: 'Likes, comments, follows and other activity',
          importance: Importance.max,
          playSound: true,
        ));

    await _localNotifications
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(const AndroidNotificationChannel(
          'chat_messages',
          'Chat Messages',
          description: 'Notifications for new chat messages',
          importance: Importance.max,
          playSound: true,
        ));
  }
  
  /// Показываем локальное уведомление
  static Future<void> _showLocalNotification(RemoteMessage message) async {
    final notifType = message.data['type'] as String? ?? 'general';
    final channelId = notifType == 'chat_message' ? 'chat_messages' : 'activity_notifications';
    final channelName = notifType == 'chat_message' ? 'Chat Messages' : 'Activity';
    final channelDesc = notifType == 'chat_message'
        ? 'Notifications for new chat messages'
        : 'Likes, comments, follows and other activity';
    final conversationId = message.data['chat_id'] as String? ?? message.data['chatId'] as String?;
    final groupKey = notifType == 'chat_message'
        ? 'osekky_chat_${conversationId ?? 'general'}'
        : 'osekky_activity';

    // Сохраняем данные как JSON для надёжного парсинга (BUG-020)
    String payload = '';
    try {
      payload = jsonEncode(message.data);
    } catch (_) {
      payload = message.data.entries.map((e) => '${e.key}: ${e.value}').join(', ');
    }

    // Используем notification объект, или fallback на data поля (data-only FCM messages)
    final displayTitle = message.notification?.title 
        ?? message.data['title'] as String? 
        ?? 'Osekky';
    final displayBody = message.notification?.body 
        ?? message.data['body'] as String? 
        ?? message.data['text'] as String? 
        ?? '';

    AppLogger.info('[FCM] foreground: title=$displayTitle body=$displayBody type=${message.data["type"]}', tag: 'FirebaseNotification');

    final androidDetails = AndroidNotificationDetails(
      channelId,
      channelName,
      channelDescription: channelDesc,
      importance: Importance.max,
      priority: Priority.max,
      color: const Color(0xFF3390EC),
      icon: '@drawable/ic_notification',
      ticker: 'Osekky',
      groupKey: groupKey,
      category: notifType == 'chat_message' ? AndroidNotificationCategory.message : AndroidNotificationCategory.social,
      styleInformation: BigTextStyleInformation(
        displayBody,
        htmlFormatBigText: true,
        contentTitle: displayTitle,
        htmlFormatContentTitle: true,
      ),
    );
    
    final iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
      threadIdentifier: groupKey,
    );
    
    final details = NotificationDetails(android: androidDetails, iOS: iosDetails);
    
    await _localNotifications.show(
      message.hashCode,
      displayTitle,
      displayBody,
      details,
      payload: payload,
    );
  }
  
  /// Клик на локальное уведомление
  static void _onNotificationTapped(NotificationResponse response) {
    AppLogger.info('Local notification tapped: ${response.payload}', 
                   tag: 'FirebaseNotification');
    
    if (response.payload != null) {
      try {
        // BUG-020: парсим через jsonDecode — UUID с дефисами работают корректно
        final decoded = jsonDecode(response.payload!);
        if (decoded is Map<String, dynamic> && decoded.isNotEmpty) {
          _navigateByType(decoded);
        } else {
          navigatorKey.currentState?.pushNamed('/activity');
        }
      } catch (e) {
        AppLogger.error('Error parsing notification payload', tag: 'FirebaseNotification', error: e);
        navigatorKey.currentState?.pushNamed('/activity');
      }
    }
  }
  
  /// Обработка чат сообщения
  static Future<void> _handleChatMessage(RemoteMessage message) async {
    final data = message.data;
    
    if (data['type'] == 'chat_message') {
      final chatId = data['chat_id'];
      final senderName = data['sender_name'];
      
      // Навигация обработается через _navigateByType при тапе на уведомление
      AppLogger.info('Chat push received: $chatId from $senderName', tag: 'FirebaseNotification');
    }
  }
  
  /// Навигация по типу push-уведомления
  static void _navigateByType(Map<String, dynamic> data) {
    final type = data['type'] as String?;
    AppLogger.info('[NAV] Push tap: type=$type data=$data', tag: 'FirebaseNotification');

    // Если navigator ещё не готов (приложение запускается) — повторяем до 5 секунд
    if (navigatorKey.currentState == null) {
      AppLogger.warning('[NAV] Navigator ещё не готов, ждём...', tag: 'FirebaseNotification');
      _retryNavigationWithDelay(data, attempt: 0);
      return;
    }

    String? stringValue(List<String> keys) {
      for (final key in keys) {
        final value = data[key];
        if (value is String && value.isNotEmpty) return value;
      }
      return null;
    }

    switch (type) {
      case 'message':
      case 'chat_message':
        final otherUserId = stringValue(['other_user_id', 'otherUserId', 'sender_id', 'senderId']);
        if (otherUserId != null) {
          navigatorKey.currentState?.pushNamed('/chat', arguments: otherUserId);
        } else {
          navigatorKey.currentState?.pushNamed('/main');
        }
        break;

      case 'like':
      case 'comment_like':
      case 'comment':
      case 'reply':
      case 'repost':
      case 'mention':
        final postId = stringValue(['post_id', 'postId']);
        final commentId = stringValue(['comment_id', 'commentId']);
        if (postId != null) {
          navigatorKey.currentState?.pushNamed('/post', arguments: {
            'postId': postId,
            'commentId': commentId,
          });
        } else {
          navigatorKey.currentState?.pushNamed('/activity');
        }
        break;

      case 'follow':
      case 'follow_request':
        final fromUserId = stringValue(['from_user_id', 'fromUserId', 'actor_id', 'actorId']);
        if (fromUserId != null) {
          navigatorKey.currentState?.pushNamed('/user', arguments: fromUserId);
        } else {
          navigatorKey.currentState?.pushNamed('/activity');
        }
        break;

      case 'debate_comment':
      case 'debate_reply':
      case 'debate_vote':
      case 'debate_like':
        final discussionId = stringValue(['discussion_id', 'discussionId', 'post_id', 'postId']);
        final debateCommentId = stringValue(['comment_id', 'commentId']);
        if (discussionId != null) {
          navigatorKey.currentState?.pushNamed('/debate', arguments: {
            'discussionId': discussionId,
            'commentId': debateCommentId,
          });
        } else {
          navigatorKey.currentState?.pushNamed('/activity');
        }
        break;

      default:
        // Неизвестный тип — переходим на вкладку активности
        navigatorKey.currentState?.pushNamed('/activity');
        break;
    }
  }
  
  /// Повторная попытка навигации если navigator ещё не готов
  static void _retryNavigationWithDelay(Map<String, dynamic> data, {required int attempt}) {
    if (attempt >= 10) {
      AppLogger.error('[NAV] Navigator так и не стал доступен после 5 секунд', tag: 'FirebaseNotification');
      return;
    }
    Future.delayed(const Duration(milliseconds: 500), () {
      if (navigatorKey.currentState != null) {
        AppLogger.info('[NAV] Navigator готов (attempt=$attempt), выполняем навигацию', tag: 'FirebaseNotification');
        _navigateByType(data);
      } else {
        _retryNavigationWithDelay(data, attempt: attempt + 1);
      }
    });
  }

  /// Отправка тестового уведомления (для отладки)
  static Future<void> sendTestNotification() async {
    const androidDetails = AndroidNotificationDetails(
      'test_channel',
      'Test Notifications',
      channelDescription: 'Test notifications for debugging',
      importance: Importance.high,
      priority: Priority.high,
    );
    
    const details = NotificationDetails(android: androidDetails);
    
    await _localNotifications.show(
      DateTime.now().millisecondsSinceEpoch.remainder(100000),
      'Test Notification',
      'Firebase notifications are working!',
      details,
    );
  }
  
  /// Отправка тестового чат уведомления
  static Future<void> sendTestChatNotification() async {
    final androidDetails = AndroidNotificationDetails(
      'chat_messages',
      'Chat Messages',
      channelDescription: 'Notifications for new chat messages',
      importance: Importance.high,
      priority: Priority.high,
      color: const Color(0xFF3390EC),
      icon: '@drawable/ic_notification',
      largeIcon: const DrawableResourceAndroidBitmap('@mipmap/ic_launcher'),
      styleInformation: const BigTextStyleInformation(
        'Тестовое сообщение от пользователя',
        htmlFormatBigText: true,
        contentTitle: 'Новое сообщение',
        htmlFormatContentTitle: true,
      ),
    );
    
    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );
    
    final details = NotificationDetails(android: androidDetails, iOS: iosDetails);
    
    await _localNotifications.show(
      DateTime.now().millisecondsSinceEpoch.remainder(100000),
      'Новое сообщение',
      'Тестовое сообщение от пользователя',
      details,
      payload: '{"type": "chat_message", "chat_id": "test"}',
    );
  }
}
