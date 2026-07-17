-- Deposit / withdraw as a logged "contact us", NOT a payment processor.
--
-- Deliberately, this app moves NO money on a deposit or withdrawal. A player
-- taps deposit, is told to message @DH_Support, and the tap is recorded here so
-- an admin sees who wants what. When crypto actually arrives (or is sent), the
-- admin credits or debits the cash balance by hand with the existing ± control.
--
-- Why this shape: the moment the app itself took a card, held a balance a player
-- could cash out, or moved crypto, it would be a money-services / gambling
-- operation needing a licence and a regulated processor. Logging an intent and
-- pointing at a human is not that. Keep it that way until the licensing exists.

CREATE TABLE IF NOT EXISTS payment_requests (
  id         BIGSERIAL PRIMARY KEY,
  user_id    UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  kind       TEXT NOT NULL CHECK (kind IN ('deposit', 'withdraw')),
  method     TEXT NOT NULL DEFAULT 'crypto',
  -- 'open' when the player has just asked; an admin marks it 'done' or
  -- 'cancelled' once they have dealt with it on Telegram.
  status     TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'done', 'cancelled')),
  note       TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  handled_at TIMESTAMPTZ,
  handled_by UUID REFERENCES profiles(id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS payment_requests_open_idx
  ON payment_requests (status, created_at DESC);

ALTER TABLE payment_requests ENABLE ROW LEVEL SECURITY;
-- No policies: readable and writable only through the functions below, so a
-- player can log their own intent but cannot see anyone else's or fake a status.

-- ---------------------------------------------------------------------------
-- A player logs that they want to deposit or withdraw
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION dh_request_payment(p_kind TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_id  BIGINT;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  IF p_kind NOT IN ('deposit', 'withdraw') THEN
    RAISE EXCEPTION 'Unknown request type.';
  END IF;

  -- One open request of each kind per player: tapping deposit five times should
  -- not flood the admin queue with five identical rows.
  UPDATE payment_requests
     SET created_at = now()
   WHERE user_id = v_uid AND kind = p_kind AND status = 'open'
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    INSERT INTO payment_requests (user_id, kind)
    VALUES (v_uid, p_kind)
    RETURNING id INTO v_id;
  END IF;

  RETURN jsonb_build_object('id', v_id);
END;
$$;

-- ---------------------------------------------------------------------------
-- Admin: the queue, and marking one handled
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION dh_admin_payment_requests(p_include_done BOOLEAN DEFAULT FALSE)
RETURNS TABLE (id BIGINT, user_id UUID, display_name TEXT, email TEXT,
               kind TEXT, method TEXT, status TEXT,
               cash_balance BIGINT, created_at TIMESTAMPTZ, handled_at TIMESTAMPTZ)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  PERFORM dh_require_admin();
  RETURN QUERY
    SELECT r.id, r.user_id, p.display_name, u.email::TEXT,
           r.kind, r.method, r.status, p.cash_balance, r.created_at, r.handled_at
      FROM payment_requests r
      JOIN profiles p ON p.id = r.user_id
      JOIN auth.users u ON u.id = r.user_id
     WHERE p_include_done OR r.status = 'open'
     ORDER BY (r.status = 'open') DESC, r.created_at DESC
     LIMIT 100;
END;
$$;

CREATE OR REPLACE FUNCTION dh_admin_resolve_payment(p_id BIGINT, p_status TEXT)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  PERFORM dh_require_admin();
  IF p_status NOT IN ('done', 'cancelled', 'open') THEN
    RAISE EXCEPTION 'Bad status.';
  END IF;

  UPDATE payment_requests
     SET status = p_status,
         handled_at = CASE WHEN p_status = 'open' THEN NULL ELSE now() END,
         handled_by = CASE WHEN p_status = 'open' THEN NULL ELSE auth.uid() END
   WHERE id = p_id;
END;
$$;

-- How many are waiting, for a badge on the admin tab.
CREATE OR REPLACE FUNCTION dh_admin_open_payment_count()
RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  PERFORM dh_require_admin();
  RETURN (SELECT COUNT(*)::INT FROM payment_requests WHERE status = 'open');
END;
$$;

-- ---------------------------------------------------------------------------
-- The player needs to see their cash balance too
-- ---------------------------------------------------------------------------
-- Both balances now travel on the profile the client already reads.
-- cash_balance is in cents; the client divides by 100 to show dollars.

GRANT EXECUTE ON FUNCTION dh_request_payment(TEXT)                TO authenticated;
GRANT EXECUTE ON FUNCTION dh_admin_payment_requests(BOOLEAN)      TO authenticated;
GRANT EXECUTE ON FUNCTION dh_admin_resolve_payment(BIGINT, TEXT)  TO authenticated;
GRANT EXECUTE ON FUNCTION dh_admin_open_payment_count()           TO authenticated;

-- profiles already has a self-select policy, but it was written before
-- cash_balance existed; it selects the whole row, so cash_balance rides along.
-- Nothing to add.
