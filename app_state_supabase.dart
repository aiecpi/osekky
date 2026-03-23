import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;
import 'models.dart';
import 'services/supabase_user_service.dart';
import 'services/supabase_auth_service.dart';
import 'config/features.dart';
import 'utils/logger.dart';

/// Расширение AppState для работы с Supabase профилями
mixin SupabaseProfileMixin {
  static const String _websiteTextSeparator = '|||OsekkyWebsiteText|||';
  Map<String, dynamic>? _currentSupabaseProfile;
  bool _isSupabaseProfileLoaded = false;
  StreamSubscription<supabase.AuthState>? _authSubscription;
  Timer? _signOutDebounceTimer; // Debounce для защиты от ложных signedOut событий
  final SupabaseUserService _supabaseUserService = SupabaseUserService();
  final supabase.SupabaseClient _supabaseClient = supabase.Supabase.instance.client;

  Map<String, dynamic>? get currentSupabaseProfile => _currentSupabaseProfile;
  bool get isSupabaseProfileLoaded => _isSupabaseProfileLoaded;

  bool _isLoadingSupabaseProfile = false;

  /// Загрузить текущего пользователя из Supabase
  Future<void> loadSupabaseCurrentUser() async {
    // Защита от повторной загрузки
    if (_isLoadingSupabaseProfile) return;
    if (_isSupabaseProfileLoaded && _currentSupabaseProfile != null) return;
    
    _isLoadingSupabaseProfile = true;
    
    try {
      // Проверяем сохранённую сессию
      var session = _supabaseClient.auth.currentSession;
      if (session != null) {
        
        // Проверяем валидность токена и пытаемся обновить
        if (session.expiresAt != null && DateTime.now().isAfter(DateTime.fromMillisecondsSinceEpoch(session.expiresAt! * 1000))) {
          AppLogger.warning('[AUTH] Сессия истекла, пытаемся обновить токен', tag: 'SupabaseProfile');
          try {
            // Пытаемся обновить сессию
            final refreshResponse = await _supabaseClient.auth.refreshSession();
            if (refreshResponse.session != null) {
              AppLogger.success('[AUTH] Токен успешно обновлён', tag: 'SupabaseProfile');
              session = refreshResponse.session!;
            } else {
              // refreshSession вернул null-сессию — реально невалидный токен
              AppLogger.warning('[AUTH] refreshSession вернул null, выполняем logout (refresh_null)', tag: 'SupabaseProfile');
              await _supabaseClient.auth.signOut();
              _isSupabaseProfileLoaded = true;
              return;
            }
          } catch (e) {
            final errStr = e.toString();
            // Только явные ошибки невалидного refresh_token — делаем logout
            // Сетевые ошибки и таймауты — НЕ делаем logout, продолжаем с текущей сессией
            final isRefreshTokenInvalid = errStr.contains('Invalid Refresh Token') ||
                errStr.contains('refresh_token_not_found') ||
                errStr.contains('Token has expired') ||
                errStr.contains('AuthApiException');
            if (isRefreshTokenInvalid) {
              AppLogger.warning('[AUTH] LOGOUT: refresh_token невалиден — $errStr', tag: 'SupabaseProfile');
              await _supabaseClient.auth.signOut();
              _isSupabaseProfileLoaded = true;
              return;
            } else {
              // Сетевая ошибка или таймаут — продолжаем с текущей сессией
              AppLogger.warning('[AUTH] Ошибка обновления токена (сеть?), продолжаем с текущей сессией: $errStr', tag: 'SupabaseProfile');
            }
          }
        }
      }
      
      // После обновления сессии получаем актуального пользователя
      final authUser = _supabaseClient.auth.currentUser;
      
      
      if (authUser == null) {
        AppLogger.warning('Нет авторизованного пользователя в Supabase', tag: 'SupabaseProfile');
        _isSupabaseProfileLoaded = true;
        return;
      }

      
      var profile = await _supabaseUserService.getProfile(authUser.id);
      
      // Если профиля нет по ID — ищем по email и исправляем ID
      if (profile == null && authUser.email != null) {
        AppLogger.warning('Профиль не найден по ID, ищем по email', tag: 'SupabaseProfile');
        try {
          final profileByEmail = await _supabaseClient
              .from('users')
              .select()
              .eq('email', authUser.email!)
              .maybeSingle();
          
          if (profileByEmail != null) {
            // Нашли по email — обновляем ID и используем этот профиль
            AppLogger.warning('Найден профиль по email, обновляем ID', tag: 'SupabaseProfile');
            await _supabaseClient
                .from('users')
                .update({'id': authUser.id})
                .eq('email', authUser.email!);
            
            // Обновляем ID в найденном профиле и используем его
            profileByEmail['id'] = authUser.id;
            profile = profileByEmail;
            AppLogger.success('Профиль загружен после обновления ID', tag: 'SupabaseProfile');
          } else {
            // Профиля нет вообще — создаём новый
            AppLogger.warning('Профиль не найден нигде, создаём новый', tag: 'SupabaseProfile');
            final username = authUser.userMetadata?['username'] as String?
                ?? authUser.email?.split('@')[0]
                ?? 'user';
            final fullName = authUser.userMetadata?['full_name'] as String?
                ?? username;
            
            // Создаём базовый профиль вручную
            profile = {
              'id': authUser.id,
              'email': authUser.email,
              'username': username,
              'full_name': fullName,
              'role': 'free',
              'is_premium': false,
              'is_verified': false,
              'is_private': false,
              'karma': 0,
              'followers_count': 0,
              'following_count': 0,
              'posts_count': 0,
              'created_at': DateTime.now().toIso8601String(),
              'updated_at': DateTime.now().toIso8601String(),
            };
            AppLogger.success('Создан базовый профиль в памяти', tag: 'SupabaseProfile');
          }
        } catch (e, stack) {
          AppLogger.error('Ошибка при поиске/создании профиля', tag: 'SupabaseProfile', error: e, stackTrace: stack);
          // Создаём минимальный профиль даже при ошибках
          profile = {
            'id': authUser.id,
            'email': authUser.email,
            'username': authUser.email?.split('@')[0] ?? 'user',
            'full_name': 'User',
            'role': 'free',
            'is_premium': false,
            'is_verified': false,
            'is_private': false,
            'karma': 0,
            'followers_count': 0,
            'following_count': 0,
            'posts_count': 0,
          };
          AppLogger.warning('Создан emergency профиль', tag: 'SupabaseProfile');
        }
      }
      
      if (profile == null) {
        AppLogger.error('Не удалось загрузить профиль из Supabase', tag: 'SupabaseProfile');
        _isSupabaseProfileLoaded = true;
        return;
      }
      
      // Конвертируем профиль в User модель с локальными полями
      final user = _mapSupabaseProfileToUser(profile);
      
      // Сохраняем профиль
      _currentSupabaseProfile = profile;
      
      // Проверяем и обновляем Premium статус
      await SupabaseAuthService().checkAndUpdatePremiumStatus(user.id);
      
      // Загружаем обновленный профиль после проверки Premium
      final updatedProfile = await _supabaseUserService.getProfile(authUser.id);
      if (updatedProfile != null) {
        final updatedUser = _mapSupabaseProfileToUser(updatedProfile);
        _currentSupabaseProfile = updatedProfile; // Обновляем профиль
        setCurrentUserFromSupabase(updatedUser);
      } else {
        setCurrentUserFromSupabase(user);
      }
      
      AppLogger.success('Профиль загружен: ${user.name} (@${user.username})', tag: 'SupabaseProfile');
      
      // Успешно загружено
      _isSupabaseProfileLoaded = true;
      
      // Загружаем чаты после загрузки профиля
      if (Features.useSupabaseChats) {
        loadChats();
      }
    } catch (e, stack) {
      AppLogger.error('Ошибка загрузки профиля Supabase', tag: 'SupabaseProfile', error: e, stackTrace: stack);
      
      final errStr = e.toString();
      // Logout только при явно невалидных токенах — НЕ при сетевых ошибках
      final isHardAuthError = errStr.contains('JWT expired') ||
          errStr.contains('PGRST303') ||
          errStr.contains('Invalid Refresh Token') ||
          errStr.contains('refresh_token_not_found') ||
          errStr.contains('invalid_grant');
      if (isHardAuthError) {
        AppLogger.warning('[AUTH] LOGOUT: жёсткая ошибка auth — $errStr', tag: 'SupabaseProfile');
        await _supabaseClient.auth.signOut();
        _currentSupabaseProfile = null;
        _isSupabaseProfileLoaded = false;
        return;
      }
      AppLogger.warning('[AUTH] Ошибка загрузки профиля (НЕ logout): $errStr', tag: 'SupabaseProfile');
      // В случае других ошибок (сеть, таймаут) — не делаем logout, можно retry
      _isSupabaseProfileLoaded = false;
    } finally {
      _isLoadingSupabaseProfile = false;
    }
  }

  /// Подписаться на изменения авторизации
  void subscribeToAuthChanges(Function() notifyListeners, {Function()? onSignedIn}) {
    _authSubscription?.cancel();
    _authSubscription = _supabaseClient.auth.onAuthStateChange.listen((data) async {
      final event = data.event;
      final session = data.session;
      
      // Игнорируем initialSession если профиль уже загружен
      if (event == supabase.AuthChangeEvent.initialSession) {
        if (_isSupabaseProfileLoaded && _currentSupabaseProfile != null) {
          return; // Профиль уже загружен, пропускаем
        }
      }
      
      if ((event == supabase.AuthChangeEvent.signedIn || 
           event == supabase.AuthChangeEvent.initialSession) && session != null) {
        _signOutDebounceTimer?.cancel(); // Отменяем pending logout если пришёл signedIn
        await loadSupabaseCurrentUser();
        // Вызываем callback для загрузки чатов
        onSignedIn?.call();
      } else if (event == supabase.AuthChangeEvent.tokenRefreshed) {
        _signOutDebounceTimer?.cancel(); // Отменяем pending logout если токен обновился
        AppLogger.info('[AUTH] Токен обновлён автоматически Supabase SDK', tag: 'SupabaseProfile');
        // Ничего не делаем — SDK уже обновил сессию
      } else if (event == supabase.AuthChangeEvent.signedOut) {
        AppLogger.warning('[AUTH] signedOut event получен - session=${session != null ? "not null" : "null"}', tag: 'SupabaseProfile');
        
        // Немедленная проверка: если currentSession не null — это ложное событие
        final currentSession = _supabaseClient.auth.currentSession;
        if (currentSession != null) {
          AppLogger.warning('[AUTH] FALSE signedOut — currentSession жив, игнорируем (сетевой глюк)', tag: 'SupabaseProfile');
          return;
        }
        
        // Debounce 1.5 сек: если за это время придёт signedIn/tokenRefreshed — отменяем logout
        _signOutDebounceTimer?.cancel();
        _signOutDebounceTimer = Timer(const Duration(milliseconds: 1500), () async {
          // Финальная проверка перед logout
          final sessionCheck = _supabaseClient.auth.currentSession;
          if (sessionCheck != null) {
            AppLogger.warning('[AUTH] signedOut debounce: сессия восстановлена, отменяем logout', tag: 'SupabaseProfile');
            return;
          }
          AppLogger.warning('[AUTH] LOGOUT: подтверждён signedOut — очищаем состояние', tag: 'SupabaseProfile');
          _currentSupabaseProfile = null;
          _isSupabaseProfileLoaded = false;
          _isLoadingSupabaseProfile = false;
          clearUserData();
          notifyListeners();
        });
      }
    });
  }

  /// Отписаться от изменений авторизации
  void unsubscribeFromAuthChanges() {
    _authSubscription?.cancel();
    _authSubscription = null;
  }

  /// Сбросить состояние Supabase профиля (для logout)
  void resetSupabaseProfile() {
    _currentSupabaseProfile = null;
    _isSupabaseProfileLoaded = false;
    _isLoadingSupabaseProfile = false;
  }

  /// Обновить профиль в Supabase
  Future<bool> updateSupabaseProfile({
    String? fullName,
    String? bio,
    String? avatarUrl,
    String? phone,
    DateTime? birthDate,
    String? gender,
    String? city,
    bool? isPrivate,
  }) async {
    try {
      final authUser = _supabaseClient.auth.currentUser;
      if (authUser == null) return false;

      await _supabaseUserService.updateProfile(
        userId: authUser.id,
        fullName: fullName,
        bio: bio,
        avatarUrl: avatarUrl,
        phone: phone,
        birthDate: birthDate,
        gender: gender,
        city: city,
        isPrivate: isPrivate,
      );

      // Сбрасываем флаг, чтобы loadSupabaseCurrentUser НЕ пропустил перезагрузку
      _isSupabaseProfileLoaded = false;
      _currentSupabaseProfile = null;
      // Перезагружаем профиль
      await loadSupabaseCurrentUser();
      
      return true;
    } catch (e, stack) {
      AppLogger.error('Ошибка обновления профиля', tag: 'SupabaseProfile', error: e, stackTrace: stack);
      return false;
    }
  }

  /// Конвертировать Supabase профиль в User модель
  User _mapSupabaseProfileToUser(Map<String, dynamic> profile) {
    // Убрали подробное логирование - слишком много спама в консоли

    // Безопасно обрабатываем avatar_url: только http/https URL, локальные пути игнорируем
    String rawAvatar = profile['avatar_url'] as String? ?? '';
    if (!(rawAvatar.startsWith('http://') || rawAvatar.startsWith('https://'))) {
      rawAvatar = '';
    }

    String? website = profile['website'] as String?;
    String? websiteText = profile['website_text'] as String?;
    if (website != null && website.contains(_websiteTextSeparator)) {
      final parts = website.split(_websiteTextSeparator);
      if (parts.length >= 2) {
        websiteText = parts.first;
        website = parts.sublist(1).join(_websiteTextSeparator);
      }
    }

    // Парсим premium_expires_at для корректного определения isCurrentlyPremium
    DateTime? premiumExpiresAt;
    if (profile['premium_expires_at'] != null) {
      try {
        premiumExpiresAt = DateTime.parse(profile['premium_expires_at'] as String);
      } catch (e) {
        AppLogger.warning('Ошибка парсинга premium_expires_at в SupabaseAppState', tag: 'SupabaseAppState', error: e);
      }
    }
    
    final roleString = profile['role'] as String?;
    final isPremiumFlag = profile['is_premium'] as bool? ?? false;
    final isPremium = roleString == 'premium' || isPremiumFlag || premiumExpiresAt != null;

    return User(
      id: profile['id'] as String,
      name: profile['full_name'] as String? ?? 'Пользователь',
      username: profile['username'] as String? ?? 'user',
      avatar: rawAvatar,
      bio: profile['bio'] as String?,
      website: website,
      websiteText: websiteText,
      location: profile['location'] as String?,
      city: profile['city'] as String?,
      profileColor: profile['profile_color'] as String?,
      email: profile['email'] as String?,
      phone: profile['phone'] as String?,
      gender: profile['gender'] as String?,
      birthDate: profile['birth_date'] != null ? DateTime.parse(profile['birth_date'] as String) : null,
      isPremium: isPremium,
      premiumExpiresAt: premiumExpiresAt,
      karma: profile['karma'] as int? ?? 0,
      followersCount: profile['followers_count'] as int? ?? 0,
      followingCount: profile['following_count'] as int? ?? 0,
      isVerified: profile['is_verified'] as bool? ?? false,
      isPrivate: profile['is_private'] as bool? ?? false,
      role: _mapRole(profile['role'] as String?),
      badges: [],
      isFollowed: false,
      isOnline: false,
    );
  }

  /// Маппинг роли из Supabase
  UserRole _mapRole(String? role) {
    switch (role) {
      case 'premium':
        return UserRole.premium;
      case 'moderator':
        return UserRole.moderator;
      case 'admin':
        return UserRole.admin;
      default:
        return UserRole.free;
    }
  }

  /// Инициализировать пользователей (для старого режима — пустой список)
  void initializeMockUsers(List<User> users, Function(User) setCurrentUser) {
    // Mock данные удалены — используйте Supabase
    AppLogger.warning('initializeMockUsers вызван, но mock данные удалены. Включите Features.useSupabaseUsers', tag: 'SupabaseProfile');
  }

  // Эти методы должны быть реализованы в основном классе
  void setCurrentUserFromSupabase(User user);
  void clearUserData();
  Future<void> loadChats({bool force = false});
}
