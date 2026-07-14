// Does a balance change actually reach the browser without a reload?
//   node scripts/test-realtime.mjs
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
const EMAIL = `dh.rt.${stamp}@gmail.com`;
const PASSWORD = 'correct-horse-battery-staple';

await db.query(
  `INSERT INTO auth.users (instance_id, id, aud, role, email, encrypted_password,
     email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
     confirmation_token, recovery_token, email_change, email_change_token_new)
   VALUES ('00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated',
     'authenticated', $1, crypt($2, gen_salt('bf')), now(),
     '{"provider":"email","providers":["email"]}'::jsonb,
     jsonb_build_object('display_name', $3::text), now(), now(), '', '', '', '')`,
  [EMAIL, PASSWORD, `RT${stamp % 100000}`],
);
const uid = (await db.query('SELECT id FROM auth.users WHERE email = $1', [EMAIL])).rows[0].id;

const sb = createClient(process.env.VITE_SUPABASE_URL, process.env.VITE_SUPABASE_ANON_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});
await sb.auth.signInWithPassword({ email: EMAIL, password: PASSWORD });

// Exactly what the app subscribes to in useAuth.
const events = [];
const channel = sb
  .channel(`profile:${uid}`)
  .on(
    'postgres_changes',
    { event: 'UPDATE', schema: 'public', table: 'profiles', filter: `id=eq.${uid}` },
    (payload) => events.push(payload.new),
  );

const subscribed = await new Promise((resolve) => {
  channel.subscribe((status) => {
    if (status === 'SUBSCRIBED') resolve(true);
    if (status === 'CHANNEL_ERROR' || status === 'TIMED_OUT') resolve(false);
  });
  setTimeout(() => resolve(false), 12000);
});
check('the browser can subscribe to its own profile', subscribed);

console.log('\nA prize lands while the player is just sitting there...');
const started = Date.now();
await db.query('UPDATE profiles SET balance = balance + 250 WHERE id = $1', [uid]);

await new Promise((r) => setTimeout(r, 4000));

check('the new balance is pushed to the browser', events.length > 0,
  '-- no event arrived, the player would have to reload');

if (events.length) {
  const took = Date.now() - started;
  // A new account starts at $0, so a $250 prize lands them on $250.
  check('the payload carries the new balance', Number(events[0].balance) === 250,
    `got ${events[0].balance}`);
  console.log(`  (arrived in ~${took}ms)`);
}

await sb.removeChannel(channel);
await db.query('DELETE FROM auth.users WHERE id = $1', [uid]);
await db.end();

console.log(`\n${passed} passed, ${failed} failed\n`);
process.exit(failed ? 1 : 0);
