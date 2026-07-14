-- Reset every balance to zero, and stop handing out a welcome bonus.
--
-- The ledger has to explain every point that ever existed, so the reset is
-- written to it as an explicit adjustment rather than done behind its back with
-- a bare UPDATE. Anyone auditing a balance later can see exactly where it went.
--
-- CONSEQUENCE, and it is not subtle: the cheapest table costs $20 to sit at, so
-- with every balance at $0 NOBODY CAN PLAY until an admin credits them
-- (Admin -> Players -> +500 or the ± button). New signups start at $0 too, so a
-- player who registers and is never topped up will sit looking at a lobby they
-- cannot enter. Someone has to be watching for signups.

-- 1. Zero every balance, recording it.
INSERT INTO ledger (user_id, kind, amount, balance_after, note)
SELECT id, 'admin_debit', -balance, 0, 'Balance reset'
  FROM profiles
 WHERE balance <> 0;

UPDATE profiles SET balance = 0 WHERE balance <> 0;

-- 2. No welcome bonus. The amount is a setting so it can be turned back on from
--    the admin panel without a migration.
INSERT INTO settings (key, value) VALUES ('signup_bonus', '0'::jsonb)
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;

CREATE OR REPLACE FUNCTION dh_handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_bonus BIGINT := COALESCE(
    (SELECT value::TEXT::BIGINT FROM settings WHERE key = 'signup_bonus'), 0
  );
BEGIN
  INSERT INTO profiles (id, display_name, balance)
  VALUES (
    NEW.id,
    COALESCE(NULLIF(NEW.raw_user_meta_data->>'display_name', ''), split_part(NEW.email, '@', 1)),
    v_bonus
  );

  -- Only write a ledger row if something actually moved.
  IF v_bonus > 0 THEN
    INSERT INTO ledger (user_id, kind, amount, balance_after, note)
    VALUES (NEW.id, 'signup', v_bonus, v_bonus, 'Welcome bonus');
  END IF;

  RETURN NEW;
END;
$$;

-- The same repair function, kept in step: no bonus for a healed profile either.
CREATE OR REPLACE FUNCTION dh_ensure_profile()
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_uid     UUID := auth.uid();
  v_name    TEXT;
  v_bonus   BIGINT := COALESCE(
    (SELECT value::TEXT::BIGINT FROM settings WHERE key = 'signup_bonus'), 0
  );
  v_profile profiles%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;

  SELECT * INTO v_profile FROM profiles WHERE id = v_uid;

  IF NOT FOUND THEN
    SELECT COALESCE(NULLIF(raw_user_meta_data->>'display_name', ''), split_part(email, '@', 1))
      INTO v_name
      FROM auth.users WHERE id = v_uid;

    INSERT INTO profiles (id, display_name, balance)
    VALUES (v_uid, v_name, v_bonus)
    ON CONFLICT (id) DO NOTHING;

    IF v_bonus > 0 THEN
      INSERT INTO ledger (user_id, kind, amount, balance_after, note)
      SELECT v_uid, 'signup', v_bonus, v_bonus, 'Welcome bonus'
      WHERE NOT EXISTS (SELECT 1 FROM ledger WHERE user_id = v_uid AND kind = 'signup');
    END IF;

    SELECT * INTO v_profile FROM profiles WHERE id = v_uid;
  END IF;

  RETURN jsonb_build_object(
    'id', v_profile.id,
    'display_name', v_profile.display_name,
    'avatar_url', v_profile.avatar_url,
    'balance', v_profile.balance,
    'is_admin', v_profile.is_admin,
    'is_banned', v_profile.is_banned
  );
END;
$$;

-- Let the admin panel turn the bonus back on.
CREATE OR REPLACE FUNCTION dh_admin_set_setting(p_key TEXT, p_value JSONB)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  PERFORM dh_require_admin();
  IF p_key NOT IN ('free_hands_per_day', 'seat_gap_ms', 'flip_delay_ms',
                   'score_hold_ms', 'countdown_ms', 'signup_bonus') THEN
    RAISE EXCEPTION 'Unknown setting.';
  END IF;
  INSERT INTO settings (key, value) VALUES (p_key, p_value)
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
END;
$$;

GRANT EXECUTE ON FUNCTION dh_admin_set_setting(TEXT, JSONB) TO authenticated;
