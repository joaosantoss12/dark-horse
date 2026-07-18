-- One free play per day by default, and a per-user override the admin can set.
--
-- The global cap drops to 1. On top of that, a single player can be given a
-- different number (more for a VIP, zero to cut them off) via
-- profiles.free_hands_override -- NULL means "use the global".

UPDATE settings SET value = '1'::jsonb WHERE key = 'free_hands_per_day';
INSERT INTO settings (key, value) VALUES ('free_hands_per_day', '1'::jsonb)
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;

ALTER TABLE profiles ADD COLUMN IF NOT EXISTS free_hands_override INT
  CHECK (free_hands_override IS NULL OR free_hands_override >= 0);

-- The cap that actually applies to a given player: their override, else global.
CREATE OR REPLACE FUNCTION dh_free_hands_cap(p_uid UUID)
RETURNS INT
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT COALESCE(
    (SELECT free_hands_override FROM profiles WHERE id = p_uid),
    dh_free_hands_per_day()
  );
$$;

-- ---------------------------------------------------------------------------
-- Join and limits now use the per-user cap
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION dh_my_limits()
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_uid  UUID := auth.uid();
  v_used INT;
  v_cap  INT;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  v_used := dh_free_hands_used(v_uid);
  v_cap  := dh_free_hands_cap(v_uid);

  RETURN jsonb_build_object(
    'freeHandsUsed', v_used,
    'freeHandsPerDay', v_cap,
    'freeHandsLeft', GREATEST(0, v_cap - v_used),
    'resetsAt', (date_trunc('day', now() AT TIME ZONE 'UTC') + interval '1 day') AT TIME ZONE 'UTC',
    'cashEnabled', dh_cash_enabled()
  );
END;
$$;

-- dh_join_room only needs the one line changed, but it is recreated wholesale so
-- the definition stays in one readable place.
CREATE OR REPLACE FUNCTION dh_join_room(p_room_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_uid     UUID := auth.uid();
  v_room    rooms%ROWTYPE;
  v_profile profiles%ROWTYPE;
  v_seat    INT;
  v_taken   INT;
  v_bal     BIGINT;
  v_col     TEXT;
  v_used    INT;
  v_cap     INT;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'You must be signed in to play.'; END IF;
  PERFORM dh_tick();

  SELECT * INTO v_room FROM rooms WHERE id = p_room_id AND is_active AND NOT is_deleted FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'That table is not open.'; END IF;

  IF v_room.mode = 'cash' AND NOT dh_cash_enabled() THEN
    RAISE EXCEPTION 'Real money tables are not open yet.';
  END IF;
  IF v_room.current_round_id IS NOT NULL THEN
    RAISE EXCEPTION 'This table is mid-hand. Try the next one.';
  END IF;

  SELECT * INTO v_profile FROM profiles WHERE id = v_uid FOR UPDATE;
  IF v_profile.is_banned THEN RAISE EXCEPTION 'Your account is suspended.'; END IF;
  IF EXISTS (SELECT 1 FROM seats WHERE room_id = p_room_id AND user_id = v_uid) THEN
    RAISE EXCEPTION 'You are already at this table.';
  END IF;

  IF v_room.mode = 'free' THEN
    v_cap := dh_free_hands_cap(v_uid);
    v_used := dh_free_hands_used(v_uid);
    IF v_used >= v_cap THEN
      IF v_cap = 1 THEN
        RAISE EXCEPTION 'You have used your free play for today. It resets at midnight UTC.';
      ELSE
        RAISE EXCEPTION 'You have played all % free hands for today. They reset at midnight UTC.', v_cap;
      END IF;
    END IF;
  END IF;

  v_col := dh_balance_col(v_room.mode);
  EXECUTE format('SELECT %I FROM profiles WHERE id = $1', v_col) INTO v_bal USING v_uid;

  IF v_bal < v_room.buy_in THEN
    IF v_room.mode = 'free' THEN
      RAISE EXCEPTION 'Not enough points for this table.';
    ELSIF v_room.mode = 'demo' THEN
      RAISE EXCEPTION 'Not enough demo balance for this table.';
    ELSE
      RAISE EXCEPTION 'Not enough real-money balance for this table.';
    END IF;
  END IF;

  SELECT MIN(i) INTO v_seat
  FROM generate_series(0, v_room.seats - 1) i
  WHERE i NOT IN (SELECT seat_index FROM seats WHERE room_id = p_room_id);
  IF v_seat IS NULL THEN RAISE EXCEPTION 'This table is full.'; END IF;

  EXECUTE format('UPDATE profiles SET %I = %I - $1 WHERE id = $2 RETURNING %I', v_col, v_col, v_col)
    INTO v_bal USING v_room.buy_in, v_uid;

  INSERT INTO seats (room_id, seat_index, user_id) VALUES (p_room_id, v_seat, v_uid);

  IF v_room.buy_in > 0 THEN
    INSERT INTO ledger (user_id, kind, amount, balance_after, note)
    VALUES (v_uid, v_room.mode || '_buy_in', -v_room.buy_in, v_bal, v_room.name);
  END IF;

  SELECT COUNT(*) INTO v_taken FROM seats WHERE room_id = p_room_id;
  IF v_taken = v_room.seats THEN
    UPDATE rooms SET fill_deadline = NULL WHERE id = p_room_id;
    PERFORM dh_deal(p_room_id);
  ELSIF v_taken = 1 THEN
    UPDATE rooms SET fill_deadline = now() + (dh_fill_window() * interval '1 second')
     WHERE id = p_room_id;
  END IF;

  RETURN jsonb_build_object('seat', v_seat, 'balance', v_bal);
END;
$$;

-- ---------------------------------------------------------------------------
-- Admin: set or clear a player's free-hands override
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION dh_admin_set_free_hands(p_user_id UUID, p_value INT)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  PERFORM dh_require_admin();
  IF p_value IS NOT NULL AND p_value < 0 THEN
    RAISE EXCEPTION 'Free hands cannot be negative.';
  END IF;
  UPDATE profiles SET free_hands_override = p_value WHERE id = p_user_id;
END;
$$;

-- The admin player list carries the override so it can be shown/edited.
DROP FUNCTION IF EXISTS dh_admin_players(TEXT);

CREATE FUNCTION dh_admin_players(p_query TEXT DEFAULT '')
RETURNS TABLE (id UUID, display_name TEXT, email TEXT, balance BIGINT, cash_balance BIGINT,
               demo_balance BIGINT, referral_count INT, free_hands_override INT,
               is_admin BOOLEAN, is_banned BOOLEAN, created_at TIMESTAMPTZ)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  PERFORM dh_require_admin();
  RETURN QUERY
    SELECT p.id, p.display_name, u.email::TEXT, p.balance, p.cash_balance,
           p.demo_balance, p.referral_count, p.free_hands_override,
           p.is_admin, p.is_banned, p.created_at
      FROM profiles p
      JOIN auth.users u ON u.id = p.id
     WHERE COALESCE(p_query, '') = ''
        OR p.display_name ILIKE '%' || p_query || '%'
        OR u.email ILIKE '%' || p_query || '%'
     ORDER BY p.created_at DESC
     LIMIT 100;
END;
$$;

GRANT EXECUTE ON FUNCTION dh_free_hands_cap(UUID)              TO authenticated;
GRANT EXECUTE ON FUNCTION dh_my_limits()                       TO authenticated;
GRANT EXECUTE ON FUNCTION dh_join_room(BIGINT)                 TO authenticated;
GRANT EXECUTE ON FUNCTION dh_admin_set_free_hands(UUID, INT)   TO authenticated;
GRANT EXECUTE ON FUNCTION dh_admin_players(TEXT)               TO authenticated;
