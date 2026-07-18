import type { RealtimeChannel } from '@supabase/supabase-js';

import { supabase } from './supabase';

const TOPIC = 'online-users';

/**
 * One real channel per browser tab, shared by every caller. Two separate
 * RealtimeChannel objects on the same topic on one socket is not allowed --
 * supabase-js throws "cannot add `presence` callbacks ... after subscribe()"
 * the moment a second one tries to register a listener. Every visitor runs
 * `startPresence` (from Shell) and an admin additionally runs
 * `watchOnlineCount`, so this has to be reference-counted, not per-call.
 */
let channel: RealtimeChannel | null = null;
let readyPromise: Promise<void> | null = null;
let refCount = 0;
let teardownTimer: ReturnType<typeof setTimeout> | null = null;
const countListeners = new Set<(count: number) => void>();

function notify() {
  if (!channel) return;
  const count = Object.keys(channel.presenceState()).length;
  countListeners.forEach((fn) => fn(count));
}

function acquire(key: string): { channel: RealtimeChannel; ready: Promise<void> } {
  refCount += 1;
  if (teardownTimer) {
    clearTimeout(teardownTimer);
    teardownTimer = null;
  }

  if (!channel) {
    const ch = supabase.channel(TOPIC, { config: { presence: { key } } });
    channel = ch;
    ch.on('presence', { event: 'sync' }, notify);
    readyPromise = new Promise((resolve) => {
      ch.subscribe((status) => {
        if (status === 'SUBSCRIBED') resolve();
      });
    });
  }

  return { channel, ready: readyPromise! };
}

function release() {
  refCount -= 1;
  if (refCount > 0) return;

  // Debounced: in dev, React 18 StrictMode fires an effect's cleanup and its
  // remount back to back, in the same tick. Tearing down synchronously here
  // would race a leave against the very next join on the same topic --
  // reusing the channel if a reacquire lands first avoids that entirely.
  teardownTimer = setTimeout(() => {
    if (refCount > 0 || !channel) return;
    const c = channel;
    channel = null;
    readyPromise = null;
    void supabase.removeChannel(c);
  }, 0);
}

/**
 * Joins the shared presence channel for the length of the session. No DB
 * writes: Supabase Realtime tracks who is connected and drops them the moment
 * their socket closes, which is exactly what "online now" means here.
 */
export function startPresence(userId: string): () => void {
  const { ready } = acquire(userId);
  void ready.then(() => channel?.track({ at: Date.now() }));
  return release;
}

/** Admin-only: watches the same channel and reports how many keys are present. */
export function watchOnlineCount(onChange: (count: number) => void): () => void {
  acquire(`admin-${Date.now()}`);
  countListeners.add(onChange);
  notify();

  return () => {
    countListeners.delete(onChange);
    release();
  };
}
