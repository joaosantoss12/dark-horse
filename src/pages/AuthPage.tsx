import { useState, type FormEvent } from 'react';

import { HowToPlay } from '../components/HowToPlay';
import { SupportLink } from '../components/Support';
import { Modal } from '../components/Modal';
import { HorseMark } from '../components/icons';
import { api } from '../lib/api';
import { setRemember, supabase } from '../lib/supabase';

// One token per browser, so a repeat signup from the same device can be
// caught. Trivially cleared by the user -- accepted, this is a deterrent, not
// a hard block.
const DEVICE_KEY = 'dh.device';

function deviceToken(): string {
  try {
    let token = localStorage.getItem(DEVICE_KEY);
    if (!token) {
      token = crypto.randomUUID();
      localStorage.setItem(DEVICE_KEY, token);
    }
    return token;
  } catch {
    return '';
  }
}

export function AuthPage() {
  const [mode, setMode] = useState<'signin' | 'signup'>('signin');
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
      if (mode === 'signup') {
        if (password.length < 8) throw new Error('Use at least 8 characters for your password.');

        // A referral code arrives as ?ref=CODE and rides along in the signup
        // metadata; the database trigger rewards the referrer.
        const ref = new URLSearchParams(window.location.search).get('ref');
        const { data, error } = await supabase.auth.signUp({
          email,
          password,
          options: {
            data: {
              display_name: name.trim() || email.split('@')[0],
              ...(ref ? { ref: ref.toUpperCase() } : {}),
            },
          },
        });
        if (error) throw error;

        // With email confirmation switched on there is no session yet; the
        // profile and welcome points are created by a database trigger either way.
        if (!data.session) {
          setNotice('Check your inbox to confirm your email, then sign in.');
        } else {
          // Session exists now, so the device check can run in this same flow.
          // A device that has already registered an account is turned away
          // immediately rather than being let in with a working session.
          try {
            await api.registerDevice(deviceToken());
          } catch (deviceErr) {
            await supabase.auth.signOut();
            throw deviceErr;
          }
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
            {busy ? 'Please wait...' : mode === 'signup' ? 'Create account' : 'Sign in'}
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

          <button className="btn btn-ghost btn-block" onClick={() => setShowRules(true)}>
            How it works
          </button>
        </div>

        {/* There is no self-service password reset. Locked out? Support sorts it out. */}
        <SupportLink />
      </div>

      {showRules && (
        <Modal title="🐎 How to play" onClose={() => setShowRules(false)}>
          <HowToPlay />
        </Modal>
      )}
    </div>
  );
}
