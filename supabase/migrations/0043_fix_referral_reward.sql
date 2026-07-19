-- 0040_remove_demo_mode.sql got the referral reward wrong: it kept the shape
-- of the OLD DEMO scheme from 0036 ("$20 demo per friend, straight away") and
-- just swapped demo_balance for cash_balance, still paying $20 real cash per
-- friend. That demo-era shape should have been removed entirely, not carried
-- over in real money.
--
-- The actual referral system:
--   every friend invited  -> 5,000 points to the referrer, immediately
--   10 friends invited    -> a one-time $10 real-cash bonus
-- (This restores 0029_referrals.sql's original design, which 0036 replaced
-- with the demo-only version.)

DELETE FROM settings WHERE key = 'referral_cash_cents';

INSERT INTO settings (key, value) VALUES
  ('referral_points',      '5000'::jsonb),  -- per friend
  ('referral_goal',        '10'::jsonb),    -- friends for the one-time bonus
  ('referral_bonus_cents', '1000'::jsonb)   -- $10, paid once
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;

CREATE OR REPLACE FUNCTION dh_handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_points    BIGINT := dh_setting_int('welcome_points', 6000);
  v_ref_code  TEXT   := NULLIF(NEW.raw_user_meta_data->>'ref', '');
  v_referrer  UUID;
  v_ref_pts   BIGINT := dh_setting_int('referral_points', 5000);
  v_goal      BIGINT := dh_setting_int('referral_goal', 10);
  v_ref_bonus BIGINT := dh_setting_int('referral_bonus_cents', 1000);
  v_bal       BIGINT;
  v_count     INT;
  v_cash      BIGINT;
BEGIN
  IF v_ref_code IS NOT NULL THEN
    SELECT id INTO v_referrer FROM profiles WHERE referral_code = upper(v_ref_code) AND id <> NEW.id;
  END IF;

  INSERT INTO profiles (id, display_name, balance, referral_code, referred_by)
  VALUES (
    NEW.id,
    COALESCE(NULLIF(NEW.raw_user_meta_data->>'display_name', ''), split_part(NEW.email, '@', 1)),
    v_points, dh_new_referral_code(), v_referrer
  );

  IF v_points > 0 THEN
    INSERT INTO ledger (user_id, kind, amount, balance_after, note)
    VALUES (NEW.id, 'signup', v_points, v_points, 'Welcome points');
  END IF;

  -- Reward the referrer: points straight away, per friend.
  IF v_referrer IS NOT NULL AND v_ref_pts > 0 THEN
    UPDATE profiles
       SET balance = balance + v_ref_pts,
           referral_count = referral_count + 1
     WHERE id = v_referrer
    RETURNING balance, referral_count INTO v_bal, v_count;

    INSERT INTO ledger (user_id, kind, amount, balance_after, note)
    VALUES (v_referrer, 'referral_points', v_ref_pts, v_bal,
            'Friend joined: ' || split_part(NEW.email, '@', 1));

    -- Hitting the friend-count goal pays a one-time real-cash bonus.
    IF v_count >= v_goal AND v_ref_bonus > 0 THEN
      UPDATE profiles
         SET cash_balance = cash_balance + v_ref_bonus, referral_bonus_awarded = TRUE
       WHERE id = v_referrer AND NOT referral_bonus_awarded
      RETURNING cash_balance INTO v_cash;

      IF FOUND THEN
        INSERT INTO ledger (user_id, kind, amount, balance_after, note)
        VALUES (v_referrer, 'referral_cash_bonus', v_ref_bonus, v_cash, 'Referral goal reached');
      END IF;
    END IF;
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
    'goal', dh_setting_int('referral_goal', 10),
    'perFriendPoints', dh_setting_int('referral_points', 5000),
    'goalBonusCents', dh_setting_int('referral_bonus_cents', 1000),
    'bonusAwarded', v_p.referral_bonus_awarded
  );
END;
$$;

CREATE OR REPLACE FUNCTION dh_admin_set_setting(p_key TEXT, p_value JSONB)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  PERFORM dh_require_admin();
  IF p_key NOT IN ('seat_gap_ms', 'flip_delay_ms', 'score_hold_ms',
                   'countdown_ms', 'signup_bonus', 'fill_window_ms', 'cash_enabled',
                   'welcome_points', 'weekly_points',
                   'referral_points', 'referral_goal', 'referral_bonus_cents') THEN
    RAISE EXCEPTION 'Unknown setting.';
  END IF;
  INSERT INTO settings (key, value) VALUES (p_key, p_value)
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
END;
$$;

-- Real cash paid out via the referral goal bonus (a cost, not rake).
CREATE OR REPLACE FUNCTION dh_admin_bank()
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_stats JSONB;
BEGIN
  PERFORM dh_require_admin();
  SELECT jsonb_build_object(
    'rakeCents',        (SELECT COALESCE(SUM(r.pot - r.paid_out), 0)
                            FROM rounds r JOIN rooms m ON m.id = r.room_id
                           WHERE r.settled_at IS NOT NULL AND m.mode = 'cash'),
    'liabilityCents',   (SELECT COALESCE(SUM(cash_balance), 0) FROM profiles),
    'depositsCents',    (SELECT COALESCE(SUM(amount), 0) FROM ledger WHERE kind = 'cash_credit' AND amount > 0),
    'withdrawalsCents', (SELECT COALESCE(SUM(-amount), 0) FROM ledger WHERE kind = 'cash_debit' AND amount < 0),
    'bonusesCents',     (SELECT COALESCE(SUM(amount), 0) FROM ledger WHERE kind = 'referral_cash_bonus')
  ) INTO v_stats;
  RETURN v_stats;
END;
$$;

-- One member already got the old (wrong) $20-per-friend real-cash bonus from
-- 0040 before this fix landed. Leave their cash_balance and the ledger row
-- alone -- they were paid in good faith and it is a real, if unintended,
-- credit. Nothing to reverse; this migration only changes behaviour going
-- forward.
