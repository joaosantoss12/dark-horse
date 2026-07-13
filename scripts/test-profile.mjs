// Profile + avatar storage rules, attacked from a real player's session.
//   node scripts/test-profile.mjs
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

const PASSWORD = 'correct-horse-battery-staple';
const stamp = Date.now();

async function makePlayer(tag) {
  const email = `dh.${tag}.${stamp}@gmail.com`;
  await db.query(
    `INSERT INTO auth.users (instance_id, id, aud, role, email, encrypted_password,
       email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
       confirmation_token, recovery_token, email_change, email_change_token_new)
     VALUES ('00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated',
       'authenticated', $1, crypt($2, gen_salt('bf')), now(),
       '{"provider":"email","providers":["email"]}'::jsonb,
       jsonb_build_object('display_name', $3::text), now(), now(), '', '', '', '')`,
    [email, PASSWORD, tag],
  );
  const id = (await db.query('SELECT id FROM auth.users WHERE email = $1', [email])).rows[0].id;

  const client = createClient(process.env.VITE_SUPABASE_URL, process.env.VITE_SUPABASE_ANON_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  await client.auth.signInWithPassword({ email, password: PASSWORD });
  return { id, client, email };
}

const alice = await makePlayer('alice');
const mallory = await makePlayer('mallory');

// A 1x1 PNG.
const png = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  'base64',
);
const blob = new Blob([png], { type: 'image/png' });

// Unique per run, so a crashed run cannot make the next one fail on "name taken".
const ALICE_NAME = `Alice${stamp % 100000}`;

console.log('\nDisplay name');
{
  const { error } = await alice.client.rpc('dh_update_profile', {
    p_display_name: ALICE_NAME, p_avatar_url: null,
  });
  check('a player can set their own name', !error, error?.message ?? '');

  const row = (await db.query('SELECT display_name FROM profiles WHERE id = $1', [alice.id])).rows[0];
  check('the name is saved', row.display_name === ALICE_NAME, row.display_name);

  // Same name, different case: the check is case-insensitive.
  const { error: dupe } = await mallory.client.rpc('dh_update_profile', {
    p_display_name: ALICE_NAME.toLowerCase(), p_avatar_url: null,
  });
  check('another player cannot take the same name', !!dupe);

  const { error: short } = await alice.client.rpc('dh_update_profile', {
    p_display_name: 'A', p_avatar_url: null,
  });
  check('a one-character name is rejected', !!short);

  // The balance must not be reachable through the profile editor.
  await alice.client.from('profiles').update({ balance: 999999 }).eq('id', alice.id);
  const bal = (await db.query('SELECT balance FROM profiles WHERE id = $1', [alice.id])).rows[0];
  check('editing a profile cannot touch the balance', Number(bal.balance) === 1000, `${bal.balance}`);
}

console.log('\nAvatar upload');
{
  const { error } = await alice.client.storage
    .from('avatars')
    .upload(`${alice.id}/avatar.png`, blob, { upsert: true, contentType: 'image/png' });
  check('a player can upload their own avatar', !error, error?.message ?? '');

  // The whole point of the folder-per-user policy.
  const { error: hijack } = await mallory.client.storage
    .from('avatars')
    .upload(`${alice.id}/avatar.png`, blob, { upsert: true, contentType: 'image/png' });
  check('a player cannot overwrite someone else\'s avatar', !!hijack, 'the upload succeeded!');

  const { error: del } = await mallory.client.storage
    .from('avatars')
    .remove([`${alice.id}/avatar.png`]);
  const stillThere = (await db.query(
    `SELECT COUNT(*)::int n FROM storage.objects WHERE bucket_id = 'avatars' AND name = $1`,
    [`${alice.id}/avatar.png`],
  )).rows[0].n;
  check('a player cannot delete someone else\'s avatar', stillThere === 1, `${del?.message ?? ''}`);

  // A non-image must be refused by storage, not just by the file picker.
  const evil = new Blob([Buffer.from('<script>alert(1)</script>')], { type: 'text/html' });
  const { error: mime } = await alice.client.storage
    .from('avatars')
    .upload(`${alice.id}/evil.html`, evil, { upsert: true, contentType: 'text/html' });
  check('a non-image file is rejected', !!mime, 'the upload succeeded!');

  const bucket = (await db.query(
    `SELECT file_size_limit, allowed_mime_types FROM storage.buckets WHERE id = 'avatars'`,
  )).rows[0];
  check('the bucket caps uploads at 2 MB', Number(bucket.file_size_limit) === 2097152);
}

console.log('\nStats');
{
  const { data, error } = await alice.client.rpc('dh_my_stats');
  check('a player can read their own stats', !error, error?.message ?? '');
  check('a player with no hands has a zeroed record',
    data?.handsPlayed === 0 && data?.net === 0, JSON.stringify(data));
}

// Clean up. Storage rows cannot be deleted with SQL -- Supabase blocks it so the
// files themselves cannot be orphaned -- so each owner removes their own.
await alice.client.storage.from('avatars').remove([`${alice.id}/avatar.png`]);
await mallory.client.storage.from('avatars').remove([`${mallory.id}/avatar.png`]);
await db.query('DELETE FROM auth.users WHERE id = ANY($1)', [[alice.id, mallory.id]]);

console.log(`\n${passed} passed, ${failed} failed\n`);
await db.end();
process.exit(failed ? 1 : 0);
