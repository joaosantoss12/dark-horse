-- Only one demo table now: $20. Retire the $50 demo table -- same treatment
-- as any other table removal: refund anyone seated (from the balance the
-- table actually plays with, via dh_balance_col), then deactivate.
DO $$
DECLARE
  v_room  rooms%ROWTYPE;
  v_seat  RECORD;
  v_col   TEXT;
  v_bal   BIGINT;
BEGIN
  SELECT * INTO v_room FROM rooms
   WHERE name = '🎬 Demo $50 · 4 seats' AND is_active
   FOR UPDATE;

  IF NOT FOUND THEN RETURN; END IF;

  IF v_room.current_round_id IS NOT NULL THEN
    RAISE EXCEPTION 'Demo $50 table is mid-hand; rerun this migration in a moment.';
  END IF;

  v_col := dh_balance_col(v_room.mode);

  FOR v_seat IN SELECT user_id FROM seats WHERE room_id = v_room.id AND user_id IS NOT NULL LOOP
    EXECUTE format('UPDATE profiles SET %I = %I + $1 WHERE id = $2 RETURNING %I', v_col, v_col, v_col)
      INTO v_bal USING v_room.buy_in, v_seat.user_id;

    IF v_room.buy_in > 0 THEN
      INSERT INTO ledger (user_id, kind, amount, balance_after, note)
      VALUES (v_seat.user_id, 'refund', v_room.buy_in, v_bal, 'Table removed');
    END IF;
  END LOOP;

  DELETE FROM seats WHERE room_id = v_room.id;
  UPDATE rooms SET is_active = FALSE, is_deleted = TRUE WHERE id = v_room.id;
END $$;
