-- Deal like a real table: place the card, let it sit, then turn it.
--
-- Before, a card appeared and flipped in the same instant, every 0.55s. Nobody
-- could follow it. Now each card has two moments:
--
--   1. the dealer LAYS it down in front of the player, face down
--   2. a beat later it TURNS OVER, and only then can anyone read it
--
-- and only after that does the dealer move to the next player. So one card is
-- 1.8s of table time, of which the first 0.9s is the card sitting face down.
--
-- The two numbers live in `settings` rather than in code, so the pace can be
-- tuned from the admin panel without a migration or a deploy.
--
-- What this costs in time, at the default pace:
--   4 seats: 12 cards x 1.8s + 4s to read the scores = 25.6s a deal, ~83s a hand
--   8 seats: 24 cards x 1.8s + 4s                    = 47.2s a deal, ~148s a hand
--
-- An 8-seat hand is now around two and a half minutes. That is the price of
-- dealing 72 cards one at a time and letting people look at them; it cannot be
-- both unhurried and quick. Turn seat_gap_ms down if it drags.

INSERT INTO settings (key, value) VALUES
  ('seat_gap_ms',   '1800'::jsonb),   -- one card: laid down, turned over, next player
  ('flip_delay_ms', '900'::jsonb),    -- how long it sits face down before it turns
  ('score_hold_ms', '4000'::jsonb),   -- to read the scores once the deal is complete
  ('countdown_ms',  '6000'::jsonb)    -- the shuffle
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;

CREATE OR REPLACE FUNCTION dh_setting_ms(p_key TEXT, p_default INT)
RETURNS NUMERIC LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT COALESCE((SELECT value::TEXT::INT FROM settings WHERE key = p_key), p_default) / 1000.0;
$$;

CREATE OR REPLACE FUNCTION dh_seat_gap()   RETURNS NUMERIC LANGUAGE sql STABLE AS $$
  SELECT dh_setting_ms('seat_gap_ms', 1800);
$$;
CREATE OR REPLACE FUNCTION dh_flip_delay() RETURNS NUMERIC LANGUAGE sql STABLE AS $$
  SELECT dh_setting_ms('flip_delay_ms', 900);
$$;
CREATE OR REPLACE FUNCTION dh_score_hold() RETURNS NUMERIC LANGUAGE sql STABLE AS $$
  SELECT dh_setting_ms('score_hold_ms', 4000);
$$;
CREATE OR REPLACE FUNCTION dh_countdown()  RETURNS NUMERIC LANGUAGE sql STABLE AS $$
  SELECT dh_setting_ms('countdown_ms', 6000);
$$;

-- These are no longer IMMUTABLE (they read a table), so dh_deal_len cannot be either.
CREATE OR REPLACE FUNCTION dh_deal_len(p_seats INT)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
  SELECT (p_seats * 3) * dh_seat_gap() + dh_score_hold();
$$;

-- ---------------------------------------------------------------------------
-- dh_get_room: a card is laid down, sits, then turns
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
  v_flip     NUMERIC := dh_flip_delay();
  v_elapsed  NUMERIC;
  v_t        NUMERIC;   -- seconds into the current deal
  v_deal     INT := 0;
  v_dealt    INT := 0;  -- cards LAID DOWN so far in this deal, across every seat
  v_turned   INT := 0;  -- cards TURNED OVER so far in this deal
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
    v_len := dh_deal_len(v_round.seats);
    v_elapsed := EXTRACT(EPOCH FROM now() - v_round.dealt_at);

    IF v_elapsed < 0 THEN
      v_phase := 'countdown';
    ELSIF now() < v_round.settle_at THEN
      v_phase := 'dealing';
      v_deal := LEAST(3, FLOOR(v_elapsed / v_len)::INT + 1);
      v_t := v_elapsed - (v_deal - 1) * v_len;

      -- Card k (1-based) is laid down at (k-1)*gap and turns at (k-1)*gap + flip.
      v_dealt  := LEAST(v_round.seats * 3, GREATEST(0, FLOOR(v_t / v_gap)::INT + 1));
      v_turned := LEAST(v_round.seats * 3, GREATEST(0, FLOOR((v_t - v_flip) / v_gap)::INT + 1));
      IF v_t < v_flip THEN v_turned := 0; END IF;

      v_revealed := LEAST(3, v_turned / v_round.seats);
    ELSE
      v_phase := 'results';
      v_deal := 3;
      v_dealt := v_round.seats * 3;
      v_turned := v_round.seats * 3;
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
                       -- The card itself, only once it has actually been turned over.
                       'cards', (
                         SELECT jsonb_agg(
                           CASE
                             WHEN h.deal_no < v_deal THEN h.cards->(i - 1)
                             WHEN h.deal_no = v_deal
                              AND v_turned >= (i - 1) * v_round.seats + rp.seat_index + 1
                               THEN h.cards->(i - 1)
                             ELSE NULL
                           END ORDER BY i)
                         FROM generate_series(1, 3) i
                       ),
                       -- How many cards are physically in front of this player,
                       -- face down or face up. The client draws a card back for
                       -- one that has landed but not yet turned.
                       'laid', (
                         SELECT COUNT(*)::INT
                         FROM generate_series(1, 3) i
                         WHERE h.deal_no < v_deal
                            OR (h.deal_no = v_deal
                                AND v_dealt >= (i - 1) * v_round.seats + rp.seat_index + 1)
                       ),
                       'score', CASE WHEN h.deal_no < v_deal
                                      OR (h.deal_no = v_deal AND v_turned >= v_round.seats * 3)
                                     THEN h.score END,
                       'value', CASE WHEN h.deal_no < v_deal
                                      OR (h.deal_no = v_deal AND v_turned >= v_round.seats * 3)
                                     THEN h.value END,
                       'category', CASE WHEN h.deal_no < v_deal
                                         OR (h.deal_no = v_deal AND v_turned >= v_round.seats * 3)
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
                     OR (h.deal_no = v_deal AND v_turned >= v_round.seats * 3))
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
    -- Whose turn it is to be dealt to right now.
    'dealingSeat', CASE WHEN v_phase = 'dealing' AND v_dealt < v_room.seats * 3
                        THEN GREATEST(0, v_dealt - 1) % v_room.seats END,
    'flips', v_turned,
    'laid', v_dealt,
    'revealed', v_revealed,
    'players', v_players,
    'startsInMs', CASE WHEN v_phase = 'countdown'
                       THEN GREATEST(0, EXTRACT(EPOCH FROM v_round.dealt_at - now()) * 1000)::INT END
  );
END;
$$;

GRANT EXECUTE ON FUNCTION dh_get_room(BIGINT)      TO authenticated;
GRANT EXECUTE ON FUNCTION dh_setting_ms(TEXT, INT) TO authenticated;

-- Let the admin panel tune the pace.
CREATE OR REPLACE FUNCTION dh_admin_set_setting(p_key TEXT, p_value JSONB)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  PERFORM dh_require_admin();
  IF p_key NOT IN ('free_hands_per_day', 'seat_gap_ms', 'flip_delay_ms',
                   'score_hold_ms', 'countdown_ms') THEN
    RAISE EXCEPTION 'Unknown setting.';
  END IF;
  INSERT INTO settings (key, value) VALUES (p_key, p_value)
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
END;
$$;

GRANT EXECUTE ON FUNCTION dh_admin_set_setting(TEXT, JSONB) TO authenticated;
