import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';

import { HowToPlay } from '../components/HowToPlay';
import { api, type Limits, type Mode, type Room } from '../lib/api';
import { money } from '../lib/money';
import { useAuth } from '../lib/useAuth';
import { useTables } from '../lib/useRoom';

function badge(room: Room, seated: boolean) {
  if (room.phase !== 'waiting') return { text: 'In play', className: 'pill live' };
  if (seated) return { text: 'Seated', className: 'pill seated' };
  if (room.players.length >= room.seats) return { text: 'Full', className: 'pill' };
  return { text: 'Open', className: 'pill' };
}

function TableCard({ room, youId, locked }: { room: Room; youId: string; locked: boolean }) {
  const seated = room.players.some((p) => p.userId === youId);
  const tag = badge(room, seated);

  const card = (
    <>
      <div className="table-card-top">
        <span className="table-name">{room.name}</span>
        <span className={tag.className}>{tag.text}</span>
      </div>

      <div className="table-meta">
        <div>
          <span>Buy-in</span>
          <b>{money(room.buyIn)}</b>
        </div>
        <div>
          <span>Top prize</span>
          <b>{money(room.prizes[0])}</b>
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
    </>
  );

  // A locked table is shown, not hidden: players should see what they are
  // missing. It just cannot be opened.
  if (locked) {
    return (
      <div className={`table-card locked ${room.mode}`} aria-disabled="true">
        {card}
        <div className="locked-veil">
          <span>Coming soon</span>
        </div>
      </div>
    );
  }

  return (
    <Link to={`/table/${room.id}`} className={`table-card ${room.mode}`}>
      {card}
    </Link>
  );
}

function Section({
  mode,
  rooms,
  youId,
  limits,
}: {
  mode: Mode;
  rooms: Room[];
  youId: string;
  limits: Limits | null;
}) {
  if (rooms.length === 0) return null;

  const cashLocked = mode === 'cash' && !limits?.cashEnabled;
  const outOfHands = mode === 'free' && limits != null && limits.freeHandsLeft <= 0;

  return (
    <section className="mode-section">
      <div className="mode-head">
        <div className="section-title">{mode === 'free' ? 'Free tables' : 'Real money'}</div>

        {mode === 'free' && limits && (
          <div className={`hands-left ${outOfHands ? 'spent' : ''}`}>
            <b>{limits.freeHandsLeft}</b> of {limits.freeHandsPerDay} free hands left today
          </div>
        )}

        {cashLocked && <div className="hands-left">Not open yet</div>}
      </div>

      {outOfHands && (
        <div className="notice limit-notice">
          You have used all {limits.freeHandsPerDay} of today's free hands. They reset at midnight
          UTC.
        </div>
      )}

      <div className="table-grid">
        {rooms.map((room) => (
          <TableCard key={room.id} room={room} youId={youId} locked={cashLocked || outOfHands} />
        ))}
      </div>
    </section>
  );
}

export function LobbyPage() {
  const { rooms, error } = useTables();
  const { profile } = useAuth();
  const [limits, setLimits] = useState<Limits | null>(null);

  // The count only moves when a hand is dealt, so refreshing it with the lobby
  // is enough.
  useEffect(() => {
    void api.limits().then(setLimits).catch(() => {});
  }, [rooms]);

  if (error) return <div className="error">{error}</div>;
  if (!rooms || !profile) return <div className="empty">Loading tables…</div>;

  const free = rooms.filter((r) => r.mode !== 'cash');
  const cash = rooms.filter((r) => r.mode === 'cash');

  return (
    <>
      <Section mode="free" rooms={free} youId={profile.id} limits={limits} />
      <Section mode="cash" rooms={cash} youId={profile.id} limits={limits} />

      {rooms.length === 0 && <div className="empty">No tables are open right now.</div>}

      <div className="section-title">How it works</div>
      <div className="panel">
        <HowToPlay />
      </div>
    </>
  );
}
