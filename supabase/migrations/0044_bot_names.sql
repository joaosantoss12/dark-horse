-- Bots were named "Bot Ada", "Bot Rex", etc. from a 7-name array -- an
-- instant giveaway when a bot fills a seat next to real players. Give bots
-- gamer-tag-style handles instead ("shadow_wolf42"), drawn from a 500-name
-- pool, so a filled seat reads like any other player.

CREATE OR REPLACE FUNCTION dh_bot_name_pool()
RETURNS TEXT[]
LANGUAGE sql IMMUTABLE
AS $$
  SELECT ARRAY(
    SELECT lower(a) || '_' || lower(n) || ((row_number() OVER (ORDER BY a, n) % 90) + 10)::text
      FROM unnest(ARRAY[
        'Shadow', 'Silent', 'Iron', 'Golden', 'Crimson', 'Frozen', 'Silver', 'Dark',
        'Swift', 'Lone', 'Mighty', 'Wild', 'Lucky', 'Royal', 'Savage', 'Blazing',
        'Midnight', 'Electric', 'Phantom', 'Rogue', 'Brave', 'Fierce', 'Rapid',
        'Cosmic', 'Sneaky'
      ]) AS a
      CROSS JOIN unnest(ARRAY[
        'Wolf', 'Fox', 'Hawk', 'Tiger', 'Dragon', 'Phoenix', 'Falcon', 'Panther',
        'Raven', 'Viper', 'Bear', 'Eagle', 'Lion', 'Shark', 'Cobra', 'Wolverine',
        'Puma', 'Lynx', 'Jaguar', 'Griffin'
      ]) AS n
     ORDER BY a, n
     LIMIT 500
  );
$$;

CREATE OR REPLACE FUNCTION dh_fill_bots(p_room_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_room  rooms%ROWTYPE;
  -- Shuffle the pool once per call so the seats filled in a single hand
  -- never repeat a name.
  v_names TEXT[] := (SELECT ARRAY(SELECT unnest(dh_bot_name_pool()) ORDER BY random()));
  v_seat  INT;
  v_added INT := 0;
BEGIN
  PERFORM dh_require_admin();
  PERFORM dh_tick();

  SELECT * INTO v_room FROM rooms WHERE id = p_room_id FOR UPDATE;
  IF v_room.current_round_id IS NOT NULL THEN
    RAISE EXCEPTION 'The hand has already started.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM seats WHERE room_id = p_room_id AND user_id IS NOT NULL) THEN
    RAISE EXCEPTION 'Take a seat yourself first, then fill the rest with bots.';
  END IF;

  LOOP
    SELECT MIN(i) INTO v_seat
    FROM generate_series(0, v_room.seats - 1) i
    WHERE i NOT IN (SELECT seat_index FROM seats WHERE room_id = p_room_id);
    EXIT WHEN v_seat IS NULL;

    INSERT INTO seats (room_id, seat_index, bot_name)
    VALUES (p_room_id, v_seat, v_names[v_added + 1]);
    v_added := v_added + 1;
  END LOOP;

  IF v_added = 0 THEN RAISE EXCEPTION 'This table is already full.'; END IF;

  PERFORM dh_deal(p_room_id);
  RETURN jsonb_build_object('added', v_added);
END;
$$;
