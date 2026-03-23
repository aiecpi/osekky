-- =====================================================
-- Миграция 157: нормализация уведомлений без дублей и без блокировки основного действия
-- =====================================================

-- 1. Актуализируем create_notification
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

  IF p_from_user_id IS NOT NULL AND p_user_id = p_from_user_id THEN
    RETURN;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM users
    WHERE id = p_user_id
      AND (is_blocked = true OR is_banned = true)
  ) THEN
    RETURN;
  END IF;

  IF p_type = 'like' AND p_post_id IS NOT NULL AND p_from_user_id IS NOT NULL THEN
    IF EXISTS (
      SELECT 1
      FROM notifications
      WHERE user_id = p_user_id
        AND type = p_type
        AND post_id = p_post_id
        AND COALESCE(from_user_id, actor_id) = p_from_user_id
    ) THEN
      RETURN;
    END IF;
  ELSIF p_type = 'comment_like' AND p_comment_id IS NOT NULL AND p_from_user_id IS NOT NULL THEN
    IF EXISTS (
      SELECT 1
      FROM notifications
      WHERE user_id = p_user_id
        AND type = p_type
        AND comment_id = p_comment_id
        AND COALESCE(from_user_id, actor_id) = p_from_user_id
    ) THEN
      RETURN;
    END IF;
  ELSIF p_type = 'follow' AND p_from_user_id IS NOT NULL THEN
    IF EXISTS (
      SELECT 1
      FROM notifications
      WHERE user_id = p_user_id
        AND type = p_type
        AND COALESCE(from_user_id, actor_id) = p_from_user_id
    ) THEN
      RETURN;
    END IF;
  ELSIF p_type = 'debate_vote' AND p_discussion_id IS NOT NULL AND p_from_user_id IS NOT NULL THEN
    IF EXISTS (
      SELECT 1
      FROM notifications
      WHERE user_id = p_user_id
        AND type = p_type
        AND discussion_id = p_discussion_id
        AND COALESCE(from_user_id, actor_id) = p_from_user_id
    ) THEN
      RETURN;
    END IF;
  END IF;

  BEGIN
    INSERT INTO notifications (
      user_id,
      type,
      title,
      body,
      actor_id,
      from_user_id,
      post_id,
      comment_id,
      discussion_id,
      is_read,
      created_at
    ) VALUES (
      p_user_id,
      p_type,
      COALESCE(p_title, 'Уведомление'),
      COALESCE(p_body, ''),
      p_from_user_id,
      p_from_user_id,
      p_post_id,
      p_comment_id,
      p_discussion_id,
      false,
      NOW()
    );
  EXCEPTION
    WHEN unique_violation THEN
      RETURN;
    WHEN check_violation THEN
      RETURN;
  END;
END;
$$;

GRANT EXECUTE ON FUNCTION create_notification(UUID, TEXT, TEXT, TEXT, UUID, UUID, UUID, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION create_notification(UUID, TEXT, TEXT, TEXT, UUID, UUID, UUID, UUID) TO anon;

-- 2. Лайк поста: уведомление не должно ломать сам лайк
CREATE OR REPLACE FUNCTION notify_post_like()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_post_author_id UUID;
BEGIN
  SELECT user_id INTO v_post_author_id
  FROM posts
  WHERE id = NEW.post_id
    AND is_deleted = false
    AND is_blocked = false;

  IF v_post_author_id IS NULL OR v_post_author_id = NEW.user_id THEN
    RETURN NEW;
  END IF;

  BEGIN
    PERFORM create_notification(
      p_user_id      => v_post_author_id,
      p_type         => 'like',
      p_from_user_id => NEW.user_id,
      p_post_id      => NEW.post_id
    );
  EXCEPTION
    WHEN OTHERS THEN
      RETURN NEW;
  END;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_post_like ON likes;
CREATE TRIGGER on_post_like
  AFTER INSERT ON likes
  FOR EACH ROW
  EXECUTE FUNCTION notify_post_like();

-- 3. Лайк комментария: уведомление не должно ломать сам лайк
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
  WHERE id = NEW.comment_id
    AND is_deleted = false;

  IF v_comment_author_id IS NULL OR v_comment_author_id = NEW.user_id THEN
    RETURN NEW;
  END IF;

  BEGIN
    PERFORM create_notification(
      p_user_id      => v_comment_author_id,
      p_type         => 'comment_like',
      p_from_user_id => NEW.user_id,
      p_post_id      => v_post_id,
      p_comment_id   => NEW.comment_id
    );
  EXCEPTION
    WHEN OTHERS THEN
      RETURN NEW;
  END;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_comment_like ON comment_likes;
CREATE TRIGGER on_comment_like
  AFTER INSERT ON comment_likes
  FOR EACH ROW
  EXECUTE FUNCTION notify_comment_like();

-- 4. Голос в дебате: уведомление не должно ломать сам голос
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

  BEGIN
    IF TG_OP = 'INSERT' THEN
      PERFORM create_notification(
        p_user_id       => v_author_id,
        p_type          => 'debate_vote',
        p_from_user_id  => NEW.user_id,
        p_discussion_id => NEW.discussion_id
      );
    END IF;
  EXCEPTION
    WHEN OTHERS THEN
      RETURN NEW;
  END;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_debate_vote ON discussion_votes;
CREATE TRIGGER on_debate_vote
  AFTER INSERT ON discussion_votes
  FOR EACH ROW
  EXECUTE FUNCTION notify_debate_vote();

SELECT '157_fix_notification_dedup_and_non_blocking applied' AS status;
