import { useState } from 'react';

import { HowToPlay } from './HowToPlay';
import { api } from '../lib/api';
import { useAuth } from '../lib/useAuth';

/**
 * Shown once, the first time a player arrives, and not dismissable by clicking
 * away: they have to read the rules and say so before the game will let them in.
 * The acceptance is recorded on the profile, so it survives a new device.
 */
export function RulesGate() {
  const { refresh } = useAuth();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const accept = async () => {
    setBusy(true);
    setError(null);
    try {
      await api.acceptRules();
      await refresh();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not save that. Try again.');
      setBusy(false);
    }
  };

  return (
    <div className="modal-backdrop gate" role="presentation">
      <div className="modal" role="dialog" aria-modal="true" aria-label="How to play">
        <div className="modal-head">
          <span className="modal-title">🐎 Before you play</span>
        </div>

        <div className="modal-body">
          {error && <div className="error">{error}</div>}
          <HowToPlay />
        </div>

        <div className="modal-foot">
          <button className="btn btn-block" disabled={busy} onClick={() => void accept()}>
            {busy ? 'One moment…' : 'I understand — let me play'}
          </button>
        </div>
      </div>
    </div>
  );
}
