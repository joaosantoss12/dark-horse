import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import dotenv from 'dotenv';
import pg from 'pg';
import { createClient } from '@supabase/supabase-js';

const root = 'c:/Users/souod/Desktop/juergen';
dotenv.config({ path: join(root, '.env.local') });

const db = new pg.Client({
  connectionString: process.env.SUPABASE_DB_URL,
  ssl: { rejectUnauthorized: false },
});
await db.connect();

const time = async (label, fn, n = 5) => {
  const times = [];
  for (let i = 0; i < n; i++) {
    const t = performance.now();
    await fn();
    times.push(performance.now() - t);
  }
  times.sort((a, b) => a - b);
  console.log(`${label.padEnd(42)} median ${times[Math.floor(n / 2)].toFixed(0)}ms   (min ${times[0].toFixed(0)}, max ${times[n - 1].toFixed(0)})`);
};

console.log('\n--- raw SQL, straight to Postgres ---');
await time('SELECT 1 (pure round trip)', () => db.query('SELECT 1'));
await time('dh_tick()', () => db.query('SELECT dh_tick()'));
await time('dh_get_room(1)', () => db.query('SELECT dh_get_room(1)'));
await time('dh_get_lobby()', () => db.query('SELECT dh_get_lobby()'));

console.log('\n--- through PostgREST, as the browser does ---');
const sb = createClient(process.env.VITE_SUPABASE_URL, process.env.VITE_SUPABASE_ANON_KEY, {
  auth: { persistSession: false },
});
// Need a session for the authenticated-only RPCs.
const stamp = Date.now();
const EMAIL = `dh.bench.${stamp}@gmail.com`;
const PASSWORD = 'correct-horse-battery-staple';
await db.query(
  `INSERT INTO auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
     raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
     confirmation_token, recovery_token, email_change, email_change_token_new)
   VALUES ('00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated',
     $1, crypt($2, gen_salt('bf')), now(), '{"provider":"email","providers":["email"]}'::jsonb,
     '{}'::jsonb, now(), now(), '', '', '', '')`,
  [EMAIL, PASSWORD],
);
const uid = (await db.query('SELECT id FROM auth.users WHERE email=$1', [EMAIL])).rows[0].id;

await time('auth.signInWithPassword', async () => {
  await sb.auth.signInWithPassword({ email: EMAIL, password: PASSWORD });
});
await time('rpc dh_get_lobby', () => sb.rpc('dh_get_lobby'));
await time('rpc dh_get_room(1)', () => sb.rpc('dh_get_room', { p_room_id: 1 }));
await time('select profiles (own row)', () => sb.from('profiles').select('*').eq('id', uid).single());

await db.query('DELETE FROM auth.users WHERE id=$1', [uid]);
await db.end();
