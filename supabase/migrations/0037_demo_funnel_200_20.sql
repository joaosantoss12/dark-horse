-- Raises the demo->withdraw funnel goal and caps the payout, so the demo
-- balance is no longer fully cashed out in one shot:
--   demo reaches $200 -> $20 moves to cash_balance (once), the rest stays
--   demo and keeps playing. Lower platform risk per unlock than the old
--   "convert everything at $100" rule, while still letting players keep
--   growing their demo balance afterwards.

UPDATE settings SET value = '20000'::jsonb WHERE key = 'demo_withdraw_goal_cents';

INSERT INTO settings (key, value) VALUES
  ('demo_withdraw_payout_cents', '2000'::jsonb)  -- $20 converted to cash on unlock
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;

CREATE OR REPLACE FUNCTION dh_check_milestones(p_uid UUID)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_p        profiles%ROWTYPE;
  v_goal     BIGINT := dh_setting_int('demo_withdraw_goal_cents', 20000);
  v_payout   BIGINT := dh_setting_int('demo_withdraw_payout_cents', 2000);
  v_new_cash BIGINT;
BEGIN
  SELECT * INTO v_p FROM profiles WHERE id = p_uid FOR UPDATE;
  IF NOT FOUND THEN RETURN; END IF;

  IF NOT v_p.withdraw_unlocked AND v_p.demo_balance >= v_goal THEN
    UPDATE profiles
       SET cash_balance = cash_balance + v_payout,
           demo_balance = demo_balance - v_payout,
           withdraw_unlocked = TRUE
     WHERE id = p_uid
    RETURNING cash_balance INTO v_new_cash;

    INSERT INTO ledger (user_id, kind, amount, balance_after, note)
    VALUES (p_uid, 'cash_bonus', v_payout, v_new_cash,
            'Demo balance reached the withdraw goal -- $20 converted to real money');
  END IF;
END;
$$;
