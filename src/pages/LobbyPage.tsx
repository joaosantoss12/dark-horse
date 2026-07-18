import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';

import { FloatingChat } from '../components/FloatingChat';
import { HowToPlay } from '../components/HowToPlay';
import { api, type Limits, type Mode, type Room } from '../lib/api';
import { stake } from '../lib/money';
import { notificationsOn, notificationsSupported, requestNotifications, setNotifications } from '../lib/notify';
import { useAuth } from '../lib/useAuth';
import { useTables } from '../lib/useRoom';

function badge(room: Room, seated: boolean) {
  if (room.phase !== 'waiting') return { text: 'In play', className: 'pill live' };
  if (seated) return { text: 'Seated', className: 'pill seated' };
  if (room.players.length >= room.seats) return { text: 'Full', className: 'pill' };
  return { text: 'Open', className: 'pill' };
}

const MODE_CHIP: Record<Mode, string> = {
  free: '🎮 Free play',
  demo: '🎬 Demo',
  cash: '💵 Real money',
};

function TableCard({ room, youId, locked }: { room: Room; youId: string; locked: boolean }) {
  const seated = room.players.some((p) => p.userId === youId);
  const tag = badge(room, seated);

  const card = (
    <>
      <div className="table-card-top">
        <span className="mode-chip">{MODE_CHIP[room.mode]}</span>
        <span className={tag.className}>{tag.text}</span>
      </div>

      <div className="table-name">{room.name}</div>

      <div className="table-meta">
        <div>
          <span>Buy-in</span>
          <b>{stake(room.mode, room.buyIn)}</b>
        </div>
        <div>
          <span>Top prize</span>
          <b>{stake(room.mode, room.prizes[0])}</b>
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
        {room.fillsInMs != null && room.players.length > 0 && (
          <span className="filling"> · filling</span>
        )}
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

  const META: Record<Mode, { icon: string; name: string; sub: string }> = {
    free: { icon: '🎮', name: 'Free Play', sub: 'Play for points. No cash value.' },
    demo: { icon: '🎬', name: 'Demo', sub: 'Play the money tables risk-free — grow it into a real bonus.' },
    cash: { icon: '💵', name: 'Real Money', sub: 'Play with your real-money balance.' },
  };
  const meta = META[mode];

  return (
    <section className={`mode-section ${mode}`}>
      <div className="mode-head">
        <div className="mode-title">
          <span className="mode-title-icon">{meta.icon}</span>
          <div>
            <div className="mode-title-name">{meta.name}</div>
            <div className="mode-title-sub">{meta.sub}</div>
          </div>
        </div>

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

function NotifyToggle() {
  const [on, setOn] = useState(notificationsOn());

  if (!notificationsSupported()) return null;

  const toggle = async () => {
    if (on) {
      setNotifications(false);
      setOn(false);
      return;
    }
    setOn(await requestNotifications());
  };

  return (
    <button className={`notify-toggle ${on ? 'on' : ''}`} onClick={() => void toggle()}>
      {on ? '🔔 Alerts on' : '🔕 Alert me when a player joins a table'}
    </button>
  );
}

export function LobbyPage() {
  const { profile } = useAuth();
  const { rooms, error } = useTables();
  const [limits, setLimits] = useState<Limits | null>(null);

  // The count only moves when a hand is dealt, so refreshing it with the lobby
  // is enough.
  useEffect(() => {
    void api.limits().then(setLimits).catch(() => {});
  }, [rooms]);

  if (error) return <div className="error">{error}</div>;
  if (!rooms || !profile) return <div className="empty">Loading tables…</div>;

  const freeRooms = rooms.filter((r) => r.mode === 'free');
  const demoRooms = rooms.filter((r) => r.mode === 'demo');
  const cashRooms = rooms.filter((r) => r.mode === 'cash');

  return (
    <>
      <div className="lobby-head">
        <NotifyToggle />
      </div>

      <div className="lobby-modes">
        <Section mode="free" rooms={freeRooms} youId={profile.id} limits={limits} />
        <Section mode="demo" rooms={demoRooms} youId={profile.id} limits={limits} />
        <Section mode="cash" rooms={cashRooms} youId={profile.id} limits={limits} />
      </div>

      {rooms.length === 0 && <div className="empty">No tables are open right now.</div>}

      <div className="section-title">How it works</div>
      <div className="panel">
        <HowToPlay />
      </div>

      <FloatingChat roomId={null} title="🌍 Lobby chat" />
    </>
  );
}
