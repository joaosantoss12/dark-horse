import { useEffect, useState } from 'react';
import { Link, useParams } from 'react-router-dom';

import { PokerTable } from '../components/PokerTable';
import { api, type Room } from '../lib/api';
import { useAuth } from '../lib/useAuth';
import { useTables } from '../lib/useRoom';

const MEDALS = ['🥇', '🥈', '🥉', '🏅'];
const ORDINALS = ['1st', '2nd', '3rd', '4th'];

function Countdown({ ms }: { ms: number }) {
  const [left, setLeft] = useState(ms);

  useEffect(() => {
    setLeft(ms);
    const target = Date.now() + ms;
    const id = setInterval(() => setLeft(Math.max(0, target - Date.now())), 100);
    return () => clearInterval(id);
  }, [ms]);

  return <div className="countdown">{Math.ceil(left / 1000)}</div>;
}

/** What the dealer's spot in the middle of the table says. */
function Dealer({ room, seated }: { room: Room; seated: boolean }) {
  if (room.phase === 'countdown' && room.startsInMs != null) {
    return (
      <>
        <div className="pt-status">Shuffling</div>
        <Countdown ms={room.startsInMs} />
      </>
    );
  }

  if (room.phase === 'dealing') {
    const total = room.seats * 3;
    const done = room.flips >= total;

    return (
      <>
        <div className="pt-status">Deal {room.deal} of 3</div>
        <div className="pt-pips">
          {[1, 2, 3].map((n) => (
            <span key={n} className={`pt-pip ${n < room.deal ? 'done' : ''} ${n === room.deal ? 'on' : ''}`} />
          ))}
        </div>
        <div className="pt-sub">
          {done
            ? 'Scoring…'
            : `Dealing card ${Math.min(3, Math.floor(room.flips / room.seats) + 1)} · ${room.flips} of ${total}`}
        </div>
      </>
    );
  }

  if (room.phase === 'results') {
    return (
      <>
        <div className="pt-status">Final</div>
        <div className="pt-headline">Winners paid</div>
        <div className="pt-sub">The table resets in a moment</div>
      </>
    );
  }

  return (
    <>
      <div className="pt-status">Waiting</div>
      <div className="pt-headline">
        {room.players.length} / {room.seats}
      </div>
      <div className="pt-sub">
        {seated ? 'Waiting for the table to fill…' : 'Take a seat for the next hand'}
      </div>
    </>
  );
}

export function TablePage() {
  const { id } = useParams();
  const roomId = Number(id);
  const { rooms, error: loadError } = useTables(roomId);
  const { profile, setBalance } = useAuth();

  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const room = rooms?.[0];

  if (loadError) return <div className="error">{loadError}</div>;
  if (!room || !profile) return <div className="empty">Loading table…</div>;

  const seated = room.players.some((p) => p.userId === profile.id);
  const full = room.players.length >= room.seats;
  const waiting = room.phase === 'waiting';
  const freeSeats = room.seats - room.players.length;

  const act = async (fn: () => Promise<unknown>) => {
    setBusy(true);
    setError(null);
    try {
      const result = (await fn()) as { balance?: number } | null;
      if (typeof result?.balance === 'number') setBalance(result.balance);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Something went wrong.');
    } finally {
      setBusy(false);
    }
  };

  return (
    <>
      <div className="table-head">
        <Link to="/" className="link back">
          ← All tables
        </Link>
        <div className="table-title">{room.name}</div>
      </div>

      {error && <div className="error">{error}</div>}

      <div className="actions sticky-actions">
        {waiting && !seated && !full && (
          <button className="btn btn-block" disabled={busy} onClick={() => act(() => api.join(room.id))}>
            Take a seat · {room.buyIn} pts
          </button>
        )}

        {waiting && seated && (
          <button
            className="btn btn-ghost btn-block"
            disabled={busy}
            onClick={() => act(() => api.leave(room.id))}
          >
            Leave table · buy-in refunded
          </button>
        )}

        {/* Admin-only: fill the empty seats so a full hand can be demoed alone. */}
        {profile.is_admin && waiting && seated && !full && (
          <button
            className="btn btn-ghost btn-block"
            disabled={busy}
            onClick={() => act(() => api.fillBots(room.id))}
          >
            🤖 Fill the last {freeSeats} seat{freeSeats === 1 ? '' : 's'} with bots
          </button>
        )}

        {waiting && !seated && full && (
          <button className="btn btn-block" disabled>
            Table full
          </button>
        )}

        {!waiting && (
          <button className="btn btn-block" disabled>
            {seated ? 'You are in this hand' : 'Hand in progress'}
          </button>
        )}
      </div>

      <div className="prize-strip">
        {room.prizes.map((prize, i) => (
          <div key={i} className="prize">
            <span className="prize-place">
              {MEDALS[i]} {ORDINALS[i]}
            </span>
            <b>+{prize}</b>
          </div>
        ))}
        <div className="prize muted">
          <span className="prize-place">Buy-in</span>
          <b>{room.buyIn}</b>
        </div>
      </div>

      <PokerTable room={room} youId={profile.id}>
        <Dealer room={room} seated={seated} />
      </PokerTable>

      {room.phase === 'results' && (
        <>
          <div className="section-title">Result</div>
          <div className="panel">
            {[...room.players]
              .sort((a, b) => (a.place ?? 99) - (b.place ?? 99))
              .map((player) => (
                <div key={player.seat} className="row">
                  <div className="place">{MEDALS[(player.place ?? 9) - 1] ?? player.place}</div>
                  <div className="row-main">
                    <div className="row-title">
                      {player.name}
                      {player.userId === profile.id && <span className="tag">You</span>}
                      {player.isBot && <span className="tag bot">Bot</span>}
                    </div>
                    <div className="row-sub">
                      {player.deals.map((d) => d.value).join(' + ')} = <b>{player.totalValue}</b>
                    </div>
                  </div>
                  <div className={`amount ${(player.won ?? 0) > 0 ? 'up' : ''}`}>
                    {(player.won ?? 0) > 0 ? `+${player.won}` : '—'}
                  </div>
                </div>
              ))}
          </div>
        </>
      )}
    </>
  );
}
