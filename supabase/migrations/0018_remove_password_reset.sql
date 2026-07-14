-- Remove password reset entirely.
--
-- What is going, and why:
--
--   dh_admin_set_password  -- let an admin write any player's password hash, so
--                             an admin could sign in as any player. Dropped, not
--                             merely un-granted: a revoked function can be
--                             re-granted by accident; a dropped one cannot be
--                             called at all.
--   admin_actions          -- existed only to record those resets. With the
--                             resets gone it records nothing.
--   dh_admin_actions       -- read the above.
--
-- Recovery now lives entirely outside the app: a locked-out player messages
-- @DH_Support and whoever holds the Supabase dashboard resets them there. The
-- power stays with the dashboard login rather than with anyone the game happens
-- to call an admin.

DROP FUNCTION IF EXISTS dh_admin_set_password(UUID, TEXT);
DROP FUNCTION IF EXISTS dh_admin_actions();
DROP TABLE IF EXISTS admin_actions;
