-- Repairs accounts that have no profile row, and makes a missing profile heal
-- itself instead of breaking sign-in.
--
-- How they went missing: migrate.mjs used to replay every migration on each run,
-- and 0001 began with DROP TABLE profiles CASCADE. Applying a later migration
-- therefore wiped the profiles of anyone who had already signed up. Migrations
-- are now recorded and run once, but the damage still needs undoing -- and the
-- app should not be one dropped row away from a dead login screen.

-- 1. Give every auth user without a profile one, with the welcome bonus.
INSERT INTO profiles (id, display_name, balance)
SELECT
  u.id,
  COALESCE(NULLIF(u.raw_user_meta_data->>'display_name', ''), split_part(u.email, '@', 1)),
  1000
FROM auth.users u
LEFT JOIN profiles p ON p.id = u.id
WHERE p.id IS NULL;

-- The ledger must explain every point that exists, including these.
INSERT INTO ledger (user_id, kind, amount, balance_after, note)
SELECT p.id, 'signup', 1000, 1000, 'Welcome bonus (restored)'
FROM profiles p
WHERE NOT EXISTS (
  SELECT 1 FROM ledger l WHERE l.user_id = p.id AND l.kind = 'signup'
);

-- 2. A safety net for the future. If a profile is ever missing when someone
--    signs in -- a failed trigger, a bad restore -- create it on the spot rather
--    than showing them an error they can do nothing about.
CREATE OR REPLACE FUNCTION dh_ensure_profile()
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_uid     UUID := auth.uid();
  v_email   TEXT;
  v_name    TEXT;
  v_profile profiles%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;

  SELECT * INTO v_profile FROM profiles WHERE id = v_uid;

  IF NOT FOUND THEN
    SELECT email, COALESCE(NULLIF(raw_user_meta_data->>'display_name', ''), split_part(email, '@', 1))
      INTO v_email, v_name
      FROM auth.users WHERE id = v_uid;

    INSERT INTO profiles (id, display_name, balance)
    VALUES (v_uid, v_name, 1000)
    ON CONFLICT (id) DO NOTHING;

    INSERT INTO ledger (user_id, kind, amount, balance_after, note)
    SELECT v_uid, 'signup', 1000, 1000, 'Welcome bonus'
    WHERE NOT EXISTS (
      SELECT 1 FROM ledger WHERE user_id = v_uid AND kind = 'signup'
    );

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

GRANT EXECUTE ON FUNCTION dh_ensure_profile() TO authenticated;
