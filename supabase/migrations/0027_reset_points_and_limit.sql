-- Zero the Free Play (points) balance again, and set the daily free limit to 7.
--
-- Points were reset once in 0021, but testing since then has credited some
-- accounts. This zeroes them again, writing the movement to the ledger rather
-- than doing it behind the ledger's back, so an audit still balances.

INSERT INTO ledger (user_id, kind, amount, balance_after, note)
SELECT id, 'admin_debit', -balance, 0, 'Free Play balance reset'
  FROM profiles
 WHERE balance <> 0;

UPDATE profiles SET balance = 0 WHERE balance <> 0;

-- 10 -> 7 free hands a day.
INSERT INTO settings (key, value) VALUES ('free_hands_per_day', '7'::jsonb)
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
