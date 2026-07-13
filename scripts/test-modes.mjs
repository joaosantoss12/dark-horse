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

console.log('\nReal money is closed');
{
  const room = (await db.query(
    `INSERT INTO rooms (name, seats, buy_in, prizes, mode, sort_order)
     VALUES ('CASHTEST', 4, 10, ARRAY[24,12]::bigint[], 'cash', 97) RETURNING id`,
  )).rows[0];

  const { error } = await sb.rpc('dh_join_room', { p_room_id: room.id });
  check('a player cannot sit at a real-money table', !!error, 'the join succeeded!');
  check('and is told why', (error?.message ?? '').includes('not open yet'), error?.message ?? '');

  const seated = (await db.query('SELECT COUNT(*)::int n FROM seats WHERE room_id = $1', [room.id])).rows[0];
  check('no seat was taken', seated.n === 0);

  const { data: limits } = await sb.rpc('dh_my_limits');
  check('the client is told cash is disabled', limits.cashEnabled === false);

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
  const t = (await db.query('SELECT dh_countdown() c, dh_card_gap() g, dh_deal_len() l')).rows[0];
  check('the countdown is 5s', Number(t.c) === 5);
  check('a card turns over every 2.4s', Number(t.g) === 2.4);
  check('a deal lasts 10.4s', Number(t.l) === 10.4);
  // 5s shuffle + three 10.4s deals.
  const hand = Number(t.c) + 3 * Number(t.l);
  check('a whole hand runs ~36s, against ~23s before', Math.abs(hand - 36.2) < 0.1, `${hand}s`);
}

await db.query('DELETE FROM auth.users WHERE id = $1', [uid]);
await db.end();

console.log(`\n${passed} passed, ${failed} failed\n`);
process.exit(failed ? 1 : 0);
