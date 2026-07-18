// Three balances, mode-aware money movement, and the demo->real funnel.
//   node scripts/test-funnel.mjs
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
const bal=async(id)=>{const r=(await db.query('SELECT balance,demo_balance,cash_balance,demo_bonus_awarded,withdraw_unlocked FROM profiles WHERE id=$1',[id])).rows[0];return r;};

console.log('\nWelcome bonus');
const p=await mk('fu');
{
  const b=await bal(p.id);
  check('new user gets 10,000 points', Number(b.balance)===10000, `${b.balance}`);
  check('and $5.00 demo (500 cents)', Number(b.demo_balance)===500, `${b.demo_balance}`);
  check('and $0 real cash', Number(b.cash_balance)===0);
}

console.log('\nMoney comes from the balance that matches the table mode');
async function roomOf(mode){ return (await db.query(`SELECT id,buy_in FROM rooms WHERE mode=$1 AND is_active ORDER BY sort_order LIMIT 1`,[mode])).rows[0]; }
{
  // Demo table: buy-in should leave demo_balance, not points or cash.
  await db.query('UPDATE profiles SET demo_balance=10000 WHERE id=$1',[p.id]); // $100 demo to play
  const demoRoom = await roomOf('demo');
  const before = await bal(p.id);
  await p.sb.rpc('dh_join_room',{p_room_id:demoRoom.id});
  const after = await bal(p.id);
  check('demo buy-in leaves the demo balance',
    Number(before.demo_balance)-Number(after.demo_balance)===Number(demoRoom.buy_in), `${before.demo_balance}->${after.demo_balance}`);
  check('demo buy-in does not touch points', Number(after.balance)===Number(before.balance));
  check('demo buy-in does not touch cash', Number(after.cash_balance)===Number(before.cash_balance));
  await p.sb.rpc('dh_leave_room',{p_room_id:demoRoom.id});
  check('leaving refunds the demo balance', Number((await bal(p.id)).demo_balance)===Number(before.demo_balance));
}

console.log('\nReal-money tables stay locked');
{
  const cashRoom = await roomOf('cash');
  const { error } = await p.sb.rpc('dh_join_room',{p_room_id:cashRoom.id});
  check('a cash table cannot be joined while locked', !!error, 'it let me in!');
}

console.log('\nThe demo -> real bonus funnel');
{
  // Reset flags, push demo just under the $30 goal, then over it, and settle.
  await db.query('UPDATE profiles SET demo_balance=2900, cash_balance=0, demo_bonus_awarded=false, withdraw_unlocked=false WHERE id=$1',[p.id]);
  await db.query('SELECT dh_check_milestones($1)',[p.id]);
  let b=await bal(p.id);
  check('below $30 demo: no bonus yet', Number(b.cash_balance)===0 && b.demo_bonus_awarded===false);

  await db.query('UPDATE profiles SET demo_balance=3000 WHERE id=$1',[p.id]); // hit $30
  await db.query('SELECT dh_check_milestones($1)',[p.id]);
  b=await bal(p.id);
  check('reaching $30 demo awards a real $5 bonus', Number(b.cash_balance)===500, `${b.cash_balance}`);
  check('the bonus is flagged so it cannot repeat', b.demo_bonus_awarded===true);

  // Call again: must not double-award.
  await db.query('UPDATE profiles SET demo_balance=5000 WHERE id=$1',[p.id]);
  await db.query('SELECT dh_check_milestones($1)',[p.id]);
  check('the bonus fires exactly once', Number((await bal(p.id)).cash_balance)===500);

  const led=(await db.query(`SELECT COUNT(*)::int n FROM ledger WHERE user_id=$1 AND kind='cash_bonus'`,[p.id])).rows[0];
  check('the bonus is written to the ledger', led.n===1);
}

console.log('\nWithdrawal unlocks at $50 real');
{
  await db.query('UPDATE profiles SET cash_balance=4999, withdraw_unlocked=false WHERE id=$1',[p.id]);
  await db.query('SELECT dh_check_milestones($1)',[p.id]);
  check('below $50: withdrawal stays locked', (await bal(p.id)).withdraw_unlocked===false);

  await db.query('UPDATE profiles SET cash_balance=5000 WHERE id=$1',[p.id]);
  await db.query('SELECT dh_check_milestones($1)',[p.id]);
  check('reaching $50 real unlocks withdrawal', (await bal(p.id)).withdraw_unlocked===true);
}

console.log('\nOne free-play table only');
{
  const free=(await db.query(`SELECT COUNT(*)::int n FROM rooms WHERE mode='free' AND is_active`)).rows[0];
  check('exactly one active free-play table', free.n===1, `${free.n}`);
}

await db.query('DELETE FROM auth.users WHERE id=$1',[p.id]);
await db.end();
console.log(`\n${passed} passed, ${failed} failed\n`);
process.exit(failed?1:0);
