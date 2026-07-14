-- A table that does not fill in time refunds everyone and clears.
--
-- The clock starts when the FIRST player sits, not when each player sits, so the
-- table has one deadline rather than one per seat. Every join resets nothing:
-- the countdown is about the table filling, not about how long you personally
-- have been waiting.
--
-- On expiry every seated player is refunded (through the ledger, like every
-- other movement) and the seats are cleared.
--
-- A NOTE ON WHAT THIS DOES, because it will be felt before it is understood:
-- with few players online, this ejects and refunds everyone who tries. It does
-- not merely fail to start a hand -- it tells each new player the game is empty
-- and then shows them the door, on a timer. If early players bounce, this is
-- why. The window is a setting so it can be lengthened, and dh_fill_bots exists
-- if you would rather a lone player could start a hand against the house.

ALTER TABLE rooms ADD COLUMN IF NOT EXISTS fill_deadline TIMESTAMPTZ;

INSERT INTO settings (key, value) VALUES ('fill_window_ms', '60000'::jsonb)
ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION dh_fill_window() RETURNS NUMERIC
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT dh_setting_ms('fill_window_ms', 60000);
$$;

-- ---------------------------------------------------------------------------
-- The first player to sit starts the clock
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
    v_cap := dh_free_hands_per_day();
    v_used := dh_free_hands_used(v_uid);
    IF v_used >= v_cap THEN
      RAISE EXCEPTION 'You have played all % free hands for today. They reset at midnight UTC.', v_cap;
    END IF;
  END IF;

  IF v_profile.balance < v_room.buy_in THEN
    IF v_profile.balance = 0 THEN
      RAISE EXCEPTION 'Your balance is $0. Message @DH_Support on Telegram to get topped up.';
    END IF;
    RAISE EXCEPTION 'This table costs $%, and you have $%.', v_room.buy_in, v_profile.balance;
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

  IF v_taken = v_room.seats THEN
    -- Full: the clock is irrelevant now.
    UPDATE rooms SET fill_deadline = NULL WHERE id = p_room_id;
    PERFORM dh_deal(p_room_id);
  ELSIF v_taken = 1 THEN
    -- The first player through the door starts the countdown.
    UPDATE rooms SET fill_deadline = now() + (dh_fill_window() * interval '1 second')
     WHERE id = p_room_id;
  END IF;

  RETURN jsonb_build_object('seat', v_seat, 'balance', v_balance);
END;
$$;

-- Leaving: if the last player goes, stop the clock.
CREATE OR REPLACE FUNCTION dh_leave_room(p_room_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_uid     UUID := auth.uid();
  v_room    rooms%ROWTYPE;
  v_balance BIGINT;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  PERFORM dh_tick();

  SELECT * INTO v_room FROM rooms WHERE id = p_room_id FOR UPDATE;
  IF v_room.current_round_id IS NOT NULL THEN
    RAISE EXCEPTION 'The hand has already started.';
  END IF;

  DELETE FROM seats WHERE room_id = p_room_id AND user_id = v_uid;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', true); END IF;

  UPDATE profiles SET balance = balance + v_room.buy_in
  WHERE id = v_uid
  RETURNING balance INTO v_balance;

  IF v_room.buy_in > 0 THEN
    INSERT INTO ledger (user_id, kind, amount, balance_after, note)
    VALUES (v_uid, 'refund', v_room.buy_in, v_balance, 'Left the table');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM seats WHERE room_id = p_room_id) THEN
    UPDATE rooms SET fill_deadline = NULL WHERE id = p_room_id;
  END IF;

  RETURN jsonb_build_object('ok', true, 'balance', v_balance);
END;
$$;

-- ---------------------------------------------------------------------------
-- The clock: settle finished hands, reset tables, and now expire unfilled ones
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION dh_tick()
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_round   RECORD;
  v_player  RECORD;
  v_room    RECORD;
  v_seat    RECORD;
  v_balance BIGINT;
BEGIN
  -- 1. Pay out any hand whose reveal has finished.
  FOR v_round IN
    SELECT * FROM rounds
    WHERE settled_at IS NULL AND settle_at <= now()
    ORDER BY id
    FOR UPDATE SKIP LOCKED
  LOOP
    FOR v_player IN
      SELECT * FROM round_players
      WHERE round_id = v_round.id AND user_id IS NOT NULL AND won > 0
    LOOP
      UPDATE profiles SET balance = balance + v_player.won
      WHERE id = v_player.user_id
      RETURNING balance INTO v_balance;

      INSERT INTO ledger (user_id, round_id, kind, amount, balance_after, note)
      VALUES (
        v_player.user_id, v_round.id, 'prize', v_player.won, v_balance,
        'Place ' || v_player.place || CASE WHEN v_player.is_split THEN ' (split)' ELSE '' END
      );
    END LOOP;

    UPDATE rounds SET settled_at = now() WHERE id = v_round.id;
  END LOOP;

  -- 2. Clear the table once the result has been on screen long enough.
  FOR v_round IN
    SELECT r.* FROM rounds r
    JOIN rooms m ON m.current_round_id = r.id
    WHERE r.settled_at IS NOT NULL AND r.reset_at <= now()
  LOOP
    DELETE FROM seats WHERE room_id = v_round.room_id;
    UPDATE rooms SET current_round_id = NULL, fill_deadline = NULL WHERE id = v_round.room_id;
  END LOOP;

  -- 3. A table that did not fill in time: refund everyone, clear the seats.
  FOR v_room IN
    SELECT * FROM rooms
    WHERE fill_deadline IS NOT NULL
      AND fill_deadline <= now()
      AND current_round_id IS NULL
    FOR UPDATE SKIP LOCKED
  LOOP
    FOR v_seat IN
      SELECT user_id FROM seats WHERE room_id = v_room.id AND user_id IS NOT NULL
    LOOP
      UPDATE profiles SET balance = balance + v_room.buy_in
      WHERE id = v_seat.user_id
      RETURNING balance INTO v_balance;

      IF v_room.buy_in > 0 THEN
        INSERT INTO ledger (user_id, kind, amount, balance_after, note)
        VALUES (v_seat.user_id, 'refund', v_room.buy_in, v_balance, 'Table did not fill in time');
      END IF;
    END LOOP;

    DELETE FROM seats WHERE room_id = v_room.id;
    UPDATE rooms SET fill_deadline = NULL WHERE id = v_room.id;
  END LOOP;
END;
$$;

GRANT EXECUTE ON FUNCTION dh_join_room(BIGINT)  TO authenticated;
GRANT EXECUTE ON FUNCTION dh_leave_room(BIGINT) TO authenticated;
GRANT EXECUTE ON FUNCTION dh_fill_window()      TO authenticated;

-- ---------------------------------------------------------------------------
-- The client needs to see the clock ticking
-- ---------------------------------------------------------------------------
-- dh_get_room already returns everything else; add how long the table has left
-- to fill. Null when no clock is running (empty table, or a hand in progress).
CREATE OR REPLACE FUNCTION dh_get_lobby()
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_rooms JSONB;
BEGIN
  PERFORM dh_tick();
  SELECT COALESCE(jsonb_agg(
           dh_get_room(id) || jsonb_build_object(
             'mode', mode,
             'fillsInMs', CASE WHEN fill_deadline IS NOT NULL AND current_round_id IS NULL
                               THEN GREATEST(0, EXTRACT(EPOCH FROM fill_deadline - now()) * 1000)::INT END
           )
           ORDER BY mode DESC, sort_order, id), '[]'::jsonb)
    INTO v_rooms
    FROM rooms WHERE is_active AND NOT is_deleted;
  RETURN v_rooms;
END;
$$;

-- And on a single table.
CREATE OR REPLACE FUNCTION dh_room_with_clock(p_room_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_room  rooms%ROWTYPE;
  v_view  JSONB;
BEGIN
  v_view := dh_get_room(p_room_id);
  SELECT * INTO v_room FROM rooms WHERE id = p_room_id;

  RETURN v_view || jsonb_build_object(
    'fillsInMs', CASE WHEN v_room.fill_deadline IS NOT NULL AND v_room.current_round_id IS NULL
                      THEN GREATEST(0, EXTRACT(EPOCH FROM v_room.fill_deadline - now()) * 1000)::INT END
  );
END;
$$;

GRANT EXECUTE ON FUNCTION dh_get_lobby()               TO authenticated;
GRANT EXECUTE ON FUNCTION dh_room_with_clock(BIGINT)   TO authenticated;
