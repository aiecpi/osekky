import 'package:get_it/get_it.dart';
import 'supabase_post_service.dart';
import 'supabase_user_service.dart';
import 'supabase_follow_request_service.dart';
import 'supabase_notification_service.dart';
import 'supabase_chat_service.dart';
import 'supabase_discussion_service.dart';
import 'supabase_storage_service.dart';
import 'supabase_community_service.dart';
import 'supabase_block_service.dart';
import 'supabase_report_service.dart';
import 'supabase_auth_service.dart';
import 'supabase_settings_service.dart';
import 'cache_service.dart';
import 'offline_queue_service.dart';

/// Локатор сервисов для управления зависимостями
class ServiceLocator {
  static final GetIt _getIt = GetIt.instance;
  
  static bool _initialized = false;
  
  /// Инициализация всех сервисов
  static Future<void> initialize() async {
    if (_initialized) return;
    
    // Регистрация сервисов как синглтонов
    _getIt.registerLazySingleton<SupabasePostService>(() => SupabasePostService());
    _getIt.registerLazySingleton<SupabaseUserService>(() => SupabaseUserService());
    _getIt.registerLazySingleton<SupabaseFollowRequestService>(() => SupabaseFollowRequestService());
    _getIt.registerLazySingleton<SupabaseNotificationService>(() => SupabaseNotificationService());
    _getIt.registerLazySingleton<SupabaseChatService>(() => SupabaseChatService());
    _getIt.registerLazySingleton<SupabaseDiscussionService>(() => SupabaseDiscussionService());
    _getIt.registerLazySingleton<SupabaseStorageService>(() => SupabaseStorageService());
    _getIt.registerLazySingleton<SupabaseCommunityService>(() => SupabaseCommunityService());
    _getIt.registerLazySingleton<SupabaseBlockService>(() => SupabaseBlockService());
    _getIt.registerLazySingleton<SupabaseReportService>(() => SupabaseReportService());
    _getIt.registerLazySingleton<SupabaseAuthService>(() => SupabaseAuthService());
    _getIt.registerLazySingleton<SupabaseSettingsService>(() => SupabaseSettingsService());
    _getIt.registerLazySingleton<CacheService>(() => CacheService());
    _getIt.registerLazySingleton<OfflineQueueService>(() => OfflineQueueService());
    
    _initialized = true;
  }
  
  /// Получить сервис
  static T get<T extends Object>() => _getIt.get<T>();
  
  /// Сброс локатора (для тестов)
  static Future<void> reset() async {
    await _getIt.reset();
    _initialized = false;
  }
}

/// Удобные геттеры для сервисов
class Services {
  static SupabasePostService get posts => ServiceLocator.get<SupabasePostService>();
  static SupabaseUserService get users => ServiceLocator.get<SupabaseUserService>();
  static SupabaseFollowRequestService get followRequests => ServiceLocator.get<SupabaseFollowRequestService>();
  static SupabaseNotificationService get notifications => ServiceLocator.get<SupabaseNotificationService>();
  static SupabaseChatService get chats => ServiceLocator.get<SupabaseChatService>();
  static SupabaseDiscussionService get discussions => ServiceLocator.get<SupabaseDiscussionService>();
  static SupabaseStorageService get storage => ServiceLocator.get<SupabaseStorageService>();
  static SupabaseCommunityService get communities => ServiceLocator.get<SupabaseCommunityService>();
  static SupabaseBlockService get blocks => ServiceLocator.get<SupabaseBlockService>();
  static SupabaseReportService get reports => ServiceLocator.get<SupabaseReportService>();
  static SupabaseAuthService get auth => ServiceLocator.get<SupabaseAuthService>();
  static SupabaseSettingsService get settings => ServiceLocator.get<SupabaseSettingsService>();
  static CacheService get cache => ServiceLocator.get<CacheService>();
  static OfflineQueueService get offlineQueue => ServiceLocator.get<OfflineQueueService>();
}
