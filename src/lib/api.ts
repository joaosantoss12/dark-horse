import { supabase } from './supabase';

export interface Card {
  r: number;
  s: 'S' | 'H' | 'D' | 'C';
}

export type Phase = 'waiting' | 'countdown' | 'dealing' | 'results';

/** One of the three deals in a hand. */
export interface Deal {
  dealNo: number;
  /** A card the dealer has not turned over yet arrives as null. */
  cards: (Card | null)[];
  /** Only set once this deal's third card is face up. */
  score: number | null;
  /** What the deal is worth: its score, or 11 for a Crown, 12 for Three of a Kind. */
  value: number | null;
  category: number | null;
}

export interface TablePlayer {
  seat: number;
  userId: string | null;
  name: string;
  avatarUrl: string | null;
  isBot: boolean;
  deals: Deal[];
  /** Running total of the deals scored so far. */
  totalValue: number | null;
  place: number | null;
  won: number | null;
  isSplit: boolean | null;
}

export interface Room {
  id: number;
  name: string;
  seats: number;
  buyIn: number;
  prizes: number[];
  phase: Phase;
  /** Which of the three deals is on the table (1-3), or 0 while waiting. */
  deal: number;
  /** Cards turned over in the current deal (0-3). */
  revealed: number;
  players: TablePlayer[];
  startsInMs: number | null;
}

export interface Profile {
  id: string;
  display_name: string;
  avatar_url: string | null;
  balance: number;
  is_admin: boolean;
  is_banned: boolean;
}

export interface Stats {
  handsPlayed: number;
  handsWon: number;
  firstPlaces: number;
  wagered: number;
  won: number;
  net: number;
  bestScore: number;
  specials: number;
  bestHand: { cards: Card[]; score: number; category: number } | null;
}

/** Storage rejects anything bigger, but failing here gives a better message. */
export const MAX_AVATAR_BYTES = 2 * 1024 * 1024;

/**
 * Postgres raises real error messages ("Not enough points for this buy-in."),
 * which are written to be shown to the player as-is.
 */
function unwrap<T>(result: { data: T | null; error: { message: string } | null }): T {
  if (result.error) throw new Error(clean(result.error.message));
  return result.data as T;
}

function clean(message: string): string {
  return message.replace(/^.*?(?:ERROR|error):\s*/i, '').trim() || 'Something went wrong.';
}

/**
 * The last table state we saw.
 *
 * Every request here takes ~100ms, which is fine -- but showing a spinner for
 * 100ms and then swapping in content reads as slow, while showing the last known
 * state and quietly refreshing it reads as instant.
 *
 * Backed by sessionStorage so a page reload paints immediately too, instead of
 * blanking while the first request flies.
 */
const memory = new Map<string, Room[]>();

const STORE_PREFIX = 'dh.cache.';

export function getCached(key: string): Room[] | null {
  const hit = memory.get(key);
  if (hit) return hit;

  try {
    const raw = sessionStorage.getItem(STORE_PREFIX + key);
    if (!raw) return null;
    const rooms = JSON.parse(raw) as Room[];
    memory.set(key, rooms);
    return rooms;
  } catch {
    return null;
  }
}

export function setCached(key: string, rooms: Room[]): void {
  memory.set(key, rooms);
  try {
    sessionStorage.setItem(STORE_PREFIX + key, JSON.stringify(rooms));
  } catch {
    // Private mode, quota, whatever -- the in-memory copy still works.
  }
}

/**
 * The lobby response already contains the full state of every table, so opening
 * one should not need its own request. Seed each table's cache from the lobby
 * and the table page can paint the moment it mounts.
 */
export function seedRoomsFromLobby(rooms: Room[]): void {
  for (const room of rooms) setCached(`room:${room.id}`, [room]);
}

/** Wipe every cached table on sign-out. */
export function clearCache(): void {
  memory.clear();
  try {
    for (const key of Object.keys(sessionStorage)) {
      if (key.startsWith(STORE_PREFIX)) sessionStorage.removeItem(key);
    }
  } catch {
    // Nothing to clear.
  }
}

/**
 * Starts loading the lobby before React has even mounted, so the first request
 * overlaps with parsing the bundle and fetching the profile rather than queueing
 * behind them.
 */
let lobbyPrefetch: Promise<Room[]> | null = null;

export function prefetchLobby() {
  lobbyPrefetch = api.lobby().catch(() => [] as Room[]);
}

export function takeLobbyPrefetch(): Promise<Room[]> | null {
  const pending = lobbyPrefetch;
  lobbyPrefetch = null;
  return pending;
}

export const api = {
  async profile(): Promise<Profile | null> {
    const { data: session } = await supabase.auth.getSession();
    const userId = session.session?.user.id;
    if (!userId) return null;

    const { data, error } = await supabase
      .from('profiles')
      .select('id, display_name, avatar_url, balance, is_admin, is_banned')
      .eq('id', userId)
      .single();

    if (error) throw new Error(clean(error.message));
    return data;
  },

  async stats(): Promise<Stats> {
    return unwrap(await supabase.rpc('dh_my_stats'));
  },

  async updateProfile(displayName: string, avatarUrl: string | null) {
    return unwrap(
      await supabase.rpc('dh_update_profile', {
        p_display_name: displayName,
        p_avatar_url: avatarUrl,
      }),
    );
  },

  /**
   * Uploads to avatars/<userId>/avatar.<ext>. Storage policy only allows a
   * player to write inside a folder named after their own id, so one player
   * cannot overwrite another's picture.
   */
  async uploadAvatar(file: File): Promise<string> {
    if (file.size > MAX_AVATAR_BYTES) {
      throw new Error('That image is over 2 MB. Pick a smaller one.');
    }

    const { data: session } = await supabase.auth.getSession();
    const userId = session.session?.user.id;
    if (!userId) throw new Error('You must be signed in.');

    const ext = file.type === 'image/png' ? 'png' : file.type === 'image/webp' ? 'webp' : 'jpg';
    const path = `${userId}/avatar.${ext}`;

    const { error } = await supabase.storage
      .from('avatars')
      .upload(path, file, { upsert: true, contentType: file.type });

    if (error) throw new Error(clean(error.message));

    const { data } = supabase.storage.from('avatars').getPublicUrl(path);
    // The path never changes, so bust the CDN cache or the old picture sticks.
    return `${data.publicUrl}?v=${Date.now()}`;
  },

  async lobby(): Promise<Room[]> {
    return unwrap(await supabase.rpc('dh_get_lobby'));
  },

  async room(id: number): Promise<Room> {
    return unwrap(await supabase.rpc('dh_get_room', { p_room_id: id }));
  },

  async join(id: number) {
    return unwrap(await supabase.rpc('dh_join_room', { p_room_id: id }));
  },

  async leave(id: number) {
    return unwrap(await supabase.rpc('dh_leave_room', { p_room_id: id }));
  },

  async fillBots(id: number) {
    return unwrap(await supabase.rpc('dh_fill_bots', { p_room_id: id }));
  },

  async history() {
    return unwrap(await supabase.rpc('dh_my_history')) ?? [];
  },

  async leaderboard() {
    return unwrap(await supabase.rpc('dh_leaderboard')) ?? [];
  },

  admin: {
    async stats() {
      return unwrap(await supabase.rpc('dh_admin_stats'));
    },
    async players(query = '') {
      return unwrap(await supabase.rpc('dh_admin_players', { p_query: query })) ?? [];
    },
    async adjust(userId: string, amount: number, note: string) {
      return unwrap(
        await supabase.rpc('dh_admin_adjust_balance', {
          p_user_id: userId,
          p_amount: amount,
          p_note: note,
        }),
      );
    },
    async setBanned(userId: string, banned: boolean) {
      return unwrap(await supabase.rpc('dh_admin_set_banned', { p_user_id: userId, p_banned: banned }));
    },
    async rooms() {
      const { data, error } = await supabase
        .from('rooms')
        .select('id, name, seats, buy_in, prizes, is_active, sort_order')
        .order('sort_order');
      if (error) throw new Error(clean(error.message));
      return data ?? [];
    },
    async saveRoom(room: {
      id: number | null;
      name: string;
      seats: number;
      buyIn: number;
      prizes: number[];
      isActive: boolean;
    }) {
      return unwrap(
        await supabase.rpc('dh_admin_save_room', {
          p_id: room.id,
          p_name: room.name,
          p_seats: room.seats,
          p_buy_in: room.buyIn,
          p_prizes: room.prizes,
          p_is_active: room.isActive,
        }),
      );
    },
  },
};

/**
 * Live table updates. Realtime tells us when a seat is taken or a hand is dealt;
 * the ticker drives the reveal, because "card 2 is now face up" is a function of
 * the clock, not of any row changing.
 */
export function watchTables(onChange: () => void): () => void {
  const channel = supabase
    .channel('tables')
    .on('postgres_changes', { event: '*', schema: 'public', table: 'seats' }, onChange)
    .on('postgres_changes', { event: '*', schema: 'public', table: 'rooms' }, onChange)
    .on('postgres_changes', { event: '*', schema: 'public', table: 'rounds' }, onChange)
    .subscribe();

  return () => {
    void supabase.removeChannel(channel);
  };
}
