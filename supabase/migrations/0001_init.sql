-- Dark Horse — schema + the entire game engine, as database functions.
--
-- The rules live here, not in the browser: the client can only call the RPCs at
-- the bottom of this file, so a player cannot deal themselves a winning hand or
-- spend the same points twice. Every function that moves money is SECURITY
-- DEFINER and runs in a single transaction.

-- ---------------------------------------------------------------------------
-- The Telegram build's throwaway tables, cleared out once on the first run.
--
-- NOTE: these DROPs used to include the game's own tables. Migrations are now
-- applied once and recorded (see the migrations table), but a migration must
-- never be destructive anyway -- someone will re-run it one day.
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS users CASCADE;

-- ---------------------------------------------------------------------------
-- Timing of a hand, all measured from rounds.dealt_at
-- ---------------------------------------------------------------------------
--   countdown : 3s  (table fills -> dealt_at)
--   card 1,2,3: dealt_at + 0.0s / 1.6s / 3.2s
--   results   : dealt_at + 4.8s  (= settle_at, when money moves)
--   reset     : settle_at + 9s   (seats cleared, table reopens)

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS profiles (
  id           UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  display_name TEXT NOT NULL DEFAULT 'Player',
  balance      BIGINT NOT NULL DEFAULT 0 CHECK (balance >= 0),
  is_admin     BOOLEAN NOT NULL DEFAULT FALSE,
  is_banned    BOOLEAN NOT NULL DEFAULT FALSE,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS rooms (
  id              BIGSERIAL PRIMARY KEY,
  name            TEXT NOT NULL,
  seats           INT NOT NULL CHECK (seats IN (4, 8)),
  buy_in          BIGINT NOT NULL CHECK (buy_in >= 0),
  prizes          BIGINT[] NOT NULL,
  is_active       BOOLEAN NOT NULL DEFAULT TRUE,
  sort_order      INT NOT NULL DEFAULT 0,
  current_round_id BIGINT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS rounds (
  id         BIGSERIAL PRIMARY KEY,
  room_id    BIGINT NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
  seats      INT NOT NULL,
  buy_in     BIGINT NOT NULL,
  prizes     BIGINT[] NOT NULL,
  pot        BIGINT NOT NULL DEFAULT 0,
  paid_out   BIGINT NOT NULL DEFAULT 0,
  dealt_at   TIMESTAMPTZ NOT NULL,
  settle_at  TIMESTAMPTZ NOT NULL,
  reset_at   TIMESTAMPTZ NOT NULL,
  settled_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE rooms
  ADD CONSTRAINT rooms_current_round_fk
  FOREIGN KEY (current_round_id) REFERENCES rounds(id) ON DELETE SET NULL;

-- Who is sitting where, right now. This is the table the lobby watches.
CREATE TABLE IF NOT EXISTS seats (
  room_id    BIGINT NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
  seat_index INT NOT NULL,
  user_id    UUID REFERENCES profiles(id) ON DELETE CASCADE,
  bot_name   TEXT,
  joined_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (room_id, seat_index),
  -- One seat per player per table. Bots have a NULL user_id, and Postgres
  -- treats NULLs as distinct, so many bots can share a table.
  UNIQUE (room_id, user_id),
  CHECK ((user_id IS NULL) <> (bot_name IS NULL))
);

-- The dealt cards. Never readable directly -- see dh_get_room(), which hides
-- cards the dealer has not turned over yet.
CREATE TABLE IF NOT EXISTS round_hands (
  round_id   BIGINT NOT NULL REFERENCES rounds(id) ON DELETE CASCADE,
  seat_index INT NOT NULL,
  user_id    UUID REFERENCES profiles(id) ON DELETE SET NULL,
  bot_name   TEXT,
  cards      JSONB NOT NULL,
  category   INT NOT NULL,
  total      INT NOT NULL,
  score      INT NOT NULL,
  place      INT NOT NULL,
  won        BIGINT NOT NULL DEFAULT 0,
  is_split   BOOLEAN NOT NULL DEFAULT FALSE,
  PRIMARY KEY (round_id, seat_index)
);

CREATE TABLE IF NOT EXISTS ledger (
  id            BIGSERIAL PRIMARY KEY,
  user_id       UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  round_id      BIGINT REFERENCES rounds(id) ON DELETE SET NULL,
  kind          TEXT NOT NULL,   -- buy_in | prize | refund | admin_credit | admin_debit | signup
  amount        BIGINT NOT NULL,
  balance_after BIGINT NOT NULL,
  note          TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX ledger_user_idx ON ledger (user_id, created_at DESC);
CREATE INDEX rounds_room_idx ON rounds (room_id, created_at DESC);
CREATE INDEX round_hands_user_idx ON round_hands (user_id);

-- ---------------------------------------------------------------------------
-- New signups get a profile and their starting points, automatically
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION dh_handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_bonus BIGINT := 1000;
BEGIN
  INSERT INTO profiles (id, display_name, balance)
  VALUES (
    NEW.id,
    COALESCE(NULLIF(NEW.raw_user_meta_data->>'display_name', ''), split_part(NEW.email, '@', 1)),
    v_bonus
  );

  INSERT INTO ledger (user_id, kind, amount, balance_after, note)
  VALUES (NEW.id, 'signup', v_bonus, v_bonus, 'Welcome bonus');

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION dh_handle_new_user();

-- ---------------------------------------------------------------------------
-- Card rules
-- ---------------------------------------------------------------------------
-- A card is {"r": 1..13, "s": "S"|"H"|"D"|"C"}, where r=1 is an Ace.

-- A = 1, 2-9 face value, 10/J/Q/K = 10.
CREATE OR REPLACE FUNCTION dh_card_value(p_rank INT)
RETURNS INT LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN p_rank >= 10 THEN 10 ELSE p_rank END;
$$;

-- Category: 2 = three of a kind, 1 = crown (K+Q+J), 0 = normal score.
CREATE OR REPLACE FUNCTION dh_category(p_cards JSONB)
RETURNS INT LANGUAGE sql IMMUTABLE AS $$
  WITH r AS (SELECT (c->>'r')::INT AS rank FROM jsonb_array_elements(p_cards) c)
  SELECT CASE
    WHEN (SELECT COUNT(DISTINCT rank) FROM r) = 1 THEN 2
    WHEN (SELECT COUNT(*) FROM r WHERE rank IN (11, 12, 13)) = 3
     AND (SELECT COUNT(DISTINCT rank) FROM r) = 3 THEN 1
    ELSE 0
  END;
$$;

-- Sum of the three card values, before taking the last digit.
CREATE OR REPLACE FUNCTION dh_total(p_cards JSONB)
RETURNS INT LANGUAGE sql IMMUTABLE AS $$
  SELECT COALESCE(SUM(dh_card_value((c->>'r')::INT)), 0)::INT
  FROM jsonb_array_elements(p_cards) c;
$$;

-- The three ranks, highest first: the tiebreak, in order.
CREATE OR REPLACE FUNCTION dh_kickers(p_cards JSONB)
RETURNS INT[] LANGUAGE sql IMMUTABLE AS $$
  SELECT ARRAY(
    SELECT (c->>'r')::INT
    FROM jsonb_array_elements(p_cards) c
    ORDER BY (c->>'r')::INT DESC
  );
$$;

-- The single sort key for a hand, strongest first. Category outranks everything;
-- then a triple's rank (KKK > AAA) or a normal hand's score; then the three
-- cards high to low. Two hands with an identical key are a true tie and split.
CREATE OR REPLACE FUNCTION dh_sort_key(p_cards JSONB)
RETURNS INT[] LANGUAGE sql IMMUTABLE AS $$
  SELECT ARRAY[
    dh_category(p_cards),
    CASE
      WHEN dh_category(p_cards) = 2 THEN (dh_kickers(p_cards))[1]  -- triple rank
      WHEN dh_category(p_cards) = 0 THEN dh_total(p_cards) % 10    -- score
      ELSE 0                                                       -- every crown is equal
    END,
    (dh_kickers(p_cards))[1],
    (dh_kickers(p_cards))[2],
    (dh_kickers(p_cards))[3]
  ];
$$;

-- ---------------------------------------------------------------------------
-- Dealing
-- ---------------------------------------------------------------------------
-- Called the moment a table fills. Shuffles, deals, scores, ranks and works out
-- every prize -- but does NOT move money yet, so nobody's balance can give the
-- result away before the cards are turned over. dh_tick() settles it later.
CREATE OR REPLACE FUNCTION dh_deal(p_room_id BIGINT)
RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_room     rooms%ROWTYPE;
  v_taken    INT;
  v_round_id BIGINT;
  v_dealt_at TIMESTAMPTZ := now() + interval '3 seconds';  -- the countdown
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
    v_dealt_at + interval '4.8 seconds',
    v_dealt_at + interval '13.8 seconds'
  )
  RETURNING id INTO v_round_id;

  -- Shuffle: gen_random_uuid() is CSPRNG-backed, unlike random(), so the deck
  -- cannot be predicted from earlier rounds.
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
  -- Deal one card at a time around the table, like a real dealer.
  dealt AS (
    SELECT p.seat_index, p.user_id, p.bot_name,
           jsonb_agg(d.card ORDER BY d.pos) AS cards
    FROM players p
    JOIN deck d ON d.pos IN (p.n, p.n + v_room.seats, p.n + 2 * v_room.seats)
    GROUP BY p.seat_index, p.user_id, p.bot_name
  ),
  scored AS (
    SELECT *,
           dh_category(cards) AS category,
           dh_total(cards)    AS total,
           dh_total(cards) % 10 AS score,
           dh_sort_key(cards) AS key
    FROM dealt
  ),
  -- rank() gives tied hands the same place and skips the next, which is exactly
  -- the rule: two players tied for 1st means the next player is 3rd.
  ranked AS (
    SELECT *, rank() OVER (ORDER BY key DESC) AS place
    FROM scored
  ),
  -- A tie group takes every prize slot it spans and divides the sum equally.
  -- Counting and summing the slots has to happen in two steps: an aggregate
  -- cannot be an argument to generate_series().
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
  INSERT INTO round_hands (round_id, seat_index, user_id, bot_name, cards, category, total, score, place, won, is_split)
  SELECT
    v_round_id, r.seat_index, r.user_id, r.bot_name, r.cards,
    r.category, r.total, r.score, r.place,
    -- Points are whole, so a pool that does not divide evenly rounds each share
    -- down; the remainder is simply not paid rather than invented.
    CASE WHEN r.bot_name IS NOT NULL THEN 0 ELSE floor(g.pool / g.members)::BIGINT END,
    g.members > 1 AND g.pool > 0
  FROM ranked r
  JOIN groups g ON g.place = r.place;

  -- Bots pay nothing in and take nothing out, so the books only count humans.
  UPDATE rounds SET
    pot = v_room.buy_in * (SELECT COUNT(*) FROM seats WHERE room_id = p_room_id AND user_id IS NOT NULL),
    paid_out = (SELECT COALESCE(SUM(won), 0) FROM round_hands WHERE round_id = v_round_id)
  WHERE id = v_round_id;

  UPDATE rooms SET current_round_id = v_round_id WHERE id = p_room_id;

  RETURN v_round_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- The clock
-- ---------------------------------------------------------------------------
-- There is no always-on server on Vercel, so time-based work happens here and
-- is called at the start of every RPC. Any player loading the lobby advances
-- the world; if everyone closes the tab mid-hand, the next visitor settles it.
CREATE OR REPLACE FUNCTION dh_tick()
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_round  RECORD;
  v_hand   RECORD;
  v_balance BIGINT;
BEGIN
  -- 1. Pay out any round whose reveal has finished.
  FOR v_round IN
    SELECT * FROM rounds
    WHERE settled_at IS NULL AND settle_at <= now()
    ORDER BY id
    FOR UPDATE SKIP LOCKED
  LOOP
    FOR v_hand IN
      SELECT * FROM round_hands
      WHERE round_id = v_round.id AND user_id IS NOT NULL AND won > 0
    LOOP
      UPDATE profiles SET balance = balance + v_hand.won
      WHERE id = v_hand.user_id
      RETURNING balance INTO v_balance;

      INSERT INTO ledger (user_id, round_id, kind, amount, balance_after, note)
      VALUES (
        v_hand.user_id, v_round.id, 'prize', v_hand.won, v_balance,
        'Place ' || v_hand.place || CASE WHEN v_hand.is_split THEN ' (split)' ELSE '' END
      );
    END LOOP;

    UPDATE rounds SET settled_at = now() WHERE id = v_round.id;
  END LOOP;

  -- 2. Clear the table once the results have been on screen long enough.
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
-- Player actions
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION dh_join_room(p_room_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_uid     UUID := auth.uid();
  v_room    rooms%ROWTYPE;
  v_profile profiles%ROWTYPE;
  v_seat    INT;
  v_taken   INT;
  v_balance BIGINT;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'You must be signed in to play.'; END IF;
  PERFORM dh_tick();

  -- Lock the room: two players clicking "join" at the same instant serialise
  -- here, so they cannot both take the last seat.
  SELECT * INTO v_room FROM rooms WHERE id = p_room_id AND is_active FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'That table is not open.'; END IF;
  IF v_room.current_round_id IS NOT NULL THEN
    RAISE EXCEPTION 'This table is mid-hand. Try the next one.';
  END IF;

  SELECT * INTO v_profile FROM profiles WHERE id = v_uid FOR UPDATE;
  IF v_profile.is_banned THEN RAISE EXCEPTION 'Your account is suspended.'; END IF;
  IF EXISTS (SELECT 1 FROM seats WHERE room_id = p_room_id AND user_id = v_uid) THEN
    RAISE EXCEPTION 'You are already at this table.';
  END IF;
  IF v_profile.balance < v_room.buy_in THEN
    RAISE EXCEPTION 'Not enough points for this buy-in.';
  END IF;

  SELECT MIN(i) INTO v_seat
  FROM generate_series(0, v_room.seats - 1) i
  WHERE i NOT IN (SELECT seat_index FROM seats WHERE room_id = p_room_id);
  IF v_seat IS NULL THEN RAISE EXCEPTION 'This table is full.'; END IF;

  UPDATE profiles SET balance = balance - v_room.buy_in
  WHERE id = v_uid
  RETURNING balance INTO v_balance;

  INSERT INTO seats (room_id, seat_index, user_id) VALUES (p_room_id, v_seat, v_uid);

  IF v_room.buy_in > 0 THEN
    INSERT INTO ledger (user_id, kind, amount, balance_after, note)
    VALUES (v_uid, 'buy_in', -v_room.buy_in, v_balance, v_room.name);
  END IF;

  -- Filling the last seat starts the hand.
  SELECT COUNT(*) INTO v_taken FROM seats WHERE room_id = p_room_id;
  IF v_taken = v_room.seats THEN PERFORM dh_deal(p_room_id); END IF;

  RETURN jsonb_build_object('seat', v_seat, 'balance', v_balance);
END;
$$;

CREATE OR REPLACE FUNCTION dh_leave_room(p_room_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_uid     UUID := auth.uid();
  v_room    rooms%ROWTYPE;
  v_balance BIGINT;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  PERFORM dh_tick();

  SELECT * INTO v_room FROM rooms WHERE id = p_room_id FOR UPDATE;
  IF v_room.current_round_id IS NOT NULL THEN
    RAISE EXCEPTION 'The hand has already started.';
  END IF;

  DELETE FROM seats WHERE room_id = p_room_id AND user_id = v_uid;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', true); END IF;

  UPDATE profiles SET balance = balance + v_room.buy_in
  WHERE id = v_uid
  RETURNING balance INTO v_balance;

  IF v_room.buy_in > 0 THEN
    INSERT INTO ledger (user_id, kind, amount, balance_after, note)
    VALUES (v_uid, 'refund', v_room.buy_in, v_balance, 'Left the table');
  END IF;

  RETURN jsonb_build_object('ok', true, 'balance', v_balance);
END;
$$;

-- ---------------------------------------------------------------------------
-- Reading the table
-- ---------------------------------------------------------------------------
-- The one place cards are exposed. A card the dealer has not turned over yet is
-- returned as null, so an unrevealed hand cannot be read out of the network tab.
CREATE OR REPLACE FUNCTION dh_get_room(p_room_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_room     rooms%ROWTYPE;
  v_round    rounds%ROWTYPE;
  v_phase    TEXT;
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
             'isBot', s.bot_name IS NOT NULL,
             'cards', jsonb_build_array(NULL, NULL, NULL)
           ) ORDER BY s.seat_index), '[]'::jsonb)
      INTO v_players
      FROM seats s
      LEFT JOIN profiles p ON p.id = s.user_id
     WHERE s.room_id = p_room_id;
  ELSE
    SELECT * INTO v_round FROM rounds WHERE id = v_room.current_round_id;

    IF now() < v_round.dealt_at THEN
      v_phase := 'countdown';
    ELSIF now() < v_round.settle_at THEN
      v_phase := 'dealing';
      -- One card every 1.6s from dealt_at.
      v_revealed := LEAST(3, FLOOR(EXTRACT(EPOCH FROM now() - v_round.dealt_at) / 1.6)::INT + 1);
    ELSE
      v_phase := 'results';
      v_revealed := 3;
    END IF;

    SELECT COALESCE(jsonb_agg(jsonb_build_object(
             'seat', h.seat_index,
             'userId', h.user_id,
             'name', COALESCE(p.display_name, h.bot_name),
             'isBot', h.bot_name IS NOT NULL,
             'cards', (
               SELECT jsonb_agg(CASE WHEN i <= v_revealed THEN h.cards->(i - 1) ELSE NULL END ORDER BY i)
               FROM generate_series(1, 3) i
             ),
             'total', CASE WHEN v_phase = 'results' THEN h.total END,
             'score', CASE WHEN v_phase = 'results' THEN h.score END,
             'category', CASE WHEN v_phase = 'results' THEN h.category END,
             'place', CASE WHEN v_phase = 'results' THEN h.place END,
             'won',   CASE WHEN v_phase = 'results' THEN h.won END,
             'isSplit', CASE WHEN v_phase = 'results' THEN h.is_split END
           ) ORDER BY h.seat_index), '[]'::jsonb)
      INTO v_players
      FROM round_hands h
      LEFT JOIN profiles p ON p.id = h.user_id
     WHERE h.round_id = v_round.id;
  END IF;

  RETURN jsonb_build_object(
    'id', v_room.id,
    'name', v_room.name,
    'seats', v_room.seats,
    'buyIn', v_room.buy_in,
    'prizes', v_room.prizes,
    'phase', v_phase,
    'revealed', v_revealed,
    'players', v_players,
    'startsInMs', CASE WHEN v_phase = 'countdown'
                       THEN GREATEST(0, EXTRACT(EPOCH FROM v_round.dealt_at - now()) * 1000)::INT END
  );
END;
$$;

CREATE OR REPLACE FUNCTION dh_get_lobby()
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_rooms JSONB;
BEGIN
  PERFORM dh_tick();
  SELECT COALESCE(jsonb_agg(dh_get_room(id) ORDER BY sort_order, id), '[]'::jsonb)
    INTO v_rooms
    FROM rooms WHERE is_active;
  RETURN v_rooms;
END;
$$;

-- ---------------------------------------------------------------------------
-- Admin
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION dh_require_admin()
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND is_admin) THEN
    RAISE EXCEPTION 'Admins only.';
  END IF;
END;
$$;

-- Fills the empty seats with test players so an admin can demo a full deal
-- alone. Bots are dealt in and ranked like anyone else, but pay no buy-in and
-- collect no prize, so they never touch the ledger.
CREATE OR REPLACE FUNCTION dh_fill_bots(p_room_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_room  rooms%ROWTYPE;
  v_names TEXT[] := ARRAY['Bot Ada', 'Bot Rex', 'Bot Nova', 'Bot Kit', 'Bot Otto', 'Bot Iris', 'Bot Zed'];
  v_seat  INT;
  v_added INT := 0;
BEGIN
  PERFORM dh_require_admin();
  PERFORM dh_tick();

  SELECT * INTO v_room FROM rooms WHERE id = p_room_id FOR UPDATE;
  IF v_room.current_round_id IS NOT NULL THEN
    RAISE EXCEPTION 'The hand has already started.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM seats WHERE room_id = p_room_id AND user_id IS NOT NULL) THEN
    RAISE EXCEPTION 'Take a seat yourself first, then fill the rest with bots.';
  END IF;

  LOOP
    SELECT MIN(i) INTO v_seat
    FROM generate_series(0, v_room.seats - 1) i
    WHERE i NOT IN (SELECT seat_index FROM seats WHERE room_id = p_room_id);
    EXIT WHEN v_seat IS NULL;

    INSERT INTO seats (room_id, seat_index, bot_name)
    VALUES (p_room_id, v_seat, v_names[(v_added % array_length(v_names, 1)) + 1]);
    v_added := v_added + 1;
  END LOOP;

  IF v_added = 0 THEN RAISE EXCEPTION 'This table is already full.'; END IF;

  PERFORM dh_deal(p_room_id);
  RETURN jsonb_build_object('added', v_added);
END;
$$;

CREATE OR REPLACE FUNCTION dh_admin_save_room(
  p_id BIGINT, p_name TEXT, p_seats INT, p_buy_in BIGINT, p_prizes BIGINT[], p_is_active BOOLEAN
)
RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_id       BIGINT;
  v_expected INT;
BEGIN
  PERFORM dh_require_admin();

  IF p_seats NOT IN (4, 8) THEN RAISE EXCEPTION 'A table must have 4 or 8 seats.'; END IF;
  IF COALESCE(TRIM(p_name), '') = '' THEN RAISE EXCEPTION 'The table needs a name.'; END IF;
  IF p_buy_in < 0 THEN RAISE EXCEPTION 'Buy-in must be 0 or more.'; END IF;

  -- A 4-seat table pays 2 places, an 8-seat table pays 4.
  v_expected := CASE WHEN p_seats = 8 THEN 4 ELSE 2 END;
  IF array_length(p_prizes, 1) IS DISTINCT FROM v_expected THEN
    RAISE EXCEPTION 'A %-seat table pays % places, so it needs % prizes.', p_seats, v_expected, v_expected;
  END IF;
  IF EXISTS (SELECT 1 FROM unnest(p_prizes) x WHERE x < 0) THEN
    RAISE EXCEPTION 'Prizes cannot be negative.';
  END IF;

  IF p_id IS NULL THEN
    INSERT INTO rooms (name, seats, buy_in, prizes, is_active, sort_order)
    VALUES (p_name, p_seats, p_buy_in, p_prizes, p_is_active,
            COALESCE((SELECT MAX(sort_order) + 1 FROM rooms), 0))
    RETURNING id INTO v_id;
  ELSE
    -- Changing a table under players who have already paid to sit down would
    -- move the goalposts mid-game.
    IF EXISTS (SELECT 1 FROM rooms WHERE id = p_id AND current_round_id IS NOT NULL) THEN
      RAISE EXCEPTION 'That table is mid-hand. Try again in a moment.';
    END IF;
    IF EXISTS (SELECT 1 FROM seats WHERE room_id = p_id) THEN
      RAISE EXCEPTION 'Players are seated at that table. Wait until it is empty.';
    END IF;

    UPDATE rooms
       SET name = p_name, seats = p_seats, buy_in = p_buy_in,
           prizes = p_prizes, is_active = p_is_active
     WHERE id = p_id
    RETURNING id INTO v_id;
  END IF;

  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION dh_admin_adjust_balance(p_user_id UUID, p_amount BIGINT, p_note TEXT)
RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_balance BIGINT;
BEGIN
  PERFORM dh_require_admin();
  IF p_amount = 0 THEN RAISE EXCEPTION 'Enter a non-zero amount.'; END IF;

  UPDATE profiles SET balance = balance + p_amount
   WHERE id = p_user_id AND balance + p_amount >= 0
  RETURNING balance INTO v_balance;

  IF NOT FOUND THEN RAISE EXCEPTION 'That would put the player below zero.'; END IF;

  INSERT INTO ledger (user_id, kind, amount, balance_after, note)
  VALUES (p_user_id,
          CASE WHEN p_amount > 0 THEN 'admin_credit' ELSE 'admin_debit' END,
          p_amount, v_balance, COALESCE(p_note, 'Admin adjustment'));

  RETURN v_balance;
END;
$$;

CREATE OR REPLACE FUNCTION dh_admin_set_banned(p_user_id UUID, p_banned BOOLEAN)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  PERFORM dh_require_admin();
  UPDATE profiles SET is_banned = p_banned WHERE id = p_user_id;
END;
$$;

-- Admin-only listings. These are functions rather than direct table reads so
-- that RLS can keep other players' balances and emails private.
CREATE OR REPLACE FUNCTION dh_admin_players(p_query TEXT DEFAULT '')
RETURNS TABLE (id UUID, display_name TEXT, email TEXT, balance BIGINT, is_admin BOOLEAN, is_banned BOOLEAN, created_at TIMESTAMPTZ)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  PERFORM dh_require_admin();
  RETURN QUERY
    SELECT p.id, p.display_name, u.email::TEXT, p.balance, p.is_admin, p.is_banned, p.created_at
      FROM profiles p
      JOIN auth.users u ON u.id = p.id
     WHERE COALESCE(p_query, '') = ''
        OR p.display_name ILIKE '%' || p_query || '%'
        OR u.email ILIKE '%' || p_query || '%'
     ORDER BY p.created_at DESC
     LIMIT 100;
END;
$$;

CREATE OR REPLACE FUNCTION dh_admin_stats()
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_stats JSONB;
BEGIN
  PERFORM dh_require_admin();
  SELECT jsonb_build_object(
    'players',      (SELECT COUNT(*) FROM profiles),
    'rounds',       (SELECT COUNT(*) FROM rounds WHERE settled_at IS NOT NULL),
    'wagered',      (SELECT COALESCE(SUM(pot), 0) FROM rounds WHERE settled_at IS NOT NULL),
    'paidOut',      (SELECT COALESCE(SUM(paid_out), 0) FROM rounds WHERE settled_at IS NOT NULL),
    'pointsInPlay', (SELECT COALESCE(SUM(balance), 0) FROM profiles)
  ) INTO v_stats;
  RETURN v_stats;
END;
$$;

-- ---------------------------------------------------------------------------
-- History
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION dh_my_history()
RETURNS TABLE (round_id BIGINT, played_at TIMESTAMPTZ, room TEXT, buy_in BIGINT, cards JSONB, score INT, place INT, won BIGINT, net BIGINT)
LANGUAGE sql SECURITY DEFINER SET search_path = public
AS $$
  SELECT r.id, r.created_at, m.name, r.buy_in, h.cards, h.score, h.place, h.won, h.won - r.buy_in
    FROM round_hands h
    JOIN rounds r ON r.id = h.round_id
    JOIN rooms  m ON m.id = r.room_id
   WHERE h.user_id = auth.uid() AND r.settled_at IS NOT NULL
   ORDER BY r.created_at DESC
   LIMIT 25;
$$;

CREATE OR REPLACE FUNCTION dh_leaderboard()
RETURNS TABLE (display_name TEXT, winnings BIGINT, wins BIGINT)
LANGUAGE sql SECURITY DEFINER SET search_path = public
AS $$
  SELECT p.display_name, SUM(h.won)::BIGINT, COUNT(*)::BIGINT
    FROM round_hands h
    JOIN rounds r ON r.id = h.round_id AND r.settled_at IS NOT NULL
    JOIN profiles p ON p.id = h.user_id
   WHERE h.won > 0
   GROUP BY p.id, p.display_name
   ORDER BY 2 DESC
   LIMIT 20;
$$;

-- ---------------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------------
-- Default deny. The browser holds an anon key that anyone can read out of the
-- bundle, so every table is locked and the RPCs above are the only way in.
ALTER TABLE profiles    ENABLE ROW LEVEL SECURITY;
ALTER TABLE rooms       ENABLE ROW LEVEL SECURITY;
ALTER TABLE rounds      ENABLE ROW LEVEL SECURITY;
ALTER TABLE seats       ENABLE ROW LEVEL SECURITY;
ALTER TABLE round_hands ENABLE ROW LEVEL SECURITY;
ALTER TABLE ledger      ENABLE ROW LEVEL SECURITY;

-- You can read your own profile, and nobody's balance but your own.
CREATE POLICY profiles_self ON profiles FOR SELECT TO authenticated USING (id = auth.uid());

-- Table configuration is public knowledge, and the seat list is what the lobby
-- watches over Realtime. Neither reveals a card.
CREATE POLICY rooms_read ON rooms FOR SELECT TO authenticated USING (true);
CREATE POLICY seats_read ON seats FOR SELECT TO authenticated USING (true);
CREATE POLICY rounds_read ON rounds FOR SELECT TO authenticated USING (true);

-- Your own ledger, nobody else's.
CREATE POLICY ledger_self ON ledger FOR SELECT TO authenticated USING (user_id = auth.uid());

-- round_hands gets NO select policy on purpose: the cards are only ever
-- reachable through dh_get_room(), which hides the ones not yet turned over.

-- Realtime pushes seat and round changes to every open browser.
ALTER PUBLICATION supabase_realtime ADD TABLE seats;
ALTER PUBLICATION supabase_realtime ADD TABLE rooms;
ALTER PUBLICATION supabase_realtime ADD TABLE rounds;

-- ---------------------------------------------------------------------------
-- Starter tables
-- ---------------------------------------------------------------------------
INSERT INTO rooms (name, seats, buy_in, prizes, sort_order) VALUES
  ('Paddock',    4, 100, ARRAY[250, 100]::BIGINT[],           0),
  ('Grandstand', 8, 100, ARRAY[350, 200, 130, 70]::BIGINT[],  1);
