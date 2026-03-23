import 'package:supabase_flutter/supabase_flutter.dart';
import '../utils/logger.dart';

/// 🚀 Сервис для отправки push-уведомлений через Supabase
class PushNotificationService {
  static final PushNotificationService _instance = PushNotificationService._internal();
  factory PushNotificationService() => _instance;
  PushNotificationService._internal();

  final SupabaseClient _supabase = Supabase.instance.client;

  /// Отправить push-уведомление конкретному пользователю
  Future<bool> sendToUser({
    required String userId,
    required String title,
    required String body,
    Map<String, dynamic>? data,
  }) async {
    try {
      final response = await _supabase.functions.invoke(
        'send-push-notification',
        body: {
          'userId': userId,
          'title': title,
          'body': body,
          'data': data ?? {},
        },
      );

      if (response.status == 200) {
        AppLogger.success('Push-уведомление отправлено пользователю $userId', tag: 'PushNotification');
        return true;
      } else {
        AppLogger.error('Ошибка отправки push-уведомления: ${response.status}', tag: 'PushNotification');
        return false;
      }
    } catch (e) {
      AppLogger.error('Ошибка отправки push-уведомления', tag: 'PushNotification', error: e);
      return false;
    }
  }

  /// Отправить push-уведомление по FCM токену
  Future<bool> sendToToken({
    required String fcmToken,
    required String title,
    required String body,
    Map<String, dynamic>? data,
  }) async {
    try {
      final response = await _supabase.functions.invoke(
        'send-push-notification',
        body: {
          'fcmToken': fcmToken,
          'title': title,
          'body': body,
          'data': data ?? {},
        },
      );

      if (response.status == 200) {
        AppLogger.success('Push-уведомление отправлено на токен', tag: 'PushNotification');
        return true;
      } else {
        AppLogger.error('Ошибка отправки push-уведомления: ${response.status}', tag: 'PushNotification');
        return false;
      }
    } catch (e) {
      AppLogger.error('Ошибка отправки push-уведомления', tag: 'PushNotification', error: e);
      return false;
    }
  }

  /// Отправить уведомление о лайке
  Future<bool> sendLikeNotification({
    required String recipientId,
    required String senderName,
    required String postId,
    String? commentId,
  }) async {
    return await sendToUser(
      userId: recipientId,
      title: 'Новый лайк',
      body: commentId != null 
        ? '$senderName лайкнул(а) ваш комментарий'
        : '$senderName лайкнул(а) ваш пост',
      data: {
        'type': 'like',
        'post_id': postId,
        'comment_id': commentId,
      },
    );
  }

  /// Отправить уведомление о комментарии
  Future<bool> sendCommentNotification({
    required String recipientId,
    required String senderName,
    required String postId,
    required String commentText,
  }) async {
    return await sendToUser(
      userId: recipientId,
      title: 'Новый комментарий',
      body: '$senderName прокомментировал(а) ваш пост',
      data: {
        'type': 'comment',
        'post_id': postId,
        'comment_text': commentText,
      },
    );
  }

  /// Отправить уведомление о подписчике
  Future<bool> sendFollowerNotification({
    required String recipientId,
    required String followerName,
    String? followerId,
  }) async {
    return await sendToUser(
      userId: recipientId,
      title: 'Новый подписчик',
      body: '$followerName подписался(ась) на вас',
      data: {
        'type': 'follow',
        'from_user_id': followerId,
      },
    );
  }

  /// Отправить уведомление о сообщении в чате
  Future<bool> sendChatNotification({
    required String recipientId,
    required String senderName,
    required String messageText,
    required String chatId,
    String? otherUserId,
  }) async {
    return await sendToUser(
      userId: recipientId,
      title: 'Новое сообщение',
      body: '$senderName: ${messageText.length > 50 ? '${messageText.substring(0, 50)}...' : messageText}',
      data: {
        'type': 'chat_message',
        'chat_id': chatId,
        'sender_name': senderName,
        'other_user_id': otherUserId,
      },
    );
  }

  /// Отправить уведомление о упоминании
  Future<bool> sendMentionNotification({
    required String recipientId,
    required String senderName,
    required String text,
    required String postId,
  }) async {
    return await sendToUser(
      userId: recipientId,
      title: 'Упоминание',
      body: '$senderName упомянул вас',
      data: {
        'type': 'mention',
        'post_id': postId,
        'text': text,
      },
    );
  }
}
