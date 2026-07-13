// Tries to cheat, using exactly what a player's browser has: the public anon
// key. Everything here MUST fail, except the things a player is allowed to do.
//   node scripts/test-security.mjs
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import dotenv from 'dotenv';
import pg from 'pg';
import { createClient } from '@supabase/supabase-js';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
dotenv.config({ path: join(root, '.env.local') });

const anon = () =>
  createClient(process.env.VITE_SUPABASE_URL, process.env.VITE_SUPABASE_ANON_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

const db = new pg.Client({
  connectionString: process.env.SUPABASE_DB_URL,
  ssl: { rejectUnauthorized: false },
});
await db.connect();

let passed = 0;
let failed = 0;
const check = (name, ok, detail = '') => {
  if (ok) { passed++; console.log(`  ok   ${name}`); }
  else { failed++; console.log(`  FAIL ${name} ${detail}`); }
};

// Supabase rejects example.com as an invalid address, so use a domain it accepts.
// Nothing is ever sent here: the account is deleted at the end of the run.
const stamp = Date.now();
const EMAIL = `dh.test.${stamp}@gmail.com`;
const PASSWORD = 'correct-horse-battery-staple';

console.log('\nSignup');
const cheat = anon();

// Create the account straight in auth.users rather than through signUp(): the
// hosted mailer only allows a couple of messages an hour, and the point of this
// script is the security model, not the mail server. This still exercises the
// real trigger -- the profile and the welcome points come from the database.
// The token columns must be '' and not NULL: Supabase's auth service reads them
// into non-nullable strings and a NULL makes every sign-in fail.
await db.query(
  `INSERT INTO auth.users (
     instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
     raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
     confirmation_token, recovery_token, email_change, email_change_token_new
   ) VALUES (
     '00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated',
     $1, crypt($2, gen_salt('bf')), now(),
     '{"provider":"email","providers":["email"]}'::jsonb,
     jsonb_build_object('display_name', 'Cheater'), now(), now(),
     '', '', '', ''
   )`,
  [EMAIL, PASSWORD],
);

const userId = (await db.query('SELECT id FROM auth.users WHERE email = $1', [EMAIL])).rows[0].id;

const profile = (await db.query('SELECT * FROM profiles WHERE id = $1', [userId])).rows[0];
check('creating an account creates a profile automatically', !!profile);
check('a new player starts with 1000 points', Number(profile?.balance) === 1000);
check('the welcome bonus is written to the ledger',
  (await db.query(`SELECT COUNT(*)::int n FROM ledger WHERE user_id = $1 AND kind = 'signup'`, [userId]))
    .rows[0].n === 1);

const { error: signInError } = await cheat.auth.signInWithPassword({
  email: EMAIL,
  password: PASSWORD,
});
check('the player can sign in with their password', !signInError, signInError?.message ?? '');

const emailConfirmationOn = false;

console.log('\nWhat a signed-in player must NOT be able to do');
{
  // 1. Give themselves points.
  const { error: e1 } = await cheat.from('profiles').update({ balance: 999999 }).eq('id', userId);
  const after = (await db.query('SELECT balance FROM profiles WHERE id = $1', [userId])).rows[0];
  check('cannot hand themselves points', Number(after.balance) === 1000,
    `balance is now ${after.balance} (error was: ${e1?.message ?? 'none'})`);

  // 2. Make themselves an admin.
  await cheat.from('profiles').update({ is_admin: true }).eq('id', userId);
  const admin = (await db.query('SELECT is_admin FROM profiles WHERE id = $1', [userId])).rows[0];
  check('cannot promote themselves to admin', admin.is_admin === false);

  // 3. Read someone else's balance.
  const { data: others } = await cheat.from('profiles').select('id, balance');
  check('cannot see other players\' balances', (others ?? []).every((p) => p.id === userId),
    `saw ${others?.length ?? 0} profiles`);

  // 4. Call an admin function.
  const { error: e4 } = await cheat.rpc('dh_admin_adjust_balance', {
    p_user_id: userId, p_amount: 100000, p_note: 'hack',
  });
  check('cannot call an admin function', !!e4, 'the call succeeded!');

  const { error: e5 } = await cheat.rpc('dh_admin_save_room', {
    p_id: null, p_name: 'Free money', p_seats: 4, p_buy_in: 0,
    p_prizes: [999999, 0], p_is_active: true,
  });
  check('cannot create a table that pays out for free', !!e5, 'the call succeeded!');

  // 5. Deal themselves a hand.
  const { error: e6 } = await cheat.rpc('dh_deal', { p_room_id: 1 });
  check('cannot force a deal', !!e6, 'the call succeeded!');

  // 6. Write their own cards.
  const { error: e7 } = await cheat.from('round_hands').insert({
    round_id: 1, seat_index: 0, cards: [], category: 2, total: 30, score: 0, place: 1, won: 99999,
  });
  check('cannot write their own winning hand', !!e7, 'the insert succeeded!');
}

console.log('\nReading cards they should not see');
{
  // Set up a live round: the cheat sits down, bots fill the table.
  await db.query(`UPDATE profiles SET is_admin = true WHERE id = $1`, [userId]);
  const room = (await db.query(
    `INSERT INTO rooms (name, seats, buy_in, prizes, sort_order)
     VALUES ('SECTEST', 4, 100, ARRAY[250,100]::bigint[], 98) RETURNING id`,
  )).rows[0];

  await cheat.rpc('dh_join_room', { p_room_id: room.id });
  await cheat.rpc('dh_fill_bots', { p_room_id: room.id });
  await db.query(`UPDATE profiles SET is_admin = false WHERE id = $1`, [userId]);

  const balance = (await db.query('SELECT balance FROM profiles WHERE id = $1', [userId])).rows[0];
  check('joining took the buy-in', Number(balance.balance) === 900, `balance ${balance.balance}`);

  // The cards exist in the database right now. Can the browser read them?
  const { data: rows } = await cheat.from('round_hands').select('*');
  check('cannot read the dealt cards from the table directly', (rows ?? []).length === 0,
    `read ${rows?.length ?? 0} hands!`);

  // And through the sanctioned route, during the countdown?
  const { data: view } = await cheat.rpc('dh_get_room', { p_room_id: room.id });
  const anyCardVisible = view.players.some((p) => p.cards.some((c) => c !== null));
  check('the room view hides every card before the reveal', !anyCardVisible,
    JSON.stringify(view.players[0]?.cards));
  check('the room view hides the scores before the reveal',
    view.players.every((p) => p.score === null && p.place === null));

  console.log('  ...waiting out the reveal');
  await new Promise((r) => setTimeout(r, 9000));

  const { data: done } = await cheat.rpc('dh_get_room', { p_room_id: room.id });
  check('after the reveal, the cards are shown',
    done.phase === 'results' && done.players.every((p) => p.cards.every((c) => c !== null)),
    `phase=${done.phase}`);

  const settled = (await db.query(
    `SELECT r.settled_at, r.pot, r.paid_out, h.won, h.place
       FROM rounds r JOIN round_hands h ON h.round_id = r.id AND h.user_id = $1
      WHERE r.room_id = $2`, [userId, room.id],
  )).rows[0];
  check('the round settled itself', settled.settled_at !== null);
  check('the pot counted only the one human', Number(settled.pot) === 100);

  const final = (await db.query('SELECT balance FROM profiles WHERE id = $1', [userId])).rows[0];
  const expected = 900 + Number(settled.won);
  check('the balance matches the prize actually won',
    Number(final.balance) === expected,
    `balance ${final.balance}, expected ${expected} (placed ${settled.place}, won ${settled.won})`);

  await db.query(`DELETE FROM rooms WHERE id = $1`, [room.id]);
}

// Clean up the test account.
await db.query(`DELETE FROM auth.users WHERE id = $1`, [userId]);

console.log(`\n${passed} passed, ${failed} failed`);
if (emailConfirmationOn) {
  console.log('\nNOTE: email confirmation is ON in Supabase. Real players will have to click a');
  console.log('link in their inbox before they can sign in, and Supabase\'s built-in mailer only');
  console.log('sends a few messages an hour. See the README.');
}
console.log('');

await db.end();
process.exit(failed ? 1 : 0);
