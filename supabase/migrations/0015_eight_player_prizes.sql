-- The 8-player prize structure the client specified.
--
--   8-player, $20 buy-in: pot 160 -> 1st 50, 2nd 40, 3rd 30, 4th 25, fee 15
--
-- Note the rake is not the same on both tables:
--   4 seats: fee 10 of 80  = 12.5%
--   8 seats: fee 15 of 160 =  9.4%
-- The 8-seat table is the better deal for a player. Deliberate or not, it is the
-- client's call -- but it is worth knowing.
--
-- The $50 tables keep the same shape as their $20 counterparts, scaled x2.5, and
-- every figure still lands on a whole number:
--   $50 · 4 seats: pot 200 -> 95 / 80,            fee 25  (12.5%)
--   $50 · 8 seats: pot 400 -> 125 / 100 / 75 / 62, fee 38 (9.5%)

UPDATE rooms SET prizes = ARRAY[50, 40, 30, 25]::BIGINT[]
 WHERE name = '🟢 $20 Table · 8 seats';

UPDATE rooms SET prizes = ARRAY[125, 100, 75, 62]::BIGINT[]
 WHERE name = '🟡 $50 Table · 8 seats';
