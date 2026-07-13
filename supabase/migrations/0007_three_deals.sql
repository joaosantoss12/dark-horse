-- Three deals per hand, instead of one.
--
-- The dealer now deals 3 cards, scores them, deals 3 more, scores again, then a
-- third time -- and only then are the winners decided. A player's total is the
-- sum of their three round values, so a bad round no longer ends you.
--
-- Round value:
--     normal hand      -> its score, 0-9
--     Crown (K+Q+J)    -> 11
--     Three of a Kind  -> 12
-- Specials have to be worth a number now that rounds are added up, and 11/12
-- keeps them strictly better than any possible 9 while preserving the order
-- Three of a Kind > Crown > any score. Max total is 36.
--
-- Each deal gets its own freshly shuffled 52-card deck. It has to: 8 players x 9
-- cards is 72 cards, which does not fit in one deck. So a card can repeat across
-- deals, but never within one.

-- ---------------------------------------------------------------------------
-- Schema
-- ---------------------------------------------------------------------------
ALTER TABLE round_hands ADD COLUMN IF NOT EXISTS deal_no INT NOT NULL DEFAULT 1;
ALTER TABLE round_hands ADD COLUMN IF NOT EXISTS value INT NOT NULL DEFAULT 0;

-- A player now has three rows per round, one per deal.
ALTER TABLE round_hands DROP CONSTRAINT IF EXISTS round_hands_pkey;
ALTER TABLE round_hands ADD PRIMARY KEY (round_id, deal_no, seat_index);

-- place/won/is_split describe the whole round, not a single deal, so they move
-- to their own table.
CREATE TABLE IF NOT EXISTS round_players (
  round_id    BIGINT NOT NULL REFERENCES rounds(id) ON DELETE CASCADE,
  seat_index  INT NOT NULL,
  user_id     UUID REFERENCES profiles(id) ON DELETE SET NULL,
  bot_name    TEXT,
  total_value INT NOT NULL,
  place       INT NOT NULL,
  won         BIGINT NOT NULL DEFAULT 0,
  is_split    BOOLEAN NOT NULL DEFAULT FALSE,
  PRIMARY KEY (round_id, seat_index)
);

CREATE INDEX IF NOT EXISTS round_players_user_idx ON round_players (user_id);

-- ---------------------------------------------------------------------------
-- Timing, all measured from rounds.dealt_at
-- ---------------------------------------------------------------------------
--   deal n starts at dealt_at + (n-1) * 6.8s
--     card 1,2,3 turn over at +0.0s / +1.6s / +3.2s
--     that deal's scores show from +4.8s, and hold until +6.8s
--   settle at dealt_at + 20.4s, table resets 9s later
CREATE OR REPLACE FUNCTION dh_deal_len() RETURNS NUMERIC LANGUAGE sql IMMUTABLE AS $$
  SELECT 6.8::NUMERIC;
$$;

-- What one deal is worth towards the total.
CREATE OR REPLACE FUNCTION dh_deal_value(p_cards JSONB)
RETURNS INT LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE dh_category(p_cards)
    WHEN 2 THEN 12                     -- three of a kind
    WHEN 1 THEN 11                     -- crown
    ELSE dh_total(p_cards) % 10        -- 0-9
  END;
$$;

-- ---------------------------------------------------------------------------
-- Dealing
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION dh_deal(p_room_id BIGINT)
RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_room     rooms%ROWTYPE;
  v_taken    INT;
  v_round_id BIGINT;
  v_dealt_at TIMESTAMPTZ := now() + interval '3 seconds';   -- the countdown
  v_len      NUMERIC := dh_deal_len();
  v_deal     INT;
BEGIN
  SELECT * INTO v_room FROM rooms WHERE id = p_room_id FOR UPDATE;
  SELECT COUNT(*) INTO v_taken FROM seats WHERE room_id = p_room_id;

  IF v_room.current_round_id IS NOT NULL OR v_taken <> v_room.seats THEN
    RETURN NULL;  -- not full, or already dealing
  END IF;

  INSERT INTO rounds (room_id, seats, buy_in, prizes, dealt_at, settle_at, reset_at)
  VALUES (
    p_room_id, v_room.seats, v_room.buy_in, v_room.prizes,
    v_dealt_at,
    v_dealt_at + (3 * v_len) * interval '1 second',
    v_dealt_at + (3 * v_len + 9) * interval '1 second'
  )
  RETURNING id INTO v_round_id;

  -- All three deals are worked out now and hidden until their moment arrives.
  -- Nothing is computed later, so a player closing the tab cannot stall the hand.
  FOR v_deal IN 1..3 LOOP
    WITH deck AS (
      -- A fresh shuffle per deal. gen_random_uuid() is CSPRNG-backed, unlike
      -- random(), so the deck cannot be predicted from earlier deals.
      SELECT jsonb_build_object('r', r, 's', s) AS card,
             row_number() OVER (ORDER BY gen_random_uuid()) AS pos
      FROM generate_series(1, 13) r
      CROSS JOIN unnest(ARRAY['S', 'H', 'D', 'C']) s
    ),
    players AS (
      SELECT seat_index, user_id, bot_name,
             row_number() OVER (ORDER BY seat_index) AS n
      FROM seats WHERE room_id = p_room_id
    ),
    dealt AS (
      -- One card at a time around the table, like a real dealer.
      SELECT p.seat_index, p.user_id, p.bot_name,
             jsonb_agg(d.card ORDER BY d.pos) AS cards
      FROM players p
      JOIN deck d ON d.pos IN (p.n, p.n + v_room.seats, p.n + 2 * v_room.seats)
      GROUP BY p.seat_index, p.user_id, p.bot_name
    )
    INSERT INTO round_hands (round_id, deal_no, seat_index, user_id, bot_name,
                             cards, category, total, score, value, place)
    SELECT v_round_id, v_deal, seat_index, user_id, bot_name,
           cards,
           dh_category(cards),
           dh_total(cards),
           dh_total(cards) % 10,
           dh_deal_value(cards),
           0                                  -- per-deal placing is meaningless now
    FROM dealt;
  END LOOP;

  -- Rank on the total of the three deals. Ties break on the strongest single
  -- deal, then the next, then the next -- so a player who got there with a
  -- Crown beats one who got there with three mediocre hands.
  WITH totals AS (
    SELECT h.seat_index,
           MAX(h.user_id::TEXT) AS user_id,
           MAX(h.bot_name)      AS bot_name,
           SUM(h.value)::INT    AS total_value,
           array_agg(dh_sort_key(h.cards) ORDER BY dh_sort_key(h.cards) DESC) AS tie_key
    FROM round_hands h
    WHERE h.round_id = v_round_id
    GROUP BY h.seat_index
  ),
  ranked AS (
    SELECT *, rank() OVER (ORDER BY total_value DESC, tie_key DESC) AS place
    FROM totals
  ),
  -- A tie group takes every prize slot it spans and divides the sum equally.
  tie_groups AS (
    SELECT place, COUNT(*)::INT AS members FROM ranked GROUP BY place
  ),
  groups AS (
    SELECT g.place, g.members,
           COALESCE((
             SELECT SUM(COALESCE(v_room.prizes[slot], 0))
             FROM generate_series(g.place::INT, g.place::INT + g.members - 1) slot
           ), 0) AS pool
    FROM tie_groups g
  )
  INSERT INTO round_players (round_id, seat_index, user_id, bot_name, total_value, place, won, is_split)
  SELECT v_round_id, r.seat_index, r.user_id::UUID, r.bot_name, r.total_value, r.place,
         -- Points are whole, so a pool that does not divide evenly rounds each
         -- share down; the remainder is not paid rather than invented.
         -- Bots pay nothing in and take nothing out.
         CASE WHEN r.bot_name IS NOT NULL THEN 0 ELSE floor(g.pool / g.members)::BIGINT END,
         g.members > 1 AND g.pool > 0
  FROM ranked r
  JOIN groups g ON g.place = r.place;

  UPDATE rounds SET
    pot = v_room.buy_in * (SELECT COUNT(*) FROM seats WHERE room_id = p_room_id AND user_id IS NOT NULL),
    paid_out = (SELECT COALESCE(SUM(won), 0) FROM round_players WHERE round_id = v_round_id)
  WHERE id = v_round_id;

  UPDATE rooms SET current_round_id = v_round_id WHERE id = p_room_id;

  RETURN v_round_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- Settling now reads round_players
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION dh_tick()
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_round   RECORD;
  v_player  RECORD;
  v_balance BIGINT;
BEGIN
  FOR v_round IN
    SELECT * FROM rounds
    WHERE settled_at IS NULL AND settle_at <= now()
    ORDER BY id
    FOR UPDATE SKIP LOCKED
  LOOP
    FOR v_player IN
      SELECT * FROM round_players
      WHERE round_id = v_round.id AND user_id IS NOT NULL AND won > 0
    LOOP
      UPDATE profiles SET balance = balance + v_player.won
      WHERE id = v_player.user_id
      RETURNING balance INTO v_balance;

      INSERT INTO ledger (user_id, round_id, kind, amount, balance_after, note)
      VALUES (
        v_player.user_id, v_round.id, 'prize', v_player.won, v_balance,
        'Place ' || v_player.place || CASE WHEN v_player.is_split THEN ' (split)' ELSE '' END
      );
    END LOOP;

    UPDATE rounds SET settled_at = now() WHERE id = v_round.id;
  END LOOP;

  FOR v_round IN
    SELECT r.* FROM rounds r
    JOIN rooms m ON m.current_round_id = r.id
    WHERE r.settled_at IS NOT NULL AND r.reset_at <= now()
  LOOP
    DELETE FROM seats WHERE room_id = v_round.room_id;
    UPDATE rooms SET current_round_id = NULL WHERE id = v_round.room_id;
  END LOOP;
END;
$$;

-- ---------------------------------------------------------------------------
-- Reading the table
-- ---------------------------------------------------------------------------
-- Still the only place cards are exposed. A card the dealer has not turned over
-- yet -- in this deal or any later one -- comes back as null.
CREATE OR REPLACE FUNCTION dh_get_room(p_room_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_room     rooms%ROWTYPE;
  v_round    rounds%ROWTYPE;
  v_phase    TEXT;
  v_len      NUMERIC := dh_deal_len();
  v_elapsed  NUMERIC;
  v_deal     INT := 0;     -- which deal is on the table (1-3)
  v_revealed INT := 0;     -- cards turned over in that deal (0-3)
  v_players  JSONB;
BEGIN
  PERFORM dh_tick();

  SELECT * INTO v_room FROM rooms WHERE id = p_room_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'That table no longer exists.'; END IF;

  IF v_room.current_round_id IS NULL THEN
    v_phase := 'waiting';

    SELECT COALESCE(jsonb_agg(jsonb_build_object(
             'seat', s.seat_index,
             'userId', s.user_id,
             'name', COALESCE(p.display_name, s.bot_name),
             'avatarUrl', p.avatar_url,
             'isBot', s.bot_name IS NOT NULL,
             'deals', '[]'::jsonb,
             'totalValue', NULL
           ) ORDER BY s.seat_index), '[]'::jsonb)
      INTO v_players
      FROM seats s
      LEFT JOIN profiles p ON p.id = s.user_id
     WHERE s.room_id = p_room_id;
  ELSE
    SELECT * INTO v_round FROM rounds WHERE id = v_room.current_round_id;
    v_elapsed := EXTRACT(EPOCH FROM now() - v_round.dealt_at);

    IF v_elapsed < 0 THEN
      v_phase := 'countdown';
    ELSIF now() < v_round.settle_at THEN
      v_phase := 'dealing';
      v_deal := LEAST(3, FLOOR(v_elapsed / v_len)::INT + 1);
      -- Where we are inside the current deal: a card every 1.6s.
      v_revealed := LEAST(3, FLOOR((v_elapsed - (v_deal - 1) * v_len) / 1.6)::INT + 1);
    ELSE
      v_phase := 'results';
      v_deal := 3;
      v_revealed := 3;
    END IF;

    SELECT COALESCE(jsonb_agg(player ORDER BY seat_index), '[]'::jsonb)
      INTO v_players
      FROM (
        SELECT
          rp.seat_index,
          jsonb_build_object(
            'seat', rp.seat_index,
            'userId', rp.user_id,
            'name', COALESCE(p.display_name, rp.bot_name),
            'avatarUrl', p.avatar_url,
            'isBot', rp.bot_name IS NOT NULL,
            'deals', (
              SELECT COALESCE(jsonb_agg(jsonb_build_object(
                       'dealNo', h.deal_no,
                       'cards', (
                         SELECT jsonb_agg(
                           CASE
                             -- An earlier deal is fully face up.
                             WHEN h.deal_no < v_deal THEN h.cards->(i - 1)
                             -- The current deal turns over one card at a time.
                             WHEN h.deal_no = v_deal AND i <= v_revealed THEN h.cards->(i - 1)
                             ELSE NULL
                           END ORDER BY i)
                         FROM generate_series(1, 3) i
                       ),
                       -- A deal's score only appears once its third card is up.
                       'score', CASE WHEN h.deal_no < v_deal
                                      OR (h.deal_no = v_deal AND v_revealed >= 3)
                                     THEN h.score END,
                       'value', CASE WHEN h.deal_no < v_deal
                                      OR (h.deal_no = v_deal AND v_revealed >= 3)
                                     THEN h.value END,
                       'category', CASE WHEN h.deal_no < v_deal
                                         OR (h.deal_no = v_deal AND v_revealed >= 3)
                                        THEN h.category END
                     ) ORDER BY h.deal_no), '[]'::jsonb)
              FROM round_hands h
              WHERE h.round_id = v_round.id AND h.seat_index = rp.seat_index
            ),
            -- The running total: only the deals that have finished scoring.
            'totalValue', (
              SELECT COALESCE(SUM(h.value), 0)
              FROM round_hands h
              WHERE h.round_id = v_round.id
                AND h.seat_index = rp.seat_index
                AND (h.deal_no < v_deal OR (h.deal_no = v_deal AND v_revealed >= 3))
            ),
            'place',   CASE WHEN v_phase = 'results' THEN rp.place END,
            'won',     CASE WHEN v_phase = 'results' THEN rp.won END,
            'isSplit', CASE WHEN v_phase = 'results' THEN rp.is_split END
          ) AS player
        FROM round_players rp
        LEFT JOIN profiles p ON p.id = rp.user_id
        WHERE rp.round_id = v_round.id
      ) rows;
  END IF;

  RETURN jsonb_build_object(
    'id', v_room.id,
    'name', v_room.name,
    'seats', v_room.seats,
    'buyIn', v_room.buy_in,
    'prizes', v_room.prizes,
    'phase', v_phase,
    'deal', v_deal,
    'revealed', v_revealed,
    'players', v_players,
    'startsInMs', CASE WHEN v_phase = 'countdown'
                       THEN GREATEST(0, EXTRACT(EPOCH FROM v_round.dealt_at - now()) * 1000)::INT END
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- History and stats now read round_players
-- ---------------------------------------------------------------------------
-- The shape of what history returns has changed (a hand is three deals now), and
-- Postgres will not replace a function whose return type differs.
DROP FUNCTION IF EXISTS dh_my_history();

CREATE FUNCTION dh_my_history()
RETURNS TABLE (round_id BIGINT, played_at TIMESTAMPTZ, room TEXT, buy_in BIGINT,
               total_value INT, place INT, won BIGINT, net BIGINT, deals JSONB)
LANGUAGE sql SECURITY DEFINER SET search_path = public
AS $$
  SELECT r.id, r.created_at, m.name, r.buy_in, rp.total_value, rp.place, rp.won,
         rp.won - r.buy_in,
         (SELECT jsonb_agg(jsonb_build_object('cards', h.cards, 'score', h.score, 'value', h.value)
                           ORDER BY h.deal_no)
            FROM round_hands h
           WHERE h.round_id = r.id AND h.seat_index = rp.seat_index)
    FROM round_players rp
    JOIN rounds r ON r.id = rp.round_id
    JOIN rooms  m ON m.id = r.room_id
   WHERE rp.user_id = auth.uid() AND r.settled_at IS NOT NULL
   ORDER BY r.created_at DESC
   LIMIT 25;
$$;

CREATE OR REPLACE FUNCTION dh_leaderboard()
RETURNS TABLE (display_name TEXT, winnings BIGINT, wins BIGINT)
LANGUAGE sql SECURITY DEFINER SET search_path = public
AS $$
  SELECT p.display_name, SUM(rp.won)::BIGINT, COUNT(*)::BIGINT
    FROM round_players rp
    JOIN rounds r ON r.id = rp.round_id AND r.settled_at IS NOT NULL
    JOIN profiles p ON p.id = rp.user_id
   WHERE rp.won > 0
   GROUP BY p.id, p.display_name
   ORDER BY 2 DESC
   LIMIT 20;
$$;

CREATE OR REPLACE FUNCTION dh_my_stats()
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_uid   UUID := auth.uid();
  v_stats JSONB;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;

  SELECT jsonb_build_object(
    'handsPlayed', COUNT(*),
    'handsWon',    COUNT(*) FILTER (WHERE rp.won > 0),
    'firstPlaces', COUNT(*) FILTER (WHERE rp.place = 1),
    'wagered',     COALESCE(SUM(r.buy_in), 0),
    'won',         COALESCE(SUM(rp.won), 0),
    'net',         COALESCE(SUM(rp.won - r.buy_in), 0),
    'bestScore',   COALESCE(MAX(rp.total_value), 0),
    'specials',    (
      SELECT COUNT(*) FROM round_hands h
       WHERE h.user_id = v_uid AND h.category > 0
    ),
    'bestHand',    (
      SELECT jsonb_build_object('cards', h.cards, 'score', h.score, 'category', h.category)
        FROM round_hands h
        JOIN rounds r2 ON r2.id = h.round_id AND r2.settled_at IS NOT NULL
       WHERE h.user_id = v_uid
       ORDER BY h.category DESC, h.score DESC
       LIMIT 1
    )
  )
  INTO v_stats
  FROM round_players rp
  JOIN rounds r ON r.id = rp.round_id AND r.settled_at IS NOT NULL
  WHERE rp.user_id = v_uid;

  RETURN v_stats;
END;
$$;

-- round_players holds placings and prizes: no read policy, same as round_hands.
ALTER TABLE round_players ENABLE ROW LEVEL SECURITY;

GRANT EXECUTE ON FUNCTION dh_get_room(BIGINT)   TO authenticated;
GRANT EXECUTE ON FUNCTION dh_my_history()       TO authenticated;
GRANT EXECUTE ON FUNCTION dh_leaderboard()      TO authenticated;
GRANT EXECUTE ON FUNCTION dh_my_stats()         TO authenticated;

-- ---------------------------------------------------------------------------
-- The stakes ladder: 20 / 50 / 100 / 500, each as a 4-seat and an 8-seat table
-- ---------------------------------------------------------------------------
-- Prizes pay out 90% of the pot; the house keeps 10%.
--   4 seats: 1st 60% of pot, 2nd 30%
--   8 seats: 1st 40%, 2nd 23.75%, 3rd 15%, 4th 11.25%
UPDATE rooms SET is_active = FALSE WHERE name IN ('Paddock', 'Grandstand');

INSERT INTO rooms (name, seats, buy_in, prizes, sort_order)
SELECT * FROM (VALUES
  ('20 · 4 seats',   4, 20::BIGINT,  ARRAY[48, 24]::BIGINT[],              1),
  ('20 · 8 seats',   8, 20::BIGINT,  ARRAY[64, 38, 24, 18]::BIGINT[],      2),
  ('50 · 4 seats',   4, 50::BIGINT,  ARRAY[120, 60]::BIGINT[],             3),
  ('50 · 8 seats',   8, 50::BIGINT,  ARRAY[160, 95, 60, 45]::BIGINT[],     4),
  ('100 · 4 seats',  4, 100::BIGINT, ARRAY[240, 120]::BIGINT[],            5),
  ('100 · 8 seats',  8, 100::BIGINT, ARRAY[320, 190, 120, 90]::BIGINT[],   6),
  ('500 · 4 seats',  4, 500::BIGINT, ARRAY[1200, 600]::BIGINT[],           7),
  ('500 · 8 seats',  8, 500::BIGINT, ARRAY[1600, 950, 600, 450]::BIGINT[], 8)
) AS t(name, seats, buy_in, prizes, sort_order)
WHERE NOT EXISTS (SELECT 1 FROM rooms WHERE rooms.name = t.name);
