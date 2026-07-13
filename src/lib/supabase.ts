import { createClient } from '@supabase/supabase-js';

const url = import.meta.env.VITE_SUPABASE_URL;
const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY;

if (!url || !anonKey) {
  throw new Error(
    'Missing VITE_SUPABASE_URL or VITE_SUPABASE_ANON_KEY. Copy .env.example to .env.local.',
  );
}

/**
 * Where the session is kept.
 *
 * "Remember me" writes it to localStorage, which survives closing the browser.
 * Without it we use sessionStorage, so the session dies with the tab -- which is
 * what a player on a shared computer expects "don't remember me" to mean.
 *
 * Supabase reads this once at startup, so the choice made at sign-in has to be
 * recorded somewhere that outlives the page: hence the flag in localStorage.
 */
const REMEMBER_KEY = 'dh.remember';

/** Call this before signing in: it decides where the new session gets written. */
export const setRemember = (remember: boolean) => {
  localStorage.setItem(REMEMBER_KEY, remember ? '1' : '0');
  if (!remember) {
    // Drop anything a previous "remember me" left behind, or the old token would
    // outlive the tab and defeat the point.
    for (const key of Object.keys(localStorage)) {
      if (key.startsWith('sb-')) localStorage.removeItem(key);
    }
  }
};

const rememberMe = () => localStorage.getItem(REMEMBER_KEY) !== '0';

// Resolved on every call, not once at startup: the client is created when the
// page loads, but the player chooses "remember me" later, at sign-in.
const store = (): Storage => (rememberMe() ? localStorage : sessionStorage);

const rememberAwareStorage = {
  getItem: (key: string) => store().getItem(key),
  setItem: (key: string, value: string) => store().setItem(key, value),
  removeItem: (key: string) => {
    // Sign-out should clear the token wherever it happens to live.
    localStorage.removeItem(key);
    sessionStorage.removeItem(key);
  },
};

// The anon key is public by design -- it is in the JS bundle. What actually
// protects the data is row level security plus the dh_* functions, which are
// the only way to move a point or see a card.
export const supabase = createClient(url, anonKey, {
  auth: {
    persistSession: true,
    autoRefreshToken: true,
    storage: rememberAwareStorage,
  },
});
