import { api, type Room } from './api';
import { supabase } from './supabase';

/**
 * Browser notifications when someone sits down at a table.
 *
 * A HARD LIMIT WORTH KNOWING: these only fire while the site is open in a tab.
 * The tab may be in the BACKGROUND -- that is the useful case, and it works --
 * but a player whose browser is closed gets nothing. Reaching them needs a push
 * server holding VAPID keys, and there is no server here: Vercel is serverless.
 * iOS shows nothing at all unless the site has been added to the home screen.
 */
const KEY = 'dh.notify';

export const notificationsSupported = () => 'Notification' in window;

export const notificationsOn = () =>
  notificationsSupported() &&
  Notification.permission === 'granted' &&
  localStorage.getItem(KEY) !== 'off';

export function setNotifications(on: boolean) {
  localStorage.setItem(KEY, on ? 'on' : 'off');
}

export async function requestNotifications(): Promise<boolean> {
  if (!notificationsSupported()) return false;

  const permission =
    Notification.permission === 'default'
      ? await Notification.requestPermission()
      : Notification.permission;

  const granted = permission === 'granted';
  setNotifications(granted);
  return granted;
}

function show(title: string, body: string, tag: string) {
  if (!notificationsOn()) return;

  // The tag collapses repeats: the same table filling twice replaces its own
  // notification rather than stacking a second one.
  const note = new Notification(title, { body, tag, renotify: true } as NotificationOptions);
  note.onclick = () => {
    window.focus();
    note.close();
  };
}

/** How many humans are sitting at each table, as we last saw it. */
const lastSeen = new Map<number, number>();

function humansAt(room: Room): number {
  return room.players.filter((p) => !p.isBot).length;
}

/**
 * Speaks up when a real player sits down at a table that is waiting to fill.
 *
 * Bots do not count: an admin filling the empty seats is not news, and would
 * fire an alert at everyone every time a hand is demoed.
 */
function announce(rooms: Room[], youId: string) {
  for (const room of rooms) {
    const seated = humansAt(room);
    const before = lastSeen.get(room.id);
    lastSeen.set(room.id, seated);

    // Nothing to compare against on the very first look.
    if (before === undefined) continue;
    // Only while the table is waiting for players.
    if (room.phase !== 'waiting') continue;
    // Somebody left, or nothing changed.
    if (seated <= before) continue;
    // You are already at this table -- you know.
    if (room.players.some((p) => p.userId === youId)) continue;

    const newest = room.players.filter((p) => !p.isBot).slice(-1)[0];
    const who = newest?.name ?? 'Someone';

    show(
      `🔔 ${room.name}`,
      `${who} joined the table (${room.players.length}/${room.seats})`,
      `room-${room.id}`,
    );
  }
}

/**
 * Watches every table for the whole session, from whatever page the player is
 * on. Previously this only ran on the lobby, so a player sitting on their
 * profile -- or with the tab in the background on the table page -- was never
 * told that a game was forming, which is exactly when it matters most.
 *
 * Driven by Realtime: a seat row changing is precisely the event we care about,
 * so there is nothing to poll.
 */
export function startNotifier(youId: string): () => void {
  let alive = true;

  const refresh = async () => {
    if (!alive || !notificationsOn()) return;
    try {
      announce(await api.lobby(), youId);
    } catch {
      // A failed refresh is not worth telling the player about.
    }
  };

  // Seed the baseline, so the first change is measured against something real
  // rather than announcing every occupied table the moment you sign in.
  void api
    .lobby()
    .then((rooms) => {
      for (const room of rooms) lastSeen.set(room.id, humansAt(room));
    })
    .catch(() => {});

  const channel = supabase
    .channel('notify-seats')
    .on('postgres_changes', { event: '*', schema: 'public', table: 'seats' }, () => void refresh())
    .subscribe();

  return () => {
    alive = false;
    void supabase.removeChannel(channel);
  };
}
