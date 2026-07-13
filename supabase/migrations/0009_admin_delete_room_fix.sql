-- Recreate the admin table-delete RPC so the admin panel can remove tables
-- reliably even when an earlier migration was skipped or the function was
-- created with an older definition.

ALTER TABLE rooms ADD COLUMN IF NOT EXISTS is_deleted BOOLEAN NOT NULL DEFAULT FALSE;

CREATE OR REPLACE FUNCTION dh_admin_delete_room(p_room_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_room    rooms%ROWTYPE;
  v_played  INT;
  v_seat    RECORD;
  v_balance BIGINT;
BEGIN
  PERFORM dh_require_admin();
  PERFORM dh_tick();

  SELECT * INTO v_room FROM rooms WHERE id = p_room_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'That table no longer exists.';
  END IF;

  IF v_room.current_round_id IS NOT NULL THEN
    RAISE EXCEPTION 'That table is mid-hand. Try again in a moment.';
  END IF;

  FOR v_seat IN
    SELECT user_id FROM seats WHERE room_id = p_room_id AND user_id IS NOT NULL
  LOOP
    UPDATE profiles
       SET balance = balance + v_room.buy_in
     WHERE id = v_seat.user_id
    RETURNING balance INTO v_balance;

    IF v_room.buy_in > 0 THEN
      INSERT INTO ledger (user_id, kind, amount, balance_after, note)
      VALUES (v_seat.user_id, 'refund', v_room.buy_in, v_balance, 'Table removed');
    END IF;
  END LOOP;

  DELETE FROM seats WHERE room_id = p_room_id;

  SELECT COUNT(*) INTO v_played FROM rounds WHERE room_id = p_room_id;

  IF v_played = 0 THEN
    DELETE FROM rooms WHERE id = p_room_id;
    RETURN jsonb_build_object('deleted', TRUE, 'rounds', 0);
  END IF;

  UPDATE rooms SET is_active = FALSE, is_deleted = TRUE WHERE id = p_room_id;
  RETURN jsonb_build_object('deleted', FALSE, 'rounds', v_played);
END;
$$;

CREATE OR REPLACE FUNCTION dh_admin_rooms()
RETURNS TABLE (id BIGINT, name TEXT, seats INT, buy_in BIGINT, prizes BIGINT[],
               is_active BOOLEAN, sort_order INT, rounds_played BIGINT)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  PERFORM dh_require_admin();
  RETURN QUERY
    SELECT m.id, m.name, m.seats, m.buy_in, m.prizes, m.is_active, m.sort_order,
           (SELECT COUNT(*) FROM rounds r WHERE r.room_id = m.id)
      FROM rooms m
     WHERE NOT m.is_deleted
     ORDER BY m.sort_order, m.id;
END;
$$;

GRANT EXECUTE ON FUNCTION dh_admin_delete_room(BIGINT) TO authenticated;
GRANT EXECUTE ON FUNCTION dh_admin_rooms() TO authenticated;
