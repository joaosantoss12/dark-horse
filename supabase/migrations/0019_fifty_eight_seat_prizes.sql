-- The 8-player $50 prizes, as specified.
--
--   pot 400 -> 115 / 95 / 85 / 70 = 365, platform fee 35
--
-- Replaces the 125 / 100 / 75 / 62 I had guessed when the figures for this table
-- had not been given. The 4-player $50 table (95 / 80, fee 25) already matched.
--
-- The rake now stands at:
--   $20 · 4 seats: 10 of  80 = 12.5%
--   $20 · 8 seats: 15 of 160 =  9.4%
--   $50 · 4 seats: 25 of 200 = 12.5%
--   $50 · 8 seats: 35 of 400 =  8.8%
--
-- The 8-seat tables are consistently the better deal for a player, and the
-- $50 · 8 table is the best of all. Worth knowing, if it was not intended.

UPDATE rooms SET prizes = ARRAY[115, 95, 85, 70]::BIGINT[]
 WHERE name = '🟡 $50 Table · 8 seats';
