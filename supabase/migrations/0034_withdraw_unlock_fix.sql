-- Withdraw stayed locked despite a $50+ balance.
--
-- withdraw_unlocked is flipped by dh_check_milestones, which ran after game
-- payouts and demo/referral bonuses -- but NOT after an admin credited cash
-- directly. So a balance topped up from the admin panel never unlocked
-- withdrawals. Two fixes:
--   1. dh_admin_adjust_cash now runs the milestone check after crediting.
--   2. Backfill: unlock anyone already at or above the threshold.

CREATE OR REPLACE FUNCTION dh_admin_adjust_cash(p_user_id UUID, p_cents BIGINT, p_note TEXT)
RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_balance BIGINT;
BEGIN
  PERFORM dh_require_admin();
  IF p_cents = 0 THEN RAISE EXCEPTION 'Enter a non-zero amount.'; END IF;

  UPDATE profiles SET cash_balance = cash_balance + p_cents
   WHERE id = p_user_id AND cash_balance + p_cents >= 0
  RETURNING cash_balance INTO v_balance;

  IF NOT FOUND THEN RAISE EXCEPTION 'That would put the real-money balance below $0.'; END IF;

  INSERT INTO ledger (user_id, kind, amount, balance_after, note)
  VALUES (p_user_id,
          CASE WHEN p_cents > 0 THEN 'cash_credit' ELSE 'cash_debit' END,
          p_cents, v_balance, COALESCE(p_note, 'Real-money adjustment'));

  -- A credit may have crossed the withdrawal threshold.
  PERFORM dh_check_milestones(p_user_id);
  RETURN v_balance;
END;
$$;

-- Backfill: anyone already at or above the goal should be unlocked now.
UPDATE profiles
   SET withdraw_unlocked = TRUE
 WHERE NOT withdraw_unlocked
   AND cash_balance >= dh_setting_int('withdraw_goal_cents', 5000);

GRANT EXECUTE ON FUNCTION dh_admin_adjust_cash(UUID, BIGINT, TEXT) TO authenticated;
