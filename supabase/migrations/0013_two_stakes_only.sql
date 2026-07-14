-- Launch with two stakes, not four.
--
-- The 100 and 500 tables go; 20 and 50 stay and get names a player can read at a
-- glance. More limits can be added from the admin panel once the game has been
-- running smoothly.
--
-- Tables that have never been played are deleted outright. Any that have been
-- are retired instead (hidden, but their rounds kept), because deleting a room
-- cascades to its rounds and would erase the record behind every prize paid
-- there. Same rule as dh_admin_delete_room.

-- Anyone still waiting at a table that is about to vanish gets their buy-in back.
DO $$
DECLARE
  v_seat RECORD;
  v_balance BIGINT;
BEGIN
  FOR v_seat IN
    SELECT s.user_id, m.buy_in
      FROM seats s
      JOIN rooms m ON m.id = s.room_id
     WHERE s.user_id IS NOT NULL
       AND m.name IN ('100 · 4 seats', '100 · 8 seats', '500 · 4 seats', '500 · 8 seats')
  LOOP
    UPDATE profiles SET balance = balance + v_seat.buy_in
    WHERE id = v_seat.user_id
    RETURNING balance INTO v_balance;

    INSERT INTO ledger (user_id, kind, amount, balance_after, note)
    VALUES (v_seat.user_id, 'refund', v_seat.buy_in, v_balance, 'Table removed');
  END LOOP;
END $$;

DELETE FROM seats
 WHERE room_id IN (
   SELECT id FROM rooms
    WHERE name IN ('100 · 4 seats', '100 · 8 seats', '500 · 4 seats', '500 · 8 seats')
 );

-- Retire the ones with history...
UPDATE rooms SET is_active = FALSE, is_deleted = TRUE
 WHERE name IN ('100 · 4 seats', '100 · 8 seats', '500 · 4 seats', '500 · 8 seats')
   AND EXISTS (SELECT 1 FROM rounds r WHERE r.room_id = rooms.id);

-- ...and delete the ones without.
DELETE FROM rooms
 WHERE name IN ('100 · 4 seats', '100 · 8 seats', '500 · 4 seats', '500 · 8 seats')
   AND NOT EXISTS (SELECT 1 FROM rounds r WHERE r.room_id = rooms.id);

-- Clear names for the two that remain.
UPDATE rooms SET name = '🟢 $20 Table · 4 seats', sort_order = 1 WHERE name = '20 · 4 seats';
UPDATE rooms SET name = '🟢 $20 Table · 8 seats', sort_order = 2 WHERE name = '20 · 8 seats';
UPDATE rooms SET name = '🟡 $50 Table · 4 seats', sort_order = 3 WHERE name = '50 · 4 seats';
UPDATE rooms SET name = '🟡 $50 Table · 8 seats', sort_order = 4 WHERE name = '50 · 8 seats';
