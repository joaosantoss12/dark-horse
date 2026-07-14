-- The dealer goes round the table, one card at a time.
--
-- Until now every seat's first card turned over at the same instant, then every
-- seat's second, then every seat's third. Now the dealer works round the table
-- the way a real one does:
--
--   card 1 to seat 1, card 1 to seat 2, ... card 1 to the last seat,
--   card 2 to seat 1, card 2 to seat 2, ... card 2 to the last seat,
--   card 3 to seat 1, ...
--
-- and only when the last card has landed are the scores read out.
--
-- So a deal is no longer a fixed length: it is one flip per seat per card, which
-- makes an 8-seat deal twice as long as a 4-seat one. dh_deal_len() therefore
-- takes the seat count.
--
--   4 seats: 12 flips x 0.55s + 3.2s to read the scores = 9.8s a deal, 34s a hand
--   8 seats: 24 flips x 0.55s + 3.2s                    = 16.4s a deal, 54s a hand

CREATE OR REPLACE FUNCTION dh_seat_gap() RETURNS NUMERIC LANGUAGE sql IMMUTABLE AS $$
  SELECT 0.55::NUMERIC;   -- between one card landing and the next
$$;

CREATE OR REPLACE FUNCTION dh_score_hold() RETURNS NUMERIC LANGUAGE sql IMMUTABLE AS $$
  SELECT 3.2::NUMERIC;    -- to take in the scores once the deal is complete
$$;

-- How long one deal takes at a table of this size.
CREATE OR REPLACE FUNCTION dh_deal_len(p_seats INT)
RETURNS NUMERIC LANGUAGE sql IMMUTABLE AS $$
  SELECT (p_seats * 3) * dh_seat_gap() + dh_score_hold();
$$;

-- ---------------------------------------------------------------------------
-- dh_deal: the clock now depends on how many seats there are
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION dh_deal(p_room_id BIGINT)
RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_room     rooms%ROWTYPE;
  v_taken    INT;
  v_round_id BIGINT;
  v_dealt_at TIMESTAMPTZ := now() + (dh_countdown() * interval '1 second');
  v_len      NUMERIC;
  v_deal     INT;
BEGIN
  SELECT * INTO v_room FROM rooms WHERE id = p_room_id FOR UPDATE;
  SELECT COUNT(*) INTO v_taken FROM seats WHERE room_id = p_room_id;

  IF v_room.current_round_id IS NOT NULL OR v_taken <> v_room.seats THEN
    RETURN NULL;
  END IF;

  v_len := dh_deal_len(v_room.seats);

  INSERT INTO rounds (room_id, seats, buy_in, prizes, dealt_at, settle_at, reset_at)
  VALUES (
    p_room_id, v_room.seats, v_room.buy_in, v_room.prizes,
    v_dealt_at,
    v_dealt_at + (3 * v_len) * interval '1 second',
    v_dealt_at + (3 * v_len + 12) * interval '1 second'
  )
  RETURNING id INTO v_round_id;

  FOR v_deal IN 1..3 LOOP
    WITH deck AS (
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
      SELECT p.seat_index, p.user_id, p.bot_name,
             jsonb_agg(d.card ORDER BY d.pos) AS cards
      FROM players p
      JOIN deck d ON d.pos IN (p.n, p.n + v_room.seats, p.n + 2 * v_room.seats)
      GROUP BY p.seat_index, p.user_id, p.bot_name
    )
    INSERT INTO round_hands (round_id, deal_no, seat_index, user_id, bot_name,
                             cards, category, total, score, value, place)
    SELECT v_round_id, v_deal, seat_index, user_id, bot_name,
           cards, dh_category(cards), dh_total(cards), dh_total(cards) % 10,
           dh_deal_value(cards), 0
    FROM dealt;
  END LOOP;

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
-- dh_get_room: a card is face up only once the dealer has reached that seat
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION dh_get_room(p_room_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_room     rooms%ROWTYPE;
  v_round    rounds%ROWTYPE;
  v_phase    TEXT;
  v_len      NUMERIC;
  v_gap      NUMERIC := dh_seat_gap();
  v_elapsed  NUMERIC;
  v_deal     INT := 0;   -- which deal is on the table (1-3)
  v_flips    INT := 0;   -- cards landed so far in THIS deal (0 .. seats * 3)
  v_revealed INT := 0;   -- how many cards every seat now holds (0-3)
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
    v_len := dh_deal_len(v_round.seats);
    v_elapsed := EXTRACT(EPOCH FROM now() - v_round.dealt_at);

    IF v_elapsed < 0 THEN
      v_phase := 'countdown';
    ELSIF now() < v_round.settle_at THEN
      v_phase := 'dealing';
      v_deal := LEAST(3, FLOOR(v_elapsed / v_len)::INT + 1);
      -- One flip every dh_seat_gap() seconds, from the start of this deal.
      v_flips := LEAST(
        v_round.seats * 3,
        FLOOR((v_elapsed - (v_deal - 1) * v_len) / v_gap)::INT
      );
      v_revealed := LEAST(3, v_flips / v_round.seats);
    ELSE
      v_phase := 'results';
      v_deal := 3;
      v_flips := v_round.seats * 3;
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
                             -- An earlier deal is entirely face up.
                             WHEN h.deal_no < v_deal THEN h.cards->(i - 1)
                             -- In this deal, card i at this seat lands on flip
                             -- (i-1)*seats + seat + 1, counting seats in order.
                             WHEN h.deal_no = v_deal
                              AND v_flips >= (i - 1) * v_round.seats + rp.seat_index + 1
                               THEN h.cards->(i - 1)
                             ELSE NULL
                           END ORDER BY i)
                         FROM generate_series(1, 3) i
                       ),
                       -- Scores are read out only once every card has landed.
                       'score', CASE WHEN h.deal_no < v_deal
                                      OR (h.deal_no = v_deal AND v_flips >= v_round.seats * 3)
                                     THEN h.score END,
                       'value', CASE WHEN h.deal_no < v_deal
                                      OR (h.deal_no = v_deal AND v_flips >= v_round.seats * 3)
                                     THEN h.value END,
                       'category', CASE WHEN h.deal_no < v_deal
                                         OR (h.deal_no = v_deal AND v_flips >= v_round.seats * 3)
                                        THEN h.category END
                     ) ORDER BY h.deal_no), '[]'::jsonb)
              FROM round_hands h
              WHERE h.round_id = v_round.id AND h.seat_index = rp.seat_index
            ),
            'totalValue', (
              SELECT COALESCE(SUM(h.value), 0)
              FROM round_hands h
              WHERE h.round_id = v_round.id
                AND h.seat_index = rp.seat_index
                AND (h.deal_no < v_deal
                     OR (h.deal_no = v_deal AND v_flips >= v_round.seats * 3))
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
    'mode', v_room.mode,
    'phase', v_phase,
    'deal', v_deal,
    -- Which seat the dealer is at right now, so the table can point at them.
    'dealingSeat', CASE WHEN v_phase = 'dealing' AND v_flips < v_room.seats * 3
                        THEN v_flips % v_room.seats END,
    'flips', v_flips,
    'revealed', v_revealed,
    'players', v_players,
    'startsInMs', CASE WHEN v_phase = 'countdown'
                       THEN GREATEST(0, EXTRACT(EPOCH FROM v_round.dealt_at - now()) * 1000)::INT END
  );
END;
$$;

-- The old zero-argument version is gone; nothing may call it by accident.
DROP FUNCTION IF EXISTS dh_deal_len();

GRANT EXECUTE ON FUNCTION dh_get_room(BIGINT) TO authenticated;
