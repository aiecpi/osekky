import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_core/firebase_core.dart';
// import 'package:flutter_app_badger/flutter_app_badger.dart'; // Временно отключен

import '../main.dart' show navigatorKey;
import '../utils/logger.dart';

// Обработчик фоновых уведомлений (приложение закрыто/в фоне)
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  AppLogger.info('[BG] Push получен: type=${message.data["type"]}, id=${message.messageId}', tag: 'NotificationService');
  // Android показывает системное уведомление автоматически через FCM notification payload
  // iOS тоже — ничего дополнительного не требуется для оффлайн/бэкграунд
}

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  FirebaseMessaging? _firebaseMessaging;
  final FlutterLocalNotificationsPlugin _localNotifications = FlutterLocalNotificationsPlugin();
  
  bool _initialized = false;
  String? _fcmToken;
  
  String? get fcmToken => _fcmToken;

  // Инициализация сервиса уведомлений
  Future<void> initialize() async {
    if (_initialized) return;

    try {
      // Инициализация локальных уведомлений (работает всегда)
      await _initializeLocalNotifications();
      
      // Используем уже инициализированный Firebase (initializeApp вызывается в FirebaseNotificationService)
      try {
        if (Firebase.apps.isEmpty) {
          await Firebase.initializeApp();
        }
        _firebaseMessaging = FirebaseMessaging.instance;
      } catch (e) {
        AppLogger.warning('Firebase недоступен, но локальные уведомления работают', tag: 'NotificationService', error: e);
        _initialized = true;
        return;
      }

      if (_firebaseMessaging == null) {
        AppLogger.warning('FirebaseMessaging недоступен, но локальные уведомления работают', tag: 'NotificationService');
        _initialized = true;
        return;
      }

      // Запрос разрешений
      NotificationSettings settings = await _firebaseMessaging!.requestPermission(
        alert: true,
        badge: true,
        sound: true,
        provisional: false,
      );

      if (settings.authorizationStatus == AuthorizationStatus.authorized) {
        AppLogger.success('Разрешение на уведомления получено', tag: 'NotificationService');
        
        // Получаем FCM токен
        _fcmToken = await _firebaseMessaging!.getToken();
        AppLogger.info('FCM Token получен', tag: 'NotificationService');
        
        // НЕ вешаем FirebaseMessaging.onMessage — это делает FirebaseNotificationService
        // Здесь только локальные уведомления уже инициализированы в _initializeLocalNotifications
        
        _initialized = true;
      } else {
        AppLogger.warning('Разрешение на уведомления отклонено', tag: 'NotificationService');
        _initialized = true;
      }
    } catch (e, st) {
      AppLogger.error('Ошибка инициализации уведомлений', tag: 'NotificationService', error: e, stackTrace: st);
    }
  }

  // Инициализация локальных уведомлений
  Future<void> _initializeLocalNotifications() async {
    const AndroidInitializationSettings androidSettings = AndroidInitializationSettings('@drawable/ic_notification');
    
    const DarwinInitializationSettings iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    const InitializationSettings settings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    await _localNotifications.initialize(
      settings,
      onDidReceiveNotificationResponse: _onNotificationTapped,
    );

    await _localNotifications
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(const AndroidNotificationChannel(
          'activity_notifications',
          'Activity Notifications',
          description: 'Likes, comments, follows and other activity notifications',
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

    await _localNotifications
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(const AndroidNotificationChannel(
          'osekky_channel',
          'Osekky Notifications',
          description: 'General Osekky notifications',
          importance: Importance.max,
          playSound: true,
        ));
  }

  // Данные последнего нажатого уведомления для обработки в UI
  Map<String, dynamic>? _pendingNotificationData;
  Map<String, dynamic>? get pendingNotificationData => _pendingNotificationData;
  
  // Очистить pending данные после обработки
  void clearPendingNotification() {
    _pendingNotificationData = null;
  }
  
  // Публичный метод навигации (используется из SplashScreen для pending уведомлений)
  void navigateToScreen(Map<String, dynamic> data) => _navigateToScreen(data);

  // Навигация к экрану в зависимости от типа уведомления
  void _navigateToScreen(Map<String, dynamic> data) {
    final type = data['type']?.toString();
    AppLogger.info('[NAV] Tap на уведомление: type=$type data=$data', tag: 'NotificationService');

    String? strVal(List<String> keys) {
      for (final k in keys) {
        final v = data[k]?.toString();
        if (v != null && v.isNotEmpty) return v;
      }
      return null;
    }

    final nav = navigatorKey.currentState;
    if (nav == null) {
      // Сохраняем для обработки после запуска и ждём готовности
      _pendingNotificationData = data;
      AppLogger.warning('[NAV] Navigator не готов — сохранено в pending, ждём...', tag: 'NotificationService');
      _retryNavigationWithDelay(data, attempt: 0);
      return;
    }

    AppLogger.info('[NAV] Данные для навигации: $data', tag: 'NotificationService');
    
    switch (type) {
      case 'chat_message':
      case 'message':
        final otherId = strVal(['other_user_id', 'otherUserId', 'sender_id', 'senderId']);
        if (otherId != null) {
          AppLogger.info('[NAV] Переход в чат с $otherId', tag: 'NotificationService');
          nav.pushNamed('/chat', arguments: otherId);
        } else {
          AppLogger.warning('[NAV] otherId не найден для chat_message, переход на main', tag: 'NotificationService');
          nav.pushNamed('/main');
        }
        break;
      case 'like':
      case 'comment_like':
      case 'comment':
      case 'reply':
      case 'repost':
      case 'mention':
        final postId = strVal(['post_id', 'postId']);
        final commentId = strVal(['comment_id', 'commentId']);
        if (postId != null) {
          AppLogger.info('[NAV] Переход на пост $postId (коммент: $commentId)', tag: 'NotificationService');
          nav.pushNamed('/post', arguments: {'postId': postId, 'commentId': commentId});
        } else {
          AppLogger.warning('[NAV] postId не найден для $type, переход на activity', tag: 'NotificationService');
          nav.pushNamed('/activity');
        }
        break;
      case 'follow':
      case 'follow_request':
        final fromId = strVal(['from_user_id', 'fromUserId', 'actor_id', 'actorId']);
        if (fromId != null) {
          AppLogger.info('[NAV] Переход на профиль $fromId', tag: 'NotificationService');
          nav.pushNamed('/user', arguments: fromId);
        } else {
          AppLogger.warning('[NAV] fromId не найден для follow, переход на activity', tag: 'NotificationService');
          nav.pushNamed('/activity');
        }
        break;
      case 'debate_comment':
      case 'debate_reply':
      case 'debate_like':
      case 'debate_vote':
        final discussionId = strVal(['discussion_id', 'discussionId', 'post_id', 'postId']);
        final debateCommentId = strVal(['comment_id', 'commentId']);
        if (discussionId != null) {
          AppLogger.info('[NAV] Переход на дебат $discussionId (коммент: $debateCommentId)', tag: 'NotificationService');
          nav.pushNamed('/debate', arguments: {'discussionId': discussionId, 'commentId': debateCommentId});
        } else {
          AppLogger.warning('[NAV] discussionId не найден для $type, переход на activity', tag: 'NotificationService');
          nav.pushNamed('/activity');
        }
        break;
      default:
        AppLogger.warning('[NAV] Неизвестный тип $type, переход на activity', tag: 'NotificationService');
        nav.pushNamed('/activity');
    }
  }

  // Обработка нажатия на локальное уведомление
  void _onNotificationTapped(NotificationResponse response) {
    AppLogger.info('Нажатие на локальное уведомление: ${response.payload}', tag: 'NotificationService');
    
    if (response.payload != null && response.payload!.isNotEmpty) {
      try {
        final decoded = jsonDecode(response.payload!) as Map<String, dynamic>;
        if (decoded.isNotEmpty) {
          _navigateToScreen(decoded);
        }
      } catch (e) {
        AppLogger.error('Ошибка парсинга payload уведомления', tag: 'NotificationService', error: e);
      }
    }
  }

  // Повторная попытка навигации если navigator ещё не готов
  void _retryNavigationWithDelay(Map<String, dynamic> data, {required int attempt}) {
    if (attempt >= 10) return;
    Future.delayed(const Duration(milliseconds: 500), () {
      if (navigatorKey.currentState != null) {
        AppLogger.info('[NAV] Navigator готов (attempt=$attempt)', tag: 'NotificationService');
        _pendingNotificationData = null;
        _navigateToScreen(data);
      } else {
        _retryNavigationWithDelay(data, attempt: attempt + 1);
      }
    });
  }

  // Показать локальное уведомление
  Future<void> showLocalNotification({
    required String title,
    required String body,
    String? payload,
    String channelId = 'activity_notifications',
    String channelName = 'Activity Notifications',
    String channelDescription = 'Likes, comments, follows and other activity notifications',
    String? groupKey,
    String? threadIdentifier,
  }) async {
    // Определяем категорию по channelId
    final isChat = channelId == 'chat_messages';
    final category = isChat
        ? AndroidNotificationCategory.message
        : AndroidNotificationCategory.social;

    // Формируем payload строку — нужен JSON если это Map
    final payloadStr = payload;

    AppLogger.info('[NOTIF] showLocalNotification: title=$title ch=$channelId', tag: 'NotificationService');

    final androidDetails = AndroidNotificationDetails(
      channelId,
      channelName,
      channelDescription: channelDescription,
      importance: Importance.max,
      priority: Priority.max,
      showWhen: true,
      icon: '@drawable/ic_notification',
      color: const Color(0xFF1976D2),
      ticker: 'Osekky',
      groupKey: groupKey ?? (isChat ? 'osekky_chat' : 'osekky_activity'),
      category: category,
      styleInformation: BigTextStyleInformation(
        body,
        htmlFormatBigText: true,
        contentTitle: title,
        htmlFormatContentTitle: true,
      ),
    );

    final iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
      threadIdentifier: threadIdentifier ?? (isChat ? 'chat' : 'activity'),
    );

    final details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    await _localNotifications.show(
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
      title,
      body,
      details,
      payload: payloadStr,
    );
  }

  // Отправить тестовое уведомление (для разработки)
  Future<void> sendTestNotification() async {
    await showLocalNotification(
      title: '🎉 Тестовое уведомление',
      body: 'Push-уведомления работают!',
    );
  }

  // Подписаться на топик
  Future<void> subscribeToTopic(String topic) async {
    if (_firebaseMessaging == null) return;
    await _firebaseMessaging!.subscribeToTopic(topic);
    AppLogger.success('Подписка на топик: $topic', tag: 'NotificationService');
  }

  // Отписаться от топика
  Future<void> unsubscribeFromTopic(String topic) async {
    if (_firebaseMessaging == null) return;
    await _firebaseMessaging!.unsubscribeFromTopic(topic);
    AppLogger.success('Отписка от топика: $topic', tag: 'NotificationService');
  }

  // Обновить FCM токен
  Future<void> refreshToken() async {
    if (_firebaseMessaging == null) return;
    _fcmToken = await _firebaseMessaging!.getToken();
    AppLogger.info('FCM Token обновлен: $_fcmToken', tag: 'NotificationService');
  }

  // Очистить все уведомления
  Future<void> clearAllNotifications() async {
    await _localNotifications.cancelAll();
  }

  // BUG-003: Установить бейдж (iOS и Android)
  Future<void> setBadgeCount(int count) async {
    try {
      // Временно отключено из-за проблем с flutter_app_badger
      AppLogger.info('Badge функциональность временно отключена: $count', tag: 'NotificationService');
    } catch (e) {
      AppLogger.error('Ошибка установки badge: $e', tag: 'NotificationService');
    }
  }
  
  // Сбросить бейдж
  Future<void> clearBadge() async {
    await setBadgeCount(0);
  }
}
