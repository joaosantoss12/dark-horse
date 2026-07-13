import { useState, type FormEvent } from 'react';

import { HorseMark } from '../components/icons';
import { setRemember, supabase } from '../lib/supabase';

export function AuthPage() {
  const [mode, setMode] = useState<'signin' | 'signup'>('signin');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [name, setName] = useState('');
  const [remember, setRememberChoice] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const submit = async (event: FormEvent) => {
    event.preventDefault();
    setBusy(true);
    setError(null);
    setNotice(null);

    // Decide where the session is stored *before* signing in, so the token is
    // written to the right place the first time.
    setRemember(remember);

    try {
      if (mode === 'signup') {
        if (password.length < 8) throw new Error('Use at least 8 characters for your password.');

        const { data, error } = await supabase.auth.signUp({
          email,
          password,
          options: { data: { display_name: name.trim() || email.split('@')[0] } },
        });
        if (error) throw error;

        // With email confirmation switched on there is no session yet; the
        // profile and welcome points are created by a database trigger either way.
        if (!data.session) {
          setNotice('Check your inbox to confirm your email, then sign in.');
        }
      } else {
        const { error } = await supabase.auth.signInWithPassword({ email, password });
        if (error) throw error;
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Something went wrong.');
    } finally {
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
          <h1>DARK HORSE</h1>
          <p className="muted">Three cards. Last digit wins.</p>
        </div>

        {error && <div className="error">{error}</div>}
        {notice && <div className="notice">{notice}</div>}

        <form onSubmit={submit}>
          {mode === 'signup' && (
            <div className="field">
              <label htmlFor="name">Display name</label>
              <input
                id="name"
                className="input"
                value={name}
                onChange={(e) => setName(e.target.value)}
                placeholder="How you appear at the table"
                autoComplete="nickname"
              />
            </div>
          )}

          <div className="field">
            <label htmlFor="email">Email</label>
            <input
              id="email"
              className="input"
              type="email"
              required
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              autoComplete="email"
            />
          </div>

          <div className="field">
            <label htmlFor="password">Password</label>
            <input
              id="password"
              className="input"
              type="password"
              required
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              autoComplete={mode === 'signup' ? 'new-password' : 'current-password'}
            />
          </div>

          <label className="check remember">
            <input
              type="checkbox"
              checked={remember}
              onChange={(e) => setRememberChoice(e.target.checked)}
            />
            <span>
              Remember me
              <em>Stay signed in on this device. Leave off on a shared computer.</em>
            </span>
          </label>

          <button className="btn btn-block" disabled={busy} type="submit">
            {busy ? 'Please wait…' : mode === 'signup' ? 'Create account' : 'Sign in'}
          </button>
        </form>

        <button
          className="link"
          onClick={() => {
            setMode(mode === 'signin' ? 'signup' : 'signin');
            setError(null);
            setNotice(null);
          }}
        >
          {mode === 'signin'
            ? 'New here? Create an account — 1,000 points to start.'
            : 'Already have an account? Sign in.'}
        </button>
      </div>
    </div>
  );
}
