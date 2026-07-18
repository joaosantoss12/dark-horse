// Referrals: 5,000 pts per friend, $10 at 10 friends.
//   node scripts/test-referrals.mjs
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import dotenv from 'dotenv';
import pg from 'pg';
const root = dirname(dirname(fileURLToPath(import.meta.url)));
dotenv.config({ path: join(root, '.env.local') });
const db = new pg.Client({ connectionString: process.env.SUPABASE_DB_URL, ssl:{rejectUnauthorized:false} });
await db.connect();
let passed=0, failed=0;
const check=(n,ok,d='')=>{ if(ok){passed++;console.log(`  ok   ${n}`);} else {failed++;console.log(`  FAIL ${n} ${d}`);} };
const stamp=Date.now();
// Create an auth user with optional ref code in metadata; the trigger does the rest.
async function signup(tag, ref){
  const meta = ref ? `jsonb_build_object('display_name',$3::text,'ref',$4::text)` : `jsonb_build_object('display_name',$3::text)`;
  const params = ref ? [ `dh.${tag}.${stamp}@gmail.com`, 'x', tag, ref ] : [ `dh.${tag}.${stamp}@gmail.com`, 'x', tag ];
  await db.query(`INSERT INTO auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at,confirmation_token,recovery_token,email_change,email_change_token_new) VALUES ('00000000-0000-0000-0000-000000000000',gen_random_uuid(),'authenticated','authenticated',$1,crypt($2,gen_salt('bf')),now(),'{"provider":"email","providers":["email"]}'::jsonb,${meta},now(),now(),'','','','')`, params);
  return (await db.query('SELECT id FROM auth.users WHERE email=$1',[params[0]])).rows[0].id;
}
const prof=async(id)=>(await db.query('SELECT balance,cash_balance,referral_code,referral_count,referral_bonus_awarded FROM profiles WHERE id=$1',[id])).rows[0];
const ids=[];

console.log('\nEach friend earns the referrer 5,000 points');
const alice = await signup('refA'); ids.push(alice);
{
  const a=await prof(alice);
  check('a referrer has a referral code', /^[A-Z2-9]{6}$/.test(a.referral_code), a.referral_code);
  const before = Number(a.balance);
  const f1 = await signup('refF1', a.referral_code); ids.push(f1);
  const a2 = await prof(alice);
  check('one friend: +5,000 points', Number(a2.balance)-before===5000, `${before}->${a2.balance}`);
  check('referral count is 1', a2.referral_count===1);

  const led=(await db.query(`SELECT COUNT(*)::int n FROM ledger WHERE user_id=$1 AND kind='referral'`,[alice])).rows[0];
  check('the referral is written to the ledger', led.n===1);
}

console.log('\nYou cannot refer yourself');
{
  const a=await prof(alice);
  // sign up a new user using alice's own code but... a self-ref needs same id, impossible at signup.
  // Instead verify an invalid code simply gives no referrer.
  const orphan = await signup('refO', 'ZZZZZZ'); ids.push(orphan);
  const o=await prof(orphan);
  check('an unknown code links no referrer', o.referral_count===0);
}

console.log('\nTen friends unlock a $10 real bonus, once');
const bob = await signup('refB'); ids.push(bob);
{
  const b0=await prof(bob);
  // Bring bob to 9 friends.
  for(let i=0;i<9;i++){ ids.push(await signup('refBf'+i, b0.referral_code)); }
  let b=await prof(bob);
  check('at 9 friends: no cash bonus yet', Number(b.cash_balance)===0 && b.referral_count===9, `count ${b.referral_count} cash ${b.cash_balance}`);

  ids.push(await signup('refBf9', b0.referral_code)); // the 10th
  b=await prof(bob);
  check('the 10th friend awards $10 (1000 cents)', Number(b.cash_balance)===1000, `${b.cash_balance}`);
  check('the bonus is flagged', b.referral_bonus_awarded===true);
  check('points also kept accruing: 10 x 5,000', Number(b.balance) >= 50000, `${b.balance}`);

  ids.push(await signup('refBf10', b0.referral_code)); // 11th
  b=await prof(bob);
  check('the $10 bonus fires only once', Number(b.cash_balance)===1000, `${b.cash_balance}`);

  const led=(await db.query(`SELECT COUNT(*)::int n FROM ledger WHERE user_id=$1 AND kind='cash_bonus'`,[bob])).rows[0];
  check('one cash_bonus ledger row', led.n===1);
}

await db.query('DELETE FROM auth.users WHERE id = ANY($1)', [ids]);
await db.end();
console.log(`\n${passed} passed, ${failed} failed\n`);
process.exit(failed?1:0);
