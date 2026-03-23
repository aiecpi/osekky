-- =====================================================
-- Миграция 158: Полное исправление всех триггеров уведомлений
-- Проблемы:
-- 1. Триггер для лайков (like) не передаёт from_user_id
-- 2. Триггер для комментариев (comment) не передаёт from_user_id
-- 3. Отсутствует триггер для comment_like
-- 4. Все триггеры должны заполнять И actor_id И from_user_id
-- =====================================================

-- =====================================================
-- 1. Гарантируем что create_notification актуальная
-- =====================================================
CREATE OR REPLACE FUNCTION create_notification(
  p_user_id UUID,
  p_type TEXT,
  p_title TEXT DEFAULT NULL,
  p_body TEXT DEFAULT NULL,
  p_from_user_id UUID DEFAULT NULL,
  p_post_id UUID DEFAULT NULL,
  p_comment_id UUID DEFAULT NULL,
  p_discussion_id UUID DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF p_user_id IS NULL OR p_type IS NULL OR btrim(p_type) = '' THEN
    RETURN;
  END IF;

  -- Не уведомляем себя
  IF p_from_user_id IS NOT NULL AND p_user_id = p_from_user_id THEN
    RETURN;
  END IF;

  -- Не уведомляем заблокированных
  IF EXISTS (
    SELECT 1 FROM users
    WHERE id = p_user_id AND (is_blocked = true OR is_banned = true)
  ) THEN
    RETURN;
  END IF;

  -- Дедупликация по типу + from_user + post/comment/discussion (без окна времени)
  IF p_type = 'like' AND p_post_id IS NOT NULL AND p_from_user_id IS NOT NULL THEN
    IF EXISTS (
      SELECT 1 FROM notifications
      WHERE user_id = p_user_id AND type = p_type
        AND post_id = p_post_id
        AND COALESCE(from_user_id, actor_id) = p_from_user_id
    ) THEN RETURN; END IF;

  ELSIF p_type = 'comment_like' AND p_comment_id IS NOT NULL AND p_from_user_id IS NOT NULL THEN
    IF EXISTS (
      SELECT 1 FROM notifications
      WHERE user_id = p_user_id AND type = p_type
        AND comment_id = p_comment_id
        AND COALESCE(from_user_id, actor_id) = p_from_user_id
    ) THEN RETURN; END IF;

  ELSIF p_type = 'follow' AND p_from_user_id IS NOT NULL THEN
    IF EXISTS (
      SELECT 1 FROM notifications
      WHERE user_id = p_user_id AND type = p_type
        AND COALESCE(from_user_id, actor_id) = p_from_user_id
    ) THEN RETURN; END IF;

  ELSIF p_type = 'debate_vote' AND p_discussion_id IS NOT NULL AND p_from_user_id IS NOT NULL THEN
    IF EXISTS (
      SELECT 1 FROM notifications
      WHERE user_id = p_user_id AND type = p_type
        AND discussion_id = p_discussion_id
        AND COALESCE(from_user_id, actor_id) = p_from_user_id
    ) THEN RETURN; END IF;

  ELSIF p_type IN ('comment', 'reply') AND p_post_id IS NOT NULL AND p_from_user_id IS NOT NULL THEN
    -- Дедупликация комментариев в течение 5 минут
    IF EXISTS (
      SELECT 1 FROM notifications
      WHERE user_id = p_user_id AND type = p_type
        AND post_id = p_post_id
        AND COALESCE(from_user_id, actor_id) = p_from_user_id
        AND created_at > NOW() - INTERVAL '5 minutes'
    ) THEN RETURN; END IF;
  END IF;

  BEGIN
    INSERT INTO notifications (
      user_id, type, title, body,
      actor_id, from_user_id,
      post_id, comment_id, discussion_id,
      is_read, created_at
    ) VALUES (
      p_user_id, p_type,
      COALESCE(p_title, 'Уведомление'),
      p_body,
      p_from_user_id, p_from_user_id,  -- actor_id = from_user_id всегда
      p_post_id, p_comment_id, p_discussion_id,
      false, NOW()
    );
  EXCEPTION WHEN OTHERS THEN
    -- Не ломаем основное действие при ошибке уведомления
    RAISE WARNING 'create_notification error: %', SQLERRM;
  END;
END;
$$;

GRANT EXECUTE ON FUNCTION create_notification TO authenticated;
GRANT EXECUTE ON FUNCTION create_notification TO anon;

-- =====================================================
-- 2. ТРИГГЕР ДЛЯ ЛАЙКОВ (like)
-- Таблица: likes (post_id, user_id)
-- =====================================================
CREATE OR REPLACE FUNCTION notify_post_like()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_author_id UUID;
BEGIN
  -- Получаем автора поста
  SELECT user_id INTO v_author_id
  FROM posts
  WHERE id = NEW.post_id;

  IF v_author_id IS NULL OR v_author_id = NEW.user_id THEN
    RETURN NEW;
  END IF;

  PERFORM create_notification(
    p_user_id      => v_author_id,
    p_type         => 'like',
    p_from_user_id => NEW.user_id,
    p_post_id      => NEW.post_id
  );

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_post_like ON likes;
CREATE TRIGGER on_post_like
  AFTER INSERT ON likes
  FOR EACH ROW
  EXECUTE FUNCTION notify_post_like();

-- =====================================================
-- 3. ТРИГГЕР ДЛЯ КОММЕНТАРИЕВ (comment)
-- Таблица: comments (id, post_id, user_id, parent_comment_id)
-- =====================================================
CREATE OR REPLACE FUNCTION notify_new_comment()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_post_author_id UUID;
  v_parent_author_id UUID;
BEGIN
  -- Если это ответ на комментарий
  IF NEW.parent_comment_id IS NOT NULL THEN
    SELECT user_id INTO v_parent_author_id
    FROM comments
    WHERE id = NEW.parent_comment_id;

    IF v_parent_author_id IS NOT NULL AND v_parent_author_id != NEW.user_id THEN
      PERFORM create_notification(
        p_user_id      => v_parent_author_id,
        p_type         => 'reply',
        p_from_user_id => NEW.user_id,
        p_post_id      => NEW.post_id,
        p_comment_id   => NEW.id
      );
    END IF;
  END IF;

  -- Уведомляем автора поста (если это не автор и не ответ на свой же комментарий)
  SELECT user_id INTO v_post_author_id
  FROM posts
  WHERE id = NEW.post_id;

  IF v_post_author_id IS NOT NULL 
     AND v_post_author_id != NEW.user_id
     AND (v_parent_author_id IS NULL OR v_post_author_id != v_parent_author_id) THEN
    PERFORM create_notification(
      p_user_id      => v_post_author_id,
      p_type         => 'comment',
      p_from_user_id => NEW.user_id,
      p_post_id      => NEW.post_id,
      p_comment_id   => NEW.id
    );
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_post_comment ON comments;
DROP TRIGGER IF EXISTS on_comment_insert ON comments;
CREATE TRIGGER on_post_comment
  AFTER INSERT ON comments
  FOR EACH ROW
  EXECUTE FUNCTION notify_new_comment();

-- =====================================================
-- 4. ТРИГГЕР ДЛЯ ЛАЙКОВ КОММЕНТАРИЕВ (comment_like)
-- Таблица: comment_likes (comment_id, user_id)
-- =====================================================
CREATE OR REPLACE FUNCTION notify_comment_like()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_comment_author_id UUID;
  v_post_id UUID;
BEGIN
  SELECT user_id, post_id INTO v_comment_author_id, v_post_id
  FROM comments
  WHERE id = NEW.comment_id;

  IF v_comment_author_id IS NULL OR v_comment_author_id = NEW.user_id THEN
    RETURN NEW;
  END IF;

  PERFORM create_notification(
    p_user_id      => v_comment_author_id,
    p_type         => 'comment_like',
    p_from_user_id => NEW.user_id,
    p_post_id      => v_post_id,
    p_comment_id   => NEW.comment_id
  );

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_comment_like ON comment_likes;
CREATE TRIGGER on_comment_like
  AFTER INSERT ON comment_likes
  FOR EACH ROW
  EXECUTE FUNCTION notify_comment_like();

-- =====================================================
-- 5. ТРИГГЕР ДЛЯ ГОЛОСОВАНИЯ В ДЕБАТАХ (debate_vote)
-- Таблица: discussion_votes (discussion_id, user_id, vote)
-- =====================================================
CREATE OR REPLACE FUNCTION notify_debate_vote()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_author_id UUID;
BEGIN
  SELECT author_id INTO v_author_id
  FROM discussions
  WHERE id = NEW.discussion_id;

  IF v_author_id IS NULL OR v_author_id = NEW.user_id THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'INSERT' THEN
    PERFORM create_notification(
      p_user_id       => v_author_id,
      p_type          => 'debate_vote',
      p_from_user_id  => NEW.user_id,
      p_discussion_id => NEW.discussion_id
    );
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_debate_vote ON discussion_votes;
CREATE TRIGGER on_debate_vote
  AFTER INSERT ON discussion_votes
  FOR EACH ROW
  EXECUTE FUNCTION notify_debate_vote();

-- =====================================================
-- 6. ТРИГГЕР ДЛЯ КОММЕНТАРИЕВ В ДЕБАТАХ (debate_comment/debate_reply)
-- Таблица: discussion_comments (id, discussion_id, author_id, parent_id)
-- =====================================================
CREATE OR REPLACE FUNCTION notify_debate_comment()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_discussion_author_id UUID;
  v_parent_author_id UUID;
BEGIN
  -- Если ответ на комментарий — уведомляем автора родительского комментария
  IF NEW.parent_id IS NOT NULL THEN
    SELECT author_id INTO v_parent_author_id
    FROM discussion_comments
    WHERE id = NEW.parent_id;

    IF v_parent_author_id IS NOT NULL AND v_parent_author_id != NEW.author_id THEN
      PERFORM create_notification(
        p_user_id       => v_parent_author_id,
        p_type          => 'debate_reply',
        p_from_user_id  => NEW.author_id,
        p_discussion_id => NEW.discussion_id,
        p_comment_id    => NEW.id
      );
    END IF;
  END IF;

  -- Уведомляем автора дебата
  SELECT author_id INTO v_discussion_author_id
  FROM discussions
  WHERE id = NEW.discussion_id;

  IF v_discussion_author_id IS NOT NULL
     AND v_discussion_author_id != NEW.author_id
     AND (v_parent_author_id IS NULL OR v_discussion_author_id != v_parent_author_id) THEN
    PERFORM create_notification(
      p_user_id       => v_discussion_author_id,
      p_type          => 'debate_comment',
      p_from_user_id  => NEW.author_id,
      p_discussion_id => NEW.discussion_id,
      p_comment_id    => NEW.id
    );
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_debate_comment ON discussion_comments;
CREATE TRIGGER on_debate_comment
  AFTER INSERT ON discussion_comments
  FOR EACH ROW
  EXECUTE FUNCTION notify_debate_comment();

-- =====================================================
-- 7. ТРИГГЕР ДЛЯ ЛАЙКОВ КОММЕНТАРИЕВ ДЕБАТОВ (debate_like)
-- Таблица: discussion_comment_likes (comment_id, user_id)
-- Создаём таблицу если её нет
-- =====================================================
CREATE TABLE IF NOT EXISTS discussion_comment_likes (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  comment_id UUID NOT NULL REFERENCES discussion_comments(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(comment_id, user_id)
);

ALTER TABLE discussion_comment_likes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Users can manage own debate comment likes" ON discussion_comment_likes;
CREATE POLICY "Users can manage own debate comment likes" ON discussion_comment_likes
  FOR ALL USING (auth.uid() = user_id);
DROP POLICY IF EXISTS "Users can view all debate comment likes" ON discussion_comment_likes;
CREATE POLICY "Users can view all debate comment likes" ON discussion_comment_likes
  FOR SELECT USING (true);

CREATE OR REPLACE FUNCTION notify_debate_comment_like()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_comment_author_id UUID;
  v_discussion_id UUID;
BEGIN
  SELECT author_id, discussion_id INTO v_comment_author_id, v_discussion_id
  FROM discussion_comments
  WHERE id = NEW.comment_id;

  IF v_comment_author_id IS NULL OR v_comment_author_id = NEW.user_id THEN
    RETURN NEW;
  END IF;

  PERFORM create_notification(
    p_user_id       => v_comment_author_id,
    p_type          => 'debate_like',
    p_from_user_id  => NEW.user_id,
    p_discussion_id => v_discussion_id,
    p_comment_id    => NEW.comment_id
  );

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_debate_comment_like ON discussion_comment_likes;
CREATE TRIGGER on_debate_comment_like
  AFTER INSERT ON discussion_comment_likes
  FOR EACH ROW
  EXECUTE FUNCTION notify_debate_comment_like();

-- =====================================================
-- 8. ТРИГГЕР ДЛЯ ПОДПИСОК (follow)
-- Таблица: follows (follower_id, following_id)
-- =====================================================
CREATE OR REPLACE FUNCTION notify_new_follow()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.follower_id = NEW.following_id THEN
    RETURN NEW;
  END IF;

  PERFORM create_notification(
    p_user_id      => NEW.following_id,
    p_type         => 'follow',
    p_from_user_id => NEW.follower_id
  );

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_new_follow ON follows;
CREATE TRIGGER on_new_follow
  AFTER INSERT ON follows
  FOR EACH ROW
  EXECUTE FUNCTION notify_new_follow();

-- =====================================================
-- 9. ПРОВЕРЯЕМ ЧТО КОЛОНКИ ЕСТЬ В notifications
-- =====================================================
ALTER TABLE notifications ADD COLUMN IF NOT EXISTS from_user_id UUID REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE notifications ADD COLUMN IF NOT EXISTS title TEXT;
ALTER TABLE notifications ADD COLUMN IF NOT EXISTS body TEXT;
ALTER TABLE notifications ADD COLUMN IF NOT EXISTS discussion_id UUID REFERENCES discussions(id) ON DELETE CASCADE;

-- Синхронизируем actor_id → from_user_id для старых записей
UPDATE notifications SET from_user_id = actor_id WHERE from_user_id IS NULL AND actor_id IS NOT NULL;

-- =====================================================
-- 10. ИНДЕКСЫ для быстрых запросов
-- =====================================================
CREATE INDEX IF NOT EXISTS idx_notifications_user_created ON notifications(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_notifications_user_unread ON notifications(user_id, is_read) WHERE is_read = false;
CREATE INDEX IF NOT EXISTS idx_notifications_from_user ON notifications(from_user_id);
CREATE INDEX IF NOT EXISTS idx_notifications_discussion ON notifications(discussion_id);

-- =====================================================
-- ИТОГ: Применены триггеры для:
-- ✅ like (on_post_like → notify_post_like)
-- ✅ comment + reply (on_post_comment → notify_new_comment)
-- ✅ comment_like (on_comment_like → notify_comment_like)
-- ✅ debate_vote (on_debate_vote → notify_debate_vote)
-- ✅ debate_comment + debate_reply (on_debate_comment → notify_debate_comment)
-- ✅ debate_like (on_debate_comment_like → notify_debate_comment_like)
-- ✅ follow (on_new_follow → notify_new_follow)
-- =====================================================
SELECT 'Migration 158 completed: all notification triggers applied' AS result;
