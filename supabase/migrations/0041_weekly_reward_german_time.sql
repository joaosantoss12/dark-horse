-- Moves the weekly points window from Friday 08:00 Portugal time to Friday
-- 10:00 German time (Europe/Berlin), still DST-aware and still only granted
-- on an actual visit during the window (no passive/cron grant).

CREATE OR REPLACE FUNCTION dh_claim_weekly()
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_uid          UUID := auth.uid();
  v_amount       BIGINT := dh_setting_int('weekly_points', 2000);
  -- Germany's clock, DST included -- 'Europe/Berlin' already knows when it's
  -- CET (UTC+1) vs CEST (UTC+2), so 10:00 here always means 10:00 on the ground.
  v_now_berlin   TIMESTAMP := now() AT TIME ZONE 'Europe/Berlin';
  v_dow          INT := EXTRACT(DOW FROM v_now_berlin)::INT; -- 0=Sun .. 5=Fri .. 6=Sat
  v_window_date  DATE := v_now_berlin::DATE - ((v_dow - 5 + 7) % 7);
  v_last         DATE;
  v_bal          BIGINT;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;

  -- If today is Friday but it's not 10:00 yet, this week's window hasn't
  -- opened -- the eligible window is still last week's.
  IF v_window_date = v_now_berlin::DATE AND v_now_berlin::TIME < TIME '10:00' THEN
    v_window_date := v_window_date - 7;
  END IF;

  SELECT last_weekly_claim INTO v_last FROM profiles WHERE id = v_uid FOR UPDATE;
  IF v_last IS NOT NULL AND v_last >= v_window_date THEN
    RETURN jsonb_build_object('claimed', false, 'amount', 0);
  END IF;

  UPDATE profiles SET balance = balance + v_amount, last_weekly_claim = v_window_date
   WHERE id = v_uid
  RETURNING balance INTO v_bal;

  INSERT INTO ledger (user_id, kind, amount, balance_after, note)
  VALUES (v_uid, 'weekly_reward', v_amount, v_bal, 'Weekly reward (Friday, German time)');

  RETURN jsonb_build_object('claimed', true, 'amount', v_amount, 'balance', v_bal);
END;
$$;

GRANT EXECUTE ON FUNCTION dh_claim_weekly() TO authenticated;
