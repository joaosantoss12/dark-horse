import { useCallback, useEffect, useState } from 'react';

import { ConfirmDialog, PromptDialog } from '../components/Dialog';
import { Modal } from '../components/Modal';
import { api, type Mode } from '../lib/api';
import { cash, money } from '../lib/money';
import { useAuth } from '../lib/useAuth';
import { watchOnlineCount } from '../lib/presence';

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
          <option value="cash">Real money — locked until enabled</option>
        </select>
        {form.mode !== 'free' && (
          <p className="field-note">
            Buy-in and prizes are in cents. Real-money tables cannot be joined until the cash switch is enabled.
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
          <label>Buy-in ($)</label>
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
        Pot <b>{money(pot)}</b> · pays out <b>{money(payout)}</b> ·{' '}
        {house >= 0 ? (
          <>
            platform fee <b>{money(house)}</b>
          </>
        ) : (
          <>
            the house <b>loses {money(-house)}</b> every hand
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
  const [removing, setRemoving] = useState<RoomRow | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  const load = useCallback(() => {
    api.admin
      .rooms()
      .then((r) => setRooms(r as RoomRow[]))
      .catch((err) => setError(err.message));
  }, []);

  useEffect(load, [load]);

  const doRemove = async (room: RoomRow) => {
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
                {room.seats} seats · buy-in {money(room.buy_in)} · prizes{' '}
                {room.prizes.map((p) => money(p)).join(' / ')}
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
            <button className="btn btn-ghost btn-sm danger" onClick={() => setRemoving(room)}>
              Delete
            </button>
          </div>
        ))}
      </div>

      {removing && (
        <ConfirmDialog
          title={Number(removing.rounds_played) > 0 ? 'Retire this table?' : 'Delete this table?'}
          tone="danger"
          confirmLabel={Number(removing.rounds_played) > 0 ? 'Retire' : 'Delete'}
          body={
            Number(removing.rounds_played) > 0 ? (
              <>
                <p>
                  <b>{removing.name}</b> has {removing.rounds_played} hand
                  {Number(removing.rounds_played) === 1 ? '' : 's'} of history.
                </p>
                <p>
                  It will be <b>retired</b> — removed from the lobby and this list, but its rounds
                  stay in the database so History and the ledger still make sense. Deleting them
                  outright would erase the record behind every prize ever paid here.
                </p>
              </>
            ) : (
              <p>
                <b>{removing.name}</b> has never been played, so it will be deleted outright.
              </p>
            )
          }
          onConfirm={() => doRemove(removing)}
          onClose={() => setRemoving(null)}
        />
      )}
    </>
  );
}

interface PlayerRow {
  id: string;
  display_name: string;
  email: string;
  balance: number;
  cash_balance: number;
  is_admin: boolean;
  is_banned: boolean;
}

function Players() {
  const [players, setPlayers] = useState<PlayerRow[]>([]);
  const [query, setQuery] = useState('');
  const [error, setError] = useState<string | null>(null);
  // Which player, and which balance, an adjust dialog is open for.
  const [adjusting, setAdjusting] = useState<{
    player: PlayerRow; kind: 'points' | 'cash';
  } | null>(null);

  const load = useCallback(() => {
    api.admin
      .players(query)
      .then((p) => setPlayers(p as PlayerRow[]))
      .catch((err) => setError(err.message));
  }, [query]);

  useEffect(load, [load]);

  const applyPoints = async (id: string, value: string) => {
    await api.admin.adjust(id, Number(value), 'Admin panel');
    load();
  };

  const applyCash = async (id: string, value: string) => {
    // Dollars -> cents, rounded so 12.505 cannot smuggle in a third decimal.
    await api.admin.adjustCash(id, Math.round(Number(value) * 100), 'Admin panel');
    load();
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
        placeholder="Search by name, email, or paste a user ID"
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
                {player.email}
              </div>
              <div className="row-sub">
                Points <b>{money(player.balance)}</b> · Real{' '}
                <b className="gold">{cash(player.cash_balance)}</b>
              </div>
            </div>
            <button
              className="btn btn-ghost btn-sm"
              onClick={() => setAdjusting({ player, kind: 'points' })}
              title="Adjust free-play points"
            >
              ± pts
            </button>
            <button
              className="btn btn-sm"
              onClick={() => setAdjusting({ player, kind: 'cash' })}
              title="Adjust real-money balance"
            >
              ± $
            </button>
            <button className="btn btn-ghost btn-sm" onClick={() => toggleBan(player)}>
              {player.is_banned ? 'Unban' : 'Ban'}
            </button>
          </div>
        ))}
      </div>

      {adjusting?.kind === 'points' && (
        <PromptDialog
          title={`Adjust points · ${adjusting.player.display_name}`}
          body={
            <p className="muted">
              Currently <b>{money(adjusting.player.balance)}</b> in free-play points. Enter a
              positive number to add, negative to remove.
            </p>
          }
          label="Points"
          type="number"
          placeholder="e.g. 500 or -100"
          confirmLabel="Apply"
          validate={(v) =>
            !Number.isInteger(Number(v)) || Number(v) === 0
              ? 'Enter a whole, non-zero number of points.'
              : null
          }
          onSubmit={(v) => applyPoints(adjusting.player.id, v)}
          onClose={() => setAdjusting(null)}
        />
      )}

      {adjusting?.kind === 'cash' && (
        <PromptDialog
          title={`Adjust real money · ${adjusting.player.display_name}`}
          body={
            <p className="muted">
              Currently <b className="gold">{cash(adjusting.player.cash_balance)}</b>. Enter dollars
              to add (e.g. <b>20</b> or <b>12.50</b>), or a negative number for a withdrawal. Only do
              this once the crypto has actually settled on Telegram.
            </p>
          }
          label="Amount ($)"
          type="number"
          placeholder="e.g. 20 or 12.50"
          confirmLabel="Apply"
          validate={(v) =>
            !Number.isFinite(Number(v)) || Number(v) === 0 ? 'Enter a non-zero dollar amount.' : null
          }
          onSubmit={(v) => applyCash(adjusting.player.id, v)}
          onClose={() => setAdjusting(null)}
        />
      )}

    </>
  );
}


/** The dealing pace and the daily free limit, tunable without a deploy. */
function Pace() {
  const [values, setValues] = useState<Record<string, number> | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [saved, setSaved] = useState(false);

  const load = useCallback(() => {
    api.admin.settings().then(setValues).catch((err) => setError(err.message));
  }, []);
  useEffect(load, [load]);

  if (!values) return <div className="muted">Loading…</div>;

  const set = (key: string, value: number) => setValues({ ...values, [key]: value });

  const save = async () => {
    setError(null);
    setSaved(false);
    try {
      for (const [key, value] of Object.entries(values)) {
        await api.admin.setSetting(key, value);
      }
      setSaved(true);
      load();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not save.');
    }
  };

  const gap = values.seat_gap_ms ?? 1800;
  const hold = values.score_hold_ms ?? 4000;
  const countdown = values.countdown_ms ?? 6000;

  // A hand is the shuffle plus three deals; a deal is one card per seat per card.
  const hand = (seats: number) => (countdown + 3 * (seats * 3 * gap + hold)) / 1000;

  const fields: [string, string, string][] = [
    ['seat_gap_ms', 'Card to card (ms)', 'From one card landing to the next. The whole pace.'],
    ['flip_delay_ms', 'Face down for (ms)', 'How long a card sits face down before it turns.'],
    ['score_hold_ms', 'Scores on screen (ms)', 'After the last card of a deal, before the next.'],
    ['countdown_ms', 'Shuffle (ms)', 'The countdown before the first card.'],
  ];

  return (
    <>
      {error && <div className="error">{error}</div>}
      {saved && <div className="notice">Saved. It applies to the next hand dealt.</div>}

      <div className="panel">
        {fields.map(([key, label, note]) => (
          <div key={key} className="field">
            <label htmlFor={key}>{label}</label>
            <input
              id={key}
              className="input"
              type="number"
              min={0}
              value={values[key] ?? 0}
              onChange={(e) => set(key, Number(e.target.value))}
            />
            <p className="field-note">{note}</p>
          </div>
        ))}

        <div className="house-note">
          At this pace a hand takes <b>{hand(4).toFixed(0)}s</b> at a 4-seat table and{' '}
          <b>{hand(8).toFixed(0)}s</b> at an 8-seat one. An 8-seat table deals twice as many
          cards, so it always takes about twice as long.
        </div>

        <button className="btn" onClick={() => void save()}>
          Save
        </button>
      </div>
    </>
  );
}

interface PaymentRow {
  id: number;
  user_id: string;
  display_name: string;
  email: string;
  kind: 'deposit' | 'withdraw';
  method: string;
  status: string;
  cash_balance: number;
  created_at: string;
}

/**
 * The deposit / withdraw queue. Each row is a player who tapped deposit or
 * withdraw and was sent to Telegram. Settle the crypto there, credit or debit
 * their cash on the Players tab, then mark it done here.
 */
/** Credit or debit a real-money balance by pasting the user's id directly. */
function CreditById({ onDone }: { onDone: () => void }) {
  const [userId, setUserId] = useState('');
  const [amount, setAmount] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  const apply = async () => {
    setError(null);
    setNotice(null);
    const cents = Math.round(Number(amount) * 100);
    if (!userId.trim()) {
      setError('Paste the player\'s user id.');
      return;
    }
    if (!Number.isFinite(cents) || cents === 0) {
      setError('Enter a non-zero dollar amount.');
      return;
    }
    setBusy(true);
    try {
      const balance = await api.admin.adjustCash(userId.trim(), cents, 'Deposit credited by admin');
      setNotice(`Done. Their real-money balance is now ${cash(balance)}.`);
      setAmount('');
      onDone();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not credit that account.');
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="panel" style={{ marginBottom: 14 }}>
      <div className="section-title" style={{ marginTop: 0 }}>Credit a deposit by user ID</div>
      <p className="muted" style={{ fontSize: 13, marginBottom: 12 }}>
        Once the crypto has settled on Telegram, paste the player's user id here and enter the
        dollar amount to credit their real-money balance directly.
      </p>
      {error && <div className="error">{error}</div>}
      {notice && <div className="notice">{notice}</div>}
      <div className="grid-2">
        <div className="field">
          <label>User ID</label>
          <input
            className="input"
            placeholder="e.g. 3f2a1c9e-…"
            value={userId}
            onChange={(e) => setUserId(e.target.value)}
          />
        </div>
        <div className="field">
          <label>Amount ($)</label>
          <input
            className="input"
            type="number"
            placeholder="e.g. 20 or 12.50"
            value={amount}
            onChange={(e) => setAmount(e.target.value)}
          />
        </div>
      </div>
      <button className="btn" disabled={busy} onClick={() => void apply()}>
        Credit account
      </button>
    </div>
  );
}

function Payments() {
  const [rows, setRows] = useState<PaymentRow[]>([]);
  const [includeDone, setIncludeDone] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(() => {
    api.admin
      .paymentRequests(includeDone)
      .then((r) => setRows(r as PaymentRow[]))
      .catch((err) => setError(err.message));
  }, [includeDone]);

  useEffect(load, [load]);

  const resolve = async (id: number, status: 'done' | 'cancelled' | 'open') => {
    setError(null);
    try {
      await api.admin.resolvePayment(id, status);
      load();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not update that request.');
    }
  };

  return (
    <>
      <CreditById onDone={load} />

      {error && <div className="error">{error}</div>}

      <p className="muted" style={{ fontSize: 13, marginBottom: 12 }}>
        Nothing here moves money. A player tapped deposit or withdraw and was sent to
        <b> @DH_Support</b>. Settle the crypto there, credit their account above or on the
        Players tab, then mark it done.
      </p>

      <label className="check" style={{ marginBottom: 12 }}>
        <input
          type="checkbox"
          checked={includeDone}
          onChange={(e) => setIncludeDone(e.target.checked)}
        />
        Show handled requests too
      </label>

      <div className="panel">
        {rows.length === 0 && <div className="muted">No requests waiting.</div>}

        {rows.map((r) => (
          <div key={r.id} className="row">
            <div className="row-main">
              <div className="row-title">
                {r.display_name}
                <span className={`tag ${r.kind === 'deposit' ? '' : 'muted-tag'}`}>{r.kind}</span>
                {r.status !== 'open' && <span className="tag muted-tag">{r.status}</span>}
              </div>
              <div className="row-sub">
                {r.email} · holds <b className="gold">{cash(r.cash_balance)}</b> ·{' '}
                {new Date(r.created_at).toLocaleString()}
              </div>
            </div>

            {r.status === 'open' ? (
              <>
                <button className="btn btn-sm" onClick={() => void resolve(r.id, 'done')}>
                  Mark done
                </button>
                <button
                  className="btn btn-ghost btn-sm"
                  onClick={() => void resolve(r.id, 'cancelled')}
                >
                  Cancel
                </button>
              </>
            ) : (
              <button className="btn btn-ghost btn-sm" onClick={() => void resolve(r.id, 'open')}>
                Reopen
              </button>
            )}
          </div>
        ))}
      </div>
    </>
  );
}

/** Platform profit: rake kept from real-money hands, plus the surrounding cash flow. */
function Bank() {
  const [bank, setBank] = useState<any>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    api.admin.bank().then(setBank).catch((err) => setError(err.message));
  }, []);

  if (error) return <div className="error">{error}</div>;
  if (!bank) return <div className="muted">Loading…</div>;

  const net = bank.rakeCents - bank.bonusesCents;

  return (
    <>
      <p className="muted" style={{ fontSize: 13, marginBottom: 12 }}>
        Rake is what the platform actually earns from real-money hands. Deposits, withdrawals and
        referral bonuses are shown for context, not counted as profit on their own.
      </p>

      <div className="panel grid-2 stats" style={{ marginBottom: 14 }}>
        <div className="stat">
          <b className="gold">{cash(bank.rakeCents)}</b>
          <span>Rake collected (real-money tables)</span>
        </div>
        <div className={`stat ${net < 0 ? 'down' : ''}`}>
          <b className={net >= 0 ? 'gold' : ''}>{cash(net)}</b>
          <span>Rake minus referral bonuses granted</span>
        </div>
      </div>

      <div className="panel">
        <div className="row">
          <div className="row-main">
            <div className="row-title">Owed to players</div>
            <div className="row-sub">Sum of every real-money balance right now</div>
          </div>
          <div className="amount">{cash(bank.liabilityCents)}</div>
        </div>
        <div className="row">
          <div className="row-main">
            <div className="row-title">Deposits credited</div>
            <div className="row-sub">Admin-confirmed crypto deposits</div>
          </div>
          <div className="amount up">{cash(bank.depositsCents)}</div>
        </div>
        <div className="row">
          <div className="row-main">
            <div className="row-title">Withdrawals paid out</div>
            <div className="row-sub">Real money sent back to players</div>
          </div>
          <div className="amount">{cash(bank.withdrawalsCents)}</div>
        </div>
        <div className="row">
          <div className="row-main">
            <div className="row-title">Referral bonuses granted</div>
            <div className="row-sub">Real cash paid to referrers when a friend joins</div>
          </div>
          <div className="amount">{cash(bank.bonusesCents)}</div>
        </div>
      </div>
    </>
  );
}

export function AdminPage() {
  const { profile } = useAuth();
  const [tab, setTab] = useState<'tables' | 'players' | 'payments' | 'pace' | 'bank'>('tables');
  const [stats, setStats] = useState<any>(null);
  const [openPayments, setOpenPayments] = useState(0);
  const [online, setOnline] = useState(0);

  useEffect(() => {
    void api.admin.stats().then(setStats).catch(() => { });
    void api.admin.openPaymentCount().then(setOpenPayments).catch(() => { });
  }, [tab]);

  useEffect(() => watchOnlineCount(setOnline), []);

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
          <b>{online}</b>
          <span>Online now</span>
        </div>
        <div className="stat">
          <b>{stats?.activeTables ?? '—'}</b>
          <span>Active tables</span>
        </div>
        <div className="stat">
          <b>{stats?.rounds ?? '—'}</b>
          <span>Rounds</span>
        </div>
        <div className="stat">
          <b>{stats?.pointsInPlay ?? '—'}</b>
          <span>Points in play</span>
        </div>
        <div className="stat">
          <b>{stats ? cash(stats.cashInPlay) : '—'}</b>
          <span>Real $ owed to players</span>
        </div>
        <div className="stat">
          <b>{stats ? stats.wagered - stats.paidOut : '—'}</b>
          <span>House (all modes)</span>
        </div>
      </div>

      <div className="tabs">
        <button className={`chip ${tab === 'tables' ? 'on' : ''}`} onClick={() => setTab('tables')}>
          Tables
        </button>
        <button className={`chip ${tab === 'players' ? 'on' : ''}`} onClick={() => setTab('players')}>
          Players
        </button>
        <button className={`chip ${tab === 'payments' ? 'on' : ''}`} onClick={() => setTab('payments')}>
          Payments
          {openPayments > 0 && <span className="chip-badge">{openPayments}</span>}
        </button>
        <button className={`chip ${tab === 'pace' ? 'on' : ''}`} onClick={() => setTab('pace')}>
          Pace
        </button>
        <button className={`chip ${tab === 'bank' ? 'on' : ''}`} onClick={() => setTab('bank')}>
          Bank
        </button>
      </div>

      {tab === 'tables' && <Tables />}
      {tab === 'players' && <Players />}
      {tab === 'payments' && <Payments />}
      {tab === 'pace' && <Pace />}
      {tab === 'bank' && <Bank />}
    </>
  );
}
