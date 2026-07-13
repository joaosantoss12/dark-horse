-- Free Mode and Real Money Mode.
--
-- IMPORTANT, and deliberate: this migration makes the game MODE-AWARE. It does
-- not make real money work, and it must not be made to until the licensing is in
-- place.
--
-- Taking stakes and paying real prizes is regulated gambling almost everywhere.
-- Before a cash table may open, the operator needs a gambling licence for each
-- market served, age verification, KYC/AML checks, a payment processor that
-- knowingly serves licensed gambling (Stripe and PayPal both forbid it
-- otherwise), responsible-gambling controls and segregated player funds.
--
-- So: cash tables can be configured, but dh_join_room refuses to seat anyone at
-- one. The refusal is in the database, not the UI, so it cannot be bypassed by
-- someone poking at the client. When the licence exists, the block is lifted in
-- one place -- see dh_cash_enabled() at the bottom.

-- ---------------------------------------------------------------------------
-- Tables belong to a mode
-- ---------------------------------------------------------------------------
ALTER TABLE rooms ADD COLUMN IF NOT EXISTS mode TEXT NOT NULL DEFAULT 'free';
ALTER TABLE rooms DROP CONSTRAINT IF EXISTS rooms_mode_check;
ALTER TABLE rooms ADD CONSTRAINT rooms_mode_check CHECK (mode IN ('free', 'cash'));

-- Everything that exists today is a free table.
UPDATE rooms SET mode = 'free' WHERE mode IS NULL;

-- ---------------------------------------------------------------------------
-- Player: a separate cash wallet, and whether they have seen the rules
-- ---------------------------------------------------------------------------
-- Cash is held in the smallest currency unit (cents), never as a float: money in
-- a floating point column is how you end up a cent short a thousand times over.
-- It stays 0 until deposits exist.
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS cash_balance BIGINT NOT NULL DEFAULT 0
  CHECK (cash_balance >= 0);
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS rules_accepted_at TIMESTAMPTZ;

-- ---------------------------------------------------------------------------
-- Settings the admin can turn
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS settings (
  key   TEXT PRIMARY KEY,
  value JSONB NOT NULL
);

INSERT INTO settings (key, value) VALUES ('free_hands_per_day', '10'::jsonb)
ON CONFLICT (key) DO NOTHING;

ALTER TABLE settings ENABLE ROW LEVEL SECURITY;
CREATE POLICY settings_read ON settings FOR SELECT TO authenticated USING (true);

CREATE OR REPLACE FUNCTION dh_free_hands_per_day()
RETURNS INT LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT COALESCE((SELECT value::TEXT::INT FROM settings WHERE key = 'free_hands_per_day'), 10);
$$;

-- Is real money open for business? No, and it must stay that way until the
-- operator is licensed. This is the single switch.
CREATE OR REPLACE FUNCTION dh_cash_enabled()
RETURNS BOOLEAN LANGUAGE sql IMMUTABLE AS $$
  SELECT FALSE;
$$;

-- ---------------------------------------------------------------------------
-- The daily free limit
-- ---------------------------------------------------------------------------
-- Counted per account against hands actually dealt, on free tables, since
-- midnight UTC. Leaving a table before the deal does not burn a hand -- you only
-- pay for what you played.
CREATE OR REPLACE FUNCTION dh_free_hands_used(p_user UUID DEFAULT auth.uid())
RETURNS INT
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT COUNT(*)::INT
    FROM round_players rp
    JOIN rounds r ON r.id = rp.round_id
    JOIN rooms  m ON m.id = r.room_id
   WHERE rp.user_id = p_user
     AND m.mode = 'free'
     AND r.created_at >= date_trunc('day', now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC';
$$;

/** What the client shows in the header: used, allowed, and when it resets. */
CREATE OR REPLACE FUNCTION dh_my_limits()
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_uid  UUID := auth.uid();
  v_used INT;
  v_cap  INT := dh_free_hands_per_day();
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  v_used := dh_free_hands_used(v_uid);

  RETURN jsonb_build_object(
    'freeHandsUsed', v_used,
    'freeHandsPerDay', v_cap,
    'freeHandsLeft', GREATEST(0, v_cap - v_used),
    -- Midnight UTC tonight.
    'resetsAt', (date_trunc('day', now() AT TIME ZONE 'UTC') + interval '1 day') AT TIME ZONE 'UTC',
    'cashEnabled', dh_cash_enabled()
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- Joining, now mode-aware
-- ---------------------------------------------------------------------------
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
  v_balance BIGINT;
  v_used    INT;
  v_cap     INT;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'You must be signed in to play.'; END IF;
  PERFORM dh_tick();

  SELECT * INTO v_room FROM rooms WHERE id = p_room_id AND is_active AND NOT is_deleted FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'That table is not open.'; END IF;

  -- Real money is not open. This lives here, in the database, so it cannot be
  -- bypassed from the client.
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

  -- The daily cap on free play.
  IF v_room.mode = 'free' THEN
    v_cap := dh_free_hands_per_day();
    v_used := dh_free_hands_used(v_uid);
    IF v_used >= v_cap THEN
      RAISE EXCEPTION 'You have played all % free hands for today. They reset at midnight UTC.', v_cap;
    END IF;
  END IF;

  IF v_profile.balance < v_room.buy_in THEN
    RAISE EXCEPTION 'Not enough points for this buy-in.';
  END IF;

  SELECT MIN(i) INTO v_seat
  FROM generate_series(0, v_room.seats - 1) i
  WHERE i NOT IN (SELECT seat_index FROM seats WHERE room_id = p_room_id);
  IF v_seat IS NULL THEN RAISE EXCEPTION 'This table is full.'; END IF;

  UPDATE profiles SET balance = balance - v_room.buy_in
  WHERE id = v_uid
  RETURNING balance INTO v_balance;

  INSERT INTO seats (room_id, seat_index, user_id) VALUES (p_room_id, v_seat, v_uid);

  IF v_room.buy_in > 0 THEN
    INSERT INTO ledger (user_id, kind, amount, balance_after, note)
    VALUES (v_uid, 'buy_in', -v_room.buy_in, v_balance, v_room.name);
  END IF;

  SELECT COUNT(*) INTO v_taken FROM seats WHERE room_id = p_room_id;
  IF v_taken = v_room.seats THEN PERFORM dh_deal(p_room_id); END IF;

  RETURN jsonb_build_object('seat', v_seat, 'balance', v_balance);
END;
$$;

-- ---------------------------------------------------------------------------
-- The rules must be seen before playing
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION dh_accept_rules()
RETURNS TIMESTAMPTZ
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_at  TIMESTAMPTZ;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;

  UPDATE profiles SET rules_accepted_at = COALESCE(rules_accepted_at, now())
  WHERE id = v_uid
  RETURNING rules_accepted_at INTO v_at;

  RETURN v_at;
END;
$$;

-- ---------------------------------------------------------------------------
-- The lobby and admin need to know a table's mode
-- ---------------------------------------------------------------------------
-- The row gained a column (mode), and Postgres will not replace a function whose
-- return type changed.
DROP FUNCTION IF EXISTS dh_admin_rooms();

CREATE FUNCTION dh_admin_rooms()
RETURNS TABLE (id BIGINT, name TEXT, seats INT, buy_in BIGINT, prizes BIGINT[],
               is_active BOOLEAN, sort_order INT, mode TEXT, rounds_played BIGINT)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  PERFORM dh_require_admin();
  RETURN QUERY
    SELECT m.id, m.name, m.seats, m.buy_in, m.prizes, m.is_active, m.sort_order, m.mode,
           (SELECT COUNT(*) FROM rounds r WHERE r.room_id = m.id)
      FROM rooms m
     WHERE NOT m.is_deleted
     ORDER BY m.mode, m.sort_order, m.id;
END;
$$;

DROP FUNCTION IF EXISTS dh_admin_save_room(BIGINT, TEXT, INT, BIGINT, BIGINT[], BOOLEAN);

CREATE FUNCTION dh_admin_save_room(
  p_id BIGINT, p_name TEXT, p_seats INT, p_buy_in BIGINT, p_prizes BIGINT[],
  p_is_active BOOLEAN, p_mode TEXT DEFAULT 'free'
)
RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_id       BIGINT;
  v_expected INT;
BEGIN
  PERFORM dh_require_admin();

  IF p_seats NOT IN (4, 8) THEN RAISE EXCEPTION 'A table must have 4 or 8 seats.'; END IF;
  IF COALESCE(TRIM(p_name), '') = '' THEN RAISE EXCEPTION 'The table needs a name.'; END IF;
  IF p_buy_in < 0 THEN RAISE EXCEPTION 'Buy-in must be 0 or more.'; END IF;
  IF p_mode NOT IN ('free', 'cash') THEN RAISE EXCEPTION 'Mode must be free or cash.'; END IF;

  v_expected := CASE WHEN p_seats = 8 THEN 4 ELSE 2 END;
  IF array_length(p_prizes, 1) IS DISTINCT FROM v_expected THEN
    RAISE EXCEPTION 'A %-seat table pays % places, so it needs % prizes.', p_seats, v_expected, v_expected;
  END IF;
  IF EXISTS (SELECT 1 FROM unnest(p_prizes) x WHERE x < 0) THEN
    RAISE EXCEPTION 'Prizes cannot be negative.';
  END IF;

  IF p_id IS NULL THEN
    INSERT INTO rooms (name, seats, buy_in, prizes, is_active, mode, sort_order)
    VALUES (p_name, p_seats, p_buy_in, p_prizes, p_is_active, p_mode,
            COALESCE((SELECT MAX(sort_order) + 1 FROM rooms), 0))
    RETURNING id INTO v_id;
  ELSE
    IF EXISTS (SELECT 1 FROM rooms WHERE id = p_id AND current_round_id IS NOT NULL) THEN
      RAISE EXCEPTION 'That table is mid-hand. Try again in a moment.';
    END IF;
    IF EXISTS (SELECT 1 FROM seats WHERE room_id = p_id) THEN
      RAISE EXCEPTION 'Players are seated at that table. Wait until it is empty.';
    END IF;

    UPDATE rooms
       SET name = p_name, seats = p_seats, buy_in = p_buy_in,
           prizes = p_prizes, is_active = p_is_active, mode = p_mode
     WHERE id = p_id
    RETURNING id INTO v_id;
  END IF;

  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION dh_admin_set_setting(p_key TEXT, p_value JSONB)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  PERFORM dh_require_admin();
  IF p_key <> 'free_hands_per_day' THEN RAISE EXCEPTION 'Unknown setting.'; END IF;
  INSERT INTO settings (key, value) VALUES (p_key, p_value)
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
END;
$$;

-- dh_get_room must report the mode so the lobby can group and label tables.
CREATE OR REPLACE FUNCTION dh_get_lobby()
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_rooms JSONB;
BEGIN
  PERFORM dh_tick();
  SELECT COALESCE(jsonb_agg(dh_get_room(id) || jsonb_build_object('mode', mode)
                            ORDER BY mode DESC, sort_order, id), '[]'::jsonb)
    INTO v_rooms
    FROM rooms WHERE is_active AND NOT is_deleted;
  RETURN v_rooms;
END;
$$;

GRANT EXECUTE ON FUNCTION dh_my_limits()                TO authenticated;
GRANT EXECUTE ON FUNCTION dh_accept_rules()             TO authenticated;
GRANT EXECUTE ON FUNCTION dh_free_hands_used(UUID)      TO authenticated;
GRANT EXECUTE ON FUNCTION dh_admin_rooms()              TO authenticated;
GRANT EXECUTE ON FUNCTION dh_admin_set_setting(TEXT, JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION dh_admin_save_room(BIGINT, TEXT, INT, BIGINT, BIGINT[], BOOLEAN, TEXT)
  TO authenticated;
GRANT EXECUTE ON FUNCTION dh_get_lobby()                TO authenticated;
