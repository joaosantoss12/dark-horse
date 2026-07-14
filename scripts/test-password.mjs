// Password reset without email: an admin sets it, the player signs in with it.
//   node scripts/test-password.mjs
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
const client = () =>
  createClient(process.env.VITE_SUPABASE_URL, process.env.VITE_SUPABASE_ANON_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

async function makeUser(tag, password) {
  const email = `dh.${tag}.${stamp}@gmail.com`;
  await db.query(
    `INSERT INTO auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,
       raw_app_meta_data,raw_user_meta_data,created_at,updated_at,
       confirmation_token,recovery_token,email_change,email_change_token_new)
     VALUES ('00000000-0000-0000-0000-000000000000',gen_random_uuid(),'authenticated','authenticated',
       $1, crypt($2, gen_salt('bf')), now(),
       '{"provider":"email","providers":["email"]}'::jsonb,
       jsonb_build_object('display_name', $3::text), now(), now(), '','','','')`,
    [email, password, `${tag}${stamp % 10000}`],
  );
  const id = (await db.query('SELECT id FROM auth.users WHERE email=$1', [email])).rows[0].id;
  return { id, email };
}

const LOST = 'the-password-i-forgot';
const NEW = 'amber-quartz-4471';

const player = await makeUser('lost', LOST);
const admin = await makeUser('admin', 'admin-password-123');
const nosy = await makeUser('nosy', 'nosy-password-123');
await db.query('UPDATE profiles SET is_admin = true WHERE id = $1', [admin.id]);

console.log('\nAn ordinary player must not be able to do this');
{
  const sb = client();
  await sb.auth.signInWithPassword({ email: nosy.email, password: 'nosy-password-123' });

  const { error } = await sb.rpc('dh_admin_set_password', {
    p_user_id: player.id,
    p_password: 'i-am-stealing-this-account',
  });
  check('a non-admin cannot set someone else\'s password', !!error, 'IT SUCCEEDED -- account takeover!');

  // And the victim's password is untouched.
  const victim = client();
  const { error: stillMine } = await victim.auth.signInWithPassword({
    email: player.email, password: LOST,
  });
  check('the player\'s old password still works', !stillMine);
}

console.log('\nAn admin resets a locked-out player');
{
  const sb = client();
  await sb.auth.signInWithPassword({ email: admin.email, password: 'admin-password-123' });

  const { data, error } = await sb.rpc('dh_admin_set_password', {
    p_user_id: player.id,
    p_password: NEW,
  });
  check('the admin can set a new password', !error, error?.message ?? '');
  check('and is shown which account it was', data?.email === player.email, JSON.stringify(data));

  const { error: tooShort } = await sb.rpc('dh_admin_set_password', {
    p_user_id: player.id, p_password: 'short',
  });
  check('a too-short password is refused', !!tooShort);

  const logged = (await db.query(
    `SELECT COUNT(*)::int n FROM admin_actions WHERE target_id = $1 AND action = 'set_password'`,
    [player.id],
  )).rows[0];
  check('the reset is written to the audit log', logged.n >= 1);
}

console.log('\nThe player gets back in');
{
  const sb = client();
  const { error } = await sb.auth.signInWithPassword({ email: player.email, password: NEW });
  check('the new password works on the normal sign-in form', !error, error?.message ?? '');

  const old = client();
  const { error: oldErr } = await old.auth.signInWithPassword({
    email: player.email, password: LOST,
  });
  check('the forgotten password no longer works', !!oldErr);
}

await db.query('DELETE FROM auth.users WHERE id = ANY($1)', [[player.id, admin.id, nosy.id]]);
await db.end();
console.log(`\n${passed} passed, ${failed} failed\n`);
process.exit(failed ? 1 : 0);
