import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../app_state.dart';
import '../l10n/app_localizations.dart';
import '../services/in_app_notification_service.dart';
import '../services/app_update_service.dart';
import '../services/notification_service.dart';
import '../services/unified_notification_manager.dart';
import 'home_screen.dart';
import 'search_screen.dart';
import 'hot_feed_screen_variant5.dart';
import 'profile_screen.dart';
import 'activity_screen_new.dart';
import 'settings_screen.dart';
import 'my_activity_screen.dart';
import 'create_content_menu.dart';

class MainScreen extends StatefulWidget {
  final int initialIndex;

  const MainScreen({super.key, this.initialIndex = 0});
  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _currentIndex = 0;
  final ScrollController _homeScrollController = ScrollController();
  final ScrollController _profileScrollController = ScrollController();
  final ScrollController _activityScrollController = ScrollController();
  final ScrollController _hotFeedScrollController = ScrollController();
  final ScrollController _discussionsScrollController = ScrollController();
  final GlobalKey _activityScreenKey = GlobalKey();
  final GlobalKey _homeScreenKey = GlobalKey();
  final GlobalKey _discussionsScreenKey = GlobalKey();
  final GlobalKey _profileScreenKey = GlobalKey();
  
  // Метод для скролла к началу главной ленты
  void scrollHomeToTop() {
    if (_homeScrollController.hasClients) {
      _homeScrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    
    // Инициализируем контекст для In-App уведомлений после первого кадра
    WidgetsBinding.instance.addPostFrameCallback((_) {
      InAppNotificationService().setContext(context);
      
      // Инициализируем единую систему уведомлений
      Notify.initialize(context);
      _handlePendingNotificationNavigation();
      
      // Проверяем обновления
      _checkForUpdates();
      
      // Устанавливаем начальный экран
      switch (_currentIndex) {
        case 0:
          InAppNotificationService().setCurrentOpenScreen('home');
          break;
        case 1:
          InAppNotificationService().setCurrentOpenScreen('discussions');
          break;
        case 3:
          InAppNotificationService().setCurrentOpenScreen('notifications');
          break;
        case 4:
          InAppNotificationService().setCurrentOpenScreen('profile');
          break;
      }
    });
  }

  void _handlePendingNotificationNavigation() {
    final notificationService = NotificationService();
    final pending = notificationService.pendingNotificationData;
    if (pending == null || pending.isEmpty || !mounted) {
      return;
    }

    notificationService.clearPendingNotification();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      final type = pending['type']?.toString();
      final postId = pending['post_id']?.toString();
      final commentId = pending['comment_id']?.toString();
      final userId = pending['user_id']?.toString();
      final senderId = pending['sender_id']?.toString();

      switch (type) {
        case 'message':
        case 'chat_message':
          final chatUserId = senderId ?? userId;
          if (chatUserId != null && chatUserId.isNotEmpty) {
            Navigator.of(context).pushNamed('/chat', arguments: chatUserId);
          }
          break;
        case 'like':
        case 'comment':
        case 'reply':
        case 'repost':
          if (postId != null && postId.isNotEmpty) {
            Navigator.of(context).pushNamed('/post', arguments: {
              'postId': postId,
              'commentId': commentId,
            });
          }
          break;
        case 'follow':
        case 'follow_request':
          final profileUserId = userId ?? senderId;
          if (profileUserId != null && profileUserId.isNotEmpty) {
            Navigator.of(context).pushNamed('/user', arguments: profileUserId);
          }
          break;
      }
    });
  }

  Future<void> _checkForUpdates() async {
    final updateService = AppUpdateService();
    final hasUpdate = await updateService.checkForUpdate();
    if (hasUpdate && mounted) {
      updateService.showUpdateDialog(context);
    }
  }

  @override
  void dispose() {
    _homeScrollController.dispose();
    _activityScrollController.dispose();
    _profileScrollController.dispose();
    _hotFeedScrollController.dispose();
    _discussionsScrollController.dispose();
    super.dispose();
  }

  void _onItemTapped(int index) {
    if (index == 2) {
      // Центральная кнопка - показать меню выбора
      showModalBottomSheet(
        context: context,
        backgroundColor: Colors.transparent,
        isScrollControlled: true,
        builder: (context) => const CreateContentMenu(),
      );
      return;
    }
    
    // Устанавливаем текущий экран для уведомлений
    switch (index) {
      case 0:
        InAppNotificationService().setCurrentOpenScreen('home');
        break;
      case 1:
        InAppNotificationService().setCurrentOpenScreen('discussions');
        break;
      case 3:
        InAppNotificationService().setCurrentOpenScreen('notifications');
        break;
      case 4:
        InAppNotificationService().setCurrentOpenScreen('profile');
        break;
    }
    
    // Если нажали на тот же таб → scroll to top + refresh
    if (_currentIndex == index) {
      _scrollToTopAndRefresh(index);
    }
    
    if (mounted) {
      setState(() {
        _currentIndex = index;
      });
    }

    // ProfileScreen теперь использует AutomaticKeepAliveClientMixin и сам управляет загрузкой данных
    // Принудительный вызов refreshData() больше не нужен

    // Если открыли вкладку "Активность" — сообщаем экрану, чтобы очистить бейдж только там
    if (index == 3) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final st = _activityScreenKey.currentState;
        try {
          (st as dynamic)?.onActivated();
        } catch (_) {}
      });
    }
  }
  
  void _scrollToTopAndRefresh(int index) {
    switch (index) {
      case 0: // Главная
        if (_homeScrollController.hasClients) {
          _homeScrollController.animateTo(
            0,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        }
        // Обновляем ленту
        final appState = Provider.of<AppState>(context, listen: false);
        appState.refreshFeed();
        break;
      case 1: // Обсуждения
        if (_discussionsScrollController.hasClients) {
          _discussionsScrollController.animateTo(
            0,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        }
        // Обновляем обсуждения
        final appState = Provider.of<AppState>(context, listen: false);
        appState.loadDiscussions(force: true);
        break;
      case 3: // Активность
        if (_activityScrollController.hasClients) {
          _activityScrollController.animateTo(
            0,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        }
        // Обновляем уведомления
        final appState = Provider.of<AppState>(context, listen: false);
        appState.loadNotifications();
        break;
      case 4: // Профиль
        if (_profileScrollController.hasClients) {
          _profileScrollController.animateTo(
            0,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        }
        // ProfileScreen использует AutomaticKeepAliveClientMixin и сам управляет обновлениями
        // Дополнительное обновление не требуется
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 60,
        title: Image.asset(
          'assets/images/logo_with_text.png',
          height: 80,
          color: Colors.white,
          fit: BoxFit.contain,
        ),
        actions: _currentIndex == 4
            ? [
                // Настройки на странице профиля
                IconButton(
                  icon: const Icon(Icons.settings_outlined),
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const SettingsScreen(),
                      ),
                    );
                  },
                ),
              ]
            : _currentIndex == 1
                ? [
                    // Моя активность (только на вкладке "Обсуждения")
                    IconButton(
                      icon: const Icon(Icons.history),
                      tooltip: AppLocalizations.of(context).myActivity,
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => const MyActivityScreen(),
                          ),
                        );
                      },
                    ),
                    // Поиск
                    IconButton(
                      icon: const Icon(Icons.search),
                      onPressed: () {
                        showModalBottomSheet(
                          context: context,
                          isScrollControlled: true,
                          backgroundColor: Colors.transparent,
                          builder: (context) => DraggableScrollableSheet(
                            initialChildSize: 0.95,
                            minChildSize: 0.5,
                            maxChildSize: 0.95,
                            builder: (context, scrollController) => Container(
                              decoration: BoxDecoration(
                                color: Theme.of(context).scaffoldBackgroundColor,
                                borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                              ),
                              child: const SearchScreen(embedded: true),
                            ),
                          ),
                        );
                      },
                    ),
                  ]
                : [
                    // Поиск
                    IconButton(
                      icon: const Icon(Icons.search),
                      onPressed: () {
                        showModalBottomSheet(
                          context: context,
                          isScrollControlled: true,
                          backgroundColor: Colors.transparent,
                          builder: (context) => DraggableScrollableSheet(
                            initialChildSize: 0.95,
                            minChildSize: 0.5,
                            maxChildSize: 0.95,
                            builder: (context, scrollController) => Container(
                              decoration: BoxDecoration(
                                color: Theme.of(context).scaffoldBackgroundColor,
                                borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                              ),
                              child: const SearchScreen(embedded: true),
                            ),
                          ),
                        );
                      },
                    ),
                  ],
      ),
      body: PageStorage(
        bucket: PageStorageBucket(),
        child: IndexedStack(
          index: _currentIndex,
          children: [
            HomeScreen(key: _homeScreenKey, scrollController: _homeScrollController),
            HotFeedScreenVariant5(key: _discussionsScreenKey),
            const SizedBox.shrink(), // Placeholder для центральной кнопки
            ActivityScreenNew(key: _activityScreenKey, scrollController: _activityScrollController),
            ProfileScreen(key: _profileScreenKey, scrollController: _profileScrollController),
          ],
        ),
      ),
      bottomNavigationBar: Consumer<AppState>(
        builder: (context, appState, child) {
          return BottomNavigationBar(
            type: BottomNavigationBarType.fixed,
            currentIndex: _currentIndex,
            selectedItemColor: const Color(0xFF003e70),
            unselectedItemColor: Colors.grey[600],
            backgroundColor: Colors.white,
            selectedFontSize: 12,
            unselectedFontSize: 11,
            onTap: _onItemTapped,
            items: [
              BottomNavigationBarItem(
                icon: const Icon(Icons.home_outlined),
                activeIcon: const Icon(Icons.home),
                label: AppLocalizations.of(context).home,
              ),
              BottomNavigationBarItem(
                icon: const Icon(Icons.forum_outlined),
                activeIcon: const Icon(Icons.forum),
                label: AppLocalizations.of(context).debates,
              ),
              BottomNavigationBarItem(
                icon: const Icon(Icons.add_circle_outline, size: 32),
                activeIcon: const Icon(Icons.add_circle, size: 32),
                label: AppLocalizations.of(context).create,
              ),
              BottomNavigationBarItem(
                icon: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    const Icon(Icons.favorite_outline),
                    if (appState.unreadNotificationsCount + appState.unreadMessagesCount > 0)
                      Positioned(
                        right: -6,
                        top: -4,
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: const BoxDecoration(
                            color: Colors.red,
                            shape: BoxShape.circle,
                          ),
                          constraints: const BoxConstraints(
                            minWidth: 18,
                            minHeight: 18,
                          ),
                          child: Text(
                            '${appState.unreadNotificationsCount + appState.unreadMessagesCount}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                  ],
                ),
                activeIcon: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    const Icon(Icons.favorite),
                    if (appState.unreadNotificationsCount + appState.unreadMessagesCount > 0)
                      Positioned(
                        right: -6,
                        top: -4,
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: const BoxDecoration(
                            color: Colors.red,
                            shape: BoxShape.circle,
                          ),
                          constraints: const BoxConstraints(
                            minWidth: 18,
                            minHeight: 18,
                          ),
                          child: Text(
                            '${appState.unreadNotificationsCount + appState.unreadMessagesCount}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                  ],
                ),
                label: AppLocalizations.of(context).activity,
              ),
              BottomNavigationBarItem(
                icon: const Icon(Icons.person_outline),
                activeIcon: const Icon(Icons.person),
                label: AppLocalizations.of(context).profile,
              ),
            ],
          );
        },
      ),
    );
  }
}
