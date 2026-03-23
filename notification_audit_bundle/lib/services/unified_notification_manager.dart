import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'notification_service.dart';
import 'in_app_notification_service.dart';
import 'push_notification_service.dart';
import '../widgets/beautiful_notification_v2.dart';
import '../utils/logger.dart';

/// 🎯 ЕДИНАЯ ЦЕНТРАЛИЗОВАННАЯ СИСТЕМА УПРАВЛЕНИЯ ВСЕМИ УВЕДОМЛЕНИЯМИ
/// 
/// Управляет:
/// - Push-уведомлениями (в шторке Android/iOS)
/// - In-App уведомлениями (внутри приложения)
/// - Всеми событиями: лайки, комментарии, сообщения, подписчики
/// 
/// Использование:
/// ```dart
/// // Простые уведомления
/// Notify.success(context, 'Готово!');
/// Notify.error(context, 'Ошибка');
/// 
/// // События
/// Notify.newLike(context, userName: 'Иван', postId: '123');
/// Notify.newComment(context, userName: 'Мария', commentText: 'Отлично!');
/// Notify.newMessage(context, userName: 'Петр', messageText: 'Привет!');
/// ```
class UnifiedNotificationManager {
  static final UnifiedNotificationManager _instance = UnifiedNotificationManager._internal();
  factory UnifiedNotificationManager() => _instance;
  UnifiedNotificationManager._internal();

  final NotificationService _pushService = NotificationService();
  final InAppNotificationService _inAppService = InAppNotificationService();
  final PushNotificationService _pushNotificationService = PushNotificationService();
  
  BuildContext? _context;
  bool _initialized = false;

  /// Инициализация системы уведомлений
  Future<void> initialize(BuildContext context) async {
    if (_initialized) return;
    
    _context = context;
    _inAppService.setContext(context);
    
    try {
      // НЕ инициализируем NotificationService здесь - это делает FirebaseNotificationService
      // await _pushService.initialize();
      _initialized = true;
      AppLogger.success('Unified Notification Manager инициализирован', tag: 'NotificationManager');
    } catch (e) {
      AppLogger.error('Ошибка инициализации Notification Manager', tag: 'NotificationManager', error: e);
    }
  }

  /// Установить контекст
  void setContext(BuildContext context) {
    _context = context;
    _inAppService.setContext(context);
  }

  /// Установить текущий открытый чат (чтобы не показывать уведомления для него)
  void setCurrentChat(String? chatId) {
    _inAppService.setCurrentOpenChat(chatId);
  }

  /// Установить текущий экран
  void setCurrentScreen(String? screenName) {
    _inAppService.setCurrentOpenScreen(screenName);
  }

  // ==================== ПРОСТЫЕ УВЕДОМЛЕНИЯ ====================

  /// ✅ Успех
  void success(BuildContext context, String message, {String? subtitle, bool showPush = false}) {
    BeautifulNotificationV2.showSuccess(
      context: context,
      message: message,
      subtitle: subtitle,
    );
    HapticFeedback.lightImpact();
    
    if (showPush) {
      _pushService.sendTestNotification();
    }
  }

  /// ❌ Ошибка
  void error(BuildContext context, String message, {String? subtitle}) {
    BeautifulNotificationV2.showError(
      context: context,
      message: message,
      subtitle: subtitle,
    );
    HapticFeedback.mediumImpact();
  }

  /// ℹ️ Информация
  void info(BuildContext context, String message, {String? subtitle}) {
    BeautifulNotificationV2.showInfo(
      context: context,
      message: message,
      subtitle: subtitle,
    );
    HapticFeedback.lightImpact();
  }

  /// ⚠️ Предупреждение
  void warning(BuildContext context, String message, {String? subtitle}) {
    BeautifulNotificationV2.showWarning(
      context: context,
      message: message,
      subtitle: subtitle,
    );
    HapticFeedback.mediumImpact();
  }

  // ==================== СПЕЦИАЛЬНЫЕ СОБЫТИЯ ====================

  /// 👋 После входа в систему
  void welcome(BuildContext context, String userName) {
    BeautifulNotificationV2.showInfo(
      context: context,
      message: 'Добро пожаловать, $userName!',
      subtitle: 'Вы успешно вошли в систему',
    );
    HapticFeedback.mediumImpact();
    AppLogger.info('Показано приветствие для $userName', tag: 'NotificationManager');
  }

  /// ✅ После публикации контента
  void published(BuildContext context, String type) {
    String typeText = '';
    String icon = '';
    
    switch (type) {
      case 'story':
        typeText = 'Story';
        icon = '📸';
        break;
      case 'discussion':
        typeText = 'обсуждение';
        icon = '💬';
        break;
      case 'post':
        typeText = 'пост';
        icon = '📝';
        break;
      default:
        typeText = 'контент';
        icon = '✅';
    }
    
    BeautifulNotificationV2.showSuccess(
      context: context,
      message: '$icon $typeText опубликован!',
      subtitle: 'Ваш контент теперь доступен другим пользователям',
    );
    HapticFeedback.lightImpact();
    AppLogger.info('Показано уведомление о публикации: $type', tag: 'NotificationManager');
  }

  
  // ==================== СОЦИАЛЬНЫЕ СОБЫТИЯ ====================

  /// Новый лайк на пост
  void newLike(
    BuildContext context, {
    required String userName,
    required String postId,
    String? recipientId,
    String? avatarUrl,
    VoidCallback? onTap,
    bool showInApp = true,
    bool showPush = true,
  }) {
    if (showInApp) {
      BeautifulNotificationV2.showLike(
        context: context,
        userName: userName,
        avatarUrl: avatarUrl,
        onTap: onTap,
      );
    }
    
    if (showPush && recipientId != null) {
      // Отправляем push-уведомление
      _pushNotificationService.sendLikeNotification(
        recipientId: recipientId,
        senderName: userName,
        postId: postId,
      );
    }
    
    AppLogger.info('Новый лайк от $userName', tag: 'NotificationManager');
  }

  /// Новый комментарий
  void newComment(
    BuildContext context, {
    required String userName,
    required String commentText,
    required String postId,
    String? commentId,
    String? avatarUrl,
    VoidCallback? onTap,
    bool showInApp = true,
    bool showPush = false,
  }) {
    if (showInApp) {
      BeautifulNotificationV2.showComment(
        context: context,
        userName: userName,
        commentText: commentText,
        avatarUrl: avatarUrl,
        onTap: onTap,
      );
    }
    
    AppLogger.info('Новый комментарий от $userName', tag: 'NotificationManager');
  }

  /// ↩️ Ответ на комментарий
  void commentReply(
    BuildContext context, {
    required String userName,
    required String replyText,
    required String postId,
    String? commentId,
    String? avatarUrl,
    VoidCallback? onTap,
    bool showInApp = true,
  }) {
    if (showInApp) {
      BeautifulNotificationV2.showCommentReply(
        context: context,
        userName: userName,
        replyText: replyText,
        avatarUrl: avatarUrl,
        onTap: onTap,
      );
    }
    
    AppLogger.info('Ответ на комментарий от $userName', tag: 'NotificationManager');
  }

  /// 💬 Новое сообщение в чате
  void newMessage(
    BuildContext context, {
    required String userName,
    required String messageText,
    required String chatId,
    String? senderId,
    String? recipientId,
    String? avatarUrl,
    VoidCallback? onTap,
    bool showInApp = true,
    bool showPush = false,
  }) {
    if (showInApp) {
      BeautifulNotificationV2.showMessage(
        context: context,
        userName: userName,
        messageText: messageText,
        avatarUrl: avatarUrl,
        onTap: onTap,
      );
    }

    if (showPush && recipientId != null && senderId != null) {
      _pushNotificationService.sendChatNotification(
        recipientId: recipientId,
        senderName: userName,
        messageText: messageText,
        chatId: chatId,
        otherUserId: senderId,
      );
    }
    
    AppLogger.info('Новое сообщение от $userName', tag: 'NotificationManager');
  }

  /// 👤 Новый подписчик
  void newFollower(
    BuildContext context, {
    required String userName,
    required String followerId,
    String? recipientId,
    String? avatarUrl,
    VoidCallback? onTap,
    bool showInApp = true,
    bool showPush = false,
  }) {
    if (showInApp) {
      BeautifulNotificationV2.showFollower(
        context: context,
        userName: userName,
        avatarUrl: avatarUrl,
        onTap: onTap,
      );
    }

    if (showPush && recipientId != null) {
      _pushNotificationService.sendFollowerNotification(
        recipientId: recipientId,
        followerName: userName,
        followerId: followerId,
      );
    }
    
    AppLogger.info('Новый подписчик: $userName', tag: 'NotificationManager');
  }

  /// 🔥 Новый дебат
  void newDebate(
    BuildContext context, {
    required String userName,
    required String debateTitle,
    required String debateId,
    String? avatarUrl,
    VoidCallback? onTap,
    bool showInApp = true,
  }) {
    if (showInApp) {
      BeautifulNotificationV2.showDebate(
        context: context,
        userName: userName,
        debateTitle: debateTitle,
        avatarUrl: avatarUrl,
        onTap: onTap,
      );
    }
    
    AppLogger.info('Новый дебат от $userName', tag: 'NotificationManager');
  }

  /// 💭 Комментарий в дебате
  void debateComment(
    BuildContext context, {
    required String userName,
    required String commentText,
    required String debateId,
    String? avatarUrl,
    VoidCallback? onTap,
    bool showInApp = true,
  }) {
    if (showInApp) {
      BeautifulNotificationV2.showDebateComment(
        context: context,
        userName: userName,
        commentText: commentText,
        avatarUrl: avatarUrl,
        onTap: onTap,
      );
    }
    
    AppLogger.info('Комментарий в дебате от $userName', tag: 'NotificationManager');
  }

  /// @ Упоминание
  void mention(
    BuildContext context, {
    required String userName,
    required String text,
    String? avatarUrl,
    VoidCallback? onTap,
    bool showInApp = true,
  }) {
    if (showInApp) {
      BeautifulNotificationV2.showWithAvatar(
        context: context,
        userName: userName,
        message: 'упомянул вас',
        subtitle: text,
        avatarUrl: avatarUrl,
        icon: Icons.alternate_email_rounded,
        color: BeautifulNotificationV2.primaryColor,
        onTap: onTap,
      );
    }
    
    AppLogger.info('Упоминание от $userName', tag: 'NotificationManager');
  }

  // ==================== СИСТЕМНЫЕ УВЕДОМЛЕНИЯ ====================

  /// ⚙️ Системное уведомление
  void system(BuildContext context, String title, String message) {
    if (_context != null) {
      _inAppService.showSystemNotification(
        title: title,
        body: message,
      );
    }
  }

  /// 🔔 Получить FCM токен
  String? get fcmToken => _pushService.fcmToken;

  /// 🔕 Очистить все уведомления
  void clearAll() {
    // Очистка будет реализована позже
    AppLogger.info('Очистка всех уведомлений', tag: 'NotificationManager');
  }
}

/// 🎯 ГЛОБАЛЬНЫЙ ДОСТУП К УВЕДОМЛЕНИЯМ
/// 
/// Простой API для использования в любом месте приложения:
/// ```dart
/// Notify.success(context, 'Готово!');
/// Notify.newLike(context, userName: 'Иван', postId: '123');
/// ```
class Notify {
  static final UnifiedNotificationManager _manager = UnifiedNotificationManager();

  // Простые уведомления
  static void success(BuildContext context, String message, {String? subtitle}) =>
      _manager.success(context, message, subtitle: subtitle);
  
  static void error(BuildContext context, String message, {String? subtitle}) =>
      _manager.error(context, message, subtitle: subtitle);
  
  static void info(BuildContext context, String message, {String? subtitle}) =>
      _manager.info(context, message, subtitle: subtitle);
  
  static void warning(BuildContext context, String message, {String? subtitle}) =>
      _manager.warning(context, message, subtitle: subtitle);
  
  // Специальные события
  static void welcome(BuildContext context, String userName) =>
      _manager.welcome(context, userName);
  
  static void published(BuildContext context, String type) =>
      _manager.published(context, type);

  // Социальные события
  static void newLike(BuildContext context, {required String userName, required String postId, String? avatarUrl, VoidCallback? onTap}) =>
      _manager.newLike(context, userName: userName, postId: postId, avatarUrl: avatarUrl, onTap: onTap);
  
  static void newComment(BuildContext context, {required String userName, required String commentText, required String postId, String? avatarUrl, VoidCallback? onTap}) =>
      _manager.newComment(context, userName: userName, commentText: commentText, postId: postId, avatarUrl: avatarUrl, onTap: onTap);
  
  static void commentReply(BuildContext context, {required String userName, required String replyText, required String postId, String? avatarUrl, VoidCallback? onTap}) =>
      _manager.commentReply(context, userName: userName, replyText: replyText, postId: postId, avatarUrl: avatarUrl, onTap: onTap);
  
  static void newMessage(BuildContext context, {required String userName, required String messageText, required String chatId, String? senderId, String? recipientId, String? avatarUrl, VoidCallback? onTap}) =>
      _manager.newMessage(context, userName: userName, messageText: messageText, chatId: chatId, senderId: senderId, recipientId: recipientId, avatarUrl: avatarUrl, onTap: onTap);
  
  static void newFollower(BuildContext context, {required String userName, required String followerId, String? recipientId, String? avatarUrl, VoidCallback? onTap}) =>
      _manager.newFollower(context, userName: userName, followerId: followerId, recipientId: recipientId, avatarUrl: avatarUrl, onTap: onTap);
  
  static void newDebate(BuildContext context, {required String userName, required String debateTitle, required String debateId, String? avatarUrl, VoidCallback? onTap}) =>
      _manager.newDebate(context, userName: userName, debateTitle: debateTitle, debateId: debateId, avatarUrl: avatarUrl, onTap: onTap);
  
  static void debateComment(BuildContext context, {required String userName, required String commentText, required String debateId, String? avatarUrl, VoidCallback? onTap}) =>
      _manager.debateComment(context, userName: userName, commentText: commentText, debateId: debateId, avatarUrl: avatarUrl, onTap: onTap);

  // Утилиты
  static void setContext(BuildContext context) => _manager.setContext(context);
  static void setCurrentChat(String? chatId) => _manager.setCurrentChat(chatId);
  static void setCurrentScreen(String? screenName) => _manager.setCurrentScreen(screenName);
  static Future<void> initialize(BuildContext context) => _manager.initialize(context);
}
