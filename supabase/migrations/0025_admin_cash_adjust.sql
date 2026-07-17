-- Admin credits or debits a player's REAL-MONEY balance.
--
-- This is the other half of the deposit/withdraw flow: the player asks on
-- Telegram, the crypto arrives (or is sent), and the admin moves the cash
-- balance here to match. It is in CENTS, so $12.50 is 1250 -- the balance never
-- touches a float, which is how you avoid losing a cent a thousand times over.
--
-- Every movement is written to the ledger, same as the points balance, so an
-- audit of real money adds up too. The ledger's amount column already holds
-- cents here; the 'cash_' kinds keep it distinct from points movements.

CREATE OR REPLACE FUNCTION dh_admin_adjust_cash(p_user_id UUID, p_cents BIGINT, p_note TEXT)
RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_balance BIGINT;
BEGIN
  PERFORM dh_require_admin();
  IF p_cents = 0 THEN RAISE EXCEPTION 'Enter a non-zero amount.'; END IF;

  UPDATE profiles SET cash_balance = cash_balance + p_cents
   WHERE id = p_user_id AND cash_balance + p_cents >= 0
  RETURNING cash_balance INTO v_balance;

  IF NOT FOUND THEN RAISE EXCEPTION 'That would put the real-money balance below $0.'; END IF;

  INSERT INTO ledger (user_id, kind, amount, balance_after, note)
  VALUES (p_user_id,
          CASE WHEN p_cents > 0 THEN 'cash_credit' ELSE 'cash_debit' END,
          p_cents, v_balance, COALESCE(p_note, 'Real-money adjustment'));

  RETURN v_balance;
END;
$$;

GRANT EXECUTE ON FUNCTION dh_admin_adjust_cash(UUID, BIGINT, TEXT) TO authenticated;

-- The admin player list needs the real-money balance too, so an admin can see
-- what to top up. Return type changes, so drop first.
DROP FUNCTION IF EXISTS dh_admin_players(TEXT);

CREATE FUNCTION dh_admin_players(p_query TEXT DEFAULT '')
RETURNS TABLE (id UUID, display_name TEXT, email TEXT, balance BIGINT, cash_balance BIGINT,
               is_admin BOOLEAN, is_banned BOOLEAN, created_at TIMESTAMPTZ)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  PERFORM dh_require_admin();
  RETURN QUERY
    SELECT p.id, p.display_name, u.email::TEXT, p.balance, p.cash_balance,
           p.is_admin, p.is_banned, p.created_at
      FROM profiles p
      JOIN auth.users u ON u.id = p.id
     WHERE COALESCE(p_query, '') = ''
        OR p.display_name ILIKE '%' || p_query || '%'
        OR u.email ILIKE '%' || p_query || '%'
     ORDER BY p.created_at DESC
     LIMIT 100;
END;
$$;

GRANT EXECUTE ON FUNCTION dh_admin_players(TEXT) TO authenticated;
