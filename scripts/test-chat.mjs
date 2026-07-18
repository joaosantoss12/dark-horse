// Chat: send rules + real-money now joinable.
//   node scripts/test-chat.mjs
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import dotenv from 'dotenv';
import pg from 'pg';
import { createClient } from '@supabase/supabase-js';
const root = dirname(dirname(fileURLToPath(import.meta.url)));
dotenv.config({ path: join(root, '.env.local') });
const db = new pg.Client({ connectionString: process.env.SUPABASE_DB_URL, ssl:{rejectUnauthorized:false} });
await db.connect();
let passed=0, failed=0;
const check=(n,ok,d='')=>{ if(ok){passed++;console.log(`  ok   ${n}`);} else {failed++;console.log(`  FAIL ${n} ${d}`);} };
const stamp=Date.now(), PW='correct-horse-battery-staple';
async function mk(tag){
  const email=`dh.${tag}.${stamp}@gmail.com`;
  await db.query(`INSERT INTO auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at,confirmation_token,recovery_token,email_change,email_change_token_new) VALUES ('00000000-0000-0000-0000-000000000000',gen_random_uuid(),'authenticated','authenticated',$1,crypt($2,gen_salt('bf')),now(),'{"provider":"email","providers":["email"]}'::jsonb,jsonb_build_object('display_name',$3::text),now(),now(),'','','','')`,[email,PW,tag]);
  const id=(await db.query('SELECT id FROM auth.users WHERE email=$1',[email])).rows[0].id;
  const sb=createClient(process.env.VITE_SUPABASE_URL,process.env.VITE_SUPABASE_ANON_KEY,{auth:{persistSession:false,autoRefreshToken:false}});
  await sb.auth.signInWithPassword({email,password:PW});
  return {id,sb};
}
const p=await mk('chat');

console.log('\nChat basics');
{
  const { error } = await p.sb.rpc('dh_send_chat', { p_room_id: null, p_body: 'Good luck! 🍀' });
  check('a global message sends', !error, error?.message ?? '');

  const { data: hist } = await p.sb.rpc('dh_chat_history', { p_room_id: null });
  check('it appears in history', (hist ?? []).some((m) => m.body.includes('Good luck')));

  const { error: empty } = await p.sb.rpc('dh_send_chat', { p_room_id: null, p_body: '   ' });
  check('an empty message is refused', !!empty);

  const { error: long } = await p.sb.rpc('dh_send_chat', { p_room_id: null, p_body: 'x'.repeat(201) });
  check('over 200 chars is refused', !!long);

  // Rate limit: a second message immediately should be blocked.
  const { error: fast } = await p.sb.rpc('dh_send_chat', { p_room_id: null, p_body: 'again' });
  check('too-fast messages are rate-limited', !!fast, 'no rate limit!');
}

console.log('\nBanned players cannot chat');
{
  await db.query('UPDATE profiles SET is_banned = true WHERE id = $1', [p.id]);
  await new Promise(r=>setTimeout(r, 1600)); // clear the rate limit window
  const { error } = await p.sb.rpc('dh_send_chat', { p_room_id: null, p_body: 'let me in' });
  check('a banned player is blocked', !!error, 'a banned player chatted!');
  await db.query('UPDATE profiles SET is_banned = false WHERE id = $1', [p.id]);
}

console.log('\nA player cannot forge a message row directly');
{
  const { data } = await p.sb.from('chat_messages').insert({ user_id: p.id, name: 'Faker', body: 'x' }).select();
  check('direct insert into chat is blocked by RLS', !data || data.length === 0);
}

console.log('\nReal money is now open');
{
  const cashRoom = (await db.query(`SELECT id FROM rooms WHERE mode='cash' AND is_active ORDER BY sort_order LIMIT 1`)).rows[0];
  await db.query('UPDATE profiles SET cash_balance = 10000 WHERE id = $1', [p.id]); // $100
  const { error } = await p.sb.rpc('dh_join_room', { p_room_id: cashRoom.id });
  check('a funded player can now join a real-money table', !error, error?.message ?? '');
  const seated = (await db.query('SELECT COUNT(*)::int n FROM seats WHERE room_id=$1 AND user_id=$2',[cashRoom.id,p.id])).rows[0];
  check('and is seated', seated.n === 1);
  await p.sb.rpc('dh_leave_room', { p_room_id: cashRoom.id });
}

await db.query('DELETE FROM auth.users WHERE id = $1', [p.id]);
await db.end();
console.log(`\n${passed} passed, ${failed} failed\n`);
process.exit(failed?1:0);
