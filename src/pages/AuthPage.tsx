import { useState, type FormEvent } from 'react';

import { HowToPlay } from '../components/HowToPlay';
import { Modal } from '../components/Modal';
import { HorseMark } from '../components/icons';
import { setRemember, supabase } from '../lib/supabase';

export function AuthPage() {
  const [mode, setMode] = useState<'signin' | 'signup' | 'forgot'>('signin');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [name, setName] = useState('');
  const [remember, setRememberChoice] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [showRules, setShowRules] = useState(false);

  const submit = async (event: FormEvent) => {
    event.preventDefault();
    setBusy(true);
    setError(null);
    setNotice(null);

    // Decide where the session is stored *before* signing in, so the token is
    // written to the right place the first time.
    setRemember(remember);

    try {
      if (mode === 'forgot') {
        if (!email.trim()) throw new Error('Enter the email you signed up with.');

        // The link in the email has to come back to this site, wherever it is
        // running -- localhost while developing, the live domain in production.
        const { error } = await supabase.auth.resetPasswordForEmail(email.trim(), {
          redirectTo: `${window.location.origin}/reset`,
        });
        if (error) throw error;

        // Deliberately the same message whether or not that address has an
        // account: otherwise this form tells a stranger who is registered here.
        setNotice('If that email has an account, a reset link is on its way.');
      } else if (mode === 'signup') {
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

          {/* Asking for a reset link needs the email and nothing else. */}
          {mode !== 'forgot' && (
            <>
              <div className="field">
                <div className="label-row">
                  <label htmlFor="password">Password</label>
                  {mode === 'signin' && (
                    <button
                      type="button"
                      className="link inline"
                      onClick={() => {
                        setMode('forgot');
                        setError(null);
                        setNotice(null);
                      }}
                    >
                      Forgot your password?
                    </button>
                  )}
                </div>
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
            </>
          )}

          {mode === 'forgot' && (
            <p className="muted forgot-note">
              We will email you a link that lets you set a new password.
            </p>
          )}

          <button className="btn btn-block" disabled={busy} type="submit">
            {busy
              ? 'Please wait…'
              : mode === 'signup'
                ? 'Create account'
                : mode === 'forgot'
                  ? 'Email me a reset link'
                  : 'Sign in'}
          </button>
        </form>

        <div className="auth-alt">
          <button
            className="btn btn-ghost btn-block"
            onClick={() => {
              setMode(mode === 'signin' ? 'signup' : 'signin');
              setError(null);
              setNotice(null);
            }}
          >
            {mode === 'signin' ? 'Create an account' : 'Sign in instead'}
          </button>

          {mode !== 'forgot' && (
            <button className="btn btn-ghost btn-block" onClick={() => setShowRules(true)}>
              How it works
            </button>
          )}
        </div>
      </div>

      {showRules && (
        <Modal title="🐎 How to play" onClose={() => setShowRules(false)}>
          <HowToPlay />
        </Modal>
      )}
    </div>
  );
}
