-- The prize structure the client specified.
--
--   4-player, $20 buy-in:  pot 80  ->  1st 38, 2nd 32,  platform fee 10
--
-- That is a 12.5% rake, and a fairly flat split between the two winners
-- (54% / 46% of what is paid out). Only that one table was specified, so the
-- other three keep the same 12.5% fee and the same shape:
--
--   4 seats: 1st 54.3%, 2nd 45.7% of the payout
--   8 seats: 1st 36%, 2nd 27%, 3rd 21%, 4th 16% of the payout
--
--   $20 · 4 seats: pot  80, pays 70  (38 / 32)              fee 10
--   $20 · 8 seats: pot 160, pays 140 (50 / 38 / 30 / 22)    fee 20
--   $50 · 4 seats: pot 200, pays 175 (95 / 80)              fee 25
--   $50 · 8 seats: pot 400, pays 350 (126 / 94 / 74 / 56)   fee 50
--
-- Every one of these adds up exactly; nothing rounds away.

UPDATE rooms SET prizes = ARRAY[38, 32]::BIGINT[]
 WHERE name = '🟢 $20 Table · 4 seats';

UPDATE rooms SET prizes = ARRAY[50, 38, 30, 22]::BIGINT[]
 WHERE name = '🟢 $20 Table · 8 seats';

UPDATE rooms SET prizes = ARRAY[95, 80]::BIGINT[]
 WHERE name = '🟡 $50 Table · 4 seats';

UPDATE rooms SET prizes = ARRAY[126, 94, 74, 56]::BIGINT[]
 WHERE name = '🟡 $50 Table · 8 seats';
