import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import '../utils/logger.dart';

class SimpleNotificationService {
  static final SimpleNotificationService _instance = SimpleNotificationService._internal();
  factory SimpleNotificationService() => _instance;
  SimpleNotificationService._internal();

  final FlutterLocalNotificationsPlugin _notifications = FlutterLocalNotificationsPlugin();
  String? _fcmToken;

  Future<void> initialize() async {
    // Инициализация локальных уведомлений
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidSettings);
    await _notifications.initialize(initSettings);

    // Настройка каналов
    const androidChannel = AndroidNotificationChannel(
      'osekky_notifications',
      'Osekky Уведомления',
      description: 'Основные уведомления приложения',
      importance: Importance.high,
    );
    
    await _notifications
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(androidChannel);

    // Инициализация Firebase
    await _initializeFirebase();
  }

  Future<void> _initializeFirebase() async {
    try {
      // Запрос разрешений
      await FirebaseMessaging.instance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );

      // Получение FCM токена
      _fcmToken = await FirebaseMessaging.instance.getToken();
      // Не логируем FCM токен для безопасности
      AppLogger.info('FCM Token получен', tag: 'SimpleNotificationService');

      // Обработка сообщений
      FirebaseMessaging.onMessage.listen(_handleForegroundMessage);
      FirebaseMessaging.onMessageOpenedApp.listen(_handleMessageOpenedApp);
    } catch (e) {
      AppLogger.error('Ошибка инициализации Firebase', tag: 'SimpleNotificationService', error: e);
    }
  }

  void _handleForegroundMessage(RemoteMessage message) {
    _showNotification(
      title: message.notification?.title ?? 'Новое уведомление',
      body: message.notification?.body ?? 'У вас новое уведомление',
    );
  }

  void _handleMessageOpenedApp(RemoteMessage message) {
    AppLogger.info('Открыто уведомление: ${message.notification?.title}', tag: 'SimpleNotificationService');
  }

  Future<void> _showNotification({
    required String title,
    required String body,
    String? payload,
  }) async {
    const androidDetails = AndroidNotificationDetails(
      'osekky_notifications',
      'Osekky Уведомления',
      channelDescription: 'Основные уведомления приложения',
      importance: Importance.high,
      priority: Priority.high,
      color: Color(0xFF2196F3),
      enableLights: true,
      enableVibration: true,
    );

    const details = NotificationDetails(android: androidDetails);

    await _notifications.show(
      DateTime.now().millisecondsSinceEpoch.remainder(100000),
      title,
      body,
      details,
      payload: payload,
    );
  }

  // Метод для отправки тестового уведомления
  Future<void> sendTestNotification() async {
    await _showNotification(
      title: '🎉 Тестовое уведомление',
      body: 'Osekky приложение работает отлично!',
      payload: 'test_notification',
    );
  }

  // Метод для уведомления о новом лайке
  Future<void> showLikeNotification(String userName) async {
    await _showNotification(
      title: '❤️ Новый лайк',
      body: '$userName лайкнул ваш пост',
      payload: 'like_notification',
    );
  }

  // Метод для уведомления о новом комментарии
  Future<void> showCommentNotification(String userName, String comment) async {
    await _showNotification(
      title: '💬 Новый комментарий',
      body: '$userName: $comment',
      payload: 'comment_notification',
    );
  }

  // Метод для уведомления о новом подписчике
  Future<void> showFollowerNotification(String userName) async {
    await _showNotification(
      title: '👤 Новый подписчик',
      body: '$userName подписался на вас',
      payload: 'follower_notification',
    );
  }

  // Метод для уведомления о новом сообщении
  Future<void> showMessageNotification(String userName, String message) async {
    await _showNotification(
      title: '💬 Новое сообщение',
      body: '$userName: $message',
      payload: 'message_notification',
    );
  }

  String? get fcmToken => _fcmToken;
}
