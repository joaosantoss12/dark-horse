import { supabase } from './supabase';

const CHANNEL = 'online-users';

/**
 * Joins the shared presence channel for the length of the session. No DB
 * writes: Supabase Realtime tracks who is connected and drops them the moment
 * their socket closes, which is exactly what "online now" means here.
 */
export function startPresence(userId: string): () => void {
  const channel = supabase.channel(CHANNEL, { config: { presence: { key: userId } } });

  channel.subscribe((status) => {
    if (status === 'SUBSCRIBED') void channel.track({ at: Date.now() });
  });

  return () => {
    void supabase.removeChannel(channel);
  };
}

/** Admin-only: watches the same channel and reports how many keys are present. */
export function watchOnlineCount(onChange: (count: number) => void): () => void {
  const channel = supabase.channel(CHANNEL, { config: { presence: { key: `admin-${Date.now()}` } } });

  channel.on('presence', { event: 'sync' }, () => {
    onChange(Object.keys(channel.presenceState()).length);
  });
  channel.subscribe();

  return () => {
    void supabase.removeChannel(channel);
  };
}
