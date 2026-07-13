-- The balance never updated by itself because profiles was not in the Realtime
-- publication. A hand settles inside the database with no request from the
-- player's browser, so if the row change is not broadcast, nothing tells them
-- they just won. They had to reload to see their own winnings.

ALTER PUBLICATION supabase_realtime ADD TABLE profiles;

-- UPDATE events only carry the columns needed to identify the row unless the
-- table says otherwise. FULL means the payload always contains the new balance,
-- so the client can use it directly instead of re-fetching.
ALTER TABLE profiles REPLICA IDENTITY FULL;
