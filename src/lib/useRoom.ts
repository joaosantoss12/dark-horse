import { useEffect, useRef, useState } from 'react';

import {
  api, getCached, seedRoomsFromLobby, setCached, takeLobbyPrefetch, watchTables, type Room,
} from './api';
import { timed } from './perf';

/**
 * Keeps a view of the tables fresh.
 *
 * Two things move a table: a row changing (someone sat down, a hand was dealt),
 * which Realtime tells us about; and the clock (the dealer turns the next card
 * 1.6s later), which no row change announces. So we listen for the first and
 * poll fast only while a hand is actually in play -- an idle lobby makes no
 * polling requests at all.
 *
 * The first render comes from the in-memory cache when there is one, so coming
 * back to the lobby is instant instead of blanking out for a round trip.
 */
export function useTables(roomId?: number) {
  const key = roomId ? `room:${roomId}` : 'lobby';

  const [rooms, setRooms] = useState<Room[] | null>(() => getCached(key));
  const [error, setError] = useState<string | null>(null);

  // The ticker reads the phase through a ref: reading state from inside the
  // interval would see whatever it was when the effect ran, forever.
  const latest = useRef<Room[] | null>(rooms);
  const inFlight = useRef(false);

  useEffect(() => {
    let alive = true;

    const apply = (next: Room[]) => {
      if (!alive) return;
      latest.current = next;
      setCached(key, next);
      // One lobby response describes every table, so opening one needs no
      // request of its own.
      if (!roomId) seedRoomsFromLobby(next);
      setRooms(next);
      setError(null);
    };

    const load = async () => {
      if (inFlight.current) return;
      inFlight.current = true;
      try {
        apply(
          roomId
            ? [await timed(`fetch table ${roomId}`, () => api.room(roomId))]
            : await timed('fetch lobby', () => api.lobby()),
        );
      } catch (err) {
        if (alive) setError(err instanceof Error ? err.message : 'Could not load the tables.');
      } finally {
        inFlight.current = false;
      }
    };

    // The lobby request may already be in flight from before React mounted.
    const prefetched = !roomId ? takeLobbyPrefetch() : null;
    if (prefetched) {
      inFlight.current = true;
      void prefetched
        .then((next) => next.length && apply(next))
        .finally(() => {
          inFlight.current = false;
        });
    } else {
      void load();
    }

    const stopWatching = watchTables(() => void load());

    // A card lands every 550ms during a deal, so poll faster than that or flips
    // get skipped and the dealer appears to jump seats. Also poll while a table
    // is counting down to fill, or its clock would sit frozen and the refund
    // would arrive without warning. An idle, empty lobby polls not at all.
    const ticker = setInterval(() => {
      const busy = latest.current?.some((r) => r.phase !== 'waiting' || r.fillsInMs != null);
      if (busy) void load();
    }, 350);

    // Safety net for a dropped Realtime socket. Realtime is what actually keeps
    // the lobby current, so this only needs to be rare -- it was firing every 5s
    // and re-fetching a lobby that had not changed.
    const slow = setInterval(() => void load(), 20_000);

    return () => {
      alive = false;
      stopWatching();
      clearInterval(ticker);
      clearInterval(slow);
    };
  }, [roomId, key]);

  return { rooms, error };
}
