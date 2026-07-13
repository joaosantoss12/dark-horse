-- A slower, more theatrical pace.
--
-- Note on the request "the cards should not be revealed all at once -- first card
-- for everyone, then the second, then the third": that is already exactly how it
-- works, and always has been. Card 1 turns over at every seat, then card 2, then
-- card 3. What was wrong was the speed: 1.6s between cards gives no time to look
-- up and see what everyone else got.
--
-- Old: countdown 3s, a card every 1.6s, 2.0s to read the scores -> deal 6.8s
-- New: countdown 5s, a card every 2.4s, 3.2s to read the scores -> deal 10.4s
--
-- A whole hand now runs 5s + 3 x 10.4s = 37.2s, against 23.4s before.

CREATE OR REPLACE FUNCTION dh_deal_len() RETURNS NUMERIC LANGUAGE sql IMMUTABLE AS $$
  SELECT 10.4::NUMERIC;   -- 3 cards x 2.4s + 3.2s to take in the scores
$$;

CREATE OR REPLACE FUNCTION dh_card_gap() RETURNS NUMERIC LANGUAGE sql IMMUTABLE AS $$
  SELECT 2.4::NUMERIC;    -- between one card turning over and the next
$$;

CREATE OR REPLACE FUNCTION dh_countdown() RETURNS NUMERIC LANGUAGE sql IMMUTABLE AS $$
  SELECT 5::NUMERIC;      -- the shuffle, before the first card
$$;

-- ---------------------------------------------------------------------------
-- dh_deal: use the new countdown
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
  v_len      NUMERIC := dh_deal_len();
  v_deal     INT;
BEGIN
  SELECT * INTO v_room FROM rooms WHERE id = p_room_id FOR UPDATE;
  SELECT COUNT(*) INTO v_taken FROM seats WHERE room_id = p_room_id;

  IF v_room.current_round_id IS NOT NULL OR v_taken <> v_room.seats THEN
    RETURN NULL;
  END IF;

  INSERT INTO rounds (room_id, seats, buy_in, prizes, dealt_at, settle_at, reset_at)
  VALUES (
    p_room_id, v_room.seats, v_room.buy_in, v_room.prizes,
    v_dealt_at,
    v_dealt_at + (3 * v_len) * interval '1 second',
    v_dealt_at + (3 * v_len + 12) * interval '1 second'   -- 12s to read the result
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
-- dh_get_room: the reveal clock now reads the card gap from one place
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION dh_get_room(p_room_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_room     rooms%ROWTYPE;
  v_round    rounds%ROWTYPE;
  v_phase    TEXT;
  v_len      NUMERIC := dh_deal_len();
  v_gap      NUMERIC := dh_card_gap();
  v_elapsed  NUMERIC;
  v_deal     INT := 0;
  v_revealed INT := 0;
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
      v_revealed := LEAST(3, FLOOR((v_elapsed - (v_deal - 1) * v_len) / v_gap)::INT + 1);
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
                             WHEN h.deal_no < v_deal THEN h.cards->(i - 1)
                             WHEN h.deal_no = v_deal AND i <= v_revealed THEN h.cards->(i - 1)
                             ELSE NULL
                           END ORDER BY i)
                         FROM generate_series(1, 3) i
                       ),
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
    'mode', v_room.mode,
    'phase', v_phase,
    'deal', v_deal,
    'revealed', v_revealed,
    'players', v_players,
    'startsInMs', CASE WHEN v_phase = 'countdown'
                       THEN GREATEST(0, EXTRACT(EPOCH FROM v_round.dealt_at - now()) * 1000)::INT END
  );
END;
$$;

GRANT EXECUTE ON FUNCTION dh_get_room(BIGINT) TO authenticated;
