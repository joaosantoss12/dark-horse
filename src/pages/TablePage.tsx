import { useEffect, useState } from 'react';
import { Link, useParams } from 'react-router-dom';

import { PlayingCard } from '../components/PlayingCard';
import { api, type Room } from '../lib/api';
import { useAuth } from '../lib/useAuth';
import { useTables } from '../lib/useRoom';

const MEDALS = ['🥇', '🥈', '🥉', '🏅'];
const ORDINALS = ['1st', '2nd', '3rd', '4th', '5th', '6th', '7th', '8th'];

const HAND_LABEL: Record<number, string> = { 2: 'Three of a Kind', 1: 'Crown' };
const handLabel = (p: { category: number | null; score: number | null }) =>
  p.category != null && HAND_LABEL[p.category] ? HAND_LABEL[p.category] : `Score ${p.score}`;

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

function status(room: Room, seated: boolean) {
  switch (room.phase) {
    case 'countdown':
      return { title: 'Table full', sub: 'The dealer is shuffling…' };
    case 'dealing':
      return { title: 'Dealing', sub: `Card ${Math.max(1, room.revealed)} of 3` };
    case 'results':
      return { title: 'Final reveal', sub: 'The table resets in a moment' };
    default:
      return {
        title: `${room.players.length} / ${room.seats} seated`,
        sub: seated ? 'Waiting for the table to fill…' : 'Take a seat to join the next deal',
      };
  }
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

  // join and leave both return the player's new balance. Use it straight away
  // rather than waiting for the Realtime round trip -- the header should change
  // the instant the buy-in is taken.
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

  const info = status(room, seated);

  // At the reveal, rank order is what people want to read. Before it, seat order.
  const bySeat = new Map(room.players.map((p) => [p.seat, p]));
  const order =
    room.phase === 'results'
      ? [...room.players].sort((a, b) => (a.place ?? 99) - (b.place ?? 99)).map((p) => p.seat)
      : Array.from({ length: room.seats }, (_, i) => i);

  const freeSeats = room.seats - room.players.length;

  // The seat list is tall, so what the player came here to do -- sit down, and
  // see what it pays -- goes above it rather than below the fold.
  const actionBar = (
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

      {/* Admin-only: fill the empty seats so a full deal can be demoed alone. */}
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
  );

  const prizeStrip = (
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
  );

  return (
    <>
      <Link to="/" className="link back">
        ← All tables
      </Link>

      {error && <div className="error">{error}</div>}

      {actionBar}
      {prizeStrip}

      <div className="stage">
        <div className="stage-head">
          <div className="stage-status">{room.name}</div>
          {room.phase === 'countdown' && room.startsInMs != null ? (
            <Countdown ms={room.startsInMs} />
          ) : (
            <div className="stage-title">{info.title}</div>
          )}
          <div className="stage-sub">{info.sub}</div>
        </div>

        <div className="seats">
          {order.map((seatIndex) => {
            const player = bySeat.get(seatIndex);

            if (!player) {
              return (
                <div key={seatIndex} className="seat empty">
                  <div className="avatar">{seatIndex + 1}</div>
                  <div className="seat-info">
                    <div className="seat-name">Empty seat</div>
                  </div>
                  <div className="hand">
                    {[0, 1, 2].map((i) => (
                      <PlayingCard key={i} card={null} />
                    ))}
                  </div>
                </div>
              );
            }

            const you = player.userId === profile.id;
            const won = player.won ?? 0;

            return (
              <div
                key={seatIndex}
                className={`seat ${you ? 'you' : ''} ${room.phase === 'results' && won > 0 ? 'winner' : ''}`}
              >
                {room.phase === 'results' ? (
                  <div className="place">{MEDALS[(player.place ?? 9) - 1] ?? player.place}</div>
                ) : player.avatarUrl ? (
                  <img className="avatar" src={player.avatarUrl} alt="" />
                ) : (
                  <div className="avatar">{player.name.charAt(0).toUpperCase()}</div>
                )}

                <div className="seat-info">
                  <div className="seat-name">
                    {player.name}
                    {you && <span className="tag">You</span>}
                    {player.isBot && <span className="tag bot">Bot</span>}
                  </div>
                  {room.phase === 'results' && (
                    <div className="seat-sub">
                      {handLabel(player)} · total {player.total}
                      {player.isSplit && <span className="tag">Split</span>}
                    </div>
                  )}
                </div>

                <div className="hand">
                  {player.cards.map((card, i) => (
                    <PlayingCard key={i} card={card} />
                  ))}
                </div>

                {room.phase === 'results' && (
                  <div className={`won ${won > 0 ? '' : 'zero'}`}>{won > 0 ? `+${won}` : '—'}</div>
                )}
              </div>
            );
          })}
        </div>
      </div>

    </>
  );
}
