import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';

/// Красивые уведомления для iOS и Android (одинаковый дизайн)
class BeautifulNotification {
  static OverlayEntry? _currentOverlay;
  static bool _isShowing = false;

  /// Типы уведомлений
  static const Color successColor = Color(0xFF4CAF50);
  static const Color errorColor = Color(0xFFF44336);
  static const Color infoColor = Color(0xFF2196F3);
  static const Color warningColor = Color(0xFFFF9800);
  static const Color premiumColor = Color(0xFF2196F3);

  /// Показать уведомление об успехе
  static void showSuccess(BuildContext context, String message, {String? subtitle}) {
    _show(
      context,
      title: AppLocalizations.of(context).translate('success'),
      message: message,
      subtitle: subtitle,
      icon: Icons.check_circle_rounded,
      color: successColor,
    );
  }

  /// Показать уведомление об ошибке
  static void showError(BuildContext context, String message, {String? subtitle}) {
    _show(
      context,
      title: AppLocalizations.of(context).translate('error'),
      message: message,
      subtitle: subtitle,
      icon: Icons.error_rounded,
      color: errorColor,
    );
  }

  /// Показать информационное уведомление
  static void showInfo(BuildContext context, String message, {String? subtitle}) {
    _show(
      context,
      title: AppLocalizations.of(context).translate('information'),
      message: message,
      subtitle: subtitle,
      icon: Icons.info_rounded,
      color: infoColor,
    );
  }

  /// Показать предупреждение
  static void showWarning(BuildContext context, String message, {String? subtitle}) {
    _show(
      context,
      title: AppLocalizations.of(context).translate('warning'),
      message: message,
      subtitle: subtitle,
      icon: Icons.warning_rounded,
      color: warningColor,
    );
  }

  /// Показать премиум уведомление
  static void showPremium(BuildContext context, String message, {String? subtitle}) {
    _show(
      context,
      title: 'Premium',
      message: message,
      subtitle: subtitle,
      icon: Icons.verified_rounded,
      color: premiumColor,
      isPremium: true,
    );
  }

  /// Показать уведомление после входа
  static void showWelcome(BuildContext context, String userName) {
    _show(
      context,
      title: AppLocalizations.of(context).translate('welcome'),
      message: userName,
      subtitle: AppLocalizations.of(context).translate('glad_to_see_you'),
      icon: Icons.waving_hand_rounded,
      color: successColor,
    );
  }

  /// Показать уведомление после публикации
  static void showPublished(BuildContext context, String type) {
    String message;
    String subtitle;
    
    switch (type) {
      case 'story':
        message = AppLocalizations.of(context).translate('post_published');
        subtitle = AppLocalizations.of(context).translate('post_visible_to_all');
        break;
      case 'discussion':
        message = AppLocalizations.of(context).translate('discussion_created');
        subtitle = AppLocalizations.of(context).translate('start_discussion_now');
        break;
      case 'comment':
        message = AppLocalizations.of(context).translate('comment_added');
        subtitle = AppLocalizations.of(context).translate('comment_published');
        break;
      default:
        message = AppLocalizations.of(context).translate('published');
        subtitle = AppLocalizations.of(context).translate('content_created');
    }
    
    _show(
      context,
      title: message,
      message: subtitle,
      icon: Icons.check_circle_rounded,
      color: successColor,
    );
  }

  /// Основной метод показа уведомления
  static void _show(
    BuildContext context, {
    required String title,
    required String message,
    String? subtitle,
    required IconData icon,
    required Color color,
    bool isPremium = false,
    Duration duration = const Duration(seconds: 3),
  }) {
    // Если уже показывается, скрываем предыдущее
    if (_isShowing) {
      _hideNotification();
    }

    _isShowing = true;

    _currentOverlay = OverlayEntry(
      builder: (context) => _NotificationWidget(
        title: title,
        message: message,
        subtitle: subtitle,
        icon: icon,
        color: color,
        isPremium: isPremium,
        onDismiss: _hideNotification,
      ),
    );

    Overlay.of(context).insert(_currentOverlay!);

    // Автоматически скрываем
    Future.delayed(duration, () {
      _hideNotification();
    });
  }

  /// Скрыть текущее уведомление
  static void _hideNotification() {
    _currentOverlay?.remove();
    _currentOverlay = null;
    _isShowing = false;
  }
}

/// Виджет уведомления
class _NotificationWidget extends StatefulWidget {
  final String title;
  final String message;
  final String? subtitle;
  final IconData icon;
  final Color color;
  final bool isPremium;
  final VoidCallback onDismiss;

  const _NotificationWidget({
    required this.title,
    required this.message,
    this.subtitle,
    required this.icon,
    required this.color,
    required this.isPremium,
    required this.onDismiss,
  });

  @override
  State<_NotificationWidget> createState() => _NotificationWidgetState();
}

class _NotificationWidgetState extends State<_NotificationWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<Offset> _slideAnimation;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 400),
      vsync: this,
    );

    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, -1.5),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutBack,
    ));

    _fadeAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOut,
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
      widget.onDismiss();
    });
  }

  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.of(context).padding.top;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Positioned(
      top: topPadding + 12,
      left: 16,
      right: 16,
      child: SlideTransition(
        position: _slideAnimation,
        child: FadeTransition(
          opacity: _fadeAnimation,
          child: GestureDetector(
            onVerticalDragEnd: (details) {
              if (details.primaryVelocity != null && details.primaryVelocity! < 0) {
                _dismiss();
              }
            },
            child: Container(
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.15),
                    blurRadius: 24,
                    offset: const Offset(0, 8),
                    spreadRadius: 0,
                  ),
                  BoxShadow(
                    color: widget.color.withValues(alpha: 0.1),
                    blurRadius: 16,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Цветная полоска сверху
                  Container(
                    height: 4,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          widget.color,
                          widget.color.withValues(alpha: 0.7),
                        ],
                      ),
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(20),
                        topRight: Radius.circular(20),
                      ),
                    ),
                  ),
                  // Основной контент
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        // Иконка
                        Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            gradient: widget.isPremium
                                ? const LinearGradient(
                                    colors: [Color(0xFF2196F3), Color(0xFF1976D2)],
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                  )
                                : LinearGradient(
                                    colors: [
                                      widget.color,
                                      widget.color.withValues(alpha: 0.8),
                                    ],
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                  ),
                            borderRadius: BorderRadius.circular(14),
                            boxShadow: [
                              BoxShadow(
                                color: widget.color.withValues(alpha: 0.3),
                                blurRadius: 8,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          child: Icon(
                            widget.icon,
                            color: Colors.white,
                            size: 24,
                          ),
                        ),
                        const SizedBox(width: 16),
                        // Текст
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                widget.title,
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: isDark ? Colors.white : Colors.black87,
                                  letterSpacing: -0.3,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                widget.message,
                                style: TextStyle(
                                  fontSize: 14,
                                  color: isDark ? Colors.white70 : Colors.black54,
                                  height: 1.3,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              if (widget.subtitle != null) ...[
                                const SizedBox(height: 2),
                                Text(
                                  widget.subtitle!,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: isDark ? Colors.white60 : Colors.black45,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        // Кнопка закрытия
                        GestureDetector(
                          onTap: _dismiss,
                          child: Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: isDark
                                  ? Colors.white.withValues(alpha: 0.1)
                                  : Colors.black.withValues(alpha: 0.05),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Icon(
                              Icons.close_rounded,
                              size: 16,
                              color: isDark ? Colors.white60 : Colors.black45,
                            ),
                          ),
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
    );
  }
}
