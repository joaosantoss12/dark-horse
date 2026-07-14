-- The messages a player sees now that balances are shown in dollars and start at
-- zero. "Not enough points for this buy-in" told a new player nothing about what
-- to do next -- and with the welcome bonus gone, EVERY new player hits it.

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
    -- With no welcome bonus, this is the first thing every new player sees. It
    -- has to say what to do about it.
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
  IF v_taken = v_room.seats THEN PERFORM dh_deal(p_room_id); END IF;

  RETURN jsonb_build_object('seat', v_seat, 'balance', v_balance);
END;
$$;

CREATE OR REPLACE FUNCTION dh_admin_adjust_balance(p_user_id UUID, p_amount BIGINT, p_note TEXT)
RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_balance BIGINT;
BEGIN
  PERFORM dh_require_admin();
  IF p_amount = 0 THEN RAISE EXCEPTION 'Enter a non-zero amount.'; END IF;

  UPDATE profiles SET balance = balance + p_amount
   WHERE id = p_user_id AND balance + p_amount >= 0
  RETURNING balance INTO v_balance;

  IF NOT FOUND THEN RAISE EXCEPTION 'That would put the player below $0.'; END IF;

  INSERT INTO ledger (user_id, kind, amount, balance_after, note)
  VALUES (p_user_id,
          CASE WHEN p_amount > 0 THEN 'admin_credit' ELSE 'admin_debit' END,
          p_amount, v_balance, COALESCE(p_note, 'Admin adjustment'));

  RETURN v_balance;
END;
$$;

GRANT EXECUTE ON FUNCTION dh_join_room(BIGINT)                        TO authenticated;
GRANT EXECUTE ON FUNCTION dh_admin_adjust_balance(UUID, BIGINT, TEXT) TO authenticated;
