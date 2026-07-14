-- Password reset without email.
--
-- There is no SMTP provider, so the reset link Supabase would send can never
-- arrive. Rather than leave a form that promises an email and delivers nothing,
-- a locked-out player messages support on Telegram and an admin sets a new
-- password for them here.
--
-- This writes to auth.users directly, hashing with bcrypt exactly as Supabase's
-- auth service does, so the new password works on the normal sign-in form.
--
-- WORTH BEING CLEAR ABOUT: this lets an admin set any player's password, which
-- means an admin can sign in as any player. That is real power. It is guarded by
-- dh_require_admin() and every use is written to the ledger-adjacent audit trail
-- below, but it is a trust boundary -- only give admin to people who should have
-- it. If email is added later, prefer the emailed reset link and drop this.

CREATE TABLE IF NOT EXISTS admin_actions (
  id         BIGSERIAL PRIMARY KEY,
  admin_id   UUID NOT NULL REFERENCES profiles(id),
  target_id  UUID REFERENCES profiles(id),
  action     TEXT NOT NULL,
  note       TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE admin_actions ENABLE ROW LEVEL SECURITY;
-- No select policy: readable only through an admin function.

CREATE OR REPLACE FUNCTION dh_admin_set_password(p_user_id UUID, p_password TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, auth, extensions
AS $$
DECLARE
  v_admin UUID := auth.uid();
  v_email TEXT;
BEGIN
  PERFORM dh_require_admin();

  IF length(COALESCE(p_password, '')) < 8 THEN
    RAISE EXCEPTION 'The password must be at least 8 characters.';
  END IF;

  SELECT email INTO v_email FROM auth.users WHERE id = p_user_id;
  IF v_email IS NULL THEN RAISE EXCEPTION 'No such player.'; END IF;

  -- bcrypt, the same hash Supabase's auth service verifies against.
  UPDATE auth.users
     SET encrypted_password = extensions.crypt(p_password, extensions.gen_salt('bf')),
         updated_at = now()
   WHERE id = p_user_id;

  INSERT INTO admin_actions (admin_id, target_id, action, note)
  VALUES (v_admin, p_user_id, 'set_password', 'Reset via support request');

  RETURN jsonb_build_object('ok', TRUE, 'email', v_email);
END;
$$;

GRANT EXECUTE ON FUNCTION dh_admin_set_password(UUID, TEXT) TO authenticated;

-- So an admin can see what other admins have been doing.
CREATE OR REPLACE FUNCTION dh_admin_actions()
RETURNS TABLE (id BIGINT, admin_name TEXT, target_name TEXT, action TEXT, note TEXT,
               created_at TIMESTAMPTZ)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  PERFORM dh_require_admin();
  RETURN QUERY
    SELECT a.id, ap.display_name, tp.display_name, a.action, a.note, a.created_at
      FROM admin_actions a
      JOIN profiles ap ON ap.id = a.admin_id
      LEFT JOIN profiles tp ON tp.id = a.target_id
     ORDER BY a.created_at DESC
     LIMIT 50;
END;
$$;

GRANT EXECUTE ON FUNCTION dh_admin_actions() TO authenticated;
