import { Link } from 'react-router-dom';

import { HowToPlay } from '../components/HowToPlay';

import { useTables } from '../lib/useRoom';
import { useAuth } from '../lib/useAuth';
import type { Room } from '../lib/api';

function badge(room: Room, seated: boolean) {
  if (room.phase !== 'waiting') return { text: 'In play', className: 'pill live' };
  if (seated) return { text: 'Seated', className: 'pill seated' };
  if (room.players.length >= room.seats) return { text: 'Full', className: 'pill' };
  return { text: 'Open', className: 'pill' };
}

export function LobbyPage() {
  const { rooms, error } = useTables();
  const { profile } = useAuth();

  if (error) return <div className="error">{error}</div>;
  if (!rooms) return <div className="empty">Loading tables…</div>;

  return (
    <>
      <div className="section-title">Tables</div>

      {rooms.length === 0 && <div className="empty">No tables are open right now.</div>}

      <div className="table-grid">
        {rooms.map((room) => {
          const seated = room.players.some((p) => p.userId === profile?.id);
          const tag = badge(room, seated);

          return (
            <Link key={room.id} to={`/table/${room.id}`} className="table-card">
              <div className="table-card-top">
                <span className="table-name">{room.name}</span>
                <span className={tag.className}>{tag.text}</span>
              </div>

              <div className="table-meta">
                <div>
                  <span>Buy-in</span>
                  <b>{room.buyIn}</b>
                </div>
                <div>
                  <span>Top prize</span>
                  <b>{room.prizes[0]}</b>
                </div>
                <div>
                  <span>Pays</span>
                  <b>
                    {room.prizes.length} of {room.seats}
                  </b>
                </div>
              </div>

              <div className="seat-dots">
                {Array.from({ length: room.seats }, (_, i) => (
                  <span key={i} className={`seat-dot ${i < room.players.length ? 'on' : ''}`} />
                ))}
              </div>
              <div className="seat-count">
                {room.players.length} / {room.seats} seated
              </div>
            </Link>
          );
        })}
      </div>

      <div className="section-title">How it works</div>
      <div className="panel">
        <HowToPlay />
      </div>
    </>
  );
}
