-- Admin adjusts a player's DEMO balance (cents), and the admin player list now
-- carries it. Same shape as the cash control. A demo credit can push a player
-- over the demo->real milestone, so it checks the funnel afterwards.

CREATE OR REPLACE FUNCTION dh_admin_adjust_demo(p_user_id UUID, p_cents BIGINT, p_note TEXT)
RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_balance BIGINT;
BEGIN
  PERFORM dh_require_admin();
  IF p_cents = 0 THEN RAISE EXCEPTION 'Enter a non-zero amount.'; END IF;

  UPDATE profiles SET demo_balance = demo_balance + p_cents
   WHERE id = p_user_id AND demo_balance + p_cents >= 0
  RETURNING demo_balance INTO v_balance;

  IF NOT FOUND THEN RAISE EXCEPTION 'That would put the demo balance below $0.'; END IF;

  INSERT INTO ledger (user_id, kind, amount, balance_after, note)
  VALUES (p_user_id,
          CASE WHEN p_cents > 0 THEN 'demo_grant' ELSE 'demo_debit' END,
          p_cents, v_balance, COALESCE(p_note, 'Demo adjustment'));

  -- A top-up may have reached the demo goal.
  PERFORM dh_check_milestones(p_user_id);
  RETURN v_balance;
END;
$$;

DROP FUNCTION IF EXISTS dh_admin_players(TEXT);

CREATE FUNCTION dh_admin_players(p_query TEXT DEFAULT '')
RETURNS TABLE (id UUID, display_name TEXT, email TEXT, balance BIGINT, cash_balance BIGINT,
               demo_balance BIGINT, referral_count INT, is_admin BOOLEAN, is_banned BOOLEAN,
               created_at TIMESTAMPTZ)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  PERFORM dh_require_admin();
  RETURN QUERY
    SELECT p.id, p.display_name, u.email::TEXT, p.balance, p.cash_balance,
           p.demo_balance, p.referral_count, p.is_admin, p.is_banned, p.created_at
      FROM profiles p
      JOIN auth.users u ON u.id = p.id
     WHERE COALESCE(p_query, '') = ''
        OR p.display_name ILIKE '%' || p_query || '%'
        OR u.email ILIKE '%' || p_query || '%'
     ORDER BY p.created_at DESC
     LIMIT 100;
END;
$$;

GRANT EXECUTE ON FUNCTION dh_admin_adjust_demo(UUID, BIGINT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION dh_admin_players(TEXT)                   TO authenticated;
