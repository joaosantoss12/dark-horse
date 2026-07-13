import {
  createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode,
} from 'react';

import { clearCache, type Profile } from './api';
import { timed } from './perf';
import { supabase } from './supabase';

interface AuthState {
  profile: Profile | null;
  loading: boolean;
  refresh: () => Promise<void>;
  /** Apply a balance the server just told us, without waiting for Realtime. */
  setBalance: (balance: number) => void;
  signOut: () => Promise<void>;
}

const Ctx = createContext<AuthState>({
  profile: null,
  loading: true,
  refresh: async () => {},
  setBalance: () => {},
  signOut: async () => {},
});

/** Last profile we saw, so a reload paints the header instead of a spinner. */
const CACHE_KEY = 'dh.profile';

function cachedProfile(): Profile | null {
  try {
    const raw = sessionStorage.getItem(CACHE_KEY);
    return raw ? (JSON.parse(raw) as Profile) : null;
  } catch {
    return null;
  }
}

export function AuthProvider({ children }: { children: ReactNode }) {
  const [profile, setProfileState] = useState<Profile | null>(cachedProfile);
  const [loading, setLoading] = useState(true);

  // Mount, the initial auth event, and React's StrictMode double-invoke were all
  // asking for the same profile: it was fetched three or four times per load.
  const loadedFor = useRef<string | null>(null);

  // Takes a value or an updater, like setState, and keeps the cached copy in step.
  const setProfile = useCallback(
    (next: Profile | null | ((prev: Profile | null) => Profile | null)) => {
      setProfileState((prev) => {
        const value = typeof next === 'function' ? next(prev) : next;
        try {
          if (value) sessionStorage.setItem(CACHE_KEY, JSON.stringify(value));
          else sessionStorage.removeItem(CACHE_KEY);
        } catch {
          // Storage unavailable; the in-memory copy is enough.
        }
        return value;
      });
    },
    [],
  );

  const load = useCallback(async (userId: string, force = false) => {
    if (!force && loadedFor.current === userId) return;
    loadedFor.current = userId;

    const { data, error } = await timed('fetch profile', async () =>
      supabase
        .from('profiles')
        .select('id, display_name, avatar_url, balance, is_admin, is_banned, rules_accepted_at')
        .eq('id', userId)
        .single(),
    );

    if (!error) {
      setProfile(data);
      return;
    }

    // PGRST116 = the row is not there. A signed-in account with no profile is a
    // dead end the player cannot fix, so build it rather than bounce them out.
    if (error.code === 'PGRST116') {
      const { data: healed } = await supabase.rpc('dh_ensure_profile');
      if (healed) {
        setProfile(healed as Profile);
        return;
      }
    }

    setProfile(null);
  }, []);

  const refresh = useCallback(async () => {
    // getSession() reads the token that is already in local storage. getUser()
    // would round-trip to Supabase to re-verify it -- on every page load, before
    // anything can render, which is what made the app feel slow.
    const { data } = await supabase.auth.getSession();
    const userId = data.session?.user.id;

    if (!userId) {
      setProfile(null);
      return;
    }
    // An explicit refresh (after saving your profile) must actually re-fetch.
    await load(userId, true);
  }, [load]);

  useEffect(() => {
    // Deliberately not refresh(): that forces a re-fetch, and StrictMode runs
    // this effect twice in development. load() de-duplicates per user.
    const init = async () => {
      const { data } = await supabase.auth.getSession();
      const userId = data.session?.user.id;
      if (userId) await load(userId);
      else setProfile(null);
    };

    void init().finally(() => setLoading(false));

    const { data } = supabase.auth.onAuthStateChange((event, session) => {
      if (event === 'SIGNED_OUT' || !session) {
        setProfile(null);
        return;
      }
      // A token refresh fires this every hour with the same user; there is no
      // point re-fetching the profile we already have.
      if (event === 'SIGNED_IN' || event === 'USER_UPDATED') {
        void load(session.user.id);
      }
    });

    return () => data.subscription.unsubscribe();
  }, [load, setProfile]);

  // A hand settles inside the database with no request from this tab, so the
  // balance has to arrive by itself.
  useEffect(() => {
    if (!profile?.id) return;

    const channel = supabase
      .channel(`profile:${profile.id}`)
      .on(
        'postgres_changes',
        { event: 'UPDATE', schema: 'public', table: 'profiles', filter: `id=eq.${profile.id}` },
        (payload) => setProfile((prev) => (prev ? { ...prev, ...(payload.new as Profile) } : prev)),
      )
      .subscribe();

    return () => {
      void supabase.removeChannel(channel);
    };
  }, [profile?.id]);

  const setBalance = useCallback((balance: number) => {
    setProfile((prev) => (prev ? { ...prev, balance } : prev));
  }, []);

  const signOut = useCallback(async () => {
    await supabase.auth.signOut();
    loadedFor.current = null;
    setProfile(null);
    // Never leave one player's cached name, balance or table state behind for
    // whoever signs in next on this machine.
    clearCache();
  }, [setProfile]);

  const value = useMemo(
    () => ({ profile, loading, refresh, setBalance, signOut }),
    [profile, loading, refresh, setBalance, signOut],
  );

  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

export const useAuth = () => useContext(Ctx);
