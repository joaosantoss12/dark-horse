// Free mode, the daily limit, and the real-money block.
//   node scripts/test-modes.mjs
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import dotenv from 'dotenv';
import pg from 'pg';
import { createClient } from '@supabase/supabase-js';

const root = dirname(dirname(fileURLToPath(import.meta.url)));
dotenv.config({ path: join(root, '.env.local') });

const db = new pg.Client({
  connectionString: process.env.SUPABASE_DB_URL,
  ssl: { rejectUnauthorized: false },
});
await db.connect();

let passed = 0, failed = 0;
const check = (name, ok, detail = '') => {
  if (ok) { passed++; console.log(`  ok   ${name}`); }
  else { failed++; console.log(`  FAIL ${name} ${detail}`); }
};

const stamp = Date.now();
const EMAIL = `dh.mode.${stamp}@gmail.com`;
const PASSWORD = 'correct-horse-battery-staple';

await db.query(
  `INSERT INTO auth.users (instance_id, id, aud, role, email, encrypted_password,
     email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
     confirmation_token, recovery_token, email_change, email_change_token_new)
   VALUES ('00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated',
     'authenticated', $1, crypt($2, gen_salt('bf')), now(),
     '{"provider":"email","providers":["email"]}'::jsonb,
     jsonb_build_object('display_name', $3::text), now(), now(), '', '', '', '')`,
  [EMAIL, PASSWORD, `Mode${stamp % 100000}`],
);
const uid = (await db.query('SELECT id FROM auth.users WHERE email = $1', [EMAIL])).rows[0].id;

const sb = createClient(process.env.VITE_SUPABASE_URL, process.env.VITE_SUPABASE_ANON_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});
await sb.auth.signInWithPassword({ email: EMAIL, password: PASSWORD });

console.log('\nThe rules must be accepted before playing');
{
  const before = (await db.query('SELECT rules_accepted_at FROM profiles WHERE id = $1', [uid])).rows[0];
  check('a new player has not accepted the rules', before.rules_accepted_at === null);

  await sb.rpc('dh_accept_rules');
  const after = (await db.query('SELECT rules_accepted_at FROM profiles WHERE id = $1', [uid])).rows[0];
  check('accepting is recorded on the profile', after.rules_accepted_at !== null);
}

console.log('\nReal money is open (the operator is licensed)');
{
  const room = (await db.query(
    `INSERT INTO rooms (name, seats, buy_in, prizes, mode, sort_order)
     VALUES ('CASHTEST', 4, 1000, ARRAY[2400,1200]::bigint[], 'cash', 97) RETURNING id`,
  )).rows[0];

  const { data: limits } = await sb.rpc('dh_my_limits');
  check('the client is told cash is enabled', limits.cashEnabled === true);

  // No real balance -> stopped for funds, not because it is locked.
  const { error } = await sb.rpc('dh_join_room', { p_room_id: room.id });
  check('an unfunded player is stopped for lack of funds',
    (error?.message ?? '').toLowerCase().includes('real-money balance'), error?.message ?? '');

  await db.query('UPDATE profiles SET cash_balance = 5000 WHERE id = $1', [uid]);
  const { error: ok } = await sb.rpc('dh_join_room', { p_room_id: room.id });
  check('a funded player can join a real-money table', !ok, ok?.message ?? '');

  await sb.rpc('dh_leave_room', { p_room_id: room.id });
  await db.query('DELETE FROM rooms WHERE id = $1', [room.id]);
}

console.log('\nThe daily free limit');
{
  // Squeeze the cap down so the test does not have to play ten hands.
  await db.query(`UPDATE settings SET value = '2'::jsonb WHERE key = 'free_hands_per_day'`);
  await db.query('UPDATE profiles SET balance = 100000, is_admin = true WHERE id = $1', [uid]);

  const room = (await db.query(
    `INSERT INTO rooms (name, seats, buy_in, prizes, mode, sort_order)
     VALUES ('FREETEST', 4, 10, ARRAY[24,12]::bigint[], 'free', 96) RETURNING id`,
  )).rows[0];

  const { data: start } = await sb.rpc('dh_my_limits');
  check('a fresh player has the full allowance', start.freeHandsLeft === 2, JSON.stringify(start));

  // Play the two hands. Each is: join, fill with bots, wait for it to settle.
  for (let hand = 1; hand <= 2; hand++) {
    const { error } = await sb.rpc('dh_join_room', { p_room_id: room.id });
    check(`hand ${hand}: allowed to join`, !error, error?.message ?? '');
    await sb.rpc('dh_fill_bots', { p_room_id: room.id });

    // 5s countdown + 3 deals x 10.4s + reset. Force the clock instead of waiting.
    await db.query(
      `UPDATE rounds SET dealt_at = now() - interval '40 seconds',
                         settle_at = now() - interval '20 seconds',
                         reset_at = now() - interval '1 second'
        WHERE room_id = $1 AND settled_at IS NULL`,
      [room.id],
    );
    await db.query('SELECT dh_tick()');
  }

  const { data: spent } = await sb.rpc('dh_my_limits');
  check('both hands are counted', spent.freeHandsUsed === 2 && spent.freeHandsLeft === 0,
    JSON.stringify(spent));

  const { error: blocked } = await sb.rpc('dh_join_room', { p_room_id: room.id });
  check('the third hand is refused', !!blocked, 'the join succeeded!');
  check('and the player is told when it resets',
    (blocked?.message ?? '').includes('midnight'), blocked?.message ?? '');

  // The block must be about hands played, not points held.
  const bal = (await db.query('SELECT balance FROM profiles WHERE id = $1', [uid])).rows[0];
  check('the player still has plenty of points -- it is the limit, not the balance',
    Number(bal.balance) > 1000, `${bal.balance}`);

  await db.query('DELETE FROM rooms WHERE id = $1', [room.id]);
  await db.query(`UPDATE settings SET value = '10'::jsonb WHERE key = 'free_hands_per_day'`);
}

console.log('\nPace');
{
  // One card per seat per card, each laid down and left to sit before it turns,
  // so a deal's length depends on how many seats there are.
  const t = (await db.query(
    'SELECT dh_countdown() c, dh_seat_gap() g, dh_flip_delay() f, dh_deal_len(4) l4, dh_deal_len(8) l8',
  )).rows[0];

  check('a card lands every 1.8s -- time to look at it', Number(t.g) === 1.8);
  check('and sits face down for 0.9s before it turns', Number(t.f) === 0.9);
  check('the pause is part of the beat, not on top of it', Number(t.f) < Number(t.g));

  const hand4 = Number(t.c) + 3 * Number(t.l4);
  const hand8 = Number(t.c) + 3 * Number(t.l8);
  check('a 4-seat hand runs ~83s', Math.abs(hand4 - 82.8) < 0.5, `${hand4}s`);
  check('an 8-seat hand runs ~148s -- twice the cards to deal',
    Math.abs(hand8 - 147.6) < 0.5, `${hand8}s`);

  // The pace is a setting, so it can be tuned without a deploy.
  const tunable = (await db.query(
    `SELECT COUNT(*)::int n FROM settings WHERE key IN ('seat_gap_ms','flip_delay_ms')`,
  )).rows[0];
  check('the pace can be tuned from the admin panel', tunable.n === 2);
}

await db.query('DELETE FROM auth.users WHERE id = $1', [uid]);
await db.end();

console.log(`\n${passed} passed, ${failed} failed\n`);
process.exit(failed ? 1 : 0);
