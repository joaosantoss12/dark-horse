import { useState, type FormEvent } from 'react';
import { useNavigate } from 'react-router-dom';

import { SupportLink } from '../components/Support';
import { HorseMark } from '../components/icons';
import { supabase } from '../lib/supabase';

/**
 * Where the link in the reset email lands.
 *
 * Supabase signs the player in with a short-lived recovery session when they
 * follow the link, so by the time this renders they are authenticated -- but
 * only to do one thing: set a new password.
 */
export function ResetPasswordPage() {
  const navigate = useNavigate();
  const [password, setPassword] = useState('');
  const [confirm, setConfirm] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState(false);

  const submit = async (event: FormEvent) => {
    event.preventDefault();
    setError(null);

    if (password.length < 8) {
      setError('Use at least 8 characters.');
      return;
    }
    if (password !== confirm) {
      setError('The two passwords do not match.');
      return;
    }

    setBusy(true);
    try {
      const { error } = await supabase.auth.updateUser({ password });
      if (error) throw error;

      setDone(true);
      // The recovery session is a real session, so they are already in.
      setTimeout(() => navigate('/', { replace: true }), 1500);
    } catch (err) {
      setError(
        err instanceof Error
          ? err.message
          : 'That link may have expired. Ask for a new one and try again.',
      );
      setBusy(false);
    }
  };

  return (
    <div className="auth-shell">
      <div className="auth-card">
        <div className="auth-brand">
          <div className="brand-mark">
            <HorseMark />
          </div>
          <h1>NEW PASSWORD</h1>
          <p className="muted">Choose something you will remember.</p>
        </div>

        {error && <div className="error">{error}</div>}
        {done && <div className="notice">Password changed. Taking you to the tables…</div>}

        <form onSubmit={submit}>
          <div className="field">
            <label htmlFor="new-password">New password</label>
            <input
              id="new-password"
              className="input"
              type="password"
              required
              autoFocus
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              autoComplete="new-password"
            />
          </div>

          <div className="field">
            <label htmlFor="confirm-password">Confirm it</label>
            <input
              id="confirm-password"
              className="input"
              type="password"
              required
              value={confirm}
              onChange={(e) => setConfirm(e.target.value)}
              autoComplete="new-password"
            />
          </div>

          <button className="btn btn-block" disabled={busy || done} type="submit">
            {busy ? 'Saving…' : 'Set new password'}
          </button>
        </form>

        <SupportLink label="Link not working? Contact support on Telegram" />
      </div>
    </div>
  );
}
