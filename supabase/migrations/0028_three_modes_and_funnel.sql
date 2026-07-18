-- Three balances, three table modes, the welcome bonus, and the demo->real funnel.
--
-- BALANCES (all already exist except demo):
--   balance       -- free-play points
--   demo_balance  -- demo cash in cents: play the money-style tables risk-free
--   cash_balance  -- real cash in cents: withdrawable, once unlocked
--
-- TABLE MODES (rooms.mode):
--   free  -- buy_in/prizes are POINTS, paid from/to balance
--   demo  -- buy_in/prizes are CENTS, paid from/to demo_balance. Nothing real is
--            at stake, so these are always playable.
--   cash  -- buy_in/prizes are CENTS, paid from/to cash_balance. Gated by
--            dh_cash_enabled(): real money, real regulation.
--
-- THE FUNNEL:
--   new user           -> 10,000 points + $5.00 demo
--   demo reaches $30   -> a real $5.00 bonus lands in cash_balance (once)
--   cash reaches $50   -> withdrawals unlock (once)
--
-- The bonus and the unlock are recorded flags so each fires exactly once, and
-- every movement goes through the ledger so all three balances audit.

-- The mode CHECK allowed only free/cash; add demo.
ALTER TABLE rooms DROP CONSTRAINT IF EXISTS rooms_mode_check;
ALTER TABLE rooms ADD CONSTRAINT rooms_mode_check CHECK (mode IN ('free', 'demo', 'cash'));

ALTER TABLE profiles ADD COLUMN IF NOT EXISTS demo_balance BIGINT NOT NULL DEFAULT 0
  CHECK (demo_balance >= 0);
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS demo_bonus_awarded BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS withdraw_unlocked BOOLEAN NOT NULL DEFAULT FALSE;

-- Funnel thresholds and rewards, as settings so they can be tuned without a deploy.
INSERT INTO settings (key, value) VALUES
  ('welcome_points',      '10000'::jsonb),
  ('welcome_demo_cents',  '500'::jsonb),
  ('demo_goal_cents',     '3000'::jsonb),   -- demo reaches $30...
  ('demo_bonus_cents',    '500'::jsonb),    -- ...earns a real $5
  ('withdraw_goal_cents', '5000'::jsonb)    -- cash reaches $50 -> unlock
ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION dh_setting_int(p_key TEXT, p_default BIGINT)
RETURNS BIGINT LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT COALESCE((SELECT value::TEXT::BIGINT FROM settings WHERE key = p_key), p_default);
$$;

-- ---------------------------------------------------------------------------
-- Welcome bonus: points + demo
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION dh_handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_points BIGINT := dh_setting_int('welcome_points', 10000);
  v_demo   BIGINT := dh_setting_int('welcome_demo_cents', 500);
BEGIN
  INSERT INTO profiles (id, display_name, balance, demo_balance)
  VALUES (
    NEW.id,
    COALESCE(NULLIF(NEW.raw_user_meta_data->>'display_name', ''), split_part(NEW.email, '@', 1)),
    v_points, v_demo
  );

  IF v_points > 0 THEN
    INSERT INTO ledger (user_id, kind, amount, balance_after, note)
    VALUES (NEW.id, 'signup', v_points, v_points, 'Welcome points');
  END IF;
  IF v_demo > 0 THEN
    INSERT INTO ledger (user_id, kind, amount, balance_after, note)
    VALUES (NEW.id, 'demo_grant', v_demo, v_demo, 'Welcome demo balance');
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
  v_demo   BIGINT := dh_setting_int('welcome_demo_cents', 500);
  v_p      profiles%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  SELECT * INTO v_p FROM profiles WHERE id = v_uid;

  IF NOT FOUND THEN
    SELECT COALESCE(NULLIF(raw_user_meta_data->>'display_name', ''), split_part(email, '@', 1))
      INTO v_name FROM auth.users WHERE id = v_uid;

    INSERT INTO profiles (id, display_name, balance, demo_balance)
    VALUES (v_uid, v_name, v_points, v_demo)
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
    'balance', v_p.balance, 'cash_balance', v_p.cash_balance, 'demo_balance', v_p.demo_balance,
    'is_admin', v_p.is_admin, 'is_banned', v_p.is_banned
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- The funnel: check after any demo/cash increase
-- ---------------------------------------------------------------------------
-- Awards the one-off real bonus when demo crosses its goal, and unlocks
-- withdrawal when cash crosses its goal. Both guarded by a flag so they fire
-- once. Safe to call as often as you like.
CREATE OR REPLACE FUNCTION dh_check_milestones(p_uid UUID)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_p          profiles%ROWTYPE;
  v_demo_goal  BIGINT := dh_setting_int('demo_goal_cents', 3000);
  v_bonus      BIGINT := dh_setting_int('demo_bonus_cents', 500);
  v_wd_goal    BIGINT := dh_setting_int('withdraw_goal_cents', 5000);
  v_new_cash   BIGINT;
BEGIN
  SELECT * INTO v_p FROM profiles WHERE id = p_uid FOR UPDATE;
  IF NOT FOUND THEN RETURN; END IF;

  -- Demo goal reached -> one real bonus into cash_balance.
  IF NOT v_p.demo_bonus_awarded AND v_p.demo_balance >= v_demo_goal AND v_bonus > 0 THEN
    UPDATE profiles
       SET cash_balance = cash_balance + v_bonus, demo_bonus_awarded = TRUE
     WHERE id = p_uid
    RETURNING cash_balance INTO v_new_cash;

    INSERT INTO ledger (user_id, kind, amount, balance_after, note)
    VALUES (p_uid, 'cash_bonus', v_bonus, v_new_cash, 'Demo milestone reached');

    v_p.cash_balance := v_new_cash;
  END IF;

  -- Cash goal reached -> withdrawals unlock.
  IF NOT v_p.withdraw_unlocked AND v_p.cash_balance >= v_wd_goal THEN
    UPDATE profiles SET withdraw_unlocked = TRUE WHERE id = p_uid;
  END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- Money movement, now mode-aware
-- ---------------------------------------------------------------------------
-- Which profile column a table's money lives in.
CREATE OR REPLACE FUNCTION dh_balance_col(p_mode TEXT)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_mode WHEN 'free' THEN 'balance'
                     WHEN 'demo' THEN 'demo_balance'
                     ELSE 'cash_balance' END;
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

  -- The daily cap applies to free play only.
  IF v_room.mode = 'free' THEN
    v_cap := dh_free_hands_per_day();
    v_used := dh_free_hands_used(v_uid);
    IF v_used >= v_cap THEN
      RAISE EXCEPTION 'You have played all % free hands for today. They reset at midnight UTC.', v_cap;
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

CREATE OR REPLACE FUNCTION dh_leave_room(p_room_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_uid  UUID := auth.uid();
  v_room rooms%ROWTYPE;
  v_bal  BIGINT;
  v_col  TEXT;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  PERFORM dh_tick();

  SELECT * INTO v_room FROM rooms WHERE id = p_room_id FOR UPDATE;
  IF v_room.current_round_id IS NOT NULL THEN
    RAISE EXCEPTION 'The hand has already started.';
  END IF;

  DELETE FROM seats WHERE room_id = p_room_id AND user_id = v_uid;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', true); END IF;

  v_col := dh_balance_col(v_room.mode);
  EXECUTE format('UPDATE profiles SET %I = %I + $1 WHERE id = $2 RETURNING %I', v_col, v_col, v_col)
    INTO v_bal USING v_room.buy_in, v_uid;

  IF v_room.buy_in > 0 THEN
    INSERT INTO ledger (user_id, kind, amount, balance_after, note)
    VALUES (v_uid, 'refund', v_room.buy_in, v_bal, 'Left the table');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM seats WHERE room_id = p_room_id) THEN
    UPDATE rooms SET fill_deadline = NULL WHERE id = p_room_id;
  END IF;

  RETURN jsonb_build_object('ok', true, 'balance', v_bal);
END;
$$;

-- ---------------------------------------------------------------------------
-- Settling pays into the right balance, and checks the funnel
-- ---------------------------------------------------------------------------
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

      -- A demo or cash win may have crossed a funnel milestone.
      IF v_mode <> 'free' THEN PERFORM dh_check_milestones(v_player.user_id); END IF;
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

GRANT EXECUTE ON FUNCTION dh_setting_int(TEXT, BIGINT)  TO authenticated;
GRANT EXECUTE ON FUNCTION dh_join_room(BIGINT)          TO authenticated;
GRANT EXECUTE ON FUNCTION dh_leave_room(BIGINT)         TO authenticated;

-- ---------------------------------------------------------------------------
-- Tables: one free 4-seat, demo tables (live), real tables (locked)
-- ---------------------------------------------------------------------------
-- Retire everything currently active; rebuild the set cleanly.
UPDATE rooms SET is_active = FALSE WHERE is_active;

-- mode defaults to 'free'; the UPDATEs below set demo/cash.
INSERT INTO rooms (name, seats, buy_in, prizes, sort_order) VALUES
  -- Free play: points.
  ('🎮 Free Play · 4 seats',        4, 1000, ARRAY[2400, 1200]::BIGINT[],       1),
  -- Demo: cents from the demo balance. Live -- nothing real at stake.
  ('🎬 Demo $20 · 4 seats',         4, 2000, ARRAY[3800, 3200]::BIGINT[],       10),
  ('🎬 Demo $50 · 4 seats',         4, 5000, ARRAY[9500, 8000]::BIGINT[],       11),
  -- Real money: cents from cash. Locked behind dh_cash_enabled().
  ('💵 $20 Table · 4 seats',        4, 2000, ARRAY[3800, 3200]::BIGINT[],       20),
  ('💵 $50 Table · 4 seats',        4, 5000, ARRAY[9500, 8000]::BIGINT[],       21);

UPDATE rooms SET mode = 'demo' WHERE name LIKE '🎬 Demo%';
UPDATE rooms SET mode = 'cash' WHERE name LIKE '💵 %';
UPDATE rooms SET mode = 'free' WHERE name LIKE '🎮 %';
