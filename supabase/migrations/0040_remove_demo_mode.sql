-- Remove demo mode entirely -- it did the same job as free play (risk-free
-- points) with extra bookkeeping. Product decisions for what replaces it:
--   withdraw unlock -> no gate at all; any real cash_balance can be withdrawn.
--   referral reward -> real cash, credited immediately (was demo cents,
--                      funnelled through a $200 goal).
--   welcome bonus    -> points only; the demo portion is dropped, not replaced.

-- ---------------------------------------------------------------------------
-- Retire the one live demo table -- same treatment as any other table
-- removal (0035_remove_demo_50.sql): refund anyone seated, then deactivate.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_room  rooms%ROWTYPE;
  v_seat  RECORD;
  v_bal   BIGINT;
BEGIN
  SELECT * INTO v_room FROM rooms
   WHERE mode = 'demo' AND is_active
   FOR UPDATE;

  IF NOT FOUND THEN RETURN; END IF;

  IF v_room.current_round_id IS NOT NULL THEN
    RAISE EXCEPTION 'A demo table is mid-hand; rerun this migration in a moment.';
  END IF;

  FOR v_seat IN SELECT user_id FROM seats WHERE room_id = v_room.id AND user_id IS NOT NULL LOOP
    UPDATE profiles SET demo_balance = demo_balance + v_room.buy_in WHERE id = v_seat.user_id
    RETURNING demo_balance INTO v_bal;

    IF v_room.buy_in > 0 THEN
      INSERT INTO ledger (user_id, kind, amount, balance_after, note)
      VALUES (v_seat.user_id, 'refund', v_room.buy_in, v_bal, 'Table removed');
    END IF;
  END LOOP;

  DELETE FROM seats WHERE room_id = v_room.id;
  UPDATE rooms SET is_active = FALSE, is_deleted = TRUE WHERE id = v_room.id;
END $$;

-- ---------------------------------------------------------------------------
-- Settings: drop everything demo-only, add the referral cash amount
-- ---------------------------------------------------------------------------
DELETE FROM settings WHERE key IN (
  'welcome_demo_cents', 'demo_withdraw_goal_cents', 'demo_withdraw_payout_cents',
  'referral_demo_cents', 'demo_goal_cents', 'demo_bonus_cents', 'withdraw_goal_cents'
);

INSERT INTO settings (key, value) VALUES
  ('referral_cash_cents', '2000'::jsonb)  -- $20 real cash per friend, paid immediately
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;

-- ---------------------------------------------------------------------------
-- Withdrawals: no gate. Unlock everyone now and flip the default so new
-- profiles start unlocked too.
-- ---------------------------------------------------------------------------
UPDATE profiles SET withdraw_unlocked = TRUE WHERE NOT withdraw_unlocked;
ALTER TABLE profiles ALTER COLUMN withdraw_unlocked SET DEFAULT TRUE;

DROP FUNCTION IF EXISTS dh_check_milestones(UUID);

-- ---------------------------------------------------------------------------
-- Money movement: 'demo' branch out of the mode-aware helpers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION dh_balance_col(p_mode TEXT)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_mode WHEN 'free' THEN 'balance' ELSE 'cash_balance' END;
$$;

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

-- dh_tick, with the funnel-milestone check dropped (nothing left to check).
CREATE OR REPLACE FUNCTION dh_tick()
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_round  RECORD;
  v_player RECORD;
  v_room   RECORD;
  v_seat   RECORD;
  v_bal    BIGINT;
  v_col    TEXT;
  v_mode   TEXT;
BEGIN
  -- 1. Pay out finished hands into the balance that matches the table's mode.
  FOR v_round IN
    SELECT r.*, m.mode AS room_mode FROM rounds r
    JOIN rooms m ON m.id = r.room_id
    WHERE r.settled_at IS NULL AND r.settle_at <= now()
    ORDER BY r.id
    FOR UPDATE OF r SKIP LOCKED
  LOOP
    v_mode := v_round.room_mode;
    v_col := dh_balance_col(v_mode);

    FOR v_player IN
      SELECT * FROM round_players
      WHERE round_id = v_round.id AND user_id IS NOT NULL AND won > 0
    LOOP
      EXECUTE format('UPDATE profiles SET %I = %I + $1 WHERE id = $2 RETURNING %I', v_col, v_col, v_col)
        INTO v_bal USING v_player.won, v_player.user_id;

      INSERT INTO ledger (user_id, round_id, kind, amount, balance_after, note)
      VALUES (v_player.user_id, v_round.id, v_mode || '_prize', v_player.won, v_bal,
              'Place ' || v_player.place || CASE WHEN v_player.is_split THEN ' (split)' ELSE '' END);
    END LOOP;

    UPDATE rounds SET settled_at = now() WHERE id = v_round.id;
  END LOOP;

  -- 2. Clear finished tables.
  FOR v_round IN
    SELECT r.* FROM rounds r JOIN rooms m ON m.current_round_id = r.id
    WHERE r.settled_at IS NOT NULL AND r.reset_at <= now()
  LOOP
    DELETE FROM seats WHERE room_id = v_round.room_id;
    UPDATE rooms SET current_round_id = NULL, fill_deadline = NULL WHERE id = v_round.room_id;
  END LOOP;

  -- 3. Refund tables that never filled.
  FOR v_room IN
    SELECT * FROM rooms
    WHERE fill_deadline IS NOT NULL AND fill_deadline <= now() AND current_round_id IS NULL
    FOR UPDATE SKIP LOCKED
  LOOP
    v_col := dh_balance_col(v_room.mode);
    FOR v_seat IN SELECT user_id FROM seats WHERE room_id = v_room.id AND user_id IS NOT NULL LOOP
      EXECUTE format('UPDATE profiles SET %I = %I + $1 WHERE id = $2 RETURNING %I', v_col, v_col, v_col)
        INTO v_bal USING v_room.buy_in, v_seat.user_id;
      IF v_room.buy_in > 0 THEN
        INSERT INTO ledger (user_id, kind, amount, balance_after, note)
        VALUES (v_seat.user_id, 'refund', v_room.buy_in, v_bal, 'Table did not fill in time');
      END IF;
    END LOOP;
    DELETE FROM seats WHERE room_id = v_room.id;
    UPDATE rooms SET fill_deadline = NULL WHERE id = v_room.id;
  END LOOP;
END;
$$;

-- dh_admin_adjust_cash, with the now-gone milestone check dropped.
CREATE OR REPLACE FUNCTION dh_admin_adjust_cash(p_user_id UUID, p_cents BIGINT, p_note TEXT)
RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_balance BIGINT;
BEGIN
  PERFORM dh_require_admin();
  IF p_cents = 0 THEN RAISE EXCEPTION 'Enter a non-zero amount.'; END IF;

  UPDATE profiles SET cash_balance = cash_balance + p_cents
   WHERE id = p_user_id AND cash_balance + p_cents >= 0
  RETURNING cash_balance INTO v_balance;

  IF NOT FOUND THEN RAISE EXCEPTION 'That would put the real-money balance below $0.'; END IF;

  INSERT INTO ledger (user_id, kind, amount, balance_after, note)
  VALUES (p_user_id,
          CASE WHEN p_cents > 0 THEN 'cash_credit' ELSE 'cash_debit' END,
          p_cents, v_balance, COALESCE(p_note, 'Real-money adjustment'));

  RETURN v_balance;
END;
$$;

DROP FUNCTION IF EXISTS dh_admin_adjust_demo(UUID, BIGINT, TEXT);

-- ---------------------------------------------------------------------------
-- Welcome bonus + referral: points only at signup, real cash per referral
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION dh_handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_points   BIGINT := dh_setting_int('welcome_points', 10000);
  v_ref_code TEXT   := NULLIF(NEW.raw_user_meta_data->>'ref', '');
  v_referrer UUID;
  v_ref_cash BIGINT := dh_setting_int('referral_cash_cents', 2000);
  v_new_cash BIGINT;
BEGIN
  IF v_ref_code IS NOT NULL THEN
    SELECT id INTO v_referrer FROM profiles WHERE referral_code = upper(v_ref_code) AND id <> NEW.id;
  END IF;

  INSERT INTO profiles (id, display_name, balance, referral_code, referred_by)
  VALUES (
    NEW.id,
    COALESCE(NULLIF(NEW.raw_user_meta_data->>'display_name', ''), split_part(NEW.email, '@', 1)),
    v_points, dh_new_referral_code(), v_referrer
  );

  IF v_points > 0 THEN
    INSERT INTO ledger (user_id, kind, amount, balance_after, note)
    VALUES (NEW.id, 'signup', v_points, v_points, 'Welcome points');
  END IF;

  -- Reward the referrer: real cash, straight away.
  IF v_referrer IS NOT NULL AND v_ref_cash > 0 THEN
    UPDATE profiles
       SET cash_balance = cash_balance + v_ref_cash,
           referral_count = referral_count + 1
     WHERE id = v_referrer
    RETURNING cash_balance INTO v_new_cash;

    INSERT INTO ledger (user_id, kind, amount, balance_after, note)
    VALUES (v_referrer, 'referral_bonus', v_ref_cash, v_new_cash,
            'Referral bonus: ' || split_part(NEW.email, '@', 1) || ' joined');
  END IF;

  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION dh_ensure_profile()
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_uid    UUID := auth.uid();
  v_name   TEXT;
  v_points BIGINT := dh_setting_int('welcome_points', 10000);
  v_p      profiles%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  SELECT * INTO v_p FROM profiles WHERE id = v_uid;

  IF NOT FOUND THEN
    SELECT COALESCE(NULLIF(raw_user_meta_data->>'display_name', ''), split_part(email, '@', 1))
      INTO v_name FROM auth.users WHERE id = v_uid;

    INSERT INTO profiles (id, display_name, balance)
    VALUES (v_uid, v_name, v_points)
    ON CONFLICT (id) DO NOTHING;

    IF v_points > 0 THEN
      INSERT INTO ledger (user_id, kind, amount, balance_after, note)
      SELECT v_uid, 'signup', v_points, v_points, 'Welcome points'
      WHERE NOT EXISTS (SELECT 1 FROM ledger WHERE user_id = v_uid AND kind = 'signup');
    END IF;

    SELECT * INTO v_p FROM profiles WHERE id = v_uid;
  END IF;

  RETURN jsonb_build_object(
    'id', v_p.id, 'display_name', v_p.display_name, 'avatar_url', v_p.avatar_url,
    'balance', v_p.balance, 'cash_balance', v_p.cash_balance,
    'withdraw_unlocked', v_p.withdraw_unlocked,
    'is_admin', v_p.is_admin, 'is_banned', v_p.is_banned
  );
END;
$$;

CREATE OR REPLACE FUNCTION dh_my_referrals()
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_p   profiles%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  SELECT * INTO v_p FROM profiles WHERE id = v_uid;

  RETURN jsonb_build_object(
    'code', v_p.referral_code,
    'count', v_p.referral_count,
    'cashPerFriendCents', dh_setting_int('referral_cash_cents', 2000),
    'totalCashEarnedCents', v_p.referral_count * dh_setting_int('referral_cash_cents', 2000)
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- Admin: drop the demo-only adjust RPC, the demo column, and demo stats
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS dh_admin_players(TEXT);

CREATE FUNCTION dh_admin_players(p_query TEXT DEFAULT '')
RETURNS TABLE (id UUID, display_name TEXT, email TEXT, balance BIGINT, cash_balance BIGINT,
               referral_count INT, is_admin BOOLEAN, is_banned BOOLEAN,
               created_at TIMESTAMPTZ)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  PERFORM dh_require_admin();
  RETURN QUERY
    SELECT p.id, p.display_name, u.email::TEXT, p.balance, p.cash_balance,
           p.referral_count, p.is_admin, p.is_banned, p.created_at
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

CREATE OR REPLACE FUNCTION dh_admin_set_setting(p_key TEXT, p_value JSONB)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  PERFORM dh_require_admin();
  IF p_key NOT IN ('seat_gap_ms', 'flip_delay_ms', 'score_hold_ms',
                   'countdown_ms', 'signup_bonus', 'fill_window_ms', 'cash_enabled',
                   'welcome_points', 'weekly_points', 'referral_cash_cents') THEN
    RAISE EXCEPTION 'Unknown setting.';
  END IF;
  INSERT INTO settings (key, value) VALUES (p_key, p_value)
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
END;
$$;

CREATE OR REPLACE FUNCTION dh_admin_stats()
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_stats JSONB;
BEGIN
  PERFORM dh_require_admin();
  SELECT jsonb_build_object(
    'players',      (SELECT COUNT(*) FROM profiles),
    'rounds',       (SELECT COUNT(*) FROM rounds WHERE settled_at IS NOT NULL),
    'wagered',      (SELECT COALESCE(SUM(pot), 0) FROM rounds WHERE settled_at IS NOT NULL),
    'paidOut',      (SELECT COALESCE(SUM(paid_out), 0) FROM rounds WHERE settled_at IS NOT NULL),
    'pointsInPlay', (SELECT COALESCE(SUM(balance), 0) FROM profiles),
    'cashInPlay',   (SELECT COALESCE(SUM(cash_balance), 0) FROM profiles),
    'activeTables', (SELECT COUNT(*) FROM rooms r
                       WHERE r.is_active AND NOT r.is_deleted
                         AND (r.current_round_id IS NOT NULL
                              OR EXISTS (SELECT 1 FROM seats s WHERE s.room_id = r.id)))
  ) INTO v_stats;
  RETURN v_stats;
END;
$$;

CREATE OR REPLACE FUNCTION dh_admin_bank()
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_stats JSONB;
BEGIN
  PERFORM dh_require_admin();
  SELECT jsonb_build_object(
    -- Rake kept from settled real-money hands -- the platform's actual profit.
    'rakeCents',        (SELECT COALESCE(SUM(r.pot - r.paid_out), 0)
                            FROM rounds r JOIN rooms m ON m.id = r.room_id
                           WHERE r.settled_at IS NOT NULL AND m.mode = 'cash'),
    -- Real money currently owed back to players.
    'liabilityCents',   (SELECT COALESCE(SUM(cash_balance), 0) FROM profiles),
    -- Deposits the admin has confirmed and credited.
    'depositsCents',    (SELECT COALESCE(SUM(amount), 0) FROM ledger WHERE kind = 'cash_credit' AND amount > 0),
    -- Withdrawals the admin has paid out.
    'withdrawalsCents', (SELECT COALESCE(SUM(-amount), 0) FROM ledger WHERE kind = 'cash_debit' AND amount < 0),
    -- Real cash paid out via the referral program (a cost, not rake).
    'bonusesCents',     (SELECT COALESCE(SUM(amount), 0) FROM ledger WHERE kind = 'referral_bonus')
  ) INTO v_stats;
  RETURN v_stats;
END;
$$;

GRANT EXECUTE ON FUNCTION dh_admin_players(TEXT) TO authenticated;

-- ---------------------------------------------------------------------------
-- Schema: drop the demo columns and tighten the mode constraint
-- ---------------------------------------------------------------------------
ALTER TABLE profiles DROP COLUMN IF EXISTS demo_balance;
ALTER TABLE profiles DROP COLUMN IF EXISTS demo_bonus_awarded;

-- The retire block above only flips is_active/is_deleted on the live demo
-- room -- it never touches mode. Any demo room, live or already soft-deleted
-- by an earlier migration (e.g. 0035_remove_demo_50.sql), still has
-- mode = 'demo' and would violate the tightened check below.
UPDATE rooms SET mode = 'free' WHERE mode = 'demo';

ALTER TABLE rooms DROP CONSTRAINT IF EXISTS rooms_mode_check;
ALTER TABLE rooms ADD CONSTRAINT rooms_mode_check CHECK (mode IN ('free', 'cash'));
