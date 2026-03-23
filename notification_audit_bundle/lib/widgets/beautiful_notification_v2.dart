import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'dart:async';
import '../l10n/app_localizations.dart';

/// 🎨 Современные уведомления с синим оттенком
/// Версия 4.0 - улучшенный дизайн с тенями, blur эффектом, без крестика
class BeautifulNotificationV2 {
  static OverlayEntry? _currentOverlay;
  static bool _isShowing = false;
  static Timer? _hideTimer;

  /// Основной синий цвет для всех уведомлений
  static const Color primaryColor = Color(0xFF1976D2);
  static const Color lightBlue = Color(0xFFE3F2FD);
  static const Color darkBlue = Color(0xFF0D47A1);
  
  /// Градиенты для современного дизайна
  static const LinearGradient blueGradient = LinearGradient(
    colors: [Color(0xFF1976D2), Color(0xFF1565C0)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  /// Показать уведомление с аватаром пользователя
  static void showWithAvatar({
    required BuildContext context,
    required String userName,
    required String message,
    String? avatarUrl,
    String? subtitle,
    IconData? icon,
    Color? color,
    VoidCallback? onTap,
    Duration duration = const Duration(seconds: 3),
  }) {
    _show(
      context,
      userName: userName,
      message: message,
      avatarUrl: avatarUrl,
      subtitle: subtitle,
      icon: icon,
      color: BeautifulNotificationV2.primaryColor,
      onTap: onTap,
      duration: duration,
      hasAvatar: true,
    );
  }

  /// Показать простое уведомление без аватара
  static void showSimple({
    required BuildContext context,
    required String title,
    required String message,
    String? subtitle,
    IconData? icon,
    Color? color,
    VoidCallback? onTap,
    Duration duration = const Duration(seconds: 3),
  }) {
    _show(
      context,
      title: title,
      message: message,
      subtitle: subtitle,
      icon: icon,
      color: BeautifulNotificationV2.primaryColor,
      onTap: onTap,
      duration: duration,
      hasAvatar: false,
    );
  }

  /// ❤️ Уведомление о лайке
  static void showLike({
    required BuildContext context,
    required String userName,
    String? avatarUrl,
    VoidCallback? onTap,
  }) {
    showWithAvatar(
      context: context,
      userName: userName,
      message: AppLocalizations.of(context).translate('liked_your_post'),
      avatarUrl: avatarUrl,
      icon: Icons.favorite_rounded,
      color: BeautifulNotificationV2.primaryColor,
      onTap: onTap,
    );
  }

  /// Уведомление о комментарии
  static void showComment({
    required BuildContext context,
    required String userName,
    required String commentText,
    String? avatarUrl,
    VoidCallback? onTap,
  }) {
    showWithAvatar(
      context: context,
      userName: userName,
      message: AppLocalizations.of(context).translate('commented'),
      subtitle: commentText.length > 50 ? '${commentText.substring(0, 50)}...' : commentText,
      avatarUrl: avatarUrl,
      icon: Icons.comment_rounded,
      color: BeautifulNotificationV2.primaryColor,
      onTap: onTap,
    );
  }

  /// Уведомление об ответе на комментарий
  static void showCommentReply({
    required BuildContext context,
    required String userName,
    required String replyText,
    String? avatarUrl,
    VoidCallback? onTap,
  }) {
    showWithAvatar(
      context: context,
      userName: userName,
      message: AppLocalizations.of(context).translate('replied_to_comment'),
      subtitle: replyText.length > 50 ? '${replyText.substring(0, 50)}...' : replyText,
      avatarUrl: avatarUrl,
      icon: Icons.reply_rounded,
      color: BeautifulNotificationV2.primaryColor,
      onTap: onTap,
    );
  }

  /// Уведомление о новом сообщении
  static void showMessage({
    required BuildContext context,
    required String userName,
    required String messageText,
    String? avatarUrl,
    VoidCallback? onTap,
  }) {
    showWithAvatar(
      context: context,
      userName: userName,
      message: messageText,
      avatarUrl: avatarUrl,
      icon: Icons.message_rounded,
      color: BeautifulNotificationV2.primaryColor,
      onTap: onTap,
    );
  }

  /// Уведомление о новом подписчике
  static void showFollower({
    required BuildContext context,
    required String userName,
    String? avatarUrl,
    VoidCallback? onTap,
  }) {
    showWithAvatar(
      context: context,
      userName: userName,
      message: AppLocalizations.of(context).translate('followed_you'),
      avatarUrl: avatarUrl,
      icon: Icons.person_add_rounded,
      color: BeautifulNotificationV2.primaryColor,
      onTap: onTap,
    );
  }

  /// Уведомление о дебате
  static void showDebate({
    required BuildContext context,
    required String userName,
    required String debateTitle,
    String? avatarUrl,
    VoidCallback? onTap,
  }) {
    showWithAvatar(
      context: context,
      userName: userName,
      message: AppLocalizations.of(context).translate('created_debate'),
      subtitle: debateTitle,
      avatarUrl: avatarUrl,
      icon: Icons.local_fire_department_rounded,
      color: BeautifulNotificationV2.primaryColor,
      onTap: onTap,
    );
  }

  /// Уведомление о комментарии в дебате
  static void showDebateComment({
    required BuildContext context,
    required String userName,
    required String commentText,
    String? avatarUrl,
    VoidCallback? onTap,
  }) {
    showWithAvatar(
      context: context,
      userName: userName,
      message: AppLocalizations.of(context).translate('commented_in_debate'),
      subtitle: commentText.length > 50 ? '${commentText.substring(0, 50)}...' : commentText,
      avatarUrl: avatarUrl,
      icon: Icons.forum_rounded,
      color: BeautifulNotificationV2.primaryColor,
      onTap: onTap,
    );
  }

  /// Успешное выполнение
  static void showSuccess({
    required BuildContext context,
    required String message,
    String? subtitle,
  }) {
    showSimple(
      context: context,
      title: AppLocalizations.of(context).translate('success'),
      message: message,
      subtitle: subtitle,
      icon: Icons.check_circle_rounded,
      color: BeautifulNotificationV2.primaryColor,
    );
  }

  /// Ошибка
  static void showError({
    required BuildContext context,
    required String message,
    String? subtitle,
  }) {
    showSimple(
      context: context,
      title: AppLocalizations.of(context).translate('error'),
      message: message,
      subtitle: subtitle,
      icon: Icons.error_rounded,
      color: BeautifulNotificationV2.primaryColor,
    );
  }

  /// Информация
  static void showInfo({
    required BuildContext context,
    required String message,
    String? subtitle,
  }) {
    showSimple(
      context: context,
      title: AppLocalizations.of(context).translate('information'),
      message: message,
      subtitle: subtitle,
      icon: Icons.info_rounded,
      color: BeautifulNotificationV2.primaryColor,
    );
  }

  /// Предупреждение
  static void showWarning({
    required BuildContext context,
    required String message,
    String? subtitle,
  }) {
    showSimple(
      context: context,
      title: AppLocalizations.of(context).translate('warning'),
      message: message,
      subtitle: subtitle,
      icon: Icons.warning_rounded,
      color: BeautifulNotificationV2.primaryColor,
    );
  }

  /// Основной метод показа уведомления
  static void _show(
    BuildContext context, {
    String? title,
    String? userName,
    required String message,
    String? subtitle,
    String? avatarUrl,
    IconData? icon,
    required Color color,
    VoidCallback? onTap,
    Duration duration = const Duration(seconds: 3),
    required bool hasAvatar,
  }) {
    if (_isShowing) {
      _hide();
    }

    _isShowing = true;
    final overlay = Overlay.of(context);
    
    _currentOverlay = OverlayEntry(
      builder: (context) => _NotificationWidget(
        title: title,
        userName: userName,
        message: message,
        subtitle: subtitle,
        avatarUrl: avatarUrl,
        icon: icon,
        color: color,
        onTap: onTap ?? () => _hide(),
        onDismiss: _hide,
        hasAvatar: hasAvatar,
      ),
    );

    overlay.insert(_currentOverlay!);

    _hideTimer?.cancel();
    _hideTimer = Timer(duration, _hide);
  }

  /// Скрыть уведомление
  static void _hide() {
    _hideTimer?.cancel();
    _currentOverlay?.remove();
    _currentOverlay = null;
    _isShowing = false;
  }
}

/// Виджет уведомления
class _NotificationWidget extends StatefulWidget {
  final String? title;
  final String? userName;
  final String message;
  final String? subtitle;
  final String? avatarUrl;
  final IconData? icon;
  final Color color;
  final VoidCallback onTap;
  final VoidCallback onDismiss;
  final bool hasAvatar;

  const _NotificationWidget({
    this.title,
    this.userName,
    required this.message,
    this.subtitle,
    this.avatarUrl,
    this.icon,
    required this.color,
    required this.onTap,
    required this.onDismiss,
    required this.hasAvatar,
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
      begin: const Offset(0, -1),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
    ));

    _fadeAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeIn,
    ));

    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _handleDismiss() {
    _controller.reverse().then((_) => widget.onDismiss());
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    return Positioned(
      top: MediaQuery.of(context).padding.top + 12,
      left: 16,
      right: 16,
      child: SlideTransition(
        position: _slideAnimation,
        child: FadeTransition(
          opacity: _fadeAnimation,
          child: GestureDetector(
            onTap: widget.onTap,
            onVerticalDragEnd: (details) {
              if (details.primaryVelocity! < -500) {
                _handleDismiss();
              }
            },
            child: Material(
              color: Colors.transparent,
              elevation: 0,
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  gradient: isDark 
                    ? LinearGradient(
                        colors: [
                          const Color(0xFF1E1E1E),
                          const Color(0xFF2A2A2A),
                        ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      )
                    : LinearGradient(
                        colors: [
                          Colors.white,
                          BeautifulNotificationV2.lightBlue.withValues(alpha: 0.3),
                        ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: BeautifulNotificationV2.primaryColor.withValues(alpha: 0.15),
                    width: 1.5,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: BeautifulNotificationV2.primaryColor.withValues(alpha: 0.15),
                      blurRadius: 20,
                      offset: const Offset(0, 8),
                      spreadRadius: 0,
                    ),
                    BoxShadow(
                      color: isDark 
                        ? Colors.black.withValues(alpha: 0.3)
                        : Colors.black.withValues(alpha: 0.05),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                      spreadRadius: 0,
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    // Аватар или иконка
                    if (widget.hasAvatar && widget.avatarUrl != null)
                      _buildModernAvatar()
                    else if (widget.icon != null)
                      _buildModernIcon(),
                    const SizedBox(width: 14),
                    
                    // Текст
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (widget.userName != null)
                            Text(
                              widget.userName!,
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: BeautifulNotificationV2.primaryColor,
                                letterSpacing: -0.2,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            )
                          else if (widget.title != null)
                            Text(
                              widget.title!,
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: BeautifulNotificationV2.primaryColor,
                                letterSpacing: -0.2,
                              ),
                            ),
                          const SizedBox(height: 3),
                          Text(
                            widget.message,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w400,
                              color: isDark ? Colors.white.withValues(alpha: 0.85) : Colors.black87,
                              height: 1.4,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (widget.subtitle != null) ...[
                            const SizedBox(height: 4),
                            Text(
                              widget.subtitle!,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w400,
                                color: isDark ? Colors.white.withValues(alpha: 0.6) : Colors.black54,
                                height: 1.3,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildModernAvatar() {
    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: [
            BeautifulNotificationV2.primaryColor.withValues(alpha: 0.1),
            BeautifulNotificationV2.primaryColor.withValues(alpha: 0.05),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(
          color: BeautifulNotificationV2.primaryColor.withValues(alpha: 0.2),
          width: 2,
        ),
        boxShadow: [
          BoxShadow(
            color: BeautifulNotificationV2.primaryColor.withValues(alpha: 0.1),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: ClipOval(
        child: widget.avatarUrl != null && widget.avatarUrl!.isNotEmpty
            ? CachedNetworkImage(
                imageUrl: widget.avatarUrl!,
                fit: BoxFit.cover,
                placeholder: (context, url) => Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        BeautifulNotificationV2.lightBlue,
                        BeautifulNotificationV2.lightBlue.withValues(alpha: 0.7),
                      ],
                    ),
                  ),
                  child: Icon(
                    Icons.person_rounded,
                    color: BeautifulNotificationV2.primaryColor,
                    size: 22,
                  ),
                ),
                errorWidget: (context, url, error) => Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        BeautifulNotificationV2.lightBlue,
                        BeautifulNotificationV2.lightBlue.withValues(alpha: 0.7),
                      ],
                    ),
                  ),
                  child: Icon(
                    Icons.person_rounded,
                    color: BeautifulNotificationV2.primaryColor,
                    size: 22,
                  ),
                ),
              )
            : Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      BeautifulNotificationV2.lightBlue,
                      BeautifulNotificationV2.lightBlue.withValues(alpha: 0.7),
                    ],
                  ),
                ),
                child: Icon(
                  Icons.person_rounded,
                  color: BeautifulNotificationV2.primaryColor,
                  size: 22,
                ),
              ),
      ),
    );
  }

  Widget _buildModernIcon() {
    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            BeautifulNotificationV2.primaryColor.withValues(alpha: 0.15),
            BeautifulNotificationV2.primaryColor.withValues(alpha: 0.08),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: BeautifulNotificationV2.primaryColor.withValues(alpha: 0.1),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Icon(
        widget.icon,
        color: BeautifulNotificationV2.primaryColor,
        size: 22,
      ),
    );
  }
}
