-- 0002 revoked EXECUTE from anon and authenticated, but that is not enough:
-- Postgres grants EXECUTE on every new function to the PUBLIC pseudo-role, and
-- anon/authenticated inherit it from there. dh_deal() was still reachable from
-- the browser. Revoke from PUBLIC, which is what actually closes the door.

REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

-- Re-grant the public API (a REVOKE FROM PUBLIC also takes these away).
GRANT EXECUTE ON FUNCTION dh_get_lobby()                            TO authenticated;
GRANT EXECUTE ON FUNCTION dh_get_room(BIGINT)                       TO authenticated;
GRANT EXECUTE ON FUNCTION dh_join_room(BIGINT)                      TO authenticated;
GRANT EXECUTE ON FUNCTION dh_leave_room(BIGINT)                     TO authenticated;
GRANT EXECUTE ON FUNCTION dh_my_history()                           TO authenticated;
GRANT EXECUTE ON FUNCTION dh_leaderboard()                          TO authenticated;
GRANT EXECUTE ON FUNCTION dh_fill_bots(BIGINT)                      TO authenticated;
GRANT EXECUTE ON FUNCTION dh_admin_save_room(BIGINT, TEXT, INT, BIGINT, BIGINT[], BOOLEAN) TO authenticated;
GRANT EXECUTE ON FUNCTION dh_admin_adjust_balance(UUID, BIGINT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION dh_admin_set_banned(UUID, BOOLEAN)        TO authenticated;
GRANT EXECUTE ON FUNCTION dh_admin_players(TEXT)                    TO authenticated;
GRANT EXECUTE ON FUNCTION dh_admin_stats()                          TO authenticated;

-- The trigger that creates a profile on signup runs as the auth admin, which
-- owns auth.users -- it does not need a grant here.
