import { useCallback, useEffect, useState } from 'react';

import { Modal } from '../components/Modal';
import { api, type Mode } from '../lib/api';
import { useAuth } from '../lib/useAuth';

interface RoomRow {
  id: number;
  name: string;
  seats: number;
  buy_in: number;
  prizes: number[];
  is_active: boolean;
  mode: Mode;
  rounds_played: number;
}

interface RoomForm {
  id: number | null;
  name: string;
  seats: number;
  buyIn: number;
  prizes: number[];
  isActive: boolean;
  mode: Mode;
}

const blank: RoomForm = {
  id: null, name: '', seats: 4, buyIn: 100, prizes: [250, 100], isActive: true, mode: 'free',
};

/** A 4-seat table pays 2 places, an 8-seat table pays 4. Keep the form honest. */
function resize(form: RoomForm, seats: number): RoomForm {
  const slots = seats === 8 ? 4 : 2;
  return { ...form, seats, prizes: Array.from({ length: slots }, (_, i) => form.prizes[i] ?? 0) };
}

function RoomEditor({ initial, onDone }: { initial: RoomForm; onDone: () => void }) {
  const [form, setForm] = useState(initial);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const pot = form.buyIn * form.seats;
  const payout = form.prizes.reduce((a, b) => a + b, 0);
  const house = pot - payout;

  const save = async () => {
    setBusy(true);
    setError(null);
    try {
      await api.admin.saveRoom(form);
      onDone();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not save the table.');
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="editor">
      {error && <div className="error">{error}</div>}

      <div className="field">
        <label>Table name</label>
        <input
          className="input"
          value={form.name}
          placeholder="Grandstand"
          onChange={(e) => setForm({ ...form, name: e.target.value })}
        />
      </div>

      <div className="field">
        <label>Mode</label>
        <select
          className="input"
          value={form.mode}
          onChange={(e) => setForm({ ...form, mode: e.target.value as Mode })}
        >
          <option value="free">Free — points, subject to the daily limit</option>
          <option value="cash">Real money — locked until licensed</option>
        </select>
        {form.mode === 'cash' && (
          <p className="field-note">
            Real-money tables can be configured but cannot be joined: the database refuses to seat
            anyone until the operator is licensed.
          </p>
        )}
      </div>

      <div className="grid-2">
        <div className="field">
          <label>Seats</label>
          <select
            className="input"
            value={form.seats}
            onChange={(e) => setForm(resize(form, Number(e.target.value)))}
          >
            <option value={4}>4 players — pays top 2</option>
            <option value={8}>8 players — pays top 4</option>
          </select>
        </div>
        <div className="field">
          <label>Buy-in (points)</label>
          <input
            className="input"
            type="number"
            min={0}
            value={form.buyIn}
            onChange={(e) => setForm({ ...form, buyIn: Number(e.target.value) })}
          />
        </div>
      </div>

      <div className="field">
        <label>Prizes — 1st, 2nd{form.seats === 8 ? ', 3rd, 4th' : ''}</label>
        <div className={form.seats === 8 ? 'grid-4' : 'grid-2'}>
          {form.prizes.map((prize, i) => (
            <input
              key={i}
              className="input"
              type="number"
              min={0}
              value={prize}
              onChange={(e) => {
                const prizes = [...form.prizes];
                prizes[i] = Number(e.target.value);
                setForm({ ...form, prizes });
              }}
            />
          ))}
        </div>
      </div>

      <div className={`house-note ${house < 0 ? 'bad' : ''}`}>
        Pot <b>{pot}</b> · pays out <b>{payout}</b> ·{' '}
        {house >= 0 ? (
          <>
            house keeps <b>{house}</b>
          </>
        ) : (
          <>
            house <b>loses {-house}</b> every hand
          </>
        )}
      </div>

      <label className="check">
        <input
          type="checkbox"
          checked={form.isActive}
          onChange={(e) => setForm({ ...form, isActive: e.target.checked })}
        />
        Open in the lobby
      </label>

      <div className="actions row-actions">
        <button className="btn" disabled={busy} onClick={save}>
          {form.id ? 'Save changes' : 'Create table'}
        </button>
        <button className="btn btn-ghost" onClick={onDone}>
          Cancel
        </button>
      </div>
    </div>
  );
}

function Tables() {
  const [rooms, setRooms] = useState<RoomRow[]>([]);
  const [editing, setEditing] = useState<RoomForm | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  const load = useCallback(() => {
    api.admin
      .rooms()
      .then((r) => setRooms(r as RoomRow[]))
      .catch((err) => setError(err.message));
  }, []);

  useEffect(load, [load]);

  // The confirmation has to say what will actually happen, and that depends on
  // whether the table has been played.
  const remove = async (room: RoomRow) => {
    const played = Number(room.rounds_played);

    const warning = played
      ? `"${room.name}" has ${played} hand${played === 1 ? '' : 's'} of history.\n\n` +
      'It will be retired: removed from the lobby and from this list, but its ' +
      'rounds stay in the database so History and the ledger still make sense. ' +
      'Deleting them outright would erase the record behind every prize ever ' +
      'paid at this table.\n\nRetire it?'
      : `"${room.name}" has never been played, so it will be deleted outright.\n\nDelete it?`;

    if (!window.confirm(warning)) return;

    setError(null);
    try {
      const result = await api.admin.deleteRoom(room.id);
      setNotice(result.deleted ? 'Table deleted.' : `Table retired. ${result.rounds} hands kept.`);
      load();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not remove that table.');
    }
  };

  return (
    <>
      {error && <div className="error">{error}</div>}
      {notice && <div className="notice">{notice}</div>}

      <button className="btn btn-block" onClick={() => setEditing(blank)}>
        + New table
      </button>

      {editing && (
        <Modal
          title={editing.id ? 'Edit table' : 'New table'}
          onClose={() => setEditing(null)}
        >
          <RoomEditor
            initial={editing}
            onDone={() => {
              setEditing(null);
              load();
            }}
          />
        </Modal>
      )}

      <div className="panel" style={{ marginTop: 14 }}>
        {rooms.map((room) => (
          <div key={room.id} className="row">
            <div className="row-main">
              <div className="row-title">
                {room.name}
                {room.mode === 'cash' && <span className="tag">Real money</span>}
                {!room.is_active && <span className="tag muted-tag">Closed</span>}
              </div>
              <div className="row-sub">
                {room.seats} seats · buy-in {room.buy_in} · prizes {room.prizes.join(' / ')}
                {Number(room.rounds_played) > 0 && ` · ${room.rounds_played} played`}
              </div>
            </div>
            <button
              className="btn btn-ghost btn-sm"
              onClick={() =>
                setEditing({
                  id: room.id,
                  name: room.name,
                  seats: room.seats,
                  buyIn: room.buy_in,
                  prizes: room.prizes,
                  isActive: room.is_active,
                  mode: room.mode,
                })
              }
            >
              Edit
            </button>
            <button className="btn btn-ghost btn-sm danger" onClick={() => void remove(room)}>
              Delete
            </button>
          </div>
        ))}
      </div>
    </>
  );
}

interface PlayerRow {
  id: string;
  display_name: string;
  email: string;
  balance: number;
  is_admin: boolean;
  is_banned: boolean;
}

function Players() {
  const [players, setPlayers] = useState<PlayerRow[]>([]);
  const [query, setQuery] = useState('');
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(() => {
    api.admin
      .players(query)
      .then((p) => setPlayers(p as PlayerRow[]))
      .catch((err) => setError(err.message));
  }, [query]);

  useEffect(load, [load]);

  const adjust = async (id: string, amount: number) => {
    setError(null);
    try {
      await api.admin.adjust(id, amount, 'Admin panel');
      load();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not adjust that balance.');
    }
  };

  const custom = async (id: string) => {
    const input = window.prompt('Points to add (use a negative number to take points away):');
    if (!input) return;
    const amount = Number(input);
    if (!Number.isInteger(amount) || amount === 0) return;
    await adjust(id, amount);
  };

  const toggleBan = async (player: PlayerRow) => {
    setError(null);
    try {
      await api.admin.setBanned(player.id, !player.is_banned);
      load();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not update that player.');
    }
  };

  return (
    <>
      {error && <div className="error">{error}</div>}

      <input
        className="input"
        placeholder="Search by name or email"
        value={query}
        onChange={(e) => setQuery(e.target.value)}
      />

      <div className="panel" style={{ marginTop: 12 }}>
        {players.length === 0 && <div className="muted">No players found.</div>}

        {players.map((player) => (
          <div key={player.id} className="row">
            <div className="row-main">
              <div className="row-title">
                {player.display_name}
                {player.is_admin && <span className="tag">Admin</span>}
                {player.is_banned && <span className="tag danger">Banned</span>}
              </div>
              <div className="row-sub">
                {player.email} · <b>{player.balance}</b> pts
              </div>
            </div>
            <button className="btn btn-ghost btn-sm" onClick={() => adjust(player.id, 500)}>
              +500
            </button>
            <button className="btn btn-ghost btn-sm" onClick={() => custom(player.id)}>
              ±
            </button>
            <button className="btn btn-ghost btn-sm" onClick={() => toggleBan(player)}>
              {player.is_banned ? 'Unban' : 'Ban'}
            </button>
          </div>
        ))}
      </div>
    </>
  );
}

export function AdminPage() {
  const { profile } = useAuth();
  const [tab, setTab] = useState<'tables' | 'players'>('tables');
  const [stats, setStats] = useState<any>(null);

  useEffect(() => {
    void api.admin.stats().then(setStats).catch(() => { });
  }, []);

  if (!profile?.is_admin) {
    return <div className="empty">This page is for admins.</div>;
  }

  return (
    <>
      <div className="section-title">Overview</div>
      <div className="panel grid-4 stats">
        <div className="stat">
          <b>{stats?.players ?? '—'}</b>
          <span>Players</span>
        </div>
        <div className="stat">
          <b>{stats?.rounds ?? '—'}</b>
          <span>Rounds</span>
        </div>
        <div className="stat">
          <b>{stats?.wagered ?? '—'}</b>
          <span>Wagered</span>
        </div>
        <div className="stat">
          <b>{stats ? stats.wagered - stats.paidOut : '—'}</b>
          <span>House</span>
        </div>
      </div>

      <div className="tabs">
        <button className={`chip ${tab === 'tables' ? 'on' : ''}`} onClick={() => setTab('tables')}>
          Tables
        </button>
        <button className={`chip ${tab === 'players' ? 'on' : ''}`} onClick={() => setTab('players')}>
          Players
        </button>
      </div>

      {tab === 'tables' ? <Tables /> : <Players />}
    </>
  );
}
