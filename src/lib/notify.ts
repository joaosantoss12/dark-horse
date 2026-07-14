import type { Room } from './api';

/**
 * Browser notifications when a table starts filling.
 *
 * A HARD LIMIT WORTH KNOWING: these only fire while the site is open in a tab
 * (it may be in the background -- that is the useful case). Reaching a player
 * whose browser is CLOSED needs a push server holding VAPID keys, and there is
 * no server here: Vercel is serverless. Telegram would reach everyone; this
 * reaches whoever has the game open.
 *
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

/** Asks the browser. Returns whether we ended up able to notify. */
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

  // The tag collapses repeats: a table filling up twice does not stack two
  // notifications, it replaces the first.
  const note = new Notification(title, { body, tag, icon: '/favicon.svg' });
  note.onclick = () => {
    window.focus();
    note.close();
  };
}

/**
 * Watches the lobby and speaks up when a table's occupancy crosses a line that
 * matters. Deliberately only two moments -- a table filling from empty, and a
 * table one seat short. Any more than that and players mute the notifications,
 * at which point the channel is dead and cannot be got back.
 */
export function watchForFillingTables(rooms: Room[], youId: string) {
  for (const room of rooms) {
    const seated = room.players.length;
    const before = lastSeen.get(room.id);
    lastSeen.set(room.id, seated);

    // Nothing to say on the first look, or if this player is already there.
    if (before === undefined) continue;
    if (room.players.some((p) => p.userId === youId)) continue;
    if (room.phase !== 'waiting') continue;

    const justOpened = before === 0 && seated === 1;
    const nearlyFull = seated === room.seats - 1 && before < seated;

    if (justOpened) {
      const who = room.players[0]?.name ?? 'Someone';
      show(
        '🔔 A table is filling',
        `${who} sat down at ${room.name} — ${seated}/${room.seats}. Join now!`,
        `room-${room.id}`,
      );
    } else if (nearlyFull) {
      show(
        '🔥 One seat left',
        `${room.name} is ${seated}/${room.seats}. Take the last seat!`,
        `room-${room.id}`,
      );
    }
  }
}

const lastSeen = new Map<number, number>();
