-- Player profiles: avatar, editable name, and career stats.

ALTER TABLE profiles ADD COLUMN IF NOT EXISTS avatar_url TEXT;

-- ---------------------------------------------------------------------------
-- Avatar storage
-- ---------------------------------------------------------------------------
-- A hard 2 MB cap and an image-only mime list, enforced by storage itself --
-- not by the upload form, which a player can bypass.
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('avatars', 'avatars', TRUE, 2097152, ARRAY['image/png', 'image/jpeg', 'image/webp'])
ON CONFLICT (id) DO UPDATE
  SET public = TRUE,
      file_size_limit = 2097152,
      allowed_mime_types = ARRAY['image/png', 'image/jpeg', 'image/webp'];

DROP POLICY IF EXISTS avatars_read      ON storage.objects;
DROP POLICY IF EXISTS avatars_insert    ON storage.objects;
DROP POLICY IF EXISTS avatars_update    ON storage.objects;
DROP POLICY IF EXISTS avatars_delete    ON storage.objects;

-- Anyone can look at an avatar: they are shown at the table to everyone.
CREATE POLICY avatars_read ON storage.objects
  FOR SELECT USING (bucket_id = 'avatars');

-- But you may only write inside a folder named after your own user id, so one
-- player cannot overwrite another's picture.
CREATE POLICY avatars_insert ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'avatars' AND (storage.foldername(name))[1] = auth.uid()::TEXT
  );

CREATE POLICY avatars_update ON storage.objects
  FOR UPDATE TO authenticated
  USING (bucket_id = 'avatars' AND (storage.foldername(name))[1] = auth.uid()::TEXT);

CREATE POLICY avatars_delete ON storage.objects
  FOR DELETE TO authenticated
  USING (bucket_id = 'avatars' AND (storage.foldername(name))[1] = auth.uid()::TEXT);

-- ---------------------------------------------------------------------------
-- Editing your own profile
-- ---------------------------------------------------------------------------
-- Goes through a function, not a table update: profiles also holds balance and
-- is_admin, and there is no write policy on that table for a reason.
CREATE OR REPLACE FUNCTION dh_update_profile(p_display_name TEXT, p_avatar_url TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_uid  UUID := auth.uid();
  v_name TEXT := TRIM(COALESCE(p_display_name, ''));
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;

  IF length(v_name) < 2 OR length(v_name) > 24 THEN
    RAISE EXCEPTION 'Your name must be between 2 and 24 characters.';
  END IF;

  IF EXISTS (
    SELECT 1 FROM profiles WHERE lower(display_name) = lower(v_name) AND id <> v_uid
  ) THEN
    RAISE EXCEPTION 'That name is taken.';
  END IF;

  UPDATE profiles
     SET display_name = v_name,
         avatar_url = NULLIF(TRIM(COALESCE(p_avatar_url, '')), '')
   WHERE id = v_uid;

  RETURN jsonb_build_object('displayName', v_name, 'avatarUrl', p_avatar_url);
END;
$$;

-- ---------------------------------------------------------------------------
-- Career stats
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION dh_my_stats()
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_uid   UUID := auth.uid();
  v_stats JSONB;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;

  SELECT jsonb_build_object(
    'handsPlayed', COUNT(*),
    'handsWon',    COUNT(*) FILTER (WHERE h.won > 0),
    'firstPlaces', COUNT(*) FILTER (WHERE h.place = 1),
    'wagered',     COALESCE(SUM(r.buy_in), 0),
    'won',         COALESCE(SUM(h.won), 0),
    'net',         COALESCE(SUM(h.won - r.buy_in), 0),
    'bestScore',   COALESCE(MAX(h.score) FILTER (WHERE h.category = 0), 0),
    -- 2 = three of a kind, 1 = crown
    'specials',    COUNT(*) FILTER (WHERE h.category > 0),
    'bestHand',    (
      SELECT jsonb_build_object('cards', h2.cards, 'score', h2.score, 'category', h2.category)
        FROM round_hands h2
        JOIN rounds r2 ON r2.id = h2.round_id AND r2.settled_at IS NOT NULL
       WHERE h2.user_id = v_uid
       ORDER BY h2.category DESC, h2.score DESC
       LIMIT 1
    )
  )
  INTO v_stats
  FROM round_hands h
  JOIN rounds r ON r.id = h.round_id AND r.settled_at IS NOT NULL
  WHERE h.user_id = v_uid;

  RETURN v_stats;
END;
$$;

-- ---------------------------------------------------------------------------
-- Show the avatar at the table
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION dh_get_room(p_room_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_room     rooms%ROWTYPE;
  v_round    rounds%ROWTYPE;
  v_phase    TEXT;
  v_revealed INT := 0;
  v_players  JSONB;
BEGIN
  PERFORM dh_tick();

  SELECT * INTO v_room FROM rooms WHERE id = p_room_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'That table no longer exists.'; END IF;

  IF v_room.current_round_id IS NULL THEN
    v_phase := 'waiting';
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
             'seat', s.seat_index,
             'userId', s.user_id,
             'name', COALESCE(p.display_name, s.bot_name),
             'avatarUrl', p.avatar_url,
             'isBot', s.bot_name IS NOT NULL,
             'cards', jsonb_build_array(NULL, NULL, NULL)
           ) ORDER BY s.seat_index), '[]'::jsonb)
      INTO v_players
      FROM seats s
      LEFT JOIN profiles p ON p.id = s.user_id
     WHERE s.room_id = p_room_id;
  ELSE
    SELECT * INTO v_round FROM rounds WHERE id = v_room.current_round_id;

    IF now() < v_round.dealt_at THEN
      v_phase := 'countdown';
    ELSIF now() < v_round.settle_at THEN
      v_phase := 'dealing';
      v_revealed := LEAST(3, FLOOR(EXTRACT(EPOCH FROM now() - v_round.dealt_at) / 1.6)::INT + 1);
    ELSE
      v_phase := 'results';
      v_revealed := 3;
    END IF;

    SELECT COALESCE(jsonb_agg(jsonb_build_object(
             'seat', h.seat_index,
             'userId', h.user_id,
             'name', COALESCE(p.display_name, h.bot_name),
             'avatarUrl', p.avatar_url,
             'isBot', h.bot_name IS NOT NULL,
             'cards', (
               SELECT jsonb_agg(CASE WHEN i <= v_revealed THEN h.cards->(i - 1) ELSE NULL END ORDER BY i)
               FROM generate_series(1, 3) i
             ),
             'total', CASE WHEN v_phase = 'results' THEN h.total END,
             'score', CASE WHEN v_phase = 'results' THEN h.score END,
             'category', CASE WHEN v_phase = 'results' THEN h.category END,
             'place', CASE WHEN v_phase = 'results' THEN h.place END,
             'won',   CASE WHEN v_phase = 'results' THEN h.won END,
             'isSplit', CASE WHEN v_phase = 'results' THEN h.is_split END
           ) ORDER BY h.seat_index), '[]'::jsonb)
      INTO v_players
      FROM round_hands h
      LEFT JOIN profiles p ON p.id = h.user_id
     WHERE h.round_id = v_round.id;
  END IF;

  RETURN jsonb_build_object(
    'id', v_room.id,
    'name', v_room.name,
    'seats', v_room.seats,
    'buyIn', v_room.buy_in,
    'prizes', v_room.prizes,
    'phase', v_phase,
    'revealed', v_revealed,
    'players', v_players,
    'startsInMs', CASE WHEN v_phase = 'countdown'
                       THEN GREATEST(0, EXTRACT(EPOCH FROM v_round.dealt_at - now()) * 1000)::INT END
  );
END;
$$;

-- New functions are not granted to the browser by default (see 0003), so the
-- two new entry points need saying out loud.
GRANT EXECUTE ON FUNCTION dh_update_profile(TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION dh_my_stats()                 TO authenticated;
GRANT EXECUTE ON FUNCTION dh_get_room(BIGINT)           TO authenticated;
