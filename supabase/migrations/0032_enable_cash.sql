-- Turn real-money tables on, and make the switch admin-controllable.
--
-- dh_cash_enabled() was hardcoded FALSE while there was no gambling licence. The
-- operator has confirmed the licence is in place, so it now reads a setting,
-- defaulted ON, that an admin can flip from the panel -- useful for pausing cash
-- play without a deploy (maintenance, a payment issue, whatever).
--
-- To pause real money again: set cash_enabled to false (Admin -> Pace/Settings),
-- or run  UPDATE settings SET value = 'false' WHERE key = 'cash_enabled';
--
-- REMINDER, on the record: enabling this makes the app take real stakes and pay
-- real prizes. That is lawful only with the licence, KYC/age checks, and a
-- payment path that this app does not itself run -- deposits and withdrawals are
-- still settled by hand via @DH_Support and the admin cash control. The switch
-- assumes the operator has all of that; it does not provide it.

INSERT INTO settings (key, value) VALUES ('cash_enabled', 'true'::jsonb)
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;

CREATE OR REPLACE FUNCTION dh_cash_enabled()
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT COALESCE((SELECT value::TEXT::BOOLEAN FROM settings WHERE key = 'cash_enabled'), FALSE);
$$;

-- Let the admin toggle it (and it is safe to expose via the settings setter).
CREATE OR REPLACE FUNCTION dh_admin_set_setting(p_key TEXT, p_value JSONB)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  PERFORM dh_require_admin();
  IF p_key NOT IN ('free_hands_per_day', 'seat_gap_ms', 'flip_delay_ms', 'score_hold_ms',
                   'countdown_ms', 'signup_bonus', 'fill_window_ms', 'cash_enabled',
                   'welcome_points', 'welcome_demo_cents', 'demo_goal_cents', 'demo_bonus_cents',
                   'withdraw_goal_cents', 'referral_points', 'referral_goal', 'referral_bonus_cents') THEN
    RAISE EXCEPTION 'Unknown setting.';
  END IF;
  INSERT INTO settings (key, value) VALUES (p_key, p_value)
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
END;
$$;

GRANT EXECUTE ON FUNCTION dh_cash_enabled()                 TO authenticated;
GRANT EXECUTE ON FUNCTION dh_admin_set_setting(TEXT, JSONB) TO authenticated;
