-- Chat: one global room and one per table.
--
--   room_id NULL  -> the global lobby chat
--   room_id = id  -> that table's chat
--
-- Messages are sent through dh_send_chat(), never by direct insert, so every
-- message is length-capped, rate-limited, and blocked for banned players in one
-- place the client cannot go around. Reading is open to any signed-in player;
-- writing is not.

CREATE TABLE IF NOT EXISTS chat_messages (
  id         BIGSERIAL PRIMARY KEY,
  room_id    BIGINT REFERENCES rooms(id) ON DELETE CASCADE,   -- NULL = global
  user_id    UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  name       TEXT NOT NULL,
  body       TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS chat_room_idx ON chat_messages (room_id, created_at DESC);

ALTER TABLE chat_messages ENABLE ROW LEVEL SECURITY;

-- Anyone signed in can read the chat.
CREATE POLICY chat_read ON chat_messages FOR SELECT TO authenticated USING (true);
-- No insert policy: messages come only through dh_send_chat().

-- Live updates.
ALTER PUBLICATION supabase_realtime ADD TABLE chat_messages;

CREATE OR REPLACE FUNCTION dh_send_chat(p_room_id BIGINT, p_body TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_uid  UUID := auth.uid();
  v_name TEXT;
  v_body TEXT := btrim(p_body);
  v_last TIMESTAMPTZ;
  v_id   BIGINT;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;

  IF length(v_body) = 0 THEN RAISE EXCEPTION 'Say something first.'; END IF;
  IF length(v_body) > 200 THEN RAISE EXCEPTION 'Keep it under 200 characters.'; END IF;

  SELECT display_name INTO v_name FROM profiles WHERE id = v_uid AND NOT is_banned;
  IF v_name IS NULL THEN RAISE EXCEPTION 'You cannot chat right now.'; END IF;

  -- The table must exist if this is a table message.
  IF p_room_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM rooms WHERE id = p_room_id) THEN
    RAISE EXCEPTION 'That table no longer exists.';
  END IF;

  -- Rate limit: at most one message every 1.5 seconds.
  SELECT MAX(created_at) INTO v_last FROM chat_messages WHERE user_id = v_uid;
  IF v_last IS NOT NULL AND now() - v_last < interval '1.5 seconds' THEN
    RAISE EXCEPTION 'Slow down a moment.';
  END IF;

  INSERT INTO chat_messages (room_id, user_id, name, body)
  VALUES (p_room_id, v_uid, v_name, v_body)
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('id', v_id);
END;
$$;

-- The recent history for a room (NULL = global), oldest first for display.
CREATE OR REPLACE FUNCTION dh_chat_history(p_room_id BIGINT)
RETURNS TABLE (id BIGINT, user_id UUID, name TEXT, body TEXT, created_at TIMESTAMPTZ)
LANGUAGE sql SECURITY DEFINER SET search_path = public
AS $$
  SELECT id, user_id, name, body, created_at
    FROM (
      SELECT * FROM chat_messages
       WHERE room_id IS NOT DISTINCT FROM p_room_id
       ORDER BY created_at DESC
       LIMIT 50
    ) recent
   ORDER BY created_at ASC;
$$;

GRANT EXECUTE ON FUNCTION dh_send_chat(BIGINT, TEXT)  TO authenticated;
GRANT EXECUTE ON FUNCTION dh_chat_history(BIGINT)     TO authenticated;
