// Модели данных для приложения Osekky

// Типы реакций на посты
enum ReactionType {
  like,
  love,
  haha,
  wow,
  sad,
  angry,
}

class User {
  final String id;
  final String name;
  final String username;
  final String avatar;
  final bool isPremium;
  final int karma;
  final int followersCount;
  final int followingCount;
  final DateTime? premiumExpiresAt;
  final List<String> badges;
  final int postsToday;
  final int postsCount;
  final UserRole role;
  final bool isFollowed;
  final List<String> followersList;
  final List<String> followingList;
  final bool isOnline;
  final DateTime? lastSeen; // Последнее посещение
  final String? bio; // О себе
  final List<String> links; // Ссылки (соцсети, сайт)
  final bool? isVerified; // Верифицированный аккаунт
  final bool isBlocked; // Заблокирован ли этот пользователь
  final bool isPrivate; // Закрытый аккаунт (требует подтверждения подписки)
  final String? email; // Email для проверки уникальности
  final String? phone; // Телефон для проверки уникальности
  final DateTime? nameChangedAt; // Дата последнего изменения имени
  final DateTime? usernameChangedAt; // Дата последнего изменения username
  final int usernameChangeCount; // Количество изменений username
  final String? gender; // Пол (мужской/женский/другой)
  final DateTime? birthDate; // Дата рождения
  final String? website; // Веб-сайт
  final String? websiteText; // Текст для ссылки (например "Мой сайт")
  final String? location; // Локация (город)
  final String? city; // Город пользователя
  final double? latitude; // Широта местоположения
  final double? longitude; // Долгота местоположения
  final bool emailVerified; // Подтверждён ли email (для защиты от спама)
  final String? deviceInstallId; // ID установки приложения (для защиты от мульти-аккаунтов)
  final bool isBanned; // Забанен ли пользователь
  final String? banReason; // Причина бана
  final DateTime? bannedUntil; // До какой даты забанен
  final String? profileColor; // Цвет фона профиля (hex)
  final DateTime? premiumGraceUntil; // Grace period после истечения Premium (7 дней)
  final bool? allowMessages; // Разрешены ли сообщения от других
  final String? whoCanMessage; // everyone / followers / nobody
  final String? privacyMessages; // privacy_messages из users: everyone/followers/nobody

  User({
    required this.id,
    required this.name,
    required this.username,
    this.avatar = '',
    this.isPremium = false,
    this.karma = 0,
    this.followersCount = 0,
    this.followingCount = 0,
    this.premiumExpiresAt,
    this.badges = const [],
    this.postsToday = 0,
    this.postsCount = 0,
    this.role = UserRole.free,
    this.isFollowed = false,
    this.followersList = const [],
    this.followingList = const [],
    this.isOnline = false,
    this.lastSeen,
    this.bio,
    this.links = const [],
    this.isVerified = false,
    this.isBlocked = false,
    this.isPrivate = false,
    this.email,
    this.phone,
    this.nameChangedAt,
    this.usernameChangedAt,
    this.usernameChangeCount = 0,
    this.gender,
    this.birthDate,
    this.city,
    this.website,
    this.websiteText,
    this.location,
    this.latitude,
    this.longitude,
    this.emailVerified = false,
    this.deviceInstallId,
    this.isBanned = false,
    this.banReason,
    this.bannedUntil,
    this.profileColor,
    this.premiumGraceUntil,
    this.allowMessages,
    this.whoCanMessage,
    this.privacyMessages,
  });

  bool get canPostAnonymously => isCurrentlyPremium;
  bool get canPostLongText => isCurrentlyPremium;
  bool get canPostMultipleImages => isCurrentlyPremium;
  int get maxTextLength => isCurrentlyPremium ? 2000 : 999;
  int get maxImagesPerPost => isCurrentlyPremium ? 10 : 3;
  int get maxPostsPerDay => isCurrentlyPremium ? 20 : 5;
  bool get canCreateCommunities => isCurrentlyPremium || karma > 1000;
  
  /// Проверяет актуальный Premium статус с учётом даты истечения и grace period
  bool get isCurrentlyPremium {
    final now = DateTime.now();
    // Обычный статус по дате истечения
    if (premiumExpiresAt != null && now.isBefore(premiumExpiresAt!)) return true;
    // Grace period после истечения (7 дней)
    if (premiumGraceUntil != null && now.isBefore(premiumGraceUntil!)) return true;
    return false;
  }

  /// Проверяет находится ли Premium в grace period
  bool get isInGracePeriod {
    if (premiumGraceUntil == null) return false;
    final now = DateTime.now();
    final expired = premiumExpiresAt == null || now.isAfter(premiumExpiresAt!);
    return expired && now.isBefore(premiumGraceUntil!);
  }
  
  /// Получает оставшиеся дни Premium
  int get premiumDaysLeft {
    if (!isPremium || premiumExpiresAt == null) return 0;
    final daysLeft = premiumExpiresAt!.difference(DateTime.now()).inDays;
    return daysLeft > 0 ? daysLeft : 0;
  }
  
  /// Проверяет истекает ли Premium скоро (менее 3 дней)
  bool get isPremiumExpiringSoon {
    final daysLeft = premiumDaysLeft;
    return daysLeft > 0 && daysLeft <= 3;
  }
  
  User copyWith({
    String? id,
    String? name,
    String? username,
    String? avatar,
    bool? isPremium,
    int? karma,
    int? followersCount,
    int? followingCount,
    DateTime? premiumExpiresAt,
    List<String>? badges,
    int? postsToday,
    int? postsCount,
    UserRole? role,
    bool? isFollowed,
    List<String>? followersList,
    List<String>? followingList,
    bool? isOnline,
    DateTime? lastSeen,
    String? bio,
    List<String>? links,
    bool? isVerified,
    bool? isBlocked,
    bool? isPrivate,
    String? email,
    String? phone,
    DateTime? nameChangedAt,
    DateTime? usernameChangedAt,
    int? usernameChangeCount,
    String? gender,
    DateTime? birthDate,
    String? city,
    String? website,
    String? websiteText,
    String? location,
    double? latitude,
    double? longitude,
    bool? emailVerified,
    String? deviceInstallId,
    bool? isBanned,
    String? banReason,
    DateTime? bannedUntil,
    String? profileColor,
    bool? allowMessages,
    String? whoCanMessage,
    String? privacyMessages,
  }) {
    return User(
      id: id ?? this.id,
      name: name ?? this.name,
      username: username ?? this.username,
      avatar: avatar ?? this.avatar,
      isPremium: isPremium ?? this.isPremium,
      karma: karma ?? this.karma,
      followersCount: followersCount ?? this.followersCount,
      followingCount: followingCount ?? this.followingCount,
      premiumExpiresAt: premiumExpiresAt ?? this.premiumExpiresAt,
      badges: badges ?? this.badges,
      postsToday: postsToday ?? this.postsToday,
      postsCount: postsCount ?? this.postsCount,
      role: role ?? this.role,
      isFollowed: isFollowed ?? this.isFollowed,
      followersList: followersList ?? this.followersList,
      followingList: followingList ?? this.followingList,
      isOnline: isOnline ?? this.isOnline,
      lastSeen: lastSeen ?? this.lastSeen,
      bio: bio ?? this.bio,
      links: links ?? this.links,
      isVerified: isVerified ?? this.isVerified,
      isBlocked: isBlocked ?? this.isBlocked,
      isPrivate: isPrivate ?? this.isPrivate,
      email: email ?? this.email,
      phone: phone ?? this.phone,
      nameChangedAt: nameChangedAt ?? this.nameChangedAt,
      usernameChangedAt: usernameChangedAt ?? this.usernameChangedAt,
      usernameChangeCount: usernameChangeCount ?? this.usernameChangeCount,
      gender: gender ?? this.gender,
      birthDate: birthDate ?? this.birthDate,
      city: city ?? this.city,
      website: website ?? this.website,
      websiteText: websiteText ?? this.websiteText,
      location: location ?? this.location,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      emailVerified: emailVerified ?? this.emailVerified,
      deviceInstallId: deviceInstallId ?? this.deviceInstallId,
      isBanned: isBanned ?? this.isBanned,
      banReason: banReason ?? this.banReason,
      bannedUntil: bannedUntil ?? this.bannedUntil,
      profileColor: profileColor ?? this.profileColor,
      allowMessages: allowMessages ?? this.allowMessages,
      whoCanMessage: whoCanMessage ?? this.whoCanMessage,
      privacyMessages: privacyMessages ?? this.privacyMessages,
    );
  }

  factory User.fromJson(Map<String, dynamic> json) {
    final roleString = json['role'] as String?;
    final role = UserRole.values.firstWhere(
      (r) => r.name == roleString,
      orElse: () => UserRole.free,
    );

    return User(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      username: json['username'] as String? ?? 'user',
      avatar: json['avatar'] as String? ?? '',
      isPremium: role == UserRole.premium || (json['is_premium'] as bool? ?? false),
      karma: json['karma'] as int? ?? 0,
      followersCount: json['followers_count'] as int? ?? 0,
      followingCount: json['following_count'] as int? ?? 0,
      premiumExpiresAt: json['premium_expires_at'] != null
          ? DateTime.tryParse(json['premium_expires_at'] as String)
          : null,
      badges: (json['badges'] as List<dynamic>? ?? []).map((e) => e.toString()).toList(),
      postsToday: json['posts_today'] as int? ?? 0,
      postsCount: json['posts_count'] as int? ?? 0,
      role: role,
      isFollowed: json['is_followed'] as bool? ?? false,
      followersList: (json['followers_list'] as List<dynamic>? ?? []).map((e) => e.toString()).toList(),
      followingList: (json['following_list'] as List<dynamic>? ?? []).map((e) => e.toString()).toList(),
      isOnline: json['is_online'] as bool? ?? false,
      lastSeen: json['last_seen'] != null ? DateTime.tryParse(json['last_seen'] as String) : null,
      bio: json['bio'] as String?,
      links: (json['links'] as List<dynamic>? ?? []).map((e) => e.toString()).toList(),
      isVerified: json['is_verified'] as bool?,
      isBlocked: json['is_blocked'] as bool? ?? false,
      isPrivate: json['is_private'] as bool? ?? false,
      email: json['email'] as String?,
      phone: json['phone'] as String?,
      nameChangedAt: json['name_changed_at'] != null ? DateTime.tryParse(json['name_changed_at'] as String) : null,
      usernameChangedAt: json['username_changed_at'] != null ? DateTime.tryParse(json['username_changed_at'] as String) : null,
      usernameChangeCount: json['username_change_count'] as int? ?? 0,
      gender: json['gender'] as String?,
      birthDate: json['birth_date'] != null ? DateTime.tryParse(json['birth_date'] as String) : null,
      website: json['website'] as String?,
      websiteText: json['website_text'] as String?,
      location: json['location'] as String?,
      city: json['city'] as String?,
      latitude: (json['latitude'] as num?)?.toDouble(),
      longitude: (json['longitude'] as num?)?.toDouble(),
      emailVerified: json['email_verified'] as bool? ?? false,
      deviceInstallId: json['device_install_id'] as String?,
      isBanned: json['is_banned'] as bool? ?? false,
      banReason: json['ban_reason'] as String?,
      bannedUntil: json['banned_until'] != null ? DateTime.tryParse(json['banned_until'] as String) : null,
      profileColor: json['profile_color'] as String?,
      allowMessages: json['allow_messages'] as bool?,
      whoCanMessage: json['who_can_message'] as String?,
      privacyMessages: json['privacy_messages'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'username': username,
      'avatar': avatar,
      'is_premium': isPremium,
      'karma': karma,
      'followers_count': followersCount,
      'following_count': followingCount,
      'premium_expires_at': premiumExpiresAt?.toIso8601String(),
      'badges': badges,
      'posts_today': postsToday,
      'posts_count': postsCount,
      'role': role.name,
      'is_followed': isFollowed,
      'followers_list': followersList,
      'following_list': followingList,
      'is_online': isOnline,
      'last_seen': lastSeen?.toIso8601String(),
      'bio': bio,
      'links': links,
      'is_verified': isVerified,
      'is_blocked': isBlocked,
      'is_private': isPrivate,
      'email': email,
      'phone': phone,
      'name_changed_at': nameChangedAt?.toIso8601String(),
      'username_changed_at': usernameChangedAt?.toIso8601String(),
      'username_change_count': usernameChangeCount,
      'gender': gender,
      'birth_date': birthDate?.toIso8601String(),
      'city': city,
      'website': website,
      'website_text': websiteText,
      'location': location,
      'latitude': latitude,
      'longitude': longitude,
      'email_verified': emailVerified,
      'device_install_id': deviceInstallId,
      'is_banned': isBanned,
      'ban_reason': banReason,
      'banned_until': bannedUntil?.toIso8601String(),
      'profile_color': profileColor,
    };
  }
}

enum UserRole { free, premium, moderator, admin }

// Тип медиа для объединённой карусели
enum MediaType { image, video }

// Элемент медиа (фото или видео)
class MediaItem {
  final String path;
  final MediaType type;
  final String? thumbnail; // Превью для видео
  
  MediaItem({
    required this.path,
    required this.type,
    this.thumbnail,
  });
  
  bool get isVideo => type == MediaType.video;
  bool get isImage => type == MediaType.image;

  factory MediaItem.fromJson(Map<String, dynamic> json) {
    final typeName = json['type'] as String?;
    final mediaType = MediaType.values.firstWhere(
      (t) => t.name == typeName,
      orElse: () => MediaType.image,
    );
    return MediaItem(
      path: json['path'] as String? ?? '',
      type: mediaType,
      thumbnail: json['thumbnail'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'path': path,
      'type': type.name,
      'thumbnail': thumbnail,
    };
  }
}

class Story {
  final String id;
  final String text;
  final User author;
  final DateTime createdAt;
  final int likes;
  final int comments;
  final int reposts;
  final int views; // Счетчик просмотров
  final bool isLiked;
  final bool isBookmarked;
  final List<String> images;
  final List<String> videos; // Видео файлы
  final String? videoThumbnail; // Превью видео
  final List<MediaItem> media; // Объединённый список медиа (фото + видео)
  final bool isAnonymous;
  final bool isAdult; // 18+ контент
  final bool isBlocked; // Заблокирован админом
  final bool isHidden; // Скрыт
  final bool isDeleted; // Удален (soft delete)
  final bool isEdited; // Был ли пост отредактирован
  
  // Репосты
  final Story? quotedStory; // Цитируемый пост (для репостов)
  
  // Цепочки историй (сериалы)
  final String? seriesId; // ID серии
  final int? seriesIndex; // Номер части (1, 2, 3...)
  final int? seriesTotalParts; // Всего частей (5, 10...)
  final List<String>? parts; // Для цепочек историй (несколько частей)
  final Poll? poll; // Опрос (если есть)
  
  // Геолокация
  final String? city; // Город
  final double? latitude; // Широта
  final double? longitude; // Долгота
  final String? locationName; // Название места (опционально)
  
  // Дебаты (для репостов дебатов)
  final String? debateId; // ID дебата
  final String? debateQuestion; // Вопрос дебата
  final List<String>? debateOptions; // Варианты ответов
  final int? debateTotalVotes; // Всего голосов
  final bool? debateIsActive; // Активен ли дебат
  final DateTime? debateEndsAt; // Когда заканчивается
  final String? debateUserVote; // Голос пользователя

  Story({
    required this.id,
    required this.text,
    required this.author,
    required this.createdAt,
    required this.likes,
    required this.comments,
    required this.reposts,
    this.views = 0,
    this.isLiked = false,
    this.isBookmarked = false,
    this.images = const [],
    this.videos = const [],
    this.videoThumbnail,
    this.media = const [],
    this.isAnonymous = false,
    this.isAdult = false,
    this.isBlocked = false,
    this.isHidden = false,
    this.isDeleted = false,
    this.isEdited = false,
    this.quotedStory,
    this.seriesId,
    this.seriesIndex,
    this.seriesTotalParts,
    this.parts,
    this.poll,
    this.city,
    this.latitude,
    this.longitude,
    this.locationName,
    // Дебаты
    this.debateId,
    this.debateQuestion,
    this.debateOptions,
    this.debateTotalVotes,
    this.debateIsActive,
    this.debateEndsAt,
    this.debateUserVote,
  });

  Story copyWith({
    String? id,
    String? text,
    User? author,
    DateTime? createdAt,
    int? likes,
    int? comments,
    int? reposts,
    int? views,
    bool? isLiked,
    bool? isBookmarked,
    bool? isEdited,
    List<String>? images,
    List<String>? videos,
    String? videoThumbnail,
    List<MediaItem>? media,
    bool? isAnonymous,
    bool? isAdult,
    bool? isBlocked,
    bool? isHidden,
    bool? isDeleted,
    Story? quotedStory,
    List<String>? parts,
    Poll? poll,
    String? city,
    double? latitude,
    double? longitude,
    String? locationName,
    // Дебаты
    String? debateId,
    String? debateQuestion,
    List<String>? debateOptions,
    int? debateTotalVotes,
    bool? debateIsActive,
    DateTime? debateEndsAt,
    String? debateUserVote,
  }) {
    return Story(
      id: id ?? this.id,
      text: text ?? this.text,
      author: author ?? this.author,
      createdAt: createdAt ?? this.createdAt,
      likes: likes ?? this.likes,
      comments: comments ?? this.comments,
      reposts: reposts ?? this.reposts,
      views: views ?? this.views,
      isLiked: isLiked ?? this.isLiked,
      isBookmarked: isBookmarked ?? this.isBookmarked,
      isEdited: isEdited ?? this.isEdited,
      images: images ?? this.images,
      videos: videos ?? this.videos,
      videoThumbnail: videoThumbnail ?? this.videoThumbnail,
      media: media ?? this.media,
      isAnonymous: isAnonymous ?? this.isAnonymous,
      isAdult: isAdult ?? this.isAdult,
      isBlocked: isBlocked ?? this.isBlocked,
      isHidden: isHidden ?? this.isHidden,
      isDeleted: isDeleted ?? this.isDeleted,
      quotedStory: quotedStory ?? this.quotedStory,
      parts: parts ?? this.parts,
      poll: poll ?? this.poll,
      city: city ?? this.city,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      locationName: locationName ?? this.locationName,
      // Дебаты
      debateId: debateId ?? this.debateId,
      debateQuestion: debateQuestion ?? this.debateQuestion,
      debateOptions: debateOptions ?? this.debateOptions,
      debateTotalVotes: debateTotalVotes ?? this.debateTotalVotes,
      debateIsActive: debateIsActive ?? this.debateIsActive,
      debateEndsAt: debateEndsAt ?? this.debateEndsAt,
      debateUserVote: debateUserVote ?? this.debateUserVote,
    );
  }

  factory Story.fromJson(Map<String, dynamic> json) {
    return Story(
      id: json['id'] as String? ?? '',
      text: json['content'] as String? ?? json['text'] as String? ?? '',
      author: json['author'] != null
          ? User.fromJson(Map<String, dynamic>.from(json['author'] as Map))
          : User(
              id: '',
              name: 'Пользователь',
              username: 'user',
              avatar: '',
              isPremium: false,
            ),
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'] as String) ?? DateTime.now()
          : DateTime.now(),
      likes: json['likes'] as int? ?? 0,
      comments: json['comments'] as int? ?? 0,
      reposts: json['reposts'] as int? ?? 0,
      views: json['views'] as int? ?? 0,
      isLiked: json['is_liked'] as bool? ?? false,
      isBookmarked: json['is_bookmarked'] as bool? ?? false,
      images: (json['images'] as List<dynamic>? ?? []).map((e) => e.toString()).toList(),
      videos: (json['videos'] as List<dynamic>? ?? []).map((e) => e.toString()).toList(),
      videoThumbnail: json['video_thumbnail'] as String?,
      media: (json['media'] as List<dynamic>? ?? [])
          .map((item) => MediaItem.fromJson(Map<String, dynamic>.from(item as Map)))
          .toList(),
      isAnonymous: json['is_anonymous'] as bool? ?? false,
      isAdult: json['is_adult'] as bool? ?? false,
      isBlocked: json['is_blocked'] as bool? ?? false,
      isHidden: json['is_hidden'] as bool? ?? false,
      isDeleted: json['is_deleted'] as bool? ?? false,
      isEdited: json['is_edited'] as bool? ?? false,
      quotedStory: json['quoted_story'] != null
          ? Story.fromJson(Map<String, dynamic>.from(json['quoted_story'] as Map))
          : null,
      seriesId: json['series_id'] as String?,
      seriesIndex: json['series_index'] as int?,
      seriesTotalParts: json['series_total_parts'] as int?,
      parts: (json['parts'] as List<dynamic>? ?? []).map((e) => e.toString()).toList(),
      poll: json['poll'] != null ? Poll.fromJson(Map<String, dynamic>.from(json['poll'] as Map)) : null,
      city: json['city'] as String?,
      latitude: (json['latitude'] as num?)?.toDouble(),
      longitude: (json['longitude'] as num?)?.toDouble(),
      locationName: json['location_name'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'text': text,
      'author': author.toJson(),
      'created_at': createdAt.toIso8601String(),
      'likes': likes,
      'comments': comments,
      'reposts': reposts,
      'views': views,
      'is_liked': isLiked,
      'is_bookmarked': isBookmarked,
      'images': images,
      'videos': videos,
      'video_thumbnail': videoThumbnail,
      'media': media.map((m) => m.toJson()).toList(),
      'is_anonymous': isAnonymous,
      'is_adult': isAdult,
      'is_blocked': isBlocked,
      'is_hidden': isHidden,
      'is_deleted': isDeleted,
      'is_edited': isEdited,
      'quoted_story': quotedStory?.toJson(),
      'series_id': seriesId,
      'series_index': seriesIndex,
      'series_total_parts': seriesTotalParts,
      'parts': parts,
      'poll': poll?.toJson(),
      'city': city,
      'latitude': latitude,
      'longitude': longitude,
      'location_name': locationName,
    };
  }
}


enum FilterType { hot, comments, new_, subscriptions, adult, anonymous, elite }

// Категории диалогов
enum DialogCategory {
  family,       // 👨‍👩‍👧 Семья и отношения
  kazakhstan,   // 🇰🇿 Казахстан
  language,     // 🗣️ Язык и культура
  youth,        // 👶 Молодёжь
  religion,     // 🕌 Религия
  career,       // 💼 Работа и карьера
  education,    // 🎓 Образование
  society,      // 🏙️ Общество
  economy,      // 💰 Экономика
  politics,     // ⚖️ Политика
  world,        // 🌍 Мир
  future,       // 🔮 Будущее
  philosophy,   // 💭 Философия
  culture,      // 🎨 Искусство и культура
  sport,        // ⚽ Спорт
  food,         // 🍔 Еда и кухня
  lifestyle,    // 🏠 Быт и образ жизни
  technology,   // 💡 Технологии
  health,       // 🏥 Здоровье
  other,        // 💬 Другое
}

// Типы диалогов
enum DialogType {
  question,     // ❓ Вопрос-Ответ
  debate,       // ⚔️ Дебаты (За/Против)
  poll,         // 📊 Опрос
  discussion,   // 💭 Обсуждение
}

// Модель диалога
class DiscussionTopic {
  final String id;
  final DialogType type;
  final DialogCategory category;
  final String title;
  final String? description;
  final User author;
  final DateTime createdAt;
  final int answersCount;
  final int viewsCount;
  final bool isActive;
  final DateTime? closesAt; // Для опросов
  
  DiscussionTopic({
    required this.id,
    required this.type,
    required this.category,
    required this.title,
    this.description,
    required this.author,
    required this.createdAt,
    this.answersCount = 0,
    this.viewsCount = 0,
    this.isActive = true,
    this.closesAt,
  });
}

// Модель ответа в диалоге
class DialogAnswer {
  final String id;
  final String dialogId;
  final String topicId; // Alias for dialogId for Supabase compatibility
  final User author;
  final String text;
  final DebateSide? side; // Для дебатов
  final DateTime createdAt;
  final int likesCount;
  final List<String> likedBy;
  final String? parentId; // Для вложенных ответов
  final int repliesCount;
  final bool isAccepted; // Принят ли ответ (для вопросов)
  
  DialogAnswer({
    required this.id,
    required this.dialogId,
    String? topicId,
    required this.author,
    required this.text,
    this.side,
    required this.createdAt,
    this.likesCount = 0,
    this.likedBy = const [],
    this.parentId,
    this.repliesCount = 0,
    this.isAccepted = false,
  }) : topicId = topicId ?? dialogId;
  
  DialogAnswer copyWith({
    String? id,
    String? dialogId,
    String? topicId,
    User? author,
    String? text,
    DebateSide? side,
    DateTime? createdAt,
    int? likesCount,
    List<String>? likedBy,
    String? parentId,
    int? repliesCount,
    bool? isAccepted,
  }) {
    return DialogAnswer(
      id: id ?? this.id,
      dialogId: dialogId ?? this.dialogId,
      topicId: topicId ?? this.topicId,
      author: author ?? this.author,
      text: text ?? this.text,
      side: side ?? this.side,
      createdAt: createdAt ?? this.createdAt,
      likesCount: likesCount ?? this.likesCount,
      likedBy: likedBy ?? this.likedBy,
      parentId: parentId ?? this.parentId,
      repliesCount: repliesCount ?? this.repliesCount,
      isAccepted: isAccepted ?? this.isAccepted,
    );
  }
}

// Типы жалоб
enum ReportType {
  spam,           // Спам
  harassment,     // Оскорбления/домогательства
  inappropriate,  // Неприемлемый контент
  adult,          // 18+ контент
  fake,           // Фейк/дезинформация
  violence,       // Насилие
  copyright,      // Нарушение авторских прав
  other,          // Другое
}

// Тип контента для жалобы
enum ReportContentType {
  story,          // Пост
  comment,        // Комментарий
  user,           // Пользователь
  community,      // Сообщество
}

// Модель жалобы
class Report {
  final String id;
  final ReportType type;
  final ReportContentType contentType;
  final String contentId; // ID поста/комментария/пользователя
  final User reporter; // Кто пожаловался
  final String? description; // Дополнительное описание
  final DateTime createdAt;
  final bool isResolved; // Рассмотрена ли жалоба
  final String? resolvedBy; // ID модератора, который рассмотрел

  Report({
    required this.id,
    required this.type,
    required this.contentType,
    required this.contentId,
    required this.reporter,
    this.description,
    required this.createdAt,
    this.isResolved = false,
    this.resolvedBy,
  });

  Report copyWith({
    String? id,
    ReportType? type,
    ReportContentType? contentType,
    String? contentId,
    User? reporter,
    String? description,
    DateTime? createdAt,
    bool? isResolved,
    String? resolvedBy,
  }) {
    return Report(
      id: id ?? this.id,
      type: type ?? this.type,
      contentType: contentType ?? this.contentType,
      contentId: contentId ?? this.contentId,
      reporter: reporter ?? this.reporter,
      description: description ?? this.description,
      createdAt: createdAt ?? this.createdAt,
      isResolved: isResolved ?? this.isResolved,
      resolvedBy: resolvedBy ?? this.resolvedBy,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'type': type.name,
      'content_type': contentType.name,
      'content_id': contentId,
      'reporter_id': reporter.id,
      'description': description,
      'created_at': createdAt.toIso8601String(),
      'is_resolved': isResolved,
      'resolved_by': resolvedBy,
    };
  }

  factory Report.fromJson(Map<String, dynamic> json) {
    return Report(
      id: json['id'] as String,
      type: ReportType.values.firstWhere(
        (e) => e.name == json['type'],
        orElse: () => ReportType.other,
      ),
      contentType: ReportContentType.values.firstWhere(
        (e) => e.name == json['content_type'],
        orElse: () => ReportContentType.story,
      ),
      contentId: json['content_id'] as String,
      reporter: User(
        id: json['reporter_id'] as String,
        name: 'User',
        username: 'user',
        avatar: '',
        isPremium: false,
        karma: 0,
      ),
      description: json['description'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
      isResolved: json['is_resolved'] as bool? ?? false,
      resolvedBy: json['resolved_by'] as String?,
    );
  }
}

// Типы уведомлений
enum NotificationType {
  like,           // Лайк на пост
  commentLike,    // Лайк на комментарий
  comment,        // Комментарий к посту
  reply,          // Ответ на комментарий
  follow,         // Новый подписчик
  mention,        // Упоминание в посте
  repost,         // Репост вашего поста
  system,         // Системное уведомление
  premium,        // Уведомление о Premium
  community,      // Уведомление от сообщества
  emailChange,    // Смена email адреса
  // Уведомления для дебатов
  debateComment,  // Комментарий к дебату
  debateReply,    // Ответ на комментарий в дебате
  debateLike,     // Лайк комментария в дебате
  debateVote,     // Голос в дебате
}

// Модель уведомления
class AppNotification {
  final String id;
  final NotificationType type;
  final User? fromUser; // Кто совершил действие (null для системных)
  final String title;
  final String message;
  final DateTime createdAt;
  final bool isRead;
  final String? relatedId; // ID поста/комментария/сообщества
  final String? imageUrl; // Аватар или превью
  final String? commentId; // ID комментария для прокрутки
  final String? commentText; // Текст комментария для отображения
  // Поля для группировки
  final bool isGrouped; // Это сгруппированное уведомление
  final int? groupCount; // Количество уведомлений в группе
  final List<User>? actors; // Все пользователи в группе

  AppNotification({
    required this.id,
    required this.type,
    this.fromUser,
    required this.title,
    required this.message,
    required this.createdAt,
    this.isRead = false,
    this.relatedId,
    this.imageUrl,
    this.commentId,
    this.commentText,
    this.isGrouped = false,
    this.groupCount,
    this.actors,
  });

  factory AppNotification.empty() => AppNotification(
        id: '',
        type: NotificationType.system,
        title: '',
        message: '',
        createdAt: DateTime(2000),
        isRead: true,
      );

  AppNotification copyWith({
    String? id,
    NotificationType? type,
    User? fromUser,
    String? title,
    String? message,
    DateTime? createdAt,
    bool? isRead,
    String? relatedId,
    String? imageUrl,
    String? commentId,
    String? commentText,
    bool? isGrouped,
    int? groupCount,
    List<User>? actors,
  }) {
    return AppNotification(
      id: id ?? this.id,
      type: type ?? this.type,
      fromUser: fromUser ?? this.fromUser,
      title: title ?? this.title,
      message: message ?? this.message,
      createdAt: createdAt ?? this.createdAt,
      isRead: isRead ?? this.isRead,
      relatedId: relatedId ?? this.relatedId,
      imageUrl: imageUrl ?? this.imageUrl,
      commentId: commentId ?? this.commentId,
      commentText: commentText ?? this.commentText,
      isGrouped: isGrouped ?? this.isGrouped,
      groupCount: groupCount ?? this.groupCount,
      actors: actors ?? this.actors,
    );
  }
}

// Модель сообщества
class Community {
  final String id;
  final String name;
  final String description;
  final String avatar;
  final String coverImage;
  final int membersCount;
  final int postsCount;
  final bool isJoined;
  final List<String> tags;

  Community({
    required this.id,
    required this.name,
    required this.description,
    required this.avatar,
    required this.coverImage,
    required this.membersCount,
    required this.postsCount,
    this.isJoined = false,
    this.tags = const [],
  });

  Community copyWith({
    String? id,
    String? name,
    String? description,
    String? avatar,
    String? coverImage,
    int? membersCount,
    int? postsCount,
    bool? isJoined,
    List<String>? tags,
  }) {
    return Community(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      avatar: avatar ?? this.avatar,
      coverImage: coverImage ?? this.coverImage,
      membersCount: membersCount ?? this.membersCount,
      postsCount: postsCount ?? this.postsCount,
      isJoined: isJoined ?? this.isJoined,
      tags: tags ?? this.tags,
    );
  }
}

// Модель сообщения в чате
class ChatMessage {
  final String id;
  final String chatId; // ID диалога
  final User sender;
  final String text;
  final DateTime createdAt;
  final bool isRead;
  final bool isDelivered; // Доставлено на устройство получателя
  final String? imageUrl; // Deprecated - используем images
  final List<String> images; // Список URL изображений
  final String? mediaUrl; // URL медиа (фото/видео/аудио)
  final String? mediaType; // Тип медиа: image, video, audio
  final String? videoThumbnail; // URL превью для видео
  final bool isEdited;
  final DateTime? editedAt;
  final bool isDeletedForMe;
  final bool isDeletedForEveryone;
  final String? replyToId; // ID сообщения, на которое отвечаем
  final ChatMessage? replyToMessage; // Само сообщение для отображения
  final Map<String, ReactionType> reactions; // userId -> ReactionType
  final bool isPinned; // Закреплено
  final bool isBookmarked; // Избранное
  final bool isSending; // Сообщение отправляется (Optimistic UI)
  final bool sendFailed; // Ошибка отправки
  final String? forwardedFromId; // ID оригинального сообщения при пересылке
  final String? forwardedFromName; // Имя отправителя оригинала

  ChatMessage({
    required this.id,
    required this.chatId,
    required this.sender,
    required this.text,
    required this.createdAt,
    this.isRead = false,
    this.isDelivered = false,
    this.imageUrl,
    this.images = const [],
    this.mediaUrl,
    this.mediaType,
    this.videoThumbnail,
    this.isEdited = false,
    this.editedAt,
    this.isDeletedForMe = false,
    this.isDeletedForEveryone = false,
    this.replyToId,
    this.replyToMessage,
    this.reactions = const {},
    this.isPinned = false,
    this.isBookmarked = false,
    this.isSending = false,
    this.sendFailed = false,
    this.forwardedFromId,
    this.forwardedFromName,
  });

  ChatMessage copyWith({
    String? id,
    String? chatId,
    User? sender,
    String? text,
    DateTime? createdAt,
    bool? isRead,
    bool? isDelivered,
    String? imageUrl,
    List<String>? images,
    String? mediaUrl,
    String? mediaType,
    String? videoThumbnail,
    bool? isEdited,
    DateTime? editedAt,
    bool? isDeletedForMe,
    bool? isDeletedForEveryone,
    String? replyToId,
    ChatMessage? replyToMessage,
    Map<String, ReactionType>? reactions,
    bool? isPinned,
    bool? isBookmarked,
    bool? isSending,
    bool? sendFailed,
    String? forwardedFromId,
    String? forwardedFromName,
  }) {
    return ChatMessage(
      id: id ?? this.id,
      chatId: chatId ?? this.chatId,
      sender: sender ?? this.sender,
      text: text ?? this.text,
      createdAt: createdAt ?? this.createdAt,
      isRead: isRead ?? this.isRead,
      isDelivered: isDelivered ?? this.isDelivered,
      imageUrl: imageUrl ?? this.imageUrl,
      images: images ?? this.images,
      mediaUrl: mediaUrl ?? this.mediaUrl,
      mediaType: mediaType ?? this.mediaType,
      videoThumbnail: videoThumbnail ?? this.videoThumbnail,
      isEdited: isEdited ?? this.isEdited,
      editedAt: editedAt ?? this.editedAt,
      isDeletedForMe: isDeletedForMe ?? this.isDeletedForMe,
      isDeletedForEveryone: isDeletedForEveryone ?? this.isDeletedForEveryone,
      replyToId: replyToId ?? this.replyToId,
      replyToMessage: replyToMessage ?? this.replyToMessage,
      reactions: reactions ?? this.reactions,
      isPinned: isPinned ?? this.isPinned,
      isBookmarked: isBookmarked ?? this.isBookmarked,
      isSending: isSending ?? this.isSending,
      sendFailed: sendFailed ?? this.sendFailed,
      forwardedFromId: forwardedFromId ?? this.forwardedFromId,
      forwardedFromName: forwardedFromName ?? this.forwardedFromName,
    );
  }
}

// Модель комментария
class Comment {
  final String id;
  final String storyId;
  final User author;
  final String text;
  final DateTime createdAt;
  final DateTime? updatedAt; // Время последнего редактирования
  final int likes;
  final bool isLiked;
  final String? replyToId; // ID комментария, на который отвечаем (корневой для ветки)
  final String? replyToAuthor; // Имя автора, которому отвечаем
  final String? replyTargetId; // Точный комментарий, на который ответили
  final String? threadRootId; // ID корневого комментария ветки
  final bool isPendingSync; // Комментарий ещё не синхронизирован с Supabase
  final bool isAnonymous; // Анонимный комментарий (Premium)
  final String? mediaUrl; // URL медиа (GIF или картинка)
  final String? mediaType; // Тип медиа: 'gif' или 'image'
  final int? mediaWidth; // Ширина медиа
  final int? mediaHeight; // Высота медиа
  final bool isPinned; // Закреплённый комментарий (автором поста)

  Comment({
    required this.id,
    required this.storyId,
    required this.author,
    required this.text,
    required this.createdAt,
    this.updatedAt,
    this.likes = 0,
    this.isLiked = false,
    this.replyToId,
    this.replyToAuthor,
    this.replyTargetId,
    this.threadRootId,
    this.isPendingSync = false,
    this.isAnonymous = false,
    this.mediaUrl,
    this.mediaType,
    this.mediaWidth,
    this.mediaHeight,
    this.isPinned = false,
  });

  // Проверка, был ли комментарий отредактирован
  bool get isEdited {
    if (updatedAt == null) return false;
    // Считаем отредактированным только если updatedAt отличается от createdAt более чем на 5 секунд
    // Это исключает ложные срабатывания из-за точности БД и таймзон
    final difference = updatedAt!.difference(createdAt);
    return difference.inSeconds > 5;
  }

  // Проверка, можно ли редактировать (в течение 10 минут)
  bool get canEdit {
    final now = DateTime.now();
    final difference = now.difference(createdAt);
    return difference.inMinutes < 10;
  }

  Comment copyWith({
    String? id,
    String? storyId,
    User? author,
    String? text,
    DateTime? createdAt,
    DateTime? updatedAt,
    int? likes,
    bool? isLiked,
    String? replyToId,
    String? replyToAuthor,
    String? replyTargetId,
    String? threadRootId,
    bool? isPendingSync,
    bool? isAnonymous,
    String? mediaUrl,
    String? mediaType,
    int? mediaWidth,
    int? mediaHeight,
    bool? isPinned,
  }) {
    return Comment(
      id: id ?? this.id,
      storyId: storyId ?? this.storyId,
      author: author ?? this.author,
      text: text ?? this.text,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      likes: likes ?? this.likes,
      isLiked: isLiked ?? this.isLiked,
      replyToId: replyToId ?? this.replyToId,
      replyToAuthor: replyToAuthor ?? this.replyToAuthor,
      replyTargetId: replyTargetId ?? this.replyTargetId,
      threadRootId: threadRootId ?? this.threadRootId,
      isPendingSync: isPendingSync ?? this.isPendingSync,
      isAnonymous: isAnonymous ?? this.isAnonymous,
      mediaUrl: mediaUrl ?? this.mediaUrl,
      mediaType: mediaType ?? this.mediaType,
      mediaWidth: mediaWidth ?? this.mediaWidth,
      mediaHeight: mediaHeight ?? this.mediaHeight,
      isPinned: isPinned ?? this.isPinned,
    );
  }
}

// Модель опроса
class Poll {
  final String id;
  final String question;
  final List<PollOption> options;
  final DateTime? endsAt; // Когда опрос закрывается
  final bool allowMultipleAnswers;
  final int totalVotes;

  Poll({
    required this.id,
    required this.question,
    required this.options,
    this.endsAt,
    this.allowMultipleAnswers = false,
    this.totalVotes = 0,
  });

  bool get isActive {
    if (endsAt == null) return true;
    return DateTime.now().isBefore(endsAt!);
  }

  Poll copyWith({
    String? id,
    String? question,
    List<PollOption>? options,
    DateTime? endsAt,
    bool? allowMultipleAnswers,
    int? totalVotes,
  }) {
    return Poll(
      id: id ?? this.id,
      question: question ?? this.question,
      options: options ?? this.options,
      endsAt: endsAt ?? this.endsAt,
      allowMultipleAnswers: allowMultipleAnswers ?? this.allowMultipleAnswers,
      totalVotes: totalVotes ?? this.totalVotes,
    );
  }

  factory Poll.fromJson(Map<String, dynamic> json) {
    return Poll(
      id: json['id'] as String? ?? '',
      question: json['question'] as String? ?? '',
      options: (json['options'] as List<dynamic>? ?? [])
          .map((item) => PollOption.fromJson(Map<String, dynamic>.from(item as Map)))
          .toList(),
      endsAt: json['ends_at'] != null ? DateTime.tryParse(json['ends_at'] as String) : null,
      allowMultipleAnswers: json['allow_multiple_answers'] as bool? ?? false,
      totalVotes: json['total_votes'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'question': question,
      'options': options.map((o) => o.toJson()).toList(),
      'ends_at': endsAt?.toIso8601String(),
      'allow_multiple_answers': allowMultipleAnswers,
      'total_votes': totalVotes,
    };
  }
}

// Вариант ответа в опросе
class PollOption {
  final String id;
  final String text;
  final int votes;
  final List<String> votedBy; // ID пользователей, проголосовавших

  PollOption({
    required this.id,
    required this.text,
    this.votes = 0,
    this.votedBy = const [],
  });

  PollOption copyWith({
    String? id,
    String? text,
    int? votes,
    List<String>? votedBy,
  }) {
    return PollOption(
      id: id ?? this.id,
      text: text ?? this.text,
      votes: votes ?? this.votes,
      votedBy: votedBy ?? this.votedBy,
    );
  }

  factory PollOption.fromJson(Map<String, dynamic> json) {
    return PollOption(
      id: json['id'] as String? ?? '',
      text: json['text'] as String? ?? '',
      votes: json['votes'] as int? ?? 0,
      votedBy: (json['voted_by'] as List<dynamic>? ?? []).map((e) => e.toString()).toList(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'text': text,
      'votes': votes,
      'voted_by': votedBy,
    };
  }
}

// Типы обсуждений
enum DiscussionType {
  discussion, // Обычное обсуждение
  debate,     // Дебат (За/Против)
}

// Категории обсуждений
enum DiscussionCategory {
  kazakhstan,   // 🇰🇿 Казахстан
  family,       // 👨‍👩‍👧 Семья и отношения
  work,         // 💼 Работа и карьера
  education,    // 🎓 Образование
  religion,     // 🕌 Религия
  economy,      // 💰 Экономика
  health,       // 🏥 Здоровье
  entertainment,// 🎮 Развлечения
  world,        // 🌍 Мир и политика
  science,      // 🔬 Наука и технологии
}

// Сторона в дебате
enum DebateSide {
  for_,      // За
  against,   // Против
  unsure,    // Не знаю
  neutral,   // Нейтральный (обычный комментарий)
}

// Модель обсуждения/дебата
class Discussion {
  final String id;
  final DiscussionType type;
  final String question;
  final String? description;
  final String? imageUrl;
  final DiscussionCategory category;
  final User author;
  final DateTime createdAt;
  final bool hasTimer;
  final DateTime? endsAt;
  final int viewsCount;
  final int commentsCount;
  
  // Для дебатов
  final int votesFor;
  final int votesAgainst;
  final int votesUnsure;
  
  // Голос текущего пользователя
  final DebateSide? userVote;
  final DateTime? userVotedAt;
  
  // Анонимность (премиум)
  final bool isAnonymous;

  Discussion({
    required this.id,
    required this.type,
    required this.question,
    this.description,
    this.imageUrl,
    required this.category,
    required this.author,
    required this.createdAt,
    this.hasTimer = false,
    this.endsAt,
    this.viewsCount = 0,
    this.commentsCount = 0,
    this.votesFor = 0,
    this.votesAgainst = 0,
    this.votesUnsure = 0,
    this.userVote,
    this.userVotedAt,
    this.isAnonymous = false,
  });

  bool get isActive {
    if (!hasTimer || endsAt == null) return true;
    return DateTime.now().isBefore(endsAt!);
  }

  bool get isEnded {
    return !isActive;
  }

  Duration? get timeRemaining {
    if (!hasTimer || endsAt == null) return null;
    final now = DateTime.now();
    if (now.isAfter(endsAt!)) return Duration.zero;
    return endsAt!.difference(now);
  }

  int get totalVotes => votesFor + votesAgainst + votesUnsure;

  double get percentFor => totalVotes > 0 ? (votesFor / totalVotes) * 100 : 0;
  double get percentAgainst => totalVotes > 0 ? (votesAgainst / totalVotes) * 100 : 0;
  double get percentUnsure => totalVotes > 0 ? (votesUnsure / totalVotes) * 100 : 0;

  bool get canChangeVote {
    if (userVotedAt == null) return true;
    final timeSinceVote = DateTime.now().difference(userVotedAt!);
    return timeSinceVote.inMinutes < 10; // Можно менять в течение 10 минут
  }

  Discussion copyWith({
    String? id,
    DiscussionType? type,
    String? question,
    String? description,
    String? imageUrl,
    DiscussionCategory? category,
    User? author,
    DateTime? createdAt,
    bool? hasTimer,
    DateTime? endsAt,
    int? viewsCount,
    int? commentsCount,
    int? votesFor,
    int? votesAgainst,
    int? votesUnsure,
    DebateSide? userVote,
    DateTime? userVotedAt,
    bool? isAnonymous,
  }) {
    return Discussion(
      id: id ?? this.id,
      type: type ?? this.type,
      question: question ?? this.question,
      description: description ?? this.description,
      imageUrl: imageUrl ?? this.imageUrl,
      category: category ?? this.category,
      author: author ?? this.author,
      createdAt: createdAt ?? this.createdAt,
      hasTimer: hasTimer ?? this.hasTimer,
      endsAt: endsAt ?? this.endsAt,
      viewsCount: viewsCount ?? this.viewsCount,
      commentsCount: commentsCount ?? this.commentsCount,
      votesFor: votesFor ?? this.votesFor,
      votesAgainst: votesAgainst ?? this.votesAgainst,
      votesUnsure: votesUnsure ?? this.votesUnsure,
      userVote: userVote ?? this.userVote,
      userVotedAt: userVotedAt ?? this.userVotedAt,
      isAnonymous: isAnonymous ?? this.isAnonymous,
    );
  }
}

// Комментарий к обсуждению
class DiscussionComment {
  final String id;
  final String discussionId;
  final User author;
  final String text;
  final DebateSide side; // Сторона в дебате
  final DateTime createdAt;
  final DateTime? updatedAt;
  final int likes;
  final bool isLiked;
  final int supports; // Поддержки (лайки)
  final int contests; // Оспаривания (дизлайки)
  final bool isSupported; // Текущий пользователь поддержал
  final bool isContested; // Текущий пользователь оспорил
  final String? replyToId;
  final String? replyToAuthor;
  final bool isAnonymous; // Анонимный комментарий (премиум)
  final String? mediaUrl; // URL медиа (GIF или картинка)
  final String? mediaType; // Тип медиа: 'gif' или 'image'
  final int? mediaWidth; // Ширина медиа
  final int? mediaHeight; // Высота медиа
  final bool isPinned; // Закреплённый комментарий

  DiscussionComment({
    required this.id,
    required this.discussionId,
    required this.author,
    required this.text,
    this.side = DebateSide.neutral,
    required this.createdAt,
    this.updatedAt,
    this.likes = 0,
    this.isLiked = false,
    this.supports = 0,
    this.contests = 0,
    this.isSupported = false,
    this.isContested = false,
    this.replyToId,
    this.replyToAuthor,
    this.isAnonymous = false,
    this.mediaUrl,
    this.mediaType,
    this.mediaWidth,
    this.mediaHeight,
    this.isPinned = false,
  });

  DiscussionComment copyWith({
    String? id,
    String? discussionId,
    User? author,
    String? text,
    DebateSide? side,
    DateTime? createdAt,
    DateTime? updatedAt,
    int? likes,
    bool? isLiked,
    int? supports,
    int? contests,
    bool? isSupported,
    bool? isContested,
    String? replyToId,
    String? replyToAuthor,
    bool? isAnonymous,
    String? mediaUrl,
    String? mediaType,
    int? mediaWidth,
    int? mediaHeight,
    bool? isPinned,
  }) {
    return DiscussionComment(
      id: id ?? this.id,
      discussionId: discussionId ?? this.discussionId,
      author: author ?? this.author,
      text: text ?? this.text,
      side: side ?? this.side,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      likes: likes ?? this.likes,
      isLiked: isLiked ?? this.isLiked,
      supports: supports ?? this.supports,
      contests: contests ?? this.contests,
      isSupported: isSupported ?? this.isSupported,
      isContested: isContested ?? this.isContested,
      replyToId: replyToId ?? this.replyToId,
      replyToAuthor: replyToAuthor ?? this.replyToAuthor,
      isAnonymous: isAnonymous ?? this.isAnonymous,
      mediaUrl: mediaUrl ?? this.mediaUrl,
      mediaType: mediaType ?? this.mediaType,
      mediaWidth: mediaWidth ?? this.mediaWidth,
      mediaHeight: mediaHeight ?? this.mediaHeight,
      isPinned: isPinned ?? this.isPinned,
    );
  }

  bool get isEdited {
    if (updatedAt == null) return false;
    final difference = updatedAt!.difference(createdAt);
    return difference.inSeconds > 5;
  }
}

// Модель вопроса
class Question {
  final String id;
  final String title;
  final String? description;
  final User author;
  final DateTime createdAt;
  final QuestionCategory category;
  final String? imageUrl;
  final bool isAnonymous;
  final int answersCount;
  final int viewsCount;
  final bool isResolved;
  final String? bestAnswerId;

  Question({
    required this.id,
    required this.title,
    this.description,
    required this.author,
    required this.createdAt,
    required this.category,
    this.imageUrl,
    this.isAnonymous = false,
    this.answersCount = 0,
    this.viewsCount = 0,
    this.isResolved = false,
    this.bestAnswerId,
  });

  Question copyWith({
    String? id,
    String? title,
    String? description,
    User? author,
    DateTime? createdAt,
    QuestionCategory? category,
    String? imageUrl,
    bool? isAnonymous,
    int? answersCount,
    int? viewsCount,
    bool? isResolved,
    String? bestAnswerId,
  }) {
    return Question(
      id: id ?? this.id,
      title: title ?? this.title,
      description: description ?? this.description,
      author: author ?? this.author,
      createdAt: createdAt ?? this.createdAt,
      category: category ?? this.category,
      imageUrl: imageUrl ?? this.imageUrl,
      isAnonymous: isAnonymous ?? this.isAnonymous,
      answersCount: answersCount ?? this.answersCount,
      viewsCount: viewsCount ?? this.viewsCount,
      isResolved: isResolved ?? this.isResolved,
      bestAnswerId: bestAnswerId ?? this.bestAnswerId,
    );
  }
}

// Категории вопросов
enum QuestionCategory {
  general,
  tech,
  health,
  education,
  career,
  relationships,
  lifestyle,
  finance,
}

// Модель ответа на вопрос
class QuestionAnswer {
  final String id;
  final String questionId;
  final User author;
  final String text;
  final DateTime createdAt;
  final int likes;
  final bool isLiked;
  final bool isBestAnswer;

  QuestionAnswer({
    required this.id,
    required this.questionId,
    required this.author,
    required this.text,
    required this.createdAt,
    this.likes = 0,
    this.isLiked = false,
    this.isBestAnswer = false,
  });

  QuestionAnswer copyWith({
    String? id,
    String? questionId,
    User? author,
    String? text,
    DateTime? createdAt,
    int? likes,
    bool? isLiked,
    bool? isBestAnswer,
  }) {
    return QuestionAnswer(
      id: id ?? this.id,
      questionId: questionId ?? this.questionId,
      author: author ?? this.author,
      text: text ?? this.text,
      createdAt: createdAt ?? this.createdAt,
      likes: likes ?? this.likes,
      isLiked: isLiked ?? this.isLiked,
      isBestAnswer: isBestAnswer ?? this.isBestAnswer,
    );
  }
}
