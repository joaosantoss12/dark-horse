-- Free play no longer has a daily hand cap at all -- not global, not per-user.
-- Removes the whole free-hands-limit system rather than just raising the
-- number, so there's no dead "resets at midnight" UI or admin override left
-- pointing at a limit that no longer exists.

ALTER TABLE profiles DROP COLUMN IF EXISTS free_hands_override;
DELETE FROM settings WHERE key = 'free_hands_per_day';

DROP FUNCTION IF EXISTS dh_admin_set_free_hands(UUID, INT);
DROP FUNCTION IF EXISTS dh_free_hands_cap(UUID);
DROP FUNCTION IF EXISTS dh_free_hands_used(UUID);
DROP FUNCTION IF EXISTS dh_free_hands_per_day();

CREATE OR REPLACE FUNCTION dh_my_limits()
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_uid UUID := auth.uid();
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  RETURN jsonb_build_object('cashEnabled', dh_cash_enabled());
END;
$$;

-- dh_join_room, with the free-hands check removed. Otherwise identical to the
-- version in 0033.
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

-- Admin player list, with free_hands_override dropped.
DROP FUNCTION IF EXISTS dh_admin_players(TEXT);

CREATE FUNCTION dh_admin_players(p_query TEXT DEFAULT '')
RETURNS TABLE (id UUID, display_name TEXT, email TEXT, balance BIGINT, cash_balance BIGINT,
               demo_balance BIGINT, referral_count INT, is_admin BOOLEAN, is_banned BOOLEAN,
               created_at TIMESTAMPTZ)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  PERFORM dh_require_admin();
  RETURN QUERY
    SELECT p.id, p.display_name, u.email::TEXT, p.balance, p.cash_balance,
           p.demo_balance, p.referral_count, p.is_admin, p.is_banned, p.created_at
      FROM profiles p
      JOIN auth.users u ON u.id = p.id
     WHERE COALESCE(p_query, '') = ''
        OR p.display_name ILIKE '%' || p_query || '%'
        OR u.email ILIKE '%' || p_query || '%'
        OR p.id::TEXT = p_query
     ORDER BY p.created_at DESC
     LIMIT 100;
END;
$$;

-- The settings whitelist, with free_hands_per_day dropped.
CREATE OR REPLACE FUNCTION dh_admin_set_setting(p_key TEXT, p_value JSONB)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  PERFORM dh_require_admin();
  IF p_key NOT IN ('seat_gap_ms', 'flip_delay_ms', 'score_hold_ms',
                   'countdown_ms', 'signup_bonus', 'fill_window_ms', 'cash_enabled',
                   'welcome_points', 'welcome_demo_cents', 'demo_goal_cents', 'demo_bonus_cents',
                   'withdraw_goal_cents', 'referral_points', 'referral_goal', 'referral_bonus_cents') THEN
    RAISE EXCEPTION 'Unknown setting.';
  END IF;
  INSERT INTO settings (key, value) VALUES (p_key, p_value)
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
END;
$$;

GRANT EXECUTE ON FUNCTION dh_my_limits()                       TO authenticated;
GRANT EXECUTE ON FUNCTION dh_join_room(BIGINT)                 TO authenticated;
GRANT EXECUTE ON FUNCTION dh_admin_players(TEXT)                TO authenticated;
GRANT EXECUTE ON FUNCTION dh_admin_set_setting(TEXT, JSONB)     TO authenticated;
