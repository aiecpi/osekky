import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../app_state.dart';
import '../services/in_app_notification_service.dart';
import 'notifications_screen.dart';
import 'chats_screen.dart';
import '../l10n/app_localizations.dart';

class ActivityScreenNew extends StatefulWidget {
  final ScrollController? scrollController;
  
  const ActivityScreenNew({super.key, this.scrollController});

  @override
  State<ActivityScreenNew> createState() => _ActivityScreenNewState();
}

class _ActivityScreenNewState extends State<ActivityScreenNew> {
  int _selectedTab = 0; // 0 - notifications, 1 - messages

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    super.dispose();
  }

  // Вызывается из MainScreen, когда пользователь открыл вкладку "Активность"
  void onActivated() {
    if (!mounted) return;
    setState(() {
      _selectedTab = 0;
    });

    InAppNotificationService().setCurrentOpenScreen('notifications');
    final appState = context.read<AppState>();
    appState.loadNotifications();
  }

  void _selectTab(int index) {
    if (_selectedTab == index) return;
    final appState = context.read<AppState>();
    setState(() {
      _selectedTab = index;
    });

    if (index == 0) {
      InAppNotificationService().setCurrentOpenScreen('notifications');
      appState.loadNotifications();
    } else {
      InAppNotificationService().setCurrentOpenScreen('chats');
      if (!appState.hasLoadedChats) {
        appState.loadChats();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, appState, _) {
        final unreadNotifications = appState.unreadNotificationsCount;
        final unreadMessages = appState.unreadMessagesCount;
        
        return Scaffold(
          backgroundColor: Colors.white,
          body: Column(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                color: const Color(0xFF003e70),
                child: Row(
                  children: [
                    Expanded(
                      child: _ActivityTabButton(
                        label: AppLocalizations.of(context).notifications,
                        count: unreadNotifications,
                        selected: _selectedTab == 0,
                        onTap: () => _selectTab(0),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _ActivityTabButton(
                        label: AppLocalizations.of(context).messages,
                        count: unreadMessages,
                        selected: _selectedTab == 1,
                        onTap: () => _selectTab(1),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: _selectedTab == 0
                      ? const NotificationsScreen(
                          key: ValueKey('notifications_tab'),
                          scrollController: null,
                          embedded: true,
                        )
                      : const ChatsScreen(
                          key: ValueKey('messages_tab'),
                          scrollController: null,
                        ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ActivityTabButton extends StatelessWidget {
  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  const _ActivityTabButton({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
        decoration: BoxDecoration(
          // Выбранный: белый фон, невыбранный: синий фон
          color: selected ? Colors.white : const Color(0xFF003e70),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: const Color(0xFF003e70),
            width: 1,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                // Выбранный: синий текст, невыбранный: белый текст
                color: selected ? const Color(0xFF003e70) : Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (count > 0) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: selected ? const Color(0xFF003e70) : Colors.white,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFF003e70)),
                ),
                child: Text(
                  '$count',
                  style: TextStyle(
                    color: selected ? Colors.white : const Color(0xFF003e70),
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
