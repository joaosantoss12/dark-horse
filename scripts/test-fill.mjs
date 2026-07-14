// The fill window: a table that does not fill refunds everyone and clears.
//   node scripts/test-fill.mjs
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
const PASSWORD = 'correct-horse-battery-staple';

async function player(tag, funds) {
  const email = `dh.${tag}.${stamp}@gmail.com`;
  await db.query(
    `INSERT INTO auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,
       raw_app_meta_data,raw_user_meta_data,created_at,updated_at,
       confirmation_token,recovery_token,email_change,email_change_token_new)
     VALUES ('00000000-0000-0000-0000-000000000000',gen_random_uuid(),'authenticated','authenticated',
       $1, crypt($2, gen_salt('bf')), now(),
       '{"provider":"email","providers":["email"]}'::jsonb,
       jsonb_build_object('display_name', $3::text), now(), now(), '','','','')`,
    [email, PASSWORD, `${tag}${stamp % 10000}`],
  );
  const id = (await db.query('SELECT id FROM auth.users WHERE email=$1', [email])).rows[0].id;
  await db.query('UPDATE profiles SET balance = $2 WHERE id = $1', [id, funds]);

  const sb = createClient(process.env.VITE_SUPABASE_URL, process.env.VITE_SUPABASE_ANON_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  await sb.auth.signInWithPassword({ email, password: PASSWORD });
  return { id, sb };
}

const balance = async (id) =>
  Number((await db.query('SELECT balance FROM profiles WHERE id=$1', [id])).rows[0].balance);

const alice = await player('fa', 100);
const bob = await player('fb', 100);

const room = (await db.query(
  `INSERT INTO rooms (name, seats, buy_in, prizes, mode, sort_order)
   VALUES ('FILLTEST', 4, 20, ARRAY[38,32]::bigint[], 'free', 94) RETURNING id`,
)).rows[0];

console.log('\nThe clock starts when the first player sits');
{
  await alice.sb.rpc('dh_join_room', { p_room_id: room.id });
  const r = (await db.query('SELECT fill_deadline FROM rooms WHERE id=$1', [room.id])).rows[0];
  check('a deadline is set', r.fill_deadline !== null);
  check('the buy-in was taken', (await balance(alice.id)) === 80);

  const { data: view } = await alice.sb.rpc('dh_room_with_clock', { p_room_id: room.id });
  check('the client is told how long is left', typeof view.fillsInMs === 'number',
    JSON.stringify(view.fillsInMs));

  // A second player does NOT restart the clock: the deadline is the table's.
  const before = r.fill_deadline;
  await bob.sb.rpc('dh_join_room', { p_room_id: room.id });
  const after = (await db.query('SELECT fill_deadline FROM rooms WHERE id=$1', [room.id])).rows[0];
  check('a second player does not reset the clock',
    new Date(after.fill_deadline).getTime() === new Date(before).getTime());
}

console.log('\nWhen it expires, everyone is refunded and the table clears');
{
  // Wind the deadline into the past rather than waiting 60s.
  await db.query(`UPDATE rooms SET fill_deadline = now() - interval '1 second' WHERE id=$1`, [room.id]);
  await db.query('SELECT dh_tick()');

  check('alice got her buy-in back', (await balance(alice.id)) === 100);
  check('bob got his buy-in back', (await balance(bob.id)) === 100);

  const seats = (await db.query('SELECT COUNT(*)::int n FROM seats WHERE room_id=$1', [room.id])).rows[0];
  check('the seats are cleared', seats.n === 0);

  const r = (await db.query('SELECT fill_deadline FROM rooms WHERE id=$1', [room.id])).rows[0];
  check('the clock is stopped', r.fill_deadline === null);

  const refunds = (await db.query(
    `SELECT COUNT(*)::int n FROM ledger WHERE kind='refund' AND note='Table did not fill in time'
      AND user_id = ANY($1)`, [[alice.id, bob.id]],
  )).rows[0];
  check('both refunds are written to the ledger', refunds.n === 2,
    `${refunds.n} rows -- the books must explain every movement`);
}

console.log('\nA table that fills in time is not affected');
{
  const c = await player('fc', 100);
  const d = await player('fd', 100);
  const e = await player('fe', 100);

  await alice.sb.rpc('dh_join_room', { p_room_id: room.id });
  await c.sb.rpc('dh_join_room', { p_room_id: room.id });
  await d.sb.rpc('dh_join_room', { p_room_id: room.id });
  await e.sb.rpc('dh_join_room', { p_room_id: room.id });

  const r = (await db.query(
    'SELECT fill_deadline, current_round_id FROM rooms WHERE id=$1', [room.id],
  )).rows[0];
  check('filling the last seat stops the clock', r.fill_deadline === null);
  check('and deals the hand', r.current_round_id !== null);

  // The expiry sweep must not touch a table that is mid-hand.
  await db.query('SELECT dh_tick()');
  const still = (await db.query('SELECT COUNT(*)::int n FROM seats WHERE room_id=$1', [room.id])).rows[0];
  check('a hand in progress is never swept away', still.n === 4);

  await db.query('DELETE FROM auth.users WHERE id = ANY($1)', [[c.id, d.id, e.id]]);
}

await db.query('DELETE FROM rooms WHERE id=$1', [room.id]);
await db.query('DELETE FROM auth.users WHERE id = ANY($1)', [[alice.id, bob.id]]);
await db.end();
console.log(`\n${passed} passed, ${failed} failed\n`);
process.exit(failed ? 1 : 0);
