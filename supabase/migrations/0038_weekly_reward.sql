-- Replaces the once-a-day points reward with a once-a-week one: 2,000 points,
-- claimable starting Friday 08:00 Portugal time, once per week, only if the
-- player actually visits during that window (still no passive/cron grant).

ALTER TABLE profiles RENAME COLUMN last_daily_claim TO last_weekly_claim;

DELETE FROM settings WHERE key = 'daily_points';
INSERT INTO settings (key, value) VALUES ('weekly_points', '2000'::jsonb)
ON CONFLICT (key) DO NOTHING;

DROP FUNCTION IF EXISTS dh_claim_daily();

CREATE FUNCTION dh_claim_weekly()
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_uid          UUID := auth.uid();
  v_amount       BIGINT := dh_setting_int('weekly_points', 2000);
  -- Portugal's clock, DST included -- 'Europe/Lisbon' already knows when it's
  -- WET (UTC+0) vs WEST (UTC+1), so 08:00 here always means 08:00 on the ground.
  v_now_lisbon   TIMESTAMP := now() AT TIME ZONE 'Europe/Lisbon';
  v_dow          INT := EXTRACT(DOW FROM v_now_lisbon)::INT; -- 0=Sun .. 5=Fri .. 6=Sat
  v_window_date  DATE := v_now_lisbon::DATE - ((v_dow - 5 + 7) % 7);
  v_last         DATE;
  v_bal          BIGINT;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;

  -- If today is Friday but it's not 08:00 yet, this week's window hasn't
  -- opened -- the eligible window is still last week's.
  IF v_window_date = v_now_lisbon::DATE AND v_now_lisbon::TIME < TIME '08:00' THEN
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
  VALUES (v_uid, 'weekly_reward', v_amount, v_bal, 'Weekly reward (Friday, Portugal time)');

  RETURN jsonb_build_object('claimed', true, 'amount', v_amount, 'balance', v_bal);
END;
$$;

GRANT EXECUTE ON FUNCTION dh_claim_weekly() TO authenticated;
