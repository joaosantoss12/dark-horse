-- admin_actions pointed at profiles with no ON DELETE rule, so deleting an
-- account that had ever acted as an admin -- or been the target of one -- failed
-- outright with a foreign key violation. You could not remove an admin at all.
--
-- The audit log has to outlive the accounts it describes: the whole point of it
-- is to answer "who reset that password" after the fact. So the references go
-- soft, and the names are snapshotted at the time of the action.

ALTER TABLE admin_actions ADD COLUMN IF NOT EXISTS admin_name  TEXT;
ALTER TABLE admin_actions ADD COLUMN IF NOT EXISTS target_name TEXT;

-- Backfill what we can before the links can go null.
UPDATE admin_actions a
   SET admin_name = COALESCE(a.admin_name, p.display_name)
  FROM profiles p WHERE p.id = a.admin_id AND a.admin_name IS NULL;

UPDATE admin_actions a
   SET target_name = COALESCE(a.target_name, p.display_name)
  FROM profiles p WHERE p.id = a.target_id AND a.target_name IS NULL;

ALTER TABLE admin_actions ALTER COLUMN admin_id DROP NOT NULL;

ALTER TABLE admin_actions DROP CONSTRAINT IF EXISTS admin_actions_admin_id_fkey;
ALTER TABLE admin_actions
  ADD CONSTRAINT admin_actions_admin_id_fkey
  FOREIGN KEY (admin_id) REFERENCES profiles(id) ON DELETE SET NULL;

ALTER TABLE admin_actions DROP CONSTRAINT IF EXISTS admin_actions_target_id_fkey;
ALTER TABLE admin_actions
  ADD CONSTRAINT admin_actions_target_id_fkey
  FOREIGN KEY (target_id) REFERENCES profiles(id) ON DELETE SET NULL;

-- Record the names as they were, so a deleted account still reads sensibly.
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

  UPDATE auth.users
     SET encrypted_password = extensions.crypt(p_password, extensions.gen_salt('bf')),
         updated_at = now()
   WHERE id = p_user_id;

  INSERT INTO admin_actions (admin_id, target_id, admin_name, target_name, action, note)
  VALUES (
    v_admin,
    p_user_id,
    (SELECT display_name FROM profiles WHERE id = v_admin),
    (SELECT display_name FROM profiles WHERE id = p_user_id),
    'set_password',
    'Reset via support request'
  );

  RETURN jsonb_build_object('ok', TRUE, 'email', v_email);
END;
$$;

CREATE OR REPLACE FUNCTION dh_admin_actions()
RETURNS TABLE (id BIGINT, admin_name TEXT, target_name TEXT, action TEXT, note TEXT,
               created_at TIMESTAMPTZ)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  PERFORM dh_require_admin();
  RETURN QUERY
    SELECT a.id,
           COALESCE(a.admin_name, '(deleted admin)'),
           COALESCE(a.target_name, '(deleted player)'),
           a.action, a.note, a.created_at
      FROM admin_actions a
     ORDER BY a.created_at DESC
     LIMIT 50;
END;
$$;

GRANT EXECUTE ON FUNCTION dh_admin_set_password(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION dh_admin_actions()                TO authenticated;
