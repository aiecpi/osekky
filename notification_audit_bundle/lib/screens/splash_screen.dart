import 'package:flutter/material.dart';
import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../config/features.dart';
import '../app_state.dart';
import '../utils/logger.dart';
import '../services/deep_link_service.dart';
import '../services/notification_service.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;
  late Animation<double> _scaleAnimation;
  StreamSubscription<Uri>? _deepLinkSubscription;

  @override
  void initState() {
    super.initState();
    
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );

    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _animationController,
        curve: const Interval(0.0, 0.6, curve: Curves.easeIn),
      ),
    );

    _scaleAnimation = Tween<double>(begin: 0.5, end: 1.0).animate(
      CurvedAnimation(
        parent: _animationController,
        curve: const Interval(0.0, 0.6, curve: Curves.easeOutBack),
      ),
    );

    _animationController.forward();

    // Слушаем deep links
    _deepLinkSubscription = DeepLinkService().deepLinkStream.listen((uri) {
      if (mounted) {
        DeepLinkService.handleDeepLink(context, uri);
      }
    });

    // Проверяем, нужно ли показывать онбординг
    _checkOnboarding();
  }

  Future<void> _checkOnboarding() async {
    // Минимальная задержка для анимации
    await Future.delayed(const Duration(milliseconds: 800));
    
    if (!mounted) return;
    final navigator = Navigator.of(context);
    final appState = context.read<AppState>();

    // Общий аварийный таймаут: через 15 сек уходим на main (если сессия есть) или welcome
    Future.delayed(const Duration(seconds: 15), () {
      if (mounted) {
        final hasSession = Supabase.instance.client.auth.currentSession != null;
        AppLogger.warning('SplashScreen timeout — forcing ${hasSession ? "/main" : "/welcome"}', tag: 'SplashScreen');
        navigator.pushReplacementNamed(hasSession ? '/main' : '/welcome');
      }
    });
    
    // Проверяем сохранённую сессию Supabase
    if (Features.useSupabaseAuth || Features.useSupabaseUsers) {
      final session = Supabase.instance.client.auth.currentSession;
      if (session != null) {
        AppLogger.success('Найдена сохранённая сессия, проверяем пользователя', tag: 'SplashScreen');

        // Проверяем существование пользователя в БД (таймаут 5 сек)
        try {
          final userId = session.user.id;
          final userExists = await Supabase.instance.client
              .from('users')
              .select('id')
              .eq('id', userId)
              .maybeSingle()
              .timeout(const Duration(seconds: 5));
          
          if (userExists == null) {
            AppLogger.warning('Пользователь удален из БД, очищаем сессию', tag: 'SplashScreen');
            await Supabase.instance.client.auth.signOut();
            if (!mounted) return;
            navigator.pushReplacementNamed('/welcome');
            return;
          }
        } catch (e) {
          AppLogger.error('Ошибка проверки пользователя (timeout или сеть)', tag: 'SplashScreen', error: e);
          // При таймауте или ошибке сети — НЕ выходим, просто идём дальше
          // Supabase сессия валидна локально, пускаем в приложение
          if (!mounted) return;
          try {
            await appState.initializeData()
                .timeout(const Duration(seconds: 6));
          } catch (_) {}
          if (!mounted) return;
          navigator.pushReplacementNamed('/main');
          return;
        }

        // Проверяем подтверждение email
        final user = session.user;
        if (user.emailConfirmedAt == null) {
          AppLogger.info('Email не подтвержден, перенаправляем на экран подтверждения', tag: 'SplashScreen');
          if (!mounted) return;
          navigator.pushReplacementNamed(
            '/email-verification-required',
            arguments: {
              'email': user.email ?? '',
              'isFirstLogin': false,
            },
          );
          return;
        }

        // Инициализируем данные с таймаутом 6 секунд
        try {
          await appState.initializeData()
              .timeout(const Duration(seconds: 6));
        } catch (e) {
          AppLogger.error('Не удалось инициализировать приложение из splash', tag: 'SplashScreen', error: e);
        }
        if (!mounted) return;
        navigator.pushReplacementNamed('/main');
        // Обрабатываем уведомление если приложение открыто через тап
        _handlePendingNotification();
        return;
      }
    }
    
    // Сразу на welcome screen (онбординг там же)
    if (mounted) navigator.pushReplacementNamed('/welcome');
  }

  /// Обрабатывает pending уведомление — когда приложение открыто тапом на push
  void _handlePendingNotification() {
    final pending = NotificationService().pendingNotificationData;
    if (pending == null || pending.isEmpty) return;
    AppLogger.info('[SPLASH] Обрабатываем pending уведомление: $pending', tag: 'SplashScreen');
    NotificationService().clearPendingNotification();
    // Небольшая задержка — даём /main загрузиться
    Future.delayed(const Duration(milliseconds: 500), () {
      NotificationService().navigateToScreen(pending);
    });
  }

  @override
  void dispose() {
    _animationController.dispose();
    _deepLinkSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF003e70),
      body: Center(
        child: AnimatedBuilder(
          animation: _animationController,
          builder: (context, child) {
            return Opacity(
              opacity: _fadeAnimation.value,
              child: Transform.scale(
                scale: _scaleAnimation.value,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Логотип (аккуратный размер)
                    SizedBox(
                      width: 120,
                      height: 120,
                      child: Image.asset(
                        'assets/images/hi4.png',
                        fit: BoxFit.contain,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      AppLocalizations.of(context).translate('share_stories'),
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
