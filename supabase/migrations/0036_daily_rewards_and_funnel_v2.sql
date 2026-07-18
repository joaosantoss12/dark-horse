-- Daily login reward, the new demo->withdraw funnel, demo-only referrals,
-- one-signup-per-device, and admin visibility (active tables, online-adjacent
-- balances, and a "Bank" view of platform profit).
--
-- THE NEW FUNNEL (replaces the old demo-goal-bonus / cash-goal-unlock chain):
--   new user            -> 10,000 points + $20.00 demo
--   demo reaches $100    -> converts entirely to cash_balance, withdrawals unlock (once)
--   every friend invited -> $20.00 demo to the referrer (replaces points + $10-at-10 bonus)
--   every calendar day visited -> 2,000 points (once per UTC day, only if claimed)
--
-- demo_bonus_awarded, demo_goal_cents, demo_bonus_cents, withdraw_goal_cents,
-- referral_points, referral_goal and referral_bonus_cents are retired by this
-- migration but not dropped destructively -- old ledger rows that reference
-- them still read fine.

ALTER TABLE profiles ADD COLUMN IF NOT EXISTS last_daily_claim DATE;

-- ---------------------------------------------------------------------------
-- Settings: new welcome/demo-goal/daily/referral amounts
-- ---------------------------------------------------------------------------
UPDATE settings SET value = '2000'::jsonb WHERE key = 'welcome_demo_cents';

DELETE FROM settings WHERE key IN (
  'demo_goal_cents', 'demo_bonus_cents', 'withdraw_goal_cents',
  'referral_points', 'referral_goal', 'referral_bonus_cents'
);

INSERT INTO settings (key, value) VALUES
  ('demo_withdraw_goal_cents', '10000'::jsonb),  -- demo reaches $100 -> convert + unlock
  ('daily_points',             '2000'::jsonb),   -- per calendar day visited
  ('referral_demo_cents',      '2000'::jsonb)    -- $20 demo per friend
ON CONFLICT (key) DO NOTHING;

-- ---------------------------------------------------------------------------
-- The funnel: demo balance reaching the goal becomes real money
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION dh_check_milestones(p_uid UUID)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_p        profiles%ROWTYPE;
  v_goal     BIGINT := dh_setting_int('demo_withdraw_goal_cents', 10000);
  v_new_cash BIGINT;
BEGIN
  SELECT * INTO v_p FROM profiles WHERE id = p_uid FOR UPDATE;
  IF NOT FOUND THEN RETURN; END IF;

  IF NOT v_p.withdraw_unlocked AND v_p.demo_balance >= v_goal THEN
    UPDATE profiles
       SET cash_balance = cash_balance + v_p.demo_balance,
           demo_balance = 0,
           withdraw_unlocked = TRUE
     WHERE id = p_uid
    RETURNING cash_balance INTO v_new_cash;

    INSERT INTO ledger (user_id, kind, amount, balance_after, note)
    VALUES (p_uid, 'cash_bonus', v_p.demo_balance, v_new_cash,
            'Demo balance reached the withdraw goal -- converted to real money');
  END IF;
END;
$$;

-- Anyone already sitting on $100+ demo under the old rules converts now.
DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN SELECT id FROM profiles WHERE NOT withdraw_unlocked AND demo_balance >= 10000 LOOP
    PERFORM dh_check_milestones(r.id);
  END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- Welcome bonus + referral, rewritten for the new amounts
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION dh_handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_points   BIGINT := dh_setting_int('welcome_points', 10000);
  v_demo     BIGINT := dh_setting_int('welcome_demo_cents', 2000);
  v_ref_code TEXT   := NULLIF(NEW.raw_user_meta_data->>'ref', '');
  v_referrer UUID;
  v_ref_demo BIGINT := dh_setting_int('referral_demo_cents', 2000);
  v_new_demo BIGINT;
BEGIN
  IF v_ref_code IS NOT NULL THEN
    SELECT id INTO v_referrer FROM profiles WHERE referral_code = upper(v_ref_code) AND id <> NEW.id;
  END IF;

  INSERT INTO profiles (id, display_name, balance, demo_balance, referral_code, referred_by)
  VALUES (
    NEW.id,
    COALESCE(NULLIF(NEW.raw_user_meta_data->>'display_name', ''), split_part(NEW.email, '@', 1)),
    v_points, v_demo, dh_new_referral_code(), v_referrer
  );

  IF v_points > 0 THEN
    INSERT INTO ledger (user_id, kind, amount, balance_after, note)
    VALUES (NEW.id, 'signup', v_points, v_points, 'Welcome points');
  END IF;
  IF v_demo > 0 THEN
    INSERT INTO ledger (user_id, kind, amount, balance_after, note)
    VALUES (NEW.id, 'demo_grant', v_demo, v_demo, 'Welcome demo balance');
  END IF;

  -- Reward the referrer: demo balance, straight away, no goal to hit.
  IF v_referrer IS NOT NULL AND v_ref_demo > 0 THEN
    UPDATE profiles
       SET demo_balance = demo_balance + v_ref_demo,
           referral_count = referral_count + 1
     WHERE id = v_referrer
    RETURNING demo_balance INTO v_new_demo;

    INSERT INTO ledger (user_id, kind, amount, balance_after, note)
    VALUES (v_referrer, 'demo_grant', v_ref_demo, v_new_demo,
            'Referral bonus: ' || split_part(NEW.email, '@', 1) || ' joined');

    -- The referral demo credit may itself have crossed the withdraw goal.
    PERFORM dh_check_milestones(v_referrer);
  END IF;

  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION dh_my_referrals()
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_p   profiles%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  SELECT * INTO v_p FROM profiles WHERE id = v_uid;

  RETURN jsonb_build_object(
    'code', v_p.referral_code,
    'count', v_p.referral_count,
    'demoPerFriendCents', dh_setting_int('referral_demo_cents', 2000),
    'totalDemoEarnedCents', v_p.referral_count * dh_setting_int('referral_demo_cents', 2000)
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- Daily login reward: once per UTC calendar day, only if actually claimed
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION dh_claim_daily()
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_uid    UUID := auth.uid();
  v_amount BIGINT := dh_setting_int('daily_points', 2000);
  v_today  DATE := (now() AT TIME ZONE 'UTC')::DATE;
  v_last   DATE;
  v_bal    BIGINT;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;

  SELECT last_daily_claim INTO v_last FROM profiles WHERE id = v_uid FOR UPDATE;
  IF v_last IS NOT NULL AND v_last >= v_today THEN
    RETURN jsonb_build_object('claimed', false, 'amount', 0);
  END IF;

  UPDATE profiles SET balance = balance + v_amount, last_daily_claim = v_today
   WHERE id = v_uid
  RETURNING balance INTO v_bal;

  INSERT INTO ledger (user_id, kind, amount, balance_after, note)
  VALUES (v_uid, 'daily_reward', v_amount, v_bal, 'Daily login reward');

  RETURN jsonb_build_object('claimed', true, 'amount', v_amount, 'balance', v_bal);
END;
$$;

-- ---------------------------------------------------------------------------
-- One signup per device (localStorage/cookie token -- trivially bypassable
-- by clearing storage, which is an accepted trade-off for the simplicity).
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS device_signups (
  device_token TEXT PRIMARY KEY,
  user_id      UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE device_signups ENABLE ROW LEVEL SECURITY;
-- No policies: only the SECURITY DEFINER function below touches this table.

CREATE OR REPLACE FUNCTION dh_register_device(p_token TEXT)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_uid UUID := auth.uid();
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  IF COALESCE(TRIM(p_token), '') = '' THEN RETURN; END IF;

  IF EXISTS (SELECT 1 FROM device_signups WHERE device_token = p_token AND user_id <> v_uid) THEN
    RAISE EXCEPTION 'This device has already been used to create an account. Please sign in instead.';
  END IF;

  INSERT INTO device_signups (device_token, user_id) VALUES (p_token, v_uid)
  ON CONFLICT (device_token) DO NOTHING;
END;
$$;

-- ---------------------------------------------------------------------------
-- Admin: active tables, balances in play, search by user id, and a Bank view
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION dh_admin_stats()
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_stats JSONB;
BEGIN
  PERFORM dh_require_admin();
  SELECT jsonb_build_object(
    'players',      (SELECT COUNT(*) FROM profiles),
    'rounds',       (SELECT COUNT(*) FROM rounds WHERE settled_at IS NOT NULL),
    'wagered',      (SELECT COALESCE(SUM(pot), 0) FROM rounds WHERE settled_at IS NOT NULL),
    'paidOut',      (SELECT COALESCE(SUM(paid_out), 0) FROM rounds WHERE settled_at IS NOT NULL),
    'pointsInPlay', (SELECT COALESCE(SUM(balance), 0) FROM profiles),
    'demoInPlay',   (SELECT COALESCE(SUM(demo_balance), 0) FROM profiles),
    'cashInPlay',   (SELECT COALESCE(SUM(cash_balance), 0) FROM profiles),
    'activeTables', (SELECT COUNT(*) FROM rooms r
                       WHERE r.is_active AND NOT r.is_deleted
                         AND (r.current_round_id IS NOT NULL
                              OR EXISTS (SELECT 1 FROM seats s WHERE s.room_id = r.id)))
  ) INTO v_stats;
  RETURN v_stats;
END;
$$;

CREATE OR REPLACE FUNCTION dh_admin_bank()
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_stats JSONB;
BEGIN
  PERFORM dh_require_admin();
  SELECT jsonb_build_object(
    -- Rake kept from settled real-money hands -- the platform's actual profit.
    'rakeCents',        (SELECT COALESCE(SUM(r.pot - r.paid_out), 0)
                            FROM rounds r JOIN rooms m ON m.id = r.room_id
                           WHERE r.settled_at IS NOT NULL AND m.mode = 'cash'),
    -- Real money currently owed back to players.
    'liabilityCents',   (SELECT COALESCE(SUM(cash_balance), 0) FROM profiles),
    -- Deposits the admin has confirmed and credited.
    'depositsCents',    (SELECT COALESCE(SUM(amount), 0) FROM ledger WHERE kind = 'cash_credit' AND amount > 0),
    -- Withdrawals the admin has paid out.
    'withdrawalsCents', (SELECT COALESCE(SUM(-amount), 0) FROM ledger WHERE kind = 'cash_debit' AND amount < 0),
    -- Demo balances that converted to real money (a cost, once withdrawn).
    'bonusesCents',     (SELECT COALESCE(SUM(amount), 0) FROM ledger WHERE kind = 'cash_bonus')
  ) INTO v_stats;
  RETURN v_stats;
END;
$$;

-- Search now also matches a pasted user id exactly, so a deposit can be
-- credited by id without hunting through name/email.
DROP FUNCTION IF EXISTS dh_admin_players(TEXT);

CREATE FUNCTION dh_admin_players(p_query TEXT DEFAULT '')
RETURNS TABLE (id UUID, display_name TEXT, email TEXT, balance BIGINT, cash_balance BIGINT,
               demo_balance BIGINT, referral_count INT, is_admin BOOLEAN, is_banned BOOLEAN,
               created_at TIMESTAMPTZ)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  PERFORM dh_require_admin();
  RETURN QUERY
    SELECT p.id, p.display_name, u.email::TEXT, p.balance, p.cash_balance,
           p.demo_balance, p.referral_count, p.is_admin, p.is_banned, p.created_at
      FROM profiles p
      JOIN auth.users u ON u.id = p.id
     WHERE COALESCE(p_query, '') = ''
        OR p.display_name ILIKE '%' || p_query || '%'
        OR u.email ILIKE '%' || p_query || '%'
        OR p.id::TEXT = p_query
     ORDER BY p.created_at DESC
     LIMIT 100;
END;
$$;

GRANT EXECUTE ON FUNCTION dh_claim_daily()         TO authenticated;
GRANT EXECUTE ON FUNCTION dh_register_device(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION dh_my_referrals()        TO authenticated;
GRANT EXECUTE ON FUNCTION dh_admin_stats()         TO authenticated;
GRANT EXECUTE ON FUNCTION dh_admin_bank()          TO authenticated;
GRANT EXECUTE ON FUNCTION dh_admin_players(TEXT)   TO authenticated;
