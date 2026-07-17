-- History and Top Winners, split by game mode.
--
-- Every history row now carries the mode of the table it was played on, and the
-- leaderboard takes a mode filter, so the client can show Free and Real-money
-- separately. Both work today: free games exist, and the cash side will populate
-- the moment real money is switched on -- no further change needed here.

-- The return shape gains `mode`, so drop before recreating.
DROP FUNCTION IF EXISTS dh_my_history();

CREATE FUNCTION dh_my_history(p_mode TEXT DEFAULT NULL)
RETURNS TABLE (round_id BIGINT, played_at TIMESTAMPTZ, room TEXT, mode TEXT, buy_in BIGINT,
               total_value INT, place INT, won BIGINT, net BIGINT, deals JSONB)
LANGUAGE sql SECURITY DEFINER SET search_path = public
AS $$
  SELECT r.id, r.created_at, m.name, m.mode, r.buy_in, rp.total_value, rp.place, rp.won,
         rp.won - r.buy_in,
         (SELECT jsonb_agg(jsonb_build_object('cards', h.cards, 'score', h.score, 'value', h.value)
                           ORDER BY h.deal_no)
            FROM round_hands h
           WHERE h.round_id = r.id AND h.seat_index = rp.seat_index)
    FROM round_players rp
    JOIN rounds r ON r.id = rp.round_id
    JOIN rooms  m ON m.id = r.room_id
   WHERE rp.user_id = auth.uid()
     AND r.settled_at IS NOT NULL
     AND (p_mode IS NULL OR m.mode = p_mode)
   ORDER BY r.created_at DESC
   LIMIT 25;
$$;

-- The leaderboard gains a mode filter. Signature change, so drop first.
DROP FUNCTION IF EXISTS dh_leaderboard();

CREATE FUNCTION dh_leaderboard(p_mode TEXT DEFAULT NULL)
RETURNS TABLE (display_name TEXT, winnings BIGINT, wins BIGINT)
LANGUAGE sql SECURITY DEFINER SET search_path = public
AS $$
  SELECT p.display_name, SUM(rp.won)::BIGINT, COUNT(*)::BIGINT
    FROM round_players rp
    JOIN rounds r ON r.id = rp.round_id AND r.settled_at IS NOT NULL
    JOIN rooms  m ON m.id = r.room_id
    JOIN profiles p ON p.id = rp.user_id
   WHERE rp.won > 0
     AND (p_mode IS NULL OR m.mode = p_mode)
   GROUP BY p.id, p.display_name
   ORDER BY 2 DESC
   LIMIT 20;
$$;

GRANT EXECUTE ON FUNCTION dh_my_history(TEXT)  TO authenticated;
GRANT EXECUTE ON FUNCTION dh_leaderboard(TEXT) TO authenticated;
