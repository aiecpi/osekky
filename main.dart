import 'dart:async';
import 'dart:ui' as ui;

import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:osekky/models.dart' as models;
import 'package:osekky/screens/complete_profile_screen.dart';
import 'package:osekky/screens/chat_screen.dart';
import 'package:osekky/screens/forgot_password_screen.dart';
import 'package:osekky/screens/login_screen.dart';
import 'package:osekky/screens/phone_verification_screen.dart';
import 'package:osekky/screens/profile_setup_screen.dart';
import 'package:osekky/screens/register_screen.dart';
import 'package:osekky/screens/simple_register_screen.dart';
import 'package:osekky/screens/welcome_screen.dart';
import 'package:osekky/screens/complete_username_screen.dart';
import 'package:osekky/screens/follow_suggestions_screen.dart';
import 'package:osekky/screens/onboarding_screen.dart';
import 'package:osekky/screens/comments_screen.dart';
import 'package:osekky/screens/discussion_detail_screen.dart';
import 'package:osekky/screens/main_screen.dart';
import 'package:osekky/screens/splash_screen.dart';
import 'package:osekky/screens/terms_screen.dart';
import 'package:osekky/screens/privacy_policy_screen.dart';
import 'package:osekky/screens/user_profile_screen.dart';
import 'package:osekky/screens/email_verification_required_screen.dart';
import 'package:osekky/services/analytics_service.dart';
import 'package:osekky/services/audio_service.dart';
import 'package:osekky/services/deep_link_service.dart';
import 'package:osekky/services/firebase_notification_service.dart';
import 'package:osekky/services/haptic_service.dart';
import 'package:osekky/config/supabase_config.dart';
import 'package:osekky/services/supabase_post_service.dart';
import 'package:osekky/l10n/app_localizations.dart';
import 'package:osekky/utils/logger.dart';
import 'package:osekky/app_state.dart';
import 'package:osekky/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// Глобальный navigatorKey для навигации из Firebase уведомлений
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

Map<String, dynamic> _normalizePostForNavigation(Map<String, dynamic> rawPost) {
  final userData = rawPost['users'] as Map<String, dynamic>?;
  final mediaUrls = (rawPost['media_urls'] as List<dynamic>?)
      ?.map((item) => item.toString())
      .toList();
  final legacyImages = (rawPost['images'] as List<dynamic>?)
      ?.map((item) => item.toString())
      .toList();

  final normalized = <String, dynamic>{
    ...rawPost,
    'author': <String, dynamic>{
      'id': userData?['id'] as String? ?? '',
      'name': userData?['full_name'] as String? ?? userData?['username'] as String? ?? 'Unknown',
      'username': userData?['username'] as String? ?? 'unknown',
      'avatar': userData?['avatar_url'] as String? ?? '',
      'is_premium': (userData?['role'] as String?) == 'premium',
      'followers_count': (userData?['followers_count'] as num?)?.toInt() ?? 0,
      'following_count': (userData?['following_count'] as num?)?.toInt() ?? 0,
      'posts_count': (userData?['posts_count'] as num?)?.toInt() ?? 0,
      'role': userData?['role'] as String? ?? 'free',
      'is_verified': userData?['is_verified'] as bool? ?? false,
      'is_private': userData?['is_private'] as bool? ?? false,
      'email': userData?['email'] as String?,
      'phone': userData?['phone'] as String?,
      'name_changed_at': userData?['name_changed_at'] as String?,
      'username_changed_at': userData?['username_changed_at'] as String?,
    },
    'likes': (rawPost['likes_count'] as num?)?.toInt() ?? 0,
    'comments': (rawPost['comments_count'] as num?)?.toInt() ?? 0,
    'reposts': (rawPost['reposts_count'] as num?)?.toInt() ?? 0,
    'views': (rawPost['views_count'] as num?)?.toInt() ?? 0,
    'images': mediaUrls ?? legacyImages ?? const <String>[],
  };

  final quotedStoryRaw = rawPost['quoted_story'];
  if (quotedStoryRaw is Map) {
    normalized['quoted_story'] = _normalizePostForNavigation(
      Map<String, dynamic>.from(quotedStoryRaw),
    );
  }
  return normalized;
}

Future<models.Story?> loadPostForNavigation(String postId) async {
  try {
    final postData = await SupabasePostService().getPostById(postId);
    if (postData == null) {
      return null;
    }
    return models.Story.fromJson(_normalizePostForNavigation(postData));
  } catch (e) {
    if (kDebugMode) {
      AppLogger.error('Ошибка загрузки поста: $e', tag: 'main');
    }
    return null;
  }
}

class UserRouteScreen extends StatefulWidget {
  final String userId;

  const UserRouteScreen({super.key, required this.userId});

  @override
  State<UserRouteScreen> createState() => _UserRouteScreenState();
}

class _UserRouteScreenState extends State<UserRouteScreen> {
  late Future<models.User?> _userFuture;

  @override
  void initState() {
    super.initState();
    _userFuture = context.read<AppState>().fetchUserProfile(widget.userId);
  }

  void _retry() {
    setState(() {
      _userFuture = context.read<AppState>().fetchUserProfile(widget.userId);
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<models.User?>(
      future: _userFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        final user = snapshot.data;
        if (user != null) {
          return UserProfileScreen(user: user);
        }

        return Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline, size: 48, color: Colors.redAccent),
                  const SizedBox(height: 12),
                  const Text(
                    'Не удалось открыть профиль',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Пользователь может быть удалён или временно недоступен.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.black54),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ElevatedButton.icon(
                        onPressed: _retry,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Повторить'),
                      ),
                      const SizedBox(width: 12),
                      TextButton(
                        onPressed: () {
                          Navigator.of(context).pushNamedAndRemoveUntil('/main', (route) => false);
                        },
                        child: const Text('На главную'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class ChatRouteScreen extends StatefulWidget {
  final String userId;

  const ChatRouteScreen({super.key, required this.userId});

  @override
  State<ChatRouteScreen> createState() => _ChatRouteScreenState();
}

class _ChatRouteScreenState extends State<ChatRouteScreen> {
  late Future<models.User?> _userFuture;

  @override
  void initState() {
    super.initState();
    _userFuture = context.read<AppState>().fetchUserProfile(widget.userId);
  }

  void _retry() {
    setState(() {
      _userFuture = context.read<AppState>().fetchUserProfile(widget.userId);
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<models.User?>(
      future: _userFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        final user = snapshot.data;
        if (user != null) {
          return ChatScreen(otherUser: user);
        }

        return Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline, size: 48, color: Colors.redAccent),
                  const SizedBox(height: 12),
                  const Text(
                    'Не удалось открыть чат',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Пользователь может быть удалён или временно недоступен.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.black54),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ElevatedButton.icon(
                        onPressed: _retry,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Повторить'),
                      ),
                      const SizedBox(width: 12),
                      TextButton(
                        onPressed: () {
                          Navigator.of(context).pushNamedAndRemoveUntil('/main', (route) => false);
                        },
                        child: const Text('На главную'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class DebateRouteScreen extends StatefulWidget {
  final String debateId;
  final String? commentId;

  const DebateRouteScreen({super.key, required this.debateId, this.commentId});

  @override
  State<DebateRouteScreen> createState() => _DebateRouteScreenState();
}

class _DebateRouteScreenState extends State<DebateRouteScreen> {
  late Future<models.Discussion?> _debateFuture;

  @override
  void initState() {
    super.initState();
    _debateFuture = _loadDebate();
  }

  Future<models.Discussion?> _loadDebate() async {
    final appState = Provider.of<AppState>(context, listen: false);
    var discussion = appState.discussions.where((d) => d.id == widget.debateId).firstOrNull;
    discussion ??= appState.allDiscussions.where((d) => d.id == widget.debateId).firstOrNull;
    if (discussion != null) return discussion;
    return appState.fetchDiscussionById(widget.debateId);
  }

  void _retry() {
    setState(() {
      _debateFuture = _loadDebate();
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<models.Discussion?>(
      future: _debateFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        final discussion = snapshot.data;
        if (discussion != null) {
          return DiscussionDetailScreen(
            discussion: discussion,
            scrollToCommentId: widget.commentId,
          );
        }

        return Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline, size: 48, color: Colors.redAccent),
                  const SizedBox(height: 12),
                  const Text(
                    'Не удалось открыть дебат',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Дебат может быть удалён или временно недоступен.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.black54),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ElevatedButton.icon(
                        onPressed: _retry,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Повторить'),
                      ),
                      const SizedBox(width: 12),
                      TextButton(
                        onPressed: () {
                          Navigator.of(context).pushNamedAndRemoveUntil('/main', (route) => false);
                        },
                        child: const Text('На главную'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class PostRouteScreen extends StatefulWidget {
  final String postId;
  final String? commentId;

  const PostRouteScreen({super.key, required this.postId, this.commentId});

  @override
  State<PostRouteScreen> createState() => _PostRouteScreenState();
}

class _PostRouteScreenState extends State<PostRouteScreen> {
  late Future<models.Story?> _postFuture;

  @override
  void initState() {
    super.initState();
    _postFuture = loadPostForNavigation(widget.postId);
  }

  void _retry() {
    setState(() {
      _postFuture = loadPostForNavigation(widget.postId);
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<models.Story?>(
      future: _postFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        final story = snapshot.data;
        if (story != null) {
          return CommentsScreen(story: story, commentId: widget.commentId);
        }

        return Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline, size: 48, color: Colors.redAccent),
                  const SizedBox(height: 12),
                  const Text(
                    'Не удалось открыть пост',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Пост может быть удалён или временно недоступен.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.black54),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ElevatedButton.icon(
                        onPressed: _retry,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Повторить'),
                      ),
                      const SizedBox(width: 12),
                      TextButton(
                        onPressed: () {
                          Navigator.of(context).pushNamedAndRemoveUntil('/main', (route) => false);
                        },
                        child: const Text('На главную'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

void _setupErrorHandlers() {
  ErrorWidget.builder = (FlutterErrorDetails details) {
    if (kReleaseMode) {
      return Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text(
              'Что-то пошло не так',
              style: TextStyle(fontSize: 16, color: Colors.grey[600], fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              'Попробуйте перезапустить приложение',
              style: TextStyle(fontSize: 13, color: Colors.grey[500]),
            ),
          ],
        ),
      );
    }
    return ErrorWidget(details.exception);
  };

  // Настройка Firebase Crashlytics
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    
    // Отправляем в Crashlytics только в production
    if (kReleaseMode) {
      try {
        FirebaseCrashlytics.instance.recordFlutterFatalError(details);
      } catch (_) {
        // Firebase ещё не инициализирован — игнорируем
      }
    } else {
      if (kDebugMode) {
        AppLogger.error(details.exceptionAsString(), tag: 'FlutterError');
        if (details.stack != null) {
          AppLogger.error(details.stack.toString(), tag: 'FlutterError');
        }
      }
    }
  };

  ui.PlatformDispatcher.instance.onError = (error, stack) {
    // Отправляем в Crashlytics только в production
    if (kReleaseMode) {
      try {
        FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
      } catch (_) {
        // Firebase ещё не инициализирован — игнорируем
      }
    } else {
      if (kDebugMode) {
        AppLogger.error(error.toString(), tag: 'PlatformDispatcher');
        AppLogger.error(stack.toString(), tag: 'PlatformDispatcher');
      }
    }
    return true;
  };
}

Future<void> initializeApp() async {
  try {
    // Параллельная инициализация сервисов для ускорения запуска
    final futures = <Future>[];

    // Инициализация Supabase с сохранением сессии
    futures.add(
      Supabase.initialize(
        url: SupabaseConfig.supabaseUrl,
        anonKey: SupabaseConfig.supabaseAnonKey,
        authOptions: const FlutterAuthClientOptions(
          authFlowType: AuthFlowType.pkce,
          autoRefreshToken: true,
        ),
        storageOptions: const StorageClientOptions(
          retryAttempts: 3,
        ),
      ).then((_) {
        if (kDebugMode) {
          AppLogger.success('Supabase инициализирован с сохранением сессии', tag: 'main');
        }
      }).catchError((e) {
        if (kDebugMode) {
          AppLogger.error('Ошибка инициализации Supabase: $e', tag: 'main');
        }
        return null;
      })
    );

    // Инициализация deep linking (синхронная, быстрая)
    DeepLinkService().initialize();

    // Ждем завершения только критически важного сервиса (с таймаутом)
    await futures[0].timeout(const Duration(seconds: 8), onTimeout: () {
      if (kDebugMode) {
        AppLogger.warning('Supabase инициализация превысила 8 секунд, продолжаем без Supabase', tag: 'main');
      }
      return null;
    });

    // Все остальные сервисы инициализируем в фоне после запуска UI
    unawaited(HapticService().initialize().catchError((e) {
      if (kDebugMode) {
        AppLogger.warning('Haptic сервис не инициализирован: $e', tag: 'main');
      }
      return null;
    }));

    unawaited(AudioService.initialize().catchError((e) {
      if (kDebugMode) {
        AppLogger.warning('Audio сервис не инициализирован: $e', tag: 'main');
      }
      return null;
    }));

    debugPrint('🟢 [main] AudioService initialized, starting runApp');

    if (kReleaseMode) {
      unawaited(FirebaseCrashlytics.instance.setCrashlyticsCollectionEnabled(true).catchError((e) {
        if (kDebugMode) {
          AppLogger.warning('Firebase Crashlytics не инициализирован: $e', tag: 'main');
        }
        return null;
      }));
    }

    // Analytics — в фоне, только если пользователь авторизован
    unawaited(AnalyticsService().initialize().then((_) {
      final hasSession = Supabase.instance.client.auth.currentSession != null;
      if (hasSession) return AnalyticsService().trackAppOpen();
      return null;
    }).catchError((e) {
      if (kDebugMode) {
        AppLogger.warning('Аналитика не инициализирована: $e', tag: 'main');
      }
      return null;
    }));

    debugPrint('🟢 [main] Calling runApp(const MyApp())');
    runApp(const MyApp());
    debugPrint('🟢 [main] runApp completed');

    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(FirebaseNotificationService.initialize().catchError((e) {
        if (kDebugMode) {
          AppLogger.warning('Firebase push-уведомления не инициализированы: $e', tag: 'main');
        }
        return null;
      }));
    });
  } catch (e, stackTrace) {
    if (kDebugMode) {
      AppLogger.error('Ошибка при инициализации приложения: $e', tag: 'main');
    }
    // Отправляем необработанные ошибки в Crashlytics
    if (kReleaseMode) {
      try {
        FirebaseCrashlytics.instance.recordError(e, stackTrace, fatal: true);
      } catch (_) {
        // Firebase ещё не инициализирован — игнорируем
      }
    } else {
      if (kDebugMode) {
        AppLogger.error(e.toString(), tag: 'main');
        AppLogger.error(stackTrace.toString(), tag: 'main');
      }
    }
    // Запускаем приложение даже если некоторые сервисы не инициализировались
    runApp(const MyApp());

    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(FirebaseNotificationService.initialize().catchError((e) {
        if (kDebugMode) {
          AppLogger.warning('Firebase push-уведомления не инициализированы: $e', tag: 'main');
        }
        return null;
      }));
    });
  }
}

void main() {
  debugPrint('🟢 [main] main() called');
  runZonedGuarded(() async {
    debugPrint('🟢 [main] runZonedGuarded started');
    // КРИТИЧЕСКИ ВАЖНО: binding должен быть инициализирован В ТОЙ ЖЕ ЗОНЕ что и runApp
    WidgetsFlutterBinding.ensureInitialized();
    debugPrint('🟢 [main] WidgetsFlutterBinding.ensureInitialized done');
    
    // Настраиваем обработчики ошибок ВНУТРИ зоны, до runApp
    final binding = WidgetsBinding.instance;
    final isTest = binding.runtimeType.toString().contains('Test');
    if (!isTest) {
      debugPrint('🟢 [main] calling _setupErrorHandlers');
      _setupErrorHandlers();
      debugPrint('🟢 [main] _setupErrorHandlers completed');
    }
    
    debugPrint('🟢 [main] calling initializeApp');
    await initializeApp();
    debugPrint('🟢 [main] initializeApp completed');
  }, (error, stack) {
    debugPrint('❌ [runZonedGuarded] ERROR: $error');
    debugPrint('❌ [runZonedGuarded] STACK: $stack');
    if (kReleaseMode) {
      try {
        FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
      } catch (_) {
        // Firebase ещё не инициализирован — игнорируем
      }
    } else {
      debugPrint('❌ [main] $error');
      debugPrint('❌ [main] $stack');
    }
  });
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (context) => AppState(),
      child: Selector<AppState, Locale?>(
        selector: (_, appState) => appState.currentLocale,
        builder: (context, locale, child) {
          return MaterialApp(
            navigatorKey: navigatorKey,
            title: 'Osekky',
            debugShowCheckedModeBanner: false,
            theme: AppTheme.lightTheme,
            locale: locale,
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: AppLocalizations.supportedLocales,
            initialRoute: '/',
            routes: {
              '/': (context) => const SplashScreen(),
              '/welcome': (context) => const WelcomeScreen(),
              '/login': (context) => const LoginScreen(),
              '/register': (context) => const SimpleRegisterScreen(),
              '/register-old': (context) => const RegisterScreen(),
              '/complete-profile': (context) => const CompleteProfileScreen(),
              '/forgot-password': (context) => const ForgotPasswordScreen(),
              '/email-verification-required': (context) {
                final data = ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>? ?? {};
                return EmailVerificationRequiredScreen(
                  email: data['email'] ?? '',
                  isFirstLogin: data['isFirstLogin'] ?? true,
                );
              },
              '/terms': (context) => const TermsScreen(),
              '/privacy': (context) => const PrivacyPolicyScreen(),
              '/phone-verification': (context) {
                final data = ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>? ?? {};
                return PhoneVerificationScreen(registrationData: data);
              },
              '/profile-setup': (context) {
                final data = ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>?;
                return ProfileSetupScreen(registrationData: data);
              },
              '/follow-suggestions': (context) {
                final data = ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>?;
                return FollowSuggestionsScreen(userData: data);
              },
              '/complete-username': (context) {
                final data = ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>? ?? {};
                return CompleteUsernameScreen(
                  email: data['email'] ?? '',
                  userId: data['userId'] ?? '',
                );
              },
              '/onboarding': (context) => const OnboardingScreen(),
              '/main': (context) => const MainScreen(),
              '/user': (context) {
                final args = ModalRoute.of(context)?.settings.arguments;
                final userId = args is String ? args : (args as Map<String, dynamic>?)?['userId'] as String?;
                if (userId == null || userId.isEmpty) {
                  return const MainScreen();
                }
                return UserRouteScreen(userId: userId);
              },
              '/chat': (context) {
                final args = ModalRoute.of(context)?.settings.arguments;
                final userId = args is String ? args : (args as Map<String, dynamic>?)?['userId'] as String?;
                if (userId == null || userId.isEmpty) {
                  return const MainScreen();
                }
                return ChatRouteScreen(userId: userId);
              },
              '/post': (context) {
                final args = ModalRoute.of(context)?.settings.arguments;
                String? postId;
                String? commentId;
                
                if (args is String) {
                  postId = args;
                } else if (args is Map<String, dynamic>) {
                  postId = args['postId'] as String?;
                  commentId = args['commentId'] as String?;
                }
                
                if (postId == null) {
                  return const MainScreen();
                }

                return PostRouteScreen(postId: postId, commentId: commentId);
              },
              '/debate': (context) {
                final args = ModalRoute.of(context)?.settings.arguments;
                String? debateId;
                String? commentId;

                if (args is String) {
                  debateId = args;
                } else if (args is Map<String, dynamic>) {
                  debateId = args['debateId'] as String? ?? args['discussionId'] as String?;
                  commentId = args['commentId'] as String?;
                }

                if (debateId == null) {
                  return const MainScreen();
                }

                return DebateRouteScreen(debateId: debateId, commentId: commentId);
              },
            },
          );
        },
      ),
    );
  }
}
