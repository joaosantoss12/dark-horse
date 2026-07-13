-- Postgres grants EXECUTE on every new function to PUBLIC. That made the
-- internals -- dh_deal(), dh_tick() -- callable straight from the browser with
-- the anon key. dh_deal() refuses to deal a table that is not full, so nothing
-- was actually stealable, but a player being able to reach into the dealer's
-- hand at all is the wrong shape. Lock the internals, then hand back EXECUTE on
-- exactly the functions the app is meant to call.

-- 1. Take EXECUTE away from the browser roles on everything in public.
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM anon, authenticated;

-- New functions must not be handed out automatically either.
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM anon, authenticated;

-- 2. Hand back only the public API. Every one of these checks auth.uid() or
--    admin rights for itself; the internals they call in turn still run,
--    because SECURITY DEFINER executes them as the owner.
GRANT EXECUTE ON FUNCTION dh_get_lobby()                            TO authenticated;
GRANT EXECUTE ON FUNCTION dh_get_room(BIGINT)                       TO authenticated;
GRANT EXECUTE ON FUNCTION dh_join_room(BIGINT)                      TO authenticated;
GRANT EXECUTE ON FUNCTION dh_leave_room(BIGINT)                     TO authenticated;
GRANT EXECUTE ON FUNCTION dh_my_history()                           TO authenticated;
GRANT EXECUTE ON FUNCTION dh_leaderboard()                          TO authenticated;

-- Admin-only entry points. These are safe to expose because each one calls
-- dh_require_admin() before it does anything.
GRANT EXECUTE ON FUNCTION dh_fill_bots(BIGINT)                      TO authenticated;
GRANT EXECUTE ON FUNCTION dh_admin_save_room(BIGINT, TEXT, INT, BIGINT, BIGINT[], BOOLEAN) TO authenticated;
GRANT EXECUTE ON FUNCTION dh_admin_adjust_balance(UUID, BIGINT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION dh_admin_set_banned(UUID, BOOLEAN)        TO authenticated;
GRANT EXECUTE ON FUNCTION dh_admin_players(TEXT)                    TO authenticated;
GRANT EXECUTE ON FUNCTION dh_admin_stats()                          TO authenticated;

-- dh_deal(), dh_tick(), dh_require_admin() and the card-maths helpers are
-- deliberately NOT granted: they are the dealer's own hands.
