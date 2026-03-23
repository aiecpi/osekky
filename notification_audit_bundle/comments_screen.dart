import 'dart:async';

import 'package:flutter/material.dart';
import '../widgets/user_avatar.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import '../app_state.dart';
import '../models.dart';
import '../components/mention_text.dart';
import '../l10n/app_localizations.dart';
import 'premium_screen.dart';
import 'user_profile_screen.dart';
import '../utils/logger.dart';
import '../services/unified_notification_manager.dart';
import '../components/media_carousel_widget.dart';
import '../components/media_menu_button.dart';
import '../components/comment_skeleton.dart';
import '../services/supabase_storage_service.dart';
import '../widgets/debate_embed_card.dart';
import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';

class CommentsScreen extends StatefulWidget {
  final Story story;
  final String? commentId; // ID комментария для прокрутки

  const CommentsScreen({
    super.key,
    required this.story,
    this.commentId,
  });

  @override
  State<CommentsScreen> createState() => _CommentsScreenState();
}

/// Тип сортировки комментариев
enum PostCommentSortType {
  top,      // Умная сортировка (лайки + ответы + автор)
  newest,   // По времени (новые сверху)
}

class _CommentsScreenState extends State<CommentsScreen> {
  final TextEditingController _commentController = TextEditingController();
  Comment? _replyingTo;
  Comment? _editingComment; // Комментарий, который редактируем
  final Set<String> _expandedComments = {}; // ID комментариев с раскрытыми ответами
  final Map<String, int> _visibleRepliesCount = {};
  Timer? _timeTicker;
  final ScrollController _scrollController = ScrollController();
  String? _highlightedCommentId; // ID подсвеченного комментария
  final Map<String, GlobalKey> _commentKeys = {}; // Ключи для каждого комментария
  bool _isLoadingComments = true; // Флаг загрузки комментариев
  bool _isLoadingMoreComments = false; // Флаг догрузки комментариев
  bool _isAnonymous = false; // Анонимный комментарий
  PostCommentSortType _sortType = PostCommentSortType.top; // По умолчанию умная сортировка
  
  // Задержка пересортировки после лайка
  DateTime? _lastLikeTime;
  static const Duration _sortDelay = Duration(seconds: 3);
  
  // Медиа для комментария
  String? _selectedMediaUrl;
  String? _selectedMediaType; // 'gif' или 'image'
  int? _selectedMediaWidth;
  int? _selectedMediaHeight;
  File? _selectedImageFile;

  // @mention автодополнение
  List<User> _mentionSuggestions = [];
  bool _showMentionOverlay = false;
  final FocusNode _commentFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();

    _timeTicker = Timer.periodic(const Duration(minutes: 1), (_) {
      if (!mounted) return;
      setState(() {});
    });
    _commentController.addListener(_onCommentTextChanged);
    // Устанавливаем подсвеченный комментарий если передан
    if (widget.commentId != null) {
      _highlightedCommentId = widget.commentId;
    }
    
    // Загружаем комментарии из Supabase
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final appState = Provider.of<AppState>(context, listen: false);
      await appState.loadCommentsForPost(widget.story.id);
      if (mounted) {
        setState(() {
          _isLoadingComments = false;
        });

        final comments = appState.getComments(widget.story.id);
        final mainComments = comments.where((c) => c.replyToId == null).toList();
        final toExpand = <String>{};
        for (final c in mainComments) {
          final hasReplies = comments.any((r) => r.threadRootId == c.id && r.id != c.id);
          if (hasReplies) toExpand.add(c.id);
        }
        if (toExpand.isNotEmpty) {
          setState(() {
            _expandedComments.addAll(toExpand);
            for (final id in toExpand) {
              _visibleRepliesCount.putIfAbsent(id, () => 1);
            }
          });
        }
        
        // Прокручиваем к комментарию после загрузки
        if (widget.commentId != null) {
          // Проверяем что комментарий существует
          final comments = appState.getComments(widget.story.id);
          final commentExists = comments.any((c) => c.id == widget.commentId);
          
          if (commentExists) {
            Future.delayed(const Duration(milliseconds: 500), () {
              _scrollToComment(widget.commentId!);
            });
          } else {
            // Если комментарий не найден, догружаем его отдельно
            unawaited(_loadAndScrollToComment(appState, widget.commentId!));
          }
        }
      }
    });
  }

  void _onCommentTextChanged() {
    final text = _commentController.text;
    final cursorPos = _commentController.selection.baseOffset;
    if (cursorPos < 0) {
      _hideMentionOverlay();
      return;
    }

    // Ищем @ перед курсором
    final beforeCursor = text.substring(0, cursorPos);
    final atIndex = beforeCursor.lastIndexOf('@');
    
    if (atIndex == -1 || (atIndex > 0 && beforeCursor[atIndex - 1] != ' ' && beforeCursor[atIndex - 1] != '\n')) {
      _hideMentionOverlay();
      return;
    }

    final query = beforeCursor.substring(atIndex + 1).toLowerCase();
    // Если есть пробел после @ — уже не ищем
    if (query.contains(' ') || query.contains('\n')) {
      _hideMentionOverlay();
      return;
    }

    final appState = Provider.of<AppState>(context, listen: false);
    final users = _getMentionableUsers(appState);
    final filtered = users.where((u) => 
      u.name.toLowerCase().contains(query) ||
      u.username.toLowerCase().contains(query)
    ).take(5).toList();

    if (filtered.isEmpty) {
      _hideMentionOverlay();
      return;
    }

    setState(() {
      _mentionSuggestions = filtered;
      _showMentionOverlay = true;
    });
  }

  List<User> _getMentionableUsers(AppState appState) {
    final comments = appState.getComments(widget.story.id);
    final seen = <String>{};
    final users = <User>[];
    // Автор поста
    if (seen.add(widget.story.author.id)) {
      users.add(widget.story.author);
    }
    // Авторы комментариев
    for (final c in comments) {
      if (!c.isAnonymous && seen.add(c.author.id)) {
        users.add(c.author);
      }
    }
    // Убираем текущего пользователя
    final currentId = appState.currentUser?.id;
    if (currentId != null) {
      users.removeWhere((u) => u.id == currentId);
    }
    return users;
  }

  Future<void> _loadAndScrollToComment(AppState appState, String commentId) async {
    try {
      // Попытка загрузить комментарий напрямую
      await appState.loadCommentById(widget.story.id, commentId);
      if (!mounted) return;
      
      // После загрузки пробуем скроллить
      final comments = appState.getComments(widget.story.id);
      final exists = comments.any((c) => c.id == commentId);
      if (exists) {
        Future.delayed(const Duration(milliseconds: 300), () {
          if (mounted) _scrollToComment(commentId);
        });
      }
    } catch (e) {
      AppLogger.warning('Failed to load comment $commentId', error: e);
    }
  }

  void _insertMention(User user) {
    final text = _commentController.text;
    final cursorPos = _commentController.selection.baseOffset;
    final beforeCursor = text.substring(0, cursorPos);
    final atIndex = beforeCursor.lastIndexOf('@');
    
    final mention = '@${user.username} ';
    final newText = text.substring(0, atIndex) + mention + text.substring(cursorPos);
    _commentController.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: atIndex + mention.length),
    );
    _hideMentionOverlay();
  }

  Future<void> _loadMoreComments() async {
    if (_isLoadingMoreComments) return;
    setState(() => _isLoadingMoreComments = true);
    final appState = Provider.of<AppState>(context, listen: false);
    await appState.loadMoreCommentsForPost(widget.story.id);
    if (mounted) setState(() => _isLoadingMoreComments = false);
  }

  void _hideMentionOverlay() {
    if (_showMentionOverlay) {
      setState(() {
        _showMentionOverlay = false;
        _mentionSuggestions = [];
      });
    }
  }

  String _formatTime(DateTime dateTime) {
    final l = AppLocalizations.of(context);
    final now = DateTime.now();
    final difference = now.difference(dateTime);

    if (difference.inMinutes < 1) {
      return l.translate('just_now');
    } else if (difference.inMinutes < 60) {
      return '${difference.inMinutes} ${l.translate('minutes_ago')}';
    } else if (difference.inHours < 24) {
      return '${difference.inHours} ${l.translate('hours_ago')}';
    } else if (difference.inDays < 7) {
      return '${difference.inDays} ${l.translate('days_ago')}';
    } else {
      return '${dateTime.day.toString().padLeft(2, '0')}.${dateTime.month.toString().padLeft(2, '0')}.${dateTime.year}';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, appState, child) {
        final comments = appState.getComments(widget.story.id);

        return Scaffold(
          backgroundColor: Colors.white,
          appBar: AppBar(
            title: Text(
              AppLocalizations.of(context).translate('post'),
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            backgroundColor: const Color(0xFF003e70),
            foregroundColor: Colors.white,
          ),
          body: Column(
            children: [
              // Пост сверху + комментарии снизу
              Expanded(
                child: ListView(
                  controller: _scrollController,
                  padding: const EdgeInsets.only(bottom: 80),
                  children: [
                    // Сам пост
                    _buildPostHeader(),
                    const Divider(height: 1, thickness: 8, color: Color(0xFFF5F5F5)),
                    // Заголовок комментариев
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          Text(
                            AppLocalizations.of(context).translate('comments'),
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '${comments.length}',
                            style: TextStyle(
                              fontSize: 16,
                              color: Colors.grey[600],
                            ),
                          ),
                          const Spacer(),
                          // Переключатель сортировки
                          _buildSortToggle(),
                        ],
                      ),
                    ),
                    // Список комментариев
                    if (_isLoadingComments)
                      Column(
                        children: List.generate(3, (_) => const CommentSkeleton()),
                      )
                    else if (comments.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 40),
                        child: Column(
                          children: [
                            Icon(
                              Icons.comment_outlined,
                              size: 48,
                              color: Colors.grey[400],
                            ),
                            const SizedBox(height: 12),
                            Text(
                              AppLocalizations.of(context).translate('no_comments_yet'),
                              style: TextStyle(
                                fontSize: 16,
                                color: Colors.grey[600],
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              AppLocalizations.of(context).translate('be_first_comment'),
                              style: TextStyle(
                                fontSize: 14,
                                color: Colors.grey[500],
                              ),
                            ),
                          ],
                        ),
                      )
                    else
                      ..._getSortedComments(comments, appState).map((comment) {
                        // Показываем только основные комментарии (не ответы)
                        // Находим все подответы по threadRootId (все комментарии одной ветки)
                        final replies = comments.where((c) => 
                          c.threadRootId == comment.id && c.id != comment.id
                        ).toList();
                        return _buildCommentWithReplies(comment, replies, appState);
                      }),
                    // Кнопка "Загрузить ещё"
                    if (!_isLoadingComments && appState.hasMoreCommentsForPost(widget.story.id))
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                        child: _isLoadingMoreComments
                            ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                            : OutlinedButton.icon(
                                onPressed: _loadMoreComments,
                                icon: const Icon(Icons.expand_more),
                                label: Text(AppLocalizations.of(context).translate('load_more')),
                                style: OutlinedButton.styleFrom(
                                  minimumSize: const Size.fromHeight(44),
                                  foregroundColor: const Color(0xFF003e70),
                                  side: const BorderSide(color: Color(0xFF003e70)),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                              ),
                      ),
                  ],
                ),
              ),

              // @mention автодополнение
              if (_showMentionOverlay && _mentionSuggestions.isNotEmpty)
                Container(
                  constraints: const BoxConstraints(maxHeight: 200),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.08),
                        blurRadius: 8,
                        offset: const Offset(0, -2),
                      ),
                    ],
                  ),
                  child: ListView.builder(
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    itemCount: _mentionSuggestions.length,
                    itemBuilder: (context, index) {
                      final user = _mentionSuggestions[index];
                      return InkWell(
                        onTap: () => _insertMention(user),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          child: Row(
                            children: [
                              UserAvatar(
                                imageUrl: user.avatar,
                                displayName: user.name,
                                radius: 16,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      user.name,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                        fontSize: 14,
                                      ),
                                    ),
                                    if (user.username.isNotEmpty)
                                      Text(
                                        '@${user.username}',
                                        style: TextStyle(
                                          color: Colors.grey[500],
                                          fontSize: 12,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              // Поле ввода комментария (зафиксировано внизу)
              Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).brightness == Brightness.dark ? const Color(0xFF1A1A2E) : Colors.white,
                  border: Border(
                    top: BorderSide(
                      color: const Color(0xFF003e70).withValues(alpha: 0.08),
                      width: 1,
                    ),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF003e70).withValues(alpha: 0.06),
                      blurRadius: 16,
                      offset: const Offset(0, -4),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    // Индикатор ответа
                    if (_replyingTo != null)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        color: Colors.grey[100],
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                AppLocalizations.of(context)
                                    .translate('reply_to')
                                    .replaceAll('{name}', _replyingTo!.isAnonymous ? AppLocalizations.of(context).translate('anonymous_user') : _replyingTo!.author.name),
                                style: TextStyle(
                                  color: Colors.grey[700],
                                  fontSize: 14,
                                ),
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.close, size: 20),
                              onPressed: () {
                                setState(() => _replyingTo = null);
                              },
                            ),
                          ],
                        ),
                      ),
                    // Индикатор редактирования
                    if (_editingComment != null)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        color: Colors.orange[50],
                        child: Row(
                          children: [
                            const Icon(Icons.edit, color: Colors.orange, size: 20),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                AppLocalizations.of(context).translate('editing_comment'),
                                style: const TextStyle(
                                  color: Colors.orange,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.close, size: 20),
                              onPressed: () {
                                setState(() {
                                  _editingComment = null;
                                  _commentController.clear();
                                });
                              },
                            ),
                          ],
                        ),
                      ),
                    // Поле ввода
                    SafeArea(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          children: [
                            // Превью выбранного медиа
                            if (_selectedMediaUrl != null || _selectedImageFile != null)
                              Container(
                                margin: const EdgeInsets.only(bottom: 8),
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: Theme.of(context).brightness == Brightness.dark 
                                      ? Colors.grey[850] 
                                      : Colors.grey[100],
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Row(
                                  children: [
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(8),
                                      child: _selectedMediaType == 'gif' && _selectedMediaUrl != null
                                          ? CachedNetworkImage(
                                              imageUrl: _selectedMediaUrl!,
                                              width: 60,
                                              height: 60,
                                              fit: BoxFit.cover,
                                            )
                                          : _selectedImageFile != null
                                              ? Image.file(
                                                  _selectedImageFile!,
                                                  width: 60,
                                                  height: 60,
                                                  fit: BoxFit.cover,
                                                )
                                              : const SizedBox.shrink(),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Text(
                                        _selectedMediaType == 'gif' ? AppLocalizations.of(context).translate('gif_attached') : AppLocalizations.of(context).translate('image_attached'),
                                        style: const TextStyle(fontSize: 14),
                                      ),
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.close, size: 20),
                                      onPressed: () {
                                        setState(() {
                                          _selectedMediaUrl = null;
                                          _selectedMediaType = null;
                                          _selectedMediaWidth = null;
                                          _selectedMediaHeight = null;
                                          _selectedImageFile = null;
                                        });
                                      },
                                    ),
                                  ],
                                ),
                              ),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                // Кнопка медиа (GIF, фото, аноним)
                                Consumer<AppState>(
                                  builder: (context, appState2, _) {
                                    final isPremium = appState2.currentUser?.isCurrentlyPremium ?? false;
                                    final isDarkTheme = Theme.of(context).brightness == Brightness.dark;
                                    return MediaMenuButton(
                                      iconColor: isDarkTheme ? Colors.white54 : const Color(0xFF003e70).withValues(alpha: 0.5),
                                      onGifSelected: (gif) {
                                        setState(() {
                                          _selectedMediaUrl = gif.images?.original?.url;
                                          _selectedMediaType = 'gif';
                                          _selectedMediaWidth = int.tryParse(gif.images?.original?.width ?? '0');
                                          _selectedMediaHeight = int.tryParse(gif.images?.original?.height ?? '0');
                                          _selectedImageFile = null;
                                        });
                                      },
                                      onImageSelected: (file) {
                                        setState(() {
                                          _selectedImageFile = file;
                                          _selectedMediaType = 'image';
                                          _selectedMediaUrl = null;
                                        });
                                      },
                                      isAnonymous: _isAnonymous,
                                      onAnonymousChanged: (value) {
                                        setState(() => _isAnonymous = value);
                                      },
                                      isPremium: isPremium,
                                      onPremiumRequired: () => _showPremiumPaywall(context),
                                    );
                                  },
                                ),
                                const SizedBox(width: 4),
                                // Поле ввода
                                Expanded(
                                  child: TextField(
                                    controller: _commentController,
                                    focusNode: _commentFocusNode,
                                    style: TextStyle(
                                      fontSize: 14,
                                      color: Theme.of(context).brightness == Brightness.dark ? Colors.white : Colors.black87,
                                      height: 1.3,
                                    ),
                                    decoration: InputDecoration(
                                      hintText: AppLocalizations.of(context).translate('write_comment'),
                                      hintStyle: TextStyle(
                                        fontSize: 14,
                                        color: Theme.of(context).brightness == Brightness.dark ? Colors.white30 : Colors.grey[400],
                                      ),
                                      filled: true,
                                      fillColor: Theme.of(context).brightness == Brightness.dark
                                          ? Colors.white.withValues(alpha: 0.06)
                                          : const Color(0xFFF0F2F5),
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(24),
                                        borderSide: BorderSide.none,
                                      ),
                                      enabledBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(24),
                                        borderSide: BorderSide(
                                          color: Theme.of(context).brightness == Brightness.dark
                                              ? Colors.white.withValues(alpha: 0.1)
                                              : const Color(0xFF003d66).withValues(alpha: 0.12),
                                          width: 0.8,
                                        ),
                                      ),
                                      focusedBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(24),
                                        borderSide: BorderSide(
                                          color: const Color(0xFF003d66).withValues(alpha: 0.3),
                                          width: 1,
                                        ),
                                      ),
                                      contentPadding: const EdgeInsets.symmetric(
                                        horizontal: 16,
                                        vertical: 10,
                                      ),
                                      isDense: true,
                                      suffixIcon: _commentController.text.isNotEmpty
                                          ? Padding(
                                              padding: const EdgeInsets.only(right: 8),
                                              child: Center(
                                                widthFactor: 1,
                                                child: Text(
                                                  '${_commentController.text.length}/500',
                                                  style: TextStyle(
                                                    fontSize: 10,
                                                    color: (500 - _commentController.text.length) < 50
                                                        ? Colors.red
                                                        : (500 - _commentController.text.length) < 100
                                                            ? Colors.orange
                                                            : Colors.grey[400],
                                                  ),
                                                ),
                                              ),
                                            )
                                          : null,
                                      suffixIconConstraints: const BoxConstraints(minHeight: 0, minWidth: 0),
                                    ),
                                    minLines: 1,
                                    maxLines: 4,
                                    maxLength: 500,
                                    textCapitalization: TextCapitalization.sentences,
                                    buildCounter: (context, {required currentLength, required isFocused, maxLength}) => const SizedBox.shrink(),
                                    onChanged: (_) => setState(() {}),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                // Кнопка отправки
                                GestureDetector(
                                  onTap: () => _sendComment(appState),
                                  child: Container(
                                    width: 38,
                                    height: 38,
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF003d66),
                                      shape: BoxShape.circle,
                                      boxShadow: [
                                        BoxShadow(
                                          color: const Color(0xFF003d66).withValues(alpha: 0.2),
                                          blurRadius: 6,
                                          offset: const Offset(0, 2),
                                        ),
                                      ],
                                    ),
                                    child: const Icon(
                                      Icons.arrow_upward_rounded,
                                      color: Colors.white,
                                      size: 20,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildPostHeader() {
    return Container(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Автор
          Row(
            children: [
              Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: const Color(0xFF003e70),
                    width: 2,
                  ),
                ),
                child: UserAvatar(
                  imageUrl: widget.story.author.avatar,
                  displayName: widget.story.author.name,
                  radius: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.story.author.name,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 17,
                      ),
                    ),
                    Text(
                      '@${widget.story.author.username} • ${_formatTime(widget.story.createdAt)}',
                      style: TextStyle(
                        color: Colors.grey[600],
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // Текст поста с кликабельными ссылками
          Builder(builder: (context) {
            final fullText = widget.story.text;
            final isDark = Theme.of(context).brightness == Brightness.dark;
            if (fullText.contains('[DEBATE:')) {
              final beforeDebate = fullText.split('[DEBATE:')[0].trim();
              final debateIdMatch = RegExp(r'\[DEBATE:([^\]]+)\]').firstMatch(fullText);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (beforeDebate.isNotEmpty)
                    MentionText(
                      text: beforeDebate,
                      style: TextStyle(
                        fontSize: 16,
                        height: 1.5,
                        color: isDark ? Colors.white.withValues(alpha: 0.95) : Colors.black87,
                      ),
                    ),
                  if (debateIdMatch != null)
                    Consumer<AppState>(builder: (context, appState, _) {
                      final debateId = debateIdMatch.group(1)!;
                      final cached = appState.discussions.where((d) => d.id == debateId).toList();
                      if (cached.isNotEmpty) {
                        return Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: DebateEmbedCard(debate: cached.first, isDark: isDark),
                        );
                      }
                      return FutureBuilder<Discussion?>(
                        future: appState.loadDiscussionById(debateId),
                        builder: (context, snapshot) {
                          if (snapshot.connectionState == ConnectionState.waiting) {
                            return Container(
                              height: 80,
                              margin: const EdgeInsets.only(top: 8),
                              decoration: BoxDecoration(
                                color: const Color(0xFF003d66).withValues(alpha: 0.08),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
                            );
                          }
                          final debate = snapshot.data;
                          if (debate != null) {
                            return Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: DebateEmbedCard(debate: debate, isDark: isDark),
                            );
                          }
                          return const SizedBox.shrink();
                        },
                      );
                    }),
                ],
              );
            }
            return MentionText(
              text: fullText,
              style: TextStyle(
                fontSize: 16,
                height: 1.5,
                color: isDark ? Colors.white.withValues(alpha: 0.95) : Colors.black87,
              ),
            );
          }),
          // Изображения если есть
          if (widget.story.images.isNotEmpty) ...[
            const SizedBox(height: 16),
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: MediaCarouselWidget(
                media: widget.story.images
                    .map((path) => MediaItem(path: path, type: MediaType.image))
                    .toList(),
                showControls: true,
                autoPlay: false,
                height: 320,
              ),
            ),
          ],
          const SizedBox(height: 16),
          // Статистика — компактная строка
          Row(
            children: [
              _buildCompactStat(Icons.favorite_border, widget.story.likes, Colors.red[400]!),
              const SizedBox(width: 20),
              _buildCompactStat(Icons.chat_bubble_outline, widget.story.comments, Colors.blue[400]!),
              const SizedBox(width: 20),
              _buildCompactStat(Icons.visibility_outlined, widget.story.views, Colors.grey[500]!),
            ],
          ),
          const SizedBox(height: 12),
          Divider(height: 1, color: Colors.grey[300]),
        ],
      ),
    );
  }

  Widget _buildCompactStat(IconData icon, int count, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 4),
        Text(
          _formatStatCount(count),
          style: TextStyle(
            color: Colors.grey[700],
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  String _formatStatCount(int count) {
    if (count >= 1000000) return '${(count / 1000000).toStringAsFixed(1)}M';
    if (count >= 1000) return '${(count / 1000).toStringAsFixed(1)}K';
    return count.toString();
  }

  Widget _buildCommentWithReplies(Comment comment, List<Comment> replies, AppState appState) {
    final isExpanded = _expandedComments.contains(comment.id);
    final hasReplies = replies.isNotEmpty;
    final repliesCount = replies.length;

    // Сортируем ответы по времени (старые сначала)
    final sortedReplies = List<Comment>.from(replies)
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

    final visibleCount = _visibleRepliesCount[comment.id] ?? 1;

    final List<Comment> repliesToShow;
    if (!isExpanded) {
      repliesToShow = const [];
    } else {
      repliesToShow = sortedReplies.take(visibleCount.clamp(0, repliesCount)).toList();
    }

    final hasMoreToShow = isExpanded && visibleCount < repliesCount;
    final remainingCount = repliesCount - visibleCount;

    return Column(
      children: [
        _buildCommentItem(
          comment, 
          appState, 
          hasReplies: hasReplies, 
          isExpanded: isExpanded,
          repliesCount: repliesCount,
          visibleRepliesCount: repliesToShow.length,
        ),
        if (hasReplies)
          AnimatedSize(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
            alignment: Alignment.topCenter,
            child: Column(
              children: [
                ...repliesToShow.map((reply) => _buildReplyItem(reply, appState)),
                if (hasMoreToShow)
                  _buildShowMoreRepliesButton(comment.id, remainingCount),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildShowMoreRepliesButton(String commentId, int remaining) {
    final showCount = remaining > 3 ? 3 : remaining;
    return GestureDetector(
      onTap: () {
        setState(() {
          _visibleRepliesCount[commentId] = (_visibleRepliesCount[commentId] ?? 1) + 3;
        });
      },
      child: Container(
        margin: const EdgeInsets.only(left: 20),
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(color: Colors.grey[300]!, width: 2),
            bottom: BorderSide(color: Colors.grey[200]!, width: 1),
          ),
        ),
        child: Row(
          children: [
            Icon(Icons.subdirectory_arrow_right, size: 16, color: const Color(0xFF003e70)),
            const SizedBox(width: 8),
            Text(
              AppLocalizations.of(context).translate('show_more_replies').replaceFirst('{count}', '$showCount'),
              style: const TextStyle(
                color: Color(0xFF003e70),
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildReplyItem(Comment reply, AppState appState) {
    final isHighlighted = _highlightedCommentId == reply.id;
    final replyLabelWidget = _buildReplyLabelWidget(reply, appState);
    final isPostAuthor = reply.author.id == widget.story.author.id;

    // Создаем ключ для этого ответа если его нет
    if (!_commentKeys.containsKey(reply.id)) {
      _commentKeys[reply.id] = GlobalKey();
    }
    
    return Container(
      key: _commentKeys[reply.id],
      margin: const EdgeInsets.only(left: 20),
      decoration: BoxDecoration(
        color: isHighlighted ? const Color(0xFF003e70).withValues(alpha: 0.1) : Colors.white,
        border: Border(
          left: BorderSide(color: Colors.grey[300]!, width: 2),
          bottom: BorderSide(color: Colors.grey[200]!, width: 1),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.only(left: 12, right: 12, top: 4, bottom: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Аватар слева
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: reply.isAnonymous
                  ? _buildAnonymousAvatar(radius: 18)
                  : GestureDetector(
                      onTap: () {
                        if (reply.author.id == appState.currentUser?.id) {
                          Navigator.pushNamed(context, '/profile');
                        } else {
                          if (!reply.isAnonymous) {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) => UserProfileScreen(user: reply.author),
                              ),
                            );
                          }
                        }
                      },
                      child: reply.isAnonymous
                          ? _buildAnonymousAvatar(radius: 18)
                          : UserAvatar(
                              imageUrl: reply.author.avatar,
                              displayName: reply.author.name,
                              radius: 18,
                            ),
                    ),
            ),
            const SizedBox(width: 10),
            // Контент справа
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Имя, время и меню
                  Row(
                    children: [
                      Expanded(
                        child: Row(
                          children: [
                            if (reply.isAnonymous) ...[
                              const Icon(Icons.lock, size: 14, color: Colors.grey),
                              const SizedBox(width: 4),
                            ],
                            Flexible(
                              child: Text(
                                _getDisplayName(reply),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15,
                                ),
                              ),
                            ),
                            if (isPostAuthor && !reply.isAnonymous) ...[
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF003e70).withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  AppLocalizations.of(context).author,
                                  style: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFF003e70),
                                  ),
                                ),
                              ),
                            ],
                            const SizedBox(width: 8),
                            Text(
                              _formatTime(reply.createdAt),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Colors.grey[600],
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      // Меню действий для ответа
                      PopupMenuButton<String>(
                        child: SizedBox(
                          width: 32,
                          height: 32,
                          child: Center(
                            child: Icon(Icons.more_horiz, size: 18, color: Colors.grey[600]),
                          ),
                        ),
                        padding: EdgeInsets.zero,
                        onSelected: (value) {
                          if (value == 'report') {
                            _showReportDialog(reply);
                          } else if (value == 'edit') {
                            setState(() {
                              _editingComment = reply;
                              _commentController.text = reply.text;
                              _replyingTo = null;
                            });
                          } else if (value == 'delete') {
                            _deleteComment(reply.id, appState);
                          }
                        },
                        itemBuilder: (context) => [
                          // Показываем "Пожаловаться" только для чужих комментариев
                          if (reply.author.id != appState.currentUser?.id)
                            PopupMenuItem(
                              value: 'report',
                              child: Row(
                                children: [
                                  const Icon(Icons.flag, color: Colors.orange, size: 18),
                                  const SizedBox(width: 8),
                                  Text(AppLocalizations.of(context).translate('report')),
                                ],
                              ),
                            ),
                          // Показываем редактирование только для своих комментариев и если не прошло 10 минут
                          if (reply.author.id == appState.currentUser?.id && reply.canEdit)
                            PopupMenuItem(
                              value: 'edit',
                              child: Row(
                                children: [
                                  const Icon(Icons.edit, color: Colors.blue, size: 18),
                                  const SizedBox(width: 8),
                                  Text(AppLocalizations.of(context).translate('edit_comment')),
                                ],
                              ),
                            ),
                          if (reply.author.id == appState.currentUser?.id)
                            PopupMenuItem(
                              value: 'delete',
                              child: Row(
                                children: [
                                  const Icon(Icons.delete, color: Colors.red, size: 18),
                                  const SizedBox(width: 8),
                                  Text(AppLocalizations.of(context).translate('delete_comment')),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                  if (replyLabelWidget != null) ...[
                    replyLabelWidget,
                  ],
                  MentionText(
                    text: reply.text,
                    style: const TextStyle(fontSize: 15, height: 1.3, color: Colors.black87),
                  ),
                  // Показываем "редактировано" если комментарий был изменён
                  if (reply.isEdited) ...[
                    const SizedBox(height: 2),
                    Text(
                      AppLocalizations.of(context).edited,
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey[500],
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ],
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      InkWell(
                        onTap: () {
                          appState.toggleCommentLike(reply.id);
                          // Устанавливаем время лайка для задержки пересортировки
                          setState(() {
                            _lastLikeTime = DateTime.now();
                          });
                        },
                        child: Row(
                          children: [
                            Icon(
                              reply.isLiked ? Icons.favorite : Icons.favorite_border,
                              size: 16,
                              color: reply.isLiked ? Colors.red : Colors.grey[600],
                            ),
                            if (reply.likes > 0) ...[
                              const SizedBox(width: 4),
                              Text(
                                '${reply.likes}',
                                style: TextStyle(color: Colors.grey[600], fontSize: 12),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(width: 20),
                      InkWell(
                        onTap: () => setState(() => _replyingTo = reply),
                        child: Row(
                          children: [
                            Icon(Icons.reply, size: 16, color: Colors.grey[600]),
                            const SizedBox(width: 4),
                            Text(
                              AppLocalizations.of(context).translate('reply'),
                              style: TextStyle(
                                color: Colors.grey[600],
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  
  Widget _buildCommentItem(
    Comment comment,
    AppState appState, {
    bool hasReplies = false,
    bool isExpanded = false,
    int repliesCount = 0,
    int visibleRepliesCount = 0,
  }) {
    final isHighlighted = _highlightedCommentId == comment.id;
    final isPostAuthor = comment.author.id == widget.story.author.id;
    
    // Создаем ключ для этого комментария если его нет
    if (!_commentKeys.containsKey(comment.id)) {
      _commentKeys[comment.id] = GlobalKey();
    }
    
    return Container(
      key: _commentKeys[comment.id],
      decoration: BoxDecoration(
        color: isHighlighted ? const Color(0xFF003e70).withValues(alpha: 0.1) : Colors.white,
        border: Border(
          bottom: BorderSide(color: Colors.grey[200]!, width: 1),
        ),
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Аватар слева
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: comment.isAnonymous
                  ? _buildAnonymousAvatar(radius: 20)
                  : GestureDetector(
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => UserProfileScreen(user: comment.author),
                          ),
                        );
                      },
                      child: UserAvatar(
                        imageUrl: comment.author.avatar,
                        displayName: comment.author.name,
                        radius: 20,
                      ),
                    ),
            ),
            const SizedBox(width: 10),
            // Контент справа
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Имя, время и меню
                  Row(
                    children: [
                      Expanded(
                        child: Row(
                          children: [
                            if (comment.isAnonymous) ...[
                              const Icon(Icons.lock, size: 14, color: Colors.grey),
                              const SizedBox(width: 4),
                            ],
                            Flexible(
                              child: Text(
                                _getDisplayName(comment),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15,
                                ),
                              ),
                            ),
                            if (isPostAuthor && !comment.isAnonymous) ...[
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF003e70).withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  AppLocalizations.of(context).author,
                                  style: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFF003e70),
                                  ),
                                ),
                              ),
                            ],
                            if (comment.isPinned) ...[
                              const SizedBox(width: 4),
                              const Icon(Icons.push_pin, size: 14, color: Color(0xFF003e70)),
                            ],
                            const SizedBox(width: 8),
                            Text(
                              _formatTime(comment.createdAt),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Colors.grey[600],
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      // Меню действий
                      PopupMenuButton<String>(
                        child: SizedBox(
                          width: 32,
                          height: 32,
                          child: Center(
                            child: Icon(Icons.more_horiz, size: 18, color: Colors.grey[600]),
                          ),
                        ),
                        padding: EdgeInsets.zero,
                        onSelected: (value) {
                          if (value == 'report') {
                            _showReportDialog(comment);
                          } else if (value == 'edit') {
                            setState(() {
                              _editingComment = comment;
                              _commentController.text = comment.text;
                              _replyingTo = null;
                            });
                          } else if (value == 'delete') {
                            _deleteComment(comment.id, appState);
                          } else if (value == 'pin') {
                            appState.togglePinComment(comment.id, widget.story.id);
                            Notify.info(
                              context,
                              comment.isPinned
                                  ? AppLocalizations.of(context).translate('message_unpinned')
                                  : AppLocalizations.of(context).translate('message_pinned'),
                            );
                          }
                        },
                        itemBuilder: (context) => [
                          // Закрепить/открепить (только автор поста)
                          if (widget.story.author.id == appState.currentUser?.id)
                            PopupMenuItem(
                              value: 'pin',
                              child: Row(
                                children: [
                                  Icon(
                                    comment.isPinned ? Icons.push_pin : Icons.push_pin_outlined,
                                    color: comment.isPinned ? Colors.grey : const Color(0xFF003e70),
                                    size: 18,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(AppLocalizations.of(context).translate(
                                    comment.isPinned ? 'unpin_comment' : 'pin_comment',
                                  )),
                                ],
                              ),
                            ),
                          // Показываем "Пожаловаться" только для чужих комментариев
                          if (comment.author.id != appState.currentUser?.id)
                            PopupMenuItem(
                              value: 'report',
                              child: Row(
                                children: [
                                  const Icon(Icons.flag, color: Colors.orange, size: 18),
                                  const SizedBox(width: 8),
                                  Text(AppLocalizations.of(context).translate('report')),
                                ],
                              ),
                            ),
                          // Показываем редактирование только для своих комментариев и если не прошло 10 минут
                          if (comment.author.id == appState.currentUser?.id && comment.canEdit)
                            PopupMenuItem(
                              value: 'edit',
                              child: Row(
                                children: [
                                  const Icon(Icons.edit, color: Colors.blue, size: 18),
                                  const SizedBox(width: 8),
                                  Text(AppLocalizations.of(context).translate('edit_comment')),
                                ],
                              ),
                            ),
                          if (comment.author.id == appState.currentUser?.id)
                            PopupMenuItem(
                              value: 'delete',
                              child: Row(
                                children: [
                                  const Icon(Icons.delete, color: Colors.red, size: 18),
                                  const SizedBox(width: 8),
                                  Text(AppLocalizations.of(context).translate('delete_comment')),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  // Текст комментария с кликабельными @mentions
                  if (comment.text.isNotEmpty)
                    MentionText(
                      text: comment.text,
                      style: const TextStyle(fontSize: 15, height: 1.3, color: Colors.black87),
                    ),
                  // Медиа (GIF или картинка)
                  if (comment.mediaUrl != null) ...[
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: GestureDetector(
                        onTap: comment.mediaType == 'image'
                            ? () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => Scaffold(
                                      backgroundColor: Colors.black,
                                      appBar: AppBar(
                                        backgroundColor: Colors.black,
                                        iconTheme: const IconThemeData(color: Colors.white),
                                      ),
                                      body: Center(
                                        child: CachedNetworkImage(
                                          imageUrl: comment.mediaUrl!,
                                          fit: BoxFit.contain,
                                        ),
                                      ),
                                    ),
                                  ),
                                );
                              }
                            : null,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(
                            maxHeight: 250,
                            maxWidth: 300,
                          ),
                          child: CachedNetworkImage(
                            imageUrl: comment.mediaUrl!,
                            fit: BoxFit.cover,
                            placeholder: (context, url) => Container(
                              height: 150,
                              width: 150,
                              color: Colors.grey[200],
                              child: const Center(
                                child: CircularProgressIndicator(),
                              ),
                            ),
                            errorWidget: (context, url, error) => Container(
                              height: 150,
                              width: 150,
                              color: Colors.grey[200],
                              child: const Icon(Icons.error),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                  // Показываем "редактировано" если комментарий был изменён
                  if (comment.isEdited) ...[
                    const SizedBox(height: 2),
                    Text(
                      AppLocalizations.of(context).edited,
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey[500],
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ],
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      InkWell(
                        onTap: () {
                          appState.toggleCommentLike(comment.id);
                          // Устанавливаем время лайка для задержки пересортировки
                          setState(() {
                            _lastLikeTime = DateTime.now();
                          });
                        },
                        child: Row(
                          children: [
                            Icon(
                              comment.isLiked ? Icons.favorite : Icons.favorite_border,
                              size: 16,
                              color: comment.isLiked ? Colors.red : Colors.grey[600],
                            ),
                            if (comment.likes > 0) ...[
                              const SizedBox(width: 4),
                              Text(
                                '${comment.likes}',
                                style: TextStyle(color: Colors.grey[600], fontSize: 12),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(width: 20),
                      InkWell(
                        onTap: () => setState(() => _replyingTo = comment),
                        child: Row(
                          children: [
                            Icon(Icons.reply, size: 16, color: Colors.grey[600]),
                            const SizedBox(width: 4),
                            Text(
                              AppLocalizations.of(context).translate('reply'),
                              style: TextStyle(
                                color: Colors.grey[600],
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  if (hasReplies)
                    GestureDetector(
                      onTap: () {
                        setState(() {
                          if (_expandedComments.contains(comment.id)) {
                            // Скрыть ответы
                            _expandedComments.remove(comment.id);
                            _visibleRepliesCount[comment.id] = 1;
                          } else {
                            // Показать все ответы сразу
                            _expandedComments.add(comment.id);
                            _visibleRepliesCount[comment.id] = repliesCount;
                          }
                        });
                      },
                      child: Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          isExpanded
                              ? AppLocalizations.of(context).hideReplies
                              : AppLocalizations.of(context).showRepliesCount(repliesCount),
                          style: const TextStyle(
                            color: Color(0xFF003e70),
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _sendComment(AppState appState) async {
    final text = _commentController.text.trim();
    if (text.isEmpty && _selectedMediaUrl == null && _selectedImageFile == null) return;
    
    // Проверяем лимит символов (500)
    if (text.length > 500) {
      Notify.error(context, AppLocalizations.of(context).commentTooLong(text.length));
      return;
    }

    // Если редактируем комментарий
    if (_editingComment != null) {
      appState.editComment(_editingComment!.id, text);
      _commentController.clear();
      setState(() => _editingComment = null);
      Notify.info(context, AppLocalizations.of(context).translate('comment_updated'));
      return;
    }

    // Загружаем картинку если выбрана
    String? uploadedMediaUrl = _selectedMediaUrl;
    if (_selectedImageFile != null) {
      final storageService = SupabaseStorageService();
      final currentUser = appState.currentUser;
      if (currentUser != null) {
        uploadedMediaUrl = await storageService.uploadCommentImage(currentUser.id, _selectedImageFile!);
      }
    }

    final newCommentId = const Uuid().v4();
    String? parentCommentId;
    String? threadRootId;
    if (_replyingTo != null) {
      parentCommentId = _replyingTo!.id;
      threadRootId = _replyingTo!.threadRootId ?? _replyingTo!.id;
    }

    // Получаем текущего пользователя
    final currentUser = appState.currentUser;
    if (currentUser == null) return;

    final comment = Comment(
      id: newCommentId,
      storyId: widget.story.id,
      author: currentUser,
      text: text.isEmpty ? '' : text, // Пустая строка если только медиа
      createdAt: DateTime.now(),
      replyToId: parentCommentId,
      replyToAuthor: _replyingTo?.isAnonymous == true ? AppLocalizations.of(context).translate('anonymous_user') : _replyingTo?.author.name,
      replyTargetId: parentCommentId,
      threadRootId: threadRootId ?? newCommentId,
      isPendingSync: true,
      isAnonymous: _isAnonymous,
      mediaUrl: uploadedMediaUrl,
      mediaType: _selectedMediaType,
      mediaWidth: _selectedMediaWidth,
      mediaHeight: _selectedMediaHeight,
    );

    appState.addComment(comment);
    _commentController.clear();
    
    // Очищаем выбранное медиа
    setState(() {
      _selectedMediaUrl = null;
      _selectedMediaType = null;
      _selectedMediaWidth = null;
      _selectedMediaHeight = null;
      _selectedImageFile = null;
    });
    
    // Если это подответ, раскрываем родительский комментарий
    final rootIdToExpand = threadRootId ?? parentCommentId;
    if (rootIdToExpand != null) {
      setState(() {
        _expandedComments.add(rootIdToExpand);
        _replyingTo = null;
        _isAnonymous = false;
      });
    } else {
      setState(() {
        _replyingTo = null;
        _isAnonymous = false;
      });
    }
    
    // Скроллим к новому комментарию, а не наверх
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToComment(comment.id);
    });
  }

  void _scrollToComment(String? commentId) {
    if (commentId == null || !mounted) return;


    final appState = Provider.of<AppState>(context, listen: false);
    final comments = appState.getComments(widget.story.id);
    final target = comments.where((c) => c.id == commentId).toList();
    final targetComment = target.isNotEmpty ? target.first : null;
    final rootIdToExpand = targetComment?.replyToId == null
        ? targetComment?.id
        : (targetComment?.threadRootId ?? targetComment?.replyToId);

    // Раскрываем комментарий если он свернут
    setState(() {
      if (rootIdToExpand != null) {
        _expandedComments.add(rootIdToExpand);
      }
      _highlightedCommentId = commentId;
    });

    // Сначала пробуем точный скролл по GlobalKey (самый надежный)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final key = _commentKeys[commentId];
      final ctx = key?.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 450),
          curve: Curves.easeInOut,
          alignment: 0.2,
        );

        Future.delayed(const Duration(milliseconds: 350), () {
          if (!mounted) return;
          final retryCtx = _commentKeys[commentId]?.currentContext;
          if (retryCtx != null) {
            Scrollable.ensureVisible(
              retryCtx,
              duration: const Duration(milliseconds: 450),
              curve: Curves.easeInOut,
              alignment: 0.2,
            );
            return;
          }
          if (_scrollController.hasClients) {
            _scrollController.animateTo(
              _scrollController.position.maxScrollExtent,
              duration: const Duration(milliseconds: 450),
              curve: Curves.easeInOut,
            );
          }
        });
      } else {
        // Fallback: скроллим по индексу (приблизительно)
        _scrollToCommentByIndex(commentId);
      }
    });

    // Убираем подсветку через 3 секунды
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() {
          _highlightedCommentId = null;
        });
      }
    });
  }

  void _scrollToCommentByIndex(String targetCommentId) {
    if (!mounted) return;
    
    final appState = Provider.of<AppState>(context, listen: false);
    final comments = appState.getComments(widget.story.id);
    
    // Ищем индекс комментария среди основных комментариев (без ответов)
    int targetIndex = -1;
    final mainComments = comments.where((c) => c.replyToId == null).toList();
    
    for (int i = 0; i < mainComments.length; i++) {
      if (mainComments[i].id == targetCommentId) {
        targetIndex = i;
        break;
      }
      // Проверяем ответы этого комментария
      final replies = comments.where((c) => 
        c.threadRootId == mainComments[i].id && c.id != mainComments[i].id
      ).toList();
      for (final reply in replies) {
        if (reply.id == targetCommentId) {
          targetIndex = i;
          break;
        }
      }
      if (targetIndex != -1) break;
    }
    
    if (targetIndex != -1) {
      // Даем время на отрисовку и скроллим
      Future.delayed(const Duration(milliseconds: 500), () {
        if (!mounted) return;

        if (!_scrollController.hasClients) {
          AppLogger.warning('ScrollController not attached yet, skip scroll', tag: 'CommentsScreen');
          return;
        }
        
        // Расчет позиции: высота поста + заголовок + отступы + индекс * высота комментария
        final rawPosition = 400.0 + (targetIndex * 200.0); // 400px на пост/заголовок, 200px на комментарий с ответами
        final max = _scrollController.position.maxScrollExtent;
        final estimatedPosition = rawPosition > max ? max : rawPosition;
        _scrollController.animateTo(
          estimatedPosition,
          duration: const Duration(milliseconds: 500),
          curve: Curves.easeInOut,
        );
      });
    } else {
      AppLogger.warning('${AppLocalizations.of(context).commentNotFound}: $targetCommentId', tag: 'CommentsScreen');
    }
  }

  void _showReportDialog(Comment comment) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(AppLocalizations.of(dialogContext).reportComment),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.warning, color: Colors.orange),
              title: Text(AppLocalizations.of(dialogContext).spamReport),
              onTap: () async {
                final success = await _submitReport(comment, AppLocalizations.of(dialogContext).spam);
                if (success && dialogContext.mounted) {
                  Navigator.pop(dialogContext);
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.block, color: Colors.red),
              title: Text(AppLocalizations.of(dialogContext).insultReport),
              onTap: () async {
                final success = await _submitReport(comment, AppLocalizations.of(dialogContext).insult);
                if (success && dialogContext.mounted) {
                  Navigator.pop(dialogContext);
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.report, color: Colors.red),
              title: Text(AppLocalizations.of(dialogContext).inappropriateContent),
              onTap: () async {
                final success = await _submitReport(comment, AppLocalizations.of(dialogContext).inappropriateContentReport);
                if (success && dialogContext.mounted) {
                  Navigator.pop(dialogContext);
                }
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(AppLocalizations.of(dialogContext).cancelButton),
          ),
        ],
      ),
    );
  }

  Future<bool> _submitReport(Comment comment, String reason) async {
    final appState = context.read<AppState>();
    
    try {
      // Определяем тип жалобы
      ReportType reportType;
      final localizations = AppLocalizations.of(context);
      if (reason == localizations.spam) {
        reportType = ReportType.spam;
      } else if (reason == localizations.insult) {
        reportType = ReportType.harassment;
      } else if (reason == localizations.inappropriateContentReport) {
        reportType = ReportType.inappropriate;
      } else {
        reportType = ReportType.other;
      }
      
      // Отправляем жалобу на сервер
      final success = await appState.reportContent(
        type: reportType,
        contentType: ReportContentType.comment,
        contentId: comment.id,
        description: '${AppLocalizations.of(context).translate('report_reason')}: $reason, ${AppLocalizations.of(context).translate('post')}: ${widget.story.id}',
      );
      
      if (mounted) {
        if (success) {
          Notify.success(context, 'Жалоба отправлена', subtitle: AppLocalizations.of(context).thanksFeedback);
          return true;
        } else {
          Notify.error(context, AppLocalizations.of(context).reportFailed, subtitle: AppLocalizations.of(context).tryLater);
          return false;
        }
      }
    } catch (e) {
      AppLogger.error('Ошибка отправки жалобы на комментарий', tag: 'CommentsScreen', error: e);
      if (mounted) {
        Notify.error(context, AppLocalizations.of(context).reportFailed, subtitle: AppLocalizations.of(context).tryLater);
      }
    }
    return false;
  }

  void _deleteComment(String commentId, AppState appState) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(AppLocalizations.of(context).deleteCommentQuestion),
        content: Text(AppLocalizations.of(context).cannotUndoAction),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(AppLocalizations.of(context).cancelButton),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              appState.deleteComment(commentId);
              Notify.info(context, AppLocalizations.of(context).translate('comment_deleted'));
            },
            child: Text(AppLocalizations.of(context).delete, style: const TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  void _showPremiumPaywall(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1F1F1F) : Colors.white,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFFFFD700), Color(0xFFFFA500)],
                ),
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.15),
                    blurRadius: 12,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: const Icon(
                Icons.visibility_off,
                size: 48,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              AppLocalizations.of(context).anonymousCommentsTitle,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: isDark ? Colors.white : Colors.black87,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              AppLocalizations.of(context).writeOpenlyShareOpinion,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: isDark ? Colors.white70 : Colors.black54,
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () {
                  Navigator.pop(context);
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const PremiumScreen()),
                  );
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFFFD700),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)).borderRadius,
                  ),
                ),
                child: Text(
                  AppLocalizations.of(context).translate('buy_premium'),
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(
                AppLocalizations.of(context).translate('maybe_later'),
                style: TextStyle(
                  color: isDark ? Colors.white60 : Colors.black45,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _getDisplayName(Comment comment) => comment.isAnonymous ? AppLocalizations.of(context).translate('anonymous_user') : comment.author.name;

  Widget _buildAnonymousAvatar({double radius = 20}) {
    return Container(
      width: radius * 2,
      height: radius * 2,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.grey[300],
      ),
      child: const Icon(
        Icons.lock,
        color: Colors.grey,
        size: 18,
      ),
    );
  }

  String? _resolveReplyLabel(Comment reply, AppState appState) {
    if (reply.replyToAuthor == null) return null;
    final comments = appState.getComments(widget.story.id);
    Comment? targetComment;
    try {
      targetComment = comments.firstWhere((c) => c.id == reply.replyTargetId);
    } catch (_) {
      targetComment = null;
    }
    final anonName = AppLocalizations.of(context).translate('anonymous_user');
    final displayName = targetComment?.isAnonymous == true || reply.replyToAuthor == 'Аноним' || reply.replyToAuthor == anonName
        ? anonName
        : reply.replyToAuthor;
    final replyPrefix = AppLocalizations.of(context).translate('reply_button');
    return '$replyPrefix ${displayName?.startsWith('@') == true ? '' : '@'}$displayName';
  }

  Widget? _buildReplyLabelWidget(Comment reply, AppState appState) {
    final labelText = _resolveReplyLabel(reply, appState);
    if (labelText == null) return null;

    return GestureDetector(
      onTap: () {
        final comments = appState.getComments(widget.story.id);
        Comment? targetComment;
        try {
          targetComment = comments.firstWhere((c) => c.id == reply.replyTargetId);
        } catch (_) {
          targetComment = null;
        }
        if (targetComment == null) return;

        final parentId = targetComment.replyToId ?? targetComment.id;
        setState(() {
          _expandedComments.add(parentId);
        });

        Future.delayed(const Duration(milliseconds: 100), () {
          _scrollToComment(targetComment!.id);
        });
      },
      child: Text(
        labelText,
        style: const TextStyle(
          color: Color(0xFF003e70),
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  /// UI переключателя сортировки
  Widget _buildSortToggle() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.grey[100],
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildSortChip('🔥 ${AppLocalizations.of(context).translate('top')}', PostCommentSortType.top),
          const SizedBox(width: 4),
          _buildSortChip('🕒 ${AppLocalizations.of(context).newTab}', PostCommentSortType.newest),
        ],
      ),
    );
  }
  
  Widget _buildSortChip(String label, PostCommentSortType type) {
    final isSelected = _sortType == type;
    return GestureDetector(
      onTap: () => setState(() => _sortType = type),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF003e70) : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? Colors.white : Colors.grey[600],
            fontSize: 12,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
          ),
        ),
      ),
    );
  }
  
  /// Получить отсортированные комментарии
  List<Comment> _getSortedComments(List<Comment> comments, AppState appState) {
    // Только основные комментарии (не ответы)
    final mainComments = comments.where((c) => c.replyToId == null).toList();
    
    // Если нет основных комментариев, показываем все отсортированные по времени
    if (mainComments.isEmpty) {
      final sortedAll = List<Comment>.from(comments);
      sortedAll.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return sortedAll;
    }
    
    // Закреплённый комментарий всегда первый
    final pinned = mainComments.where((c) => c.isPinned).toList();
    final unpinned = mainComments.where((c) => !c.isPinned).toList();
    
    List<Comment> sorted;
    switch (_sortType) {
      case PostCommentSortType.top:
        sorted = _getSmartSortedComments(unpinned, comments);
      case PostCommentSortType.newest:
        unpinned.sort((a, b) => b.createdAt.compareTo(a.createdAt));
        sorted = unpinned;
    }
    
    // Последний комментарий текущего пользователя — первым (для него)
    final currentUserId = appState.currentUser?.id;
    if (currentUserId != null) {
      final myComments = sorted.where((c) => c.author.id == currentUserId).toList();
      if (myComments.isNotEmpty) {
        myComments.sort((a, b) => b.createdAt.compareTo(a.createdAt));
        final newest = myComments.first;
        final idx = sorted.indexOf(newest);
        if (idx > 0) {
          sorted.removeAt(idx);
          sorted.insert(0, newest);
        }
      }
    }
    
    return [...pinned, ...sorted];
  }
  
  /// Умная сортировка: по лайкам + ответам (score), потом по времени
  List<Comment> _getSmartSortedComments(List<Comment> mainComments, List<Comment> allComments) {
    // Если был лайк недавно, не пересортировываем сразу
    final now = DateTime.now();
    final shouldSkipResort = _lastLikeTime != null && 
        now.difference(_lastLikeTime!) < _sortDelay;
    
    // Считаем score = лайки + кол-во ответов
    final scored = mainComments.map((c) {
      final repliesCount = allComments.where((r) => 
        r.threadRootId == c.id && r.id != c.id
      ).length;
      final score = c.likes + repliesCount;
      return MapEntry(c, score);
    }).toList();

    // Сортируем по score (убывание), при равном — по времени (новые первые)
    scored.sort((a, b) {
      final scoreCmp = b.value.compareTo(a.value);
      
      // Если был недавний лайк, уменьшаем приоритет score для избежания прыжков
      if (shouldSkipResort) {
        // При недавнем лайке сортируем в основном по времени, но немного учитываем score
        final timeCmp = b.key.createdAt.compareTo(a.key.createdAt);
        if (scoreCmp.abs() > 2) {
          // Если разница в score большая, всё равно учитываем её
          return scoreCmp > 0 ? 1 : -1;
        }
        return timeCmp;
      }
      
      if (scoreCmp != 0) return scoreCmp;
      return b.key.createdAt.compareTo(a.key.createdAt);
    });

    return scored.map((e) => e.key).toList();
  }

  @override
  void dispose() {
    _timeTicker?.cancel();
    _commentController.removeListener(_onCommentTextChanged);
    _commentController.dispose();
    _commentFocusNode.dispose();
    _scrollController.dispose();
    _commentKeys.clear();
    super.dispose();
  }
}
