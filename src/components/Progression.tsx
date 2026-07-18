import { useEffect, useState } from 'react';

import { api } from '../lib/api';
import { cash } from '../lib/money';

/** Five levels, a new one every 100 games played. */
export const LEVELS = [
  { min: 0, name: 'Rookie', icon: '🐣' },
  { min: 100, name: 'Player', icon: '🎯' },
  { min: 200, name: 'Shark', icon: '🦈' },
  { min: 300, name: 'Whale', icon: '🐋' },
  { min: 400, name: 'Dark Horse', icon: '🐎' },
];

export function levelFor(gamesPlayed: number) {
  let idx = 0;
  for (let i = 0; i < LEVELS.length; i++) if (gamesPlayed >= LEVELS[i].min) idx = i;
  const current = LEVELS[idx];
  const next = LEVELS[idx + 1] ?? null;
  return { idx, current, next };
}

function Level({ gamesPlayed }: { gamesPlayed: number }) {
  const { idx, current, next } = levelFor(gamesPlayed);
  const pct = next
    ? Math.min(100, Math.round(((gamesPlayed - current.min) / (next.min - current.min)) * 100))
    : 100;

  return (
    <div className="panel level-card">
      <div className="level-head">
        <span className="level-icon">{current.icon}</span>
        <div className="level-id">
          <div className="level-name">
            Level {idx + 1} · {current.name}
          </div>
          <div className="level-sub">{gamesPlayed.toLocaleString()} games played</div>
        </div>
      </div>

      {next ? (
        <>
          <div className="wallet-goal-line">
            <span>
              {next.icon} {next.name} at {next.min}
            </span>
            <b>{next.min - gamesPlayed} to go</b>
          </div>
          <div className="wallet-progress">
            <div className="wallet-progress-bar" style={{ width: `${pct}%` }} />
          </div>
        </>
      ) : (
        <div className="wallet-goal done">🏆 Top level reached — you are a Dark Horse.</div>
      )}

      <div className="level-ladder">
        {LEVELS.map((l, i) => (
          <div key={l.name} className={`level-pip ${i <= idx ? 'on' : ''}`} title={l.name}>
            <span>{l.icon}</span>
            <em>{l.name}</em>
          </div>
        ))}
      </div>
    </div>
  );
}

function Referrals() {
  const [ref, setRef] = useState<Awaited<ReturnType<typeof api.referrals>> | null>(null);
  const [copied, setCopied] = useState(false);

  useEffect(() => {
    void api.referrals().then(setRef).catch(() => {});
  }, []);

  if (!ref) return null;

  const link = `${window.location.origin}/?ref=${ref.code}`;

  const copy = async () => {
    try {
      await navigator.clipboard.writeText(link);
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    } catch {
      // Clipboard blocked; the field is selectable as a fallback.
    }
  };

  return (
    <div className="panel">
      <p className="muted" style={{ fontSize: 14, marginBottom: 12 }}>
        Invite friends. Every friend who signs up with your link earns you{' '}
        <b className="gold">{cash(ref.demoPerFriendCents)}</b> demo balance.
      </p>

      <div className="field">
        <label>Your invite link</label>
        <div className="ref-link">
          <input className="input" readOnly value={link} onFocus={(e) => e.target.select()} />
          <button className="btn btn-sm" onClick={() => void copy()}>
            {copied ? 'Copied!' : 'Copy'}
          </button>
        </div>
      </div>

      <div className="wallet-goal-line">
        <span>{ref.count} friend{ref.count === 1 ? '' : 's'} invited</span>
        <b>{cash(ref.totalDemoEarnedCents)} demo earned</b>
      </div>
    </div>
  );
}

/** Levels and referrals, shown on the profile. */
export function Progression({ gamesPlayed }: { gamesPlayed: number }) {
  return (
    <>
      <div className="section-title">Your level</div>
      <Level gamesPlayed={gamesPlayed} />

      <div className="section-title">Invite friends</div>
      <Referrals />
    </>
  );
}
