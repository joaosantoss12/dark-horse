-- Referral system.
--
--   every friend who signs up with your code -> 5,000 points to you
--   10 friends -> a $10.00 real bonus (once)
--
-- Each profile gets a short code. A new user who signed up with ?ref=CODE is
-- linked to the referrer, who is rewarded in the signup trigger -- all inside
-- the one transaction that creates the new account, so a referral can never be
-- counted twice or half-applied.

ALTER TABLE profiles ADD COLUMN IF NOT EXISTS referral_code TEXT UNIQUE;
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS referred_by UUID REFERENCES profiles(id) ON DELETE SET NULL;
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS referral_count INT NOT NULL DEFAULT 0;
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS referral_bonus_awarded BOOLEAN NOT NULL DEFAULT FALSE;

INSERT INTO settings (key, value) VALUES
  ('referral_points',       '5000'::jsonb),   -- per friend
  ('referral_goal',         '10'::jsonb),     -- friends for the big bonus
  ('referral_bonus_cents',  '1000'::jsonb)    -- $10
ON CONFLICT (key) DO NOTHING;

-- A short, unambiguous code (no O/0/I/1). Retries on the astronomically unlikely
-- collision.
CREATE OR REPLACE FUNCTION dh_new_referral_code()
RETURNS TEXT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_alphabet TEXT := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_code TEXT;
  v_i INT;
BEGIN
  LOOP
    v_code := '';
    FOR v_i IN 1..6 LOOP
      v_code := v_code || substr(v_alphabet, 1 + floor(random() * length(v_alphabet))::INT, 1);
    END LOOP;
    EXIT WHEN NOT EXISTS (SELECT 1 FROM profiles WHERE referral_code = v_code);
  END LOOP;
  RETURN v_code;
END;
$$;

-- Backfill codes for everyone who predates this.
UPDATE profiles SET referral_code = dh_new_referral_code() WHERE referral_code IS NULL;

-- ---------------------------------------------------------------------------
-- Reward the referrer, inside the new-user trigger
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION dh_handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_points   BIGINT := dh_setting_int('welcome_points', 10000);
  v_demo     BIGINT := dh_setting_int('welcome_demo_cents', 500);
  v_ref_code TEXT   := NULLIF(NEW.raw_user_meta_data->>'ref', '');
  v_referrer UUID;
  v_ref_pts  BIGINT := dh_setting_int('referral_points', 5000);
  v_goal     BIGINT := dh_setting_int('referral_goal', 10);
  v_ref_bonus BIGINT := dh_setting_int('referral_bonus_cents', 1000);
  v_count    INT;
  v_bal      BIGINT;
  v_cash     BIGINT;
BEGIN
  -- Who referred this new user, if anyone (cannot refer yourself).
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

  -- Reward the referrer: points per friend, plus a one-off cash bonus at the goal.
  IF v_referrer IS NOT NULL THEN
    UPDATE profiles
       SET balance = balance + v_ref_pts,
           referral_count = referral_count + 1
     WHERE id = v_referrer
    RETURNING balance, referral_count INTO v_bal, v_count;

    INSERT INTO ledger (user_id, kind, amount, balance_after, note)
    VALUES (v_referrer, 'referral', v_ref_pts, v_bal, 'Friend joined: ' || split_part(NEW.email, '@', 1));

    IF v_count >= v_goal THEN
      UPDATE profiles
         SET cash_balance = cash_balance + v_ref_bonus, referral_bonus_awarded = TRUE
       WHERE id = v_referrer AND NOT referral_bonus_awarded
      RETURNING cash_balance INTO v_cash;

      IF FOUND THEN
        INSERT INTO ledger (user_id, kind, amount, balance_after, note)
        VALUES (v_referrer, 'cash_bonus', v_ref_bonus, v_cash, 'Referral goal reached');
        PERFORM dh_check_milestones(v_referrer);
      END IF;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------------
-- What the player sees
-- ---------------------------------------------------------------------------
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

GRANT EXECUTE ON FUNCTION dh_my_referrals() TO authenticated;
