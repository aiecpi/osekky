import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:visibility_detector/visibility_detector.dart';
import '../widgets/user_avatar.dart';
import '../app_state.dart';
import '../models.dart';
import '../components/empty_state_widget.dart';
import 'user_profile_screen.dart';
import 'comments_screen.dart';
import 'premium_screen.dart';
import 'discussion_detail_screen.dart';
import '../l10n/app_localizations.dart';

class NotificationsScreen extends StatefulWidget {
  final bool embedded;
  final ScrollController? scrollController;
  
  const NotificationsScreen({super.key, this.embedded = false, this.scrollController});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> with WidgetsBindingObserver {
  final ScrollController _internalScrollController = ScrollController();
  bool _isScreenVisible = false;
  Timer? _markAllReadTimer;
  bool _markAllReadRequested = false;
  DateTime? _lastRefreshAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Загружаем свежие уведомления при каждом открытии экрана
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshNotificationsIfNeeded(force: true);
    });
    _internalScrollController.addListener(_onScroll);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshNotificationsIfNeeded(force: true);
    }
  }

  Future<void> _refreshNotificationsIfNeeded({bool force = false}) async {
    if (!mounted) return;
    final appState = Provider.of<AppState>(context, listen: false);
    if (appState.isNotificationsLoading) return;

    final now = DateTime.now();
    if (!force && _lastRefreshAt != null && now.difference(_lastRefreshAt!) < const Duration(seconds: 2)) {
      return;
    }

    _lastRefreshAt = now;
    await appState.loadNotifications();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _markAllReadTimer?.cancel();
    _internalScrollController.removeListener(_onScroll);
    _internalScrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    final controller = widget.scrollController ?? _internalScrollController;
    if (!controller.hasClients) return;
    final position = controller.position;
    if (position.pixels >= position.maxScrollExtent - 200) {
      final appState = context.read<AppState>();
      if (!appState.isLoadingMoreNotifications && appState.hasMoreNotifications) {
        appState.loadMoreNotifications();
      }
    }
  }

  ScrollController get _controller => widget.scrollController ?? _internalScrollController;

  @override
  Widget build(BuildContext context) {
    return VisibilityDetector(
      key: const Key('notifications_screen_visibility'),
      onVisibilityChanged: (info) {
        final visible = info.visibleFraction > 0.6;
        if (visible == _isScreenVisible) return;
        if (!mounted) return;
        setState(() {
          _isScreenVisible = visible;
        });

        _markAllReadTimer?.cancel();
        if (!visible) {
          _markAllReadRequested = false;
          return;
        }
        unawaited(_refreshNotificationsIfNeeded());
        // markAllRead убран — пользователь сам нажимает на каждое уведомление
        // чтобы пометить его прочитанным. Auto-read стирал badge преждевременно.
      },
      child: Consumer<AppState>(
        builder: (context, appState, _) {
          final notifications = appState.filteredNotifications;
          
          return Scaffold(
          backgroundColor: Colors.white,
          appBar: !widget.embedded ? AppBar(
            backgroundColor: Colors.white,
            elevation: 0,
            title: Text(
              AppLocalizations.of(context).notifications,
              style: const TextStyle(
                color: Color(0xFF003e70),
                fontWeight: FontWeight.bold,
              ),
            ),
          ) : null,
          body: RefreshIndicator(
            onRefresh: () async {
              final messenger = ScaffoldMessenger.of(context);
              final errText = AppLocalizations.of(context).notificationsError;
              try {
                await appState.loadNotifications();
              } catch (e) {
                if (mounted) {
                  messenger.showSnackBar(
                    SnackBar(
                      content: Text(errText),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              }
            },
            child: (notifications.isEmpty && (appState.isNotificationsLoading || appState.isOffline))
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 12),
                        Text(AppLocalizations.of(context).loadingText),
                      ],
                    ),
                  )
                : ListView.builder(
                    controller: _controller,
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.only(bottom: 16),
                    itemCount: (notifications.isEmpty ? 1 : notifications.length + 1) + (appState.hasMoreNotifications ? 1 : 0),
                    cacheExtent: 500, // Оптимизация: предзагрузка элементов
                    itemBuilder: (context, index) {
                      if (index == 0) {
                        return _buildFilterChips(appState);
                      }

                      final dataIndex = index - 1;
                      if (dataIndex >= notifications.length) {
                        if (!appState.hasMoreNotifications) {
                          return notifications.isEmpty
                              ? SizedBox(
                                  height: MediaQuery.of(context).size.height * 0.4,
                                  child: _buildEmptyState(context),
                                )
                              : const SizedBox.shrink();
                        }
                        return const Padding(
                          padding: EdgeInsets.symmetric(vertical: 24),
                          child: Center(child: CircularProgressIndicator()),
                        );
                      }

                      final notification = notifications[dataIndex];
                      return _buildNotificationItem(context, appState, notification);
                    },
                  ),
          ),
          );
        },
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    return EmptyStateWidget(
      icon: Icons.notifications_none,
      title: AppLocalizations.of(context).noNotifications,
      subtitle: AppLocalizations.of(context).translate('no_notifications_subtitle'),
    );
  }

  Widget _buildNotificationItem(BuildContext context, AppState appState, AppNotification notification) {
    return Dismissible(
      key: Key(notification.id),
      direction: DismissDirection.endToStart,
      background: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.red[400],
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.red.withValues(alpha: 0.2),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        child: const Icon(Icons.delete_outline, color: Colors.white, size: 24),
      ),
      confirmDismiss: (_) async {
        final beforeCount = appState.filteredNotifications.length;
        await appState.deleteNotification(notification.id);
        if (!context.mounted) return false;

        final deleted = appState.filteredNotifications.length < beforeCount;
        if (!deleted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(AppLocalizations.of(context).translate('try_again')),
              backgroundColor: Colors.red,
            ),
          );
        }

        return deleted;
      },
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4), // Уменьшил vertical с 6 до 4
        decoration: BoxDecoration(
          color: notification.isRead ? Colors.white : const Color(0xFF003e70).withValues(alpha: 0.03),
          borderRadius: BorderRadius.circular(12), // Уменьшил с 16 до 12
          border: Border.all(
            color: notification.isRead ? Colors.grey[100]! : const Color(0xFF003e70).withValues(alpha: 0.15),
            width: 1, // Уменьшил с 1.5 до 1
          ),
          boxShadow: [
            BoxShadow(
              color: notification.isRead 
                  ? Colors.grey.withValues(alpha: 0.04) // Уменьшил с 0.05 до 0.04
                  : const Color(0xFF003e70).withValues(alpha: 0.06), // Уменьшил с 0.08 до 0.06
              blurRadius: notification.isRead ? 2 : 4, // Уменьшил с 8 до 4
              offset: const Offset(0, 1), // Уменьшил с 2 до 1
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(12), // Уменьшил с 16 до 12
            splashColor: const Color(0xFF003e70).withValues(alpha: 0.05),
            highlightColor: const Color(0xFF003e70).withValues(alpha: 0.05),
            onTap: () async {
              appState.markNotificationAsRead(notification.id);
              await _handleNotificationTap(context, appState, notification);
            },
            child: VisibilityDetector(
              key: Key('notif_vis_${notification.id}'),
              onVisibilityChanged: (info) {
                if (!notification.isRead && info.visibleFraction > 0.8) {
                  Future.delayed(const Duration(seconds: 2), () {
                    if (mounted && !notification.isRead) {
                      appState.markNotificationAsRead(notification.id);
                    }
                  });
                }
              },
              child: Padding(
                padding: const EdgeInsets.all(12), // Уменьшил с 16 до 12
                child: Row(
                  children: [
                    // Аватар пользователя (кликабельный)
                    _buildLeadingIcon(notification),
                    const SizedBox(width: 12), // Уменьшил с 14 до 12
                    // Контент
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            Provider.of<AppState>(context, listen: false).getLocalizedNotificationTitleByType(context, notification.type),
                            style: TextStyle(
                              fontSize: 14, // Уменьшил с 16 до 14
                              fontWeight: notification.isRead ? FontWeight.w600 : FontWeight.bold,
                              color: notification.isRead ? Colors.grey[700] : const Color(0xFF003e70),
                              letterSpacing: -0.1, // Уменьшил с -0.2 до -0.1
                            ),
                          ),
                          const SizedBox(height: 4), // Уменьшил с 6 до 4
                          _buildMessageText(context, notification),
                          const SizedBox(height: 6), // Уменьшил с 8 до 6
                          Text(
                            _formatTime(context, notification.createdAt),
                            style: TextStyle(
                              fontSize: 12, // Уменьшил с 13 до 12
                              color: Colors.grey[500],
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    // Индикатор непрочитанного
                    if (!notification.isRead)
                      Container(
                        width: 8, // Уменьшил с 10 до 8
                        height: 8, // Уменьшил с 10 до 8
                        decoration: BoxDecoration(
                          color: const Color(0xFF003e70),
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF003e70).withValues(alpha: 0.3),
                              blurRadius: 2, // Уменьшил с 4 до 2
                              offset: const Offset(0, 1),
                            ),
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
    );
  }

  Future<void> _handleNotificationTap(BuildContext context, AppState appState, AppNotification notification) async {
    switch (notification.type) {
      case NotificationType.like:
      case NotificationType.commentLike:
      case NotificationType.comment:
      case NotificationType.mention:
      case NotificationType.repost:
        // Переход к посту
        final postId = (notification.relatedId ?? '').trim();
        if (postId.isNotEmpty) {
          final story = await _resolveStoryForPostId(appState, postId);
          if (story == null) return;

          // Если это репост, открываем оригинальный пост
          final storyToOpen = story.quotedStory ?? story;
          if (!context.mounted) return;
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => CommentsScreen(
                story: storyToOpen,
                commentId: notification.commentId,
              ),
            ),
          );
        }
        break;
      
      case NotificationType.follow:
        if (notification.fromUser != null) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => UserProfileScreen(user: notification.fromUser!),
            ),
          );
        }
        break;
      
      case NotificationType.reply:
        final postId = (notification.relatedId ?? '').trim();
        if (postId.isNotEmpty) {
          final story = await _resolveStoryForPostId(appState, postId);
          if (story == null) return;

          final storyToOpen = story.quotedStory ?? story;
          if (!context.mounted) return;
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => CommentsScreen(
                story: storyToOpen,
                commentId: notification.commentId,
              ),
            ),
          );
        }
        break;
      
      case NotificationType.system:
        final relatedId = (notification.relatedId ?? '').trim();
        if (relatedId.isNotEmpty) {
          final story = await _resolveStoryForPostId(appState, relatedId);
          if (story != null) {
            if (!context.mounted) return;
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => CommentsScreen(
                  story: story,
                  commentId: notification.commentId,
                ),
              ),
            );
            break;
          }
        }
        showDialog(
          context: context,
          builder: (_) => AlertDialog(
            title: Text(notification.title),
            content: Text(notification.message),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(AppLocalizations.of(context).closeButton),
              ),
            ],
          ),
        );
        break;
      
      case NotificationType.premium:
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const PremiumScreen()),
        );
        break;
      
      case NotificationType.community:
        final messenger = ScaffoldMessenger.maybeOf(context);
        messenger?.showSnackBar(
          SnackBar(
            content: Text(
              notification.relatedId != null
                  ? AppLocalizations.of(context).translate('community_coming_soon')
                  : AppLocalizations.of(context).translate('community_feature_in_progress'),
            ),
          ),
        );
        break;
      
      // Уведомления для дебатов - открываем дебат
      case NotificationType.debateComment:
      case NotificationType.debateReply:
      case NotificationType.debateLike:
      case NotificationType.debateVote:
        if (notification.relatedId != null) {
          var discussion = appState.discussions.cast<Discussion?>().firstWhere(
            (d) => d?.id == notification.relatedId,
            orElse: () => null,
          );
          discussion ??= appState.allDiscussions.cast<Discussion?>().firstWhere(
            (d) => d?.id == notification.relatedId,
            orElse: () => null,
          );
          // Если не в кеше — загружаем из БД
          if (discussion == null) {
            discussion = await appState.fetchDiscussionById(notification.relatedId!);
          }
          if (discussion != null && context.mounted) {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => DiscussionDetailScreen(
                  discussion: discussion!,
                  scrollToCommentId: notification.commentId,
                ),
              ),
            );
          }
        }
        break;
      
      case NotificationType.emailChange:
        // Для уведомлений о смене email не делаем переход - просто показываем
        break;
      
      default:
        break;
    }
  }

  Future<Story?> _resolveStoryForPostId(AppState appState, String postId) async {
    try {
      final cached = appState.stories.where((s) => s.id == postId).toList();
      if (cached.isNotEmpty) return cached.first;
      return await appState.fetchStoryById(postId);
    } catch (_) {
      return null;
    }
  }

  IconData _getNotificationIcon(NotificationType type) {
    switch (type) {
      case NotificationType.like:
        return Icons.favorite;
      case NotificationType.commentLike:
        return Icons.favorite;
      case NotificationType.comment:
        return Icons.chat_bubble;
      case NotificationType.reply:
        return Icons.reply;
      case NotificationType.follow:
        return Icons.person_add;
      case NotificationType.mention:
        return Icons.alternate_email;
      case NotificationType.repost:
        return Icons.repeat;
      case NotificationType.system:
        return Icons.info;
      case NotificationType.premium:
        return Icons.star;
      case NotificationType.community:
        return Icons.group;
      // Иконки для дебатов
      case NotificationType.debateComment:
        return Icons.how_to_vote;
      case NotificationType.debateReply:
        return Icons.forum;
      case NotificationType.debateLike:
        return Icons.thumb_up;
      case NotificationType.debateVote:
        return Icons.how_to_vote;
      case NotificationType.emailChange:
        return Icons.email;
    }
  }

  Color _getNotificationColor(NotificationType type) {
    switch (type) {
      case NotificationType.like:
        return Colors.red;
      case NotificationType.commentLike:
        return Colors.red;
      case NotificationType.comment:
        return Colors.blue;
      case NotificationType.reply:
        return Colors.green;
      case NotificationType.follow:
        return const Color(0xFF003e70);
      case NotificationType.mention:
        return Colors.purple;
      case NotificationType.repost:
        return Colors.orange;
      case NotificationType.system:
        return Colors.grey;
      case NotificationType.premium:
        return Colors.amber;
      case NotificationType.community:
        return Colors.teal;
      // Цвета для дебатов (темно-синий как основной цвет дебатов)
      case NotificationType.debateComment:
        return const Color(0xFF1565C0);
      case NotificationType.debateReply:
        return const Color(0xFF1565C0);
      case NotificationType.debateLike:
        return const Color(0xFF1565C0);
      case NotificationType.debateVote:
        return const Color(0xFF1565C0);
      case NotificationType.emailChange:
        return const Color(0xFF003e70);
    }
  }

  Widget _buildLeadingIcon(AppNotification notification) {
    // Проверяем, это сгруппированное уведомление
    final isGrouped = notification.isGrouped;
    
    if (isGrouped && notification.actors != null && notification.actors!.isNotEmpty) {
      // Показываем несколько аватаров для сгруппированных уведомлений
      final actors = notification.actors!;
      final displayCount = actors.length > 3 ? 3 : actors.length;
      
      return SizedBox(
        width: 40,
        height: 40,
        child: Stack(
          children: [
            // Показываем до 3 аватаров
            for (int i = 0; i < displayCount; i++)
              Positioned(
                left: i * 10.0,
                top: 0,
                child: Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.white, width: 2),
                    shape: BoxShape.circle,
                  ),
                  child: UserAvatar(
                    imageUrl: actors[i].avatar,
                    displayName: actors[i].name,
                    radius: 15,
                  ),
                ),
              ),
            // Иконка типа уведомления
            Positioned(
              right: -4,
              bottom: -4,
              child: Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  color: _getNotificationColor(notification.type),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                  boxShadow: [
                    BoxShadow(
                      color: _getNotificationColor(notification.type).withValues(alpha: 0.2),
                      blurRadius: 4,
                      offset: const Offset(0, 1),
                    ),
                  ],
                ),
                child: Icon(
                  _getNotificationIcon(notification.type),
                  color: Colors.white,
                  size: 14,
                ),
              ),
            ),
          ],
        ),
      );
    }
    
    if (notification.fromUser != null &&
        notification.type != NotificationType.system &&
        notification.type != NotificationType.premium &&
        notification.type != NotificationType.community) {
      return GestureDetector(
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => UserProfileScreen(user: notification.fromUser!),
            ),
          );
        },
        child: Stack(
          children: [
            UserAvatar(
              imageUrl: notification.fromUser!.avatar,
              displayName: notification.fromUser!.name,
              radius: 20, // Уменьшил с 26 до 20
            ),
            Positioned(
              right: -4,
              bottom: -4,
              child: Container(
                padding: const EdgeInsets.all(3), // Уменьшил с 5 до 3
                decoration: BoxDecoration(
                  color: _getNotificationColor(notification.type),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2), // Уменьшил с 2.5 до 2
                  boxShadow: [
                    BoxShadow(
                      color: _getNotificationColor(notification.type).withValues(alpha: 0.2),
                      blurRadius: 4, // Уменьшил с 8 до 4
                      offset: const Offset(0, 1), // Уменьшил с 2 до 1
                    ),
                  ],
                ),
                child: Icon(
                  _getNotificationIcon(notification.type),
                  color: Colors.white,
                  size: 14, // Уменьшил с 18 до 14
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      width: 40, // Уменьшил с 52 до 40
      height: 40, // Уменьшил с 52 до 40
      decoration: BoxDecoration(
        color: _getNotificationColor(notification.type).withValues(alpha: 0.1),
        shape: BoxShape.circle,
        border: Border.all(
          color: _getNotificationColor(notification.type).withValues(alpha: 0.2),
          width: 1, // Уменьшил с 1.5 до 1
        ),
        boxShadow: [
          BoxShadow(
            color: _getNotificationColor(notification.type).withValues(alpha: 0.1),
            blurRadius: 4, // Уменьшил с 8 до 4
            offset: const Offset(0, 1), // Уменьшил с 2 до 1
          ),
        ],
      ),
      child: Icon(
        _getNotificationIcon(notification.type),
        color: _getNotificationColor(notification.type),
        size: 20, // Уменьшил с 26 до 20
      ),
    );
  }

  Widget _buildMessageText(BuildContext context, AppNotification notification) {
    final appState = Provider.of<AppState>(context, listen: false);
    final typeString = appState.notificationTypeToString(notification.type);
    final localizedMessage = appState.getLocalizedNotificationMessage(
      context, 
      typeString, 
      notification.message,
      commentText: notification.commentText,
    );
    
    // Проверяем, это сгруппированное уведомление
    final isGrouped = notification.isGrouped;
    
    if (isGrouped) {
      // Показываем сгруппированное сообщение
      return Text(
        localizedMessage,
        style: TextStyle(
          fontSize: 13,
          color: notification.isRead ? Colors.grey[600] : Colors.grey[700],
          fontWeight: notification.isRead ? FontWeight.w500 : FontWeight.w600,
          height: 1.2,
        ),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      );
    }
    
    if (notification.type == NotificationType.system ||
        notification.type == NotificationType.premium ||
        notification.type == NotificationType.community) {
      return Text(
        AppLocalizations.of(context).translate(localizedMessage),
        style: TextStyle(
          fontSize: 13, // Уменьшил с 15 до 13
          color: notification.isRead ? Colors.grey[600] : Colors.grey[700],
          fontWeight: notification.isRead ? FontWeight.w500 : FontWeight.w600,
          height: 1.2, // Уменьшил с 1.3 до 1.2
        ),
        maxLines: 2, // Уменьшил с 3 до 2
        overflow: TextOverflow.ellipsis,
      );
    }

    final senderName = notification.fromUser?.name ?? '';
    final hasCommentText = notification.commentText != null && notification.commentText!.isNotEmpty;
    
    // Формируем текст сообщения с текстом комментария
    String messageText = localizedMessage;
    if (hasCommentText && (notification.type == NotificationType.comment || notification.type == NotificationType.reply)) {
      final truncatedComment = _truncateCommentText(notification.commentText!);
      messageText = '${messageText.replaceAll(': $truncatedComment', '')}: $truncatedComment';
    }
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        RichText(
          text: TextSpan(
            children: [
              TextSpan(
                text: senderName,
                style: TextStyle(
                  fontSize: 13,
                  color: notification.isRead ? Colors.grey[600] : const Color(0xFF003e70),
                  fontWeight: notification.isRead ? FontWeight.w600 : FontWeight.bold,
                ),
              ),
              TextSpan(
                text: ' $messageText',
                style: TextStyle(
                  fontSize: 13,
                  color: notification.isRead ? Colors.grey[500] : Colors.grey[600],
                  fontWeight: FontWeight.w500,
                  height: 1.2,
                ),
              ),
            ],
          ),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }

  String _truncateCommentText(String text) {
    if (text.length <= 35) {
      return text;
    }
    return '${text.substring(0, 35)}...';
  }

  String _formatTime(BuildContext context, DateTime dateTime) {
    final l10n = AppLocalizations.of(context);
    final now = DateTime.now();
    final difference = now.difference(dateTime);
    
    if (difference.inMinutes < 1) {
      return l10n.translate('just_now');
    } else if (difference.inMinutes < 60) {
      return '${difference.inMinutes} ${l10n.translate('minutes_ago')}';
    } else if (difference.inHours < 24) {
      return '${difference.inHours} ${l10n.translate('hours_ago')}';
    } else if (difference.inDays < 7) {
      return '${difference.inDays} ${l10n.translate('days_ago')}';
    } else {
      return '${dateTime.day}.${dateTime.month}.${dateTime.year}';
    }
  }

  Widget _buildFilterChips(AppState appState) {
    final l10n = AppLocalizations.of(context);
    final labels = <String, String>{
      'all': l10n.all,
      NotificationType.like.name: l10n.likes,
      NotificationType.commentLike.name: l10n.commentLikes,
      NotificationType.comment.name: l10n.comments,
      NotificationType.follow.name: l10n.subscriptions,
      NotificationType.mention.name: l10n.mentions,
    };
    final current = appState.notificationFilter ?? 'all';

    return SizedBox(
      height: 48,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        scrollDirection: Axis.horizontal,
        itemBuilder: (context, index) {
          final entry = labels.entries.elementAt(index);
          final selected = entry.key == current;
          return GestureDetector(
            onTap: () =>
                appState.setNotificationFilter(entry.key == 'all' ? null : entry.key),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeInOut,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
              decoration: BoxDecoration(
                color: selected ? const Color(0xFF003e70) : Colors.white,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: selected ? const Color(0xFF003e70) : Colors.grey.shade300,
                  width: 1,
                ),
                boxShadow: selected
                    ? [
                        BoxShadow(
                          color: const Color(0xFF003e70).withValues(alpha: 0.12),
                          blurRadius: 4,
                          offset: const Offset(0, 1),
                        ),
                      ]
                    : null,
              ),
              child: Text(
                entry.value,
                style: TextStyle(
                  color: selected ? Colors.white : const Color(0xFF003e70),
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
              ),
            ),
          );
        },
        separatorBuilder: (_, __) => const SizedBox(width: 5),
        itemCount: labels.length,
      ),
    );
  }
}

