// Deposit/withdraw logging + admin cash adjustment (cents).
//   node scripts/test-payments.mjs
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import dotenv from 'dotenv';
import pg from 'pg';
import { createClient } from '@supabase/supabase-js';

const root = dirname(dirname(fileURLToPath(import.meta.url)));
dotenv.config({ path: join(root, '.env.local') });

const db = new pg.Client({ connectionString: process.env.SUPABASE_DB_URL, ssl: { rejectUnauthorized: false } });
await db.connect();
let passed = 0, failed = 0;
const check = (n, ok, d='') => { if (ok){passed++;console.log(`  ok   ${n}`);} else {failed++;console.log(`  FAIL ${n} ${d}`);} };

const stamp = Date.now();
const PW = 'correct-horse-battery-staple';
async function mk(tag) {
  const email = `dh.${tag}.${stamp}@gmail.com`;
  await db.query(`INSERT INTO auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at,confirmation_token,recovery_token,email_change,email_change_token_new) VALUES ('00000000-0000-0000-0000-000000000000',gen_random_uuid(),'authenticated','authenticated',$1,crypt($2,gen_salt('bf')),now(),'{"provider":"email","providers":["email"]}'::jsonb,jsonb_build_object('display_name',$3::text),now(),now(),'','','','')`, [email, PW, tag]);
  const id = (await db.query('SELECT id FROM auth.users WHERE email=$1',[email])).rows[0].id;
  const sb = createClient(process.env.VITE_SUPABASE_URL, process.env.VITE_SUPABASE_ANON_KEY, { auth:{persistSession:false,autoRefreshToken:false} });
  await sb.auth.signInWithPassword({ email, password: PW });
  return { id, sb, email };
}
const cash = async (id) => Number((await db.query('SELECT cash_balance FROM profiles WHERE id=$1',[id])).rows[0].cash_balance);

const player = await mk('pay');
const admin = await mk('padmin');
await db.query('UPDATE profiles SET is_admin=true WHERE id=$1', [admin.id]);

console.log('\nA player logs a request; it moves no money');
{
  const before = await cash(player.id);
  await player.sb.rpc('dh_request_payment', { p_kind: 'deposit' });
  check('deposit request accepted', true);
  check('no money moved', (await cash(player.id)) === before);

  // Tapping again does not stack a second open row.
  await player.sb.rpc('dh_request_payment', { p_kind: 'deposit' });
  const open = (await db.query(`SELECT COUNT(*)::int n FROM payment_requests WHERE user_id=$1 AND kind='deposit' AND status='open'`,[player.id])).rows[0];
  check('tapping twice keeps one open row', open.n === 1, `${open.n}`);

  await player.sb.rpc('dh_request_payment', { p_kind: 'withdraw' });
  const kinds = (await db.query(`SELECT COUNT(DISTINCT kind)::int n FROM payment_requests WHERE user_id=$1 AND status='open'`,[player.id])).rows[0];
  check('deposit and withdraw are separate requests', kinds.n === 2);
}

console.log('\nA player cannot see or fake the queue');
{
  const { data: mine } = await player.sb.rpc('dh_request_payment', { p_kind: 'deposit' });
  check('own request returns an id', !!mine?.id);
  const { error } = await player.sb.rpc('dh_admin_payment_requests', { p_include_done: false });
  check('a non-admin cannot read the queue', !!error, 'it returned the queue!');
  const { data: direct } = await player.sb.from('payment_requests').select('*');
  check('and cannot read the table directly', (direct ?? []).length === 0, `read ${direct?.length}`);
}

console.log('\nAdmin sees the queue and settles a request');
{
  const { data: q, error } = await admin.sb.rpc('dh_admin_payment_requests', { p_include_done: false });
  check('admin reads the queue', !error, error?.message ?? '');
  check('the player is in it', q.some((r) => r.user_id === player.id));
  const row = q.find((r) => r.user_id === player.id);
  check('a row carries name and email', !!row.display_name && !!row.email);

  const { data: n } = await admin.sb.rpc('dh_admin_open_payment_count');
  check('the open count is reported', n >= 1, `${n}`);

  await admin.sb.rpc('dh_admin_resolve_payment', { p_id: row.id, p_status: 'done' });
  const still = (await db.query(`SELECT status FROM payment_requests WHERE id=$1`,[row.id])).rows[0];
  check('marking done updates the status', still.status === 'done');
}

console.log('\nAdmin credits real money, in cents');
{
  // $12.50 -> 1250 cents
  const after = await admin.sb.rpc('dh_admin_adjust_cash', { p_user_id: player.id, p_cents: 1250, p_note: 'test' });
  check('crediting returns the new balance', Number(after.data) === 1250, JSON.stringify(after.data));
  check('the cash balance carries cents', (await cash(player.id)) === 1250);

  const led = (await db.query(`SELECT amount, kind FROM ledger WHERE user_id=$1 AND kind='cash_credit'`,[player.id])).rows[0];
  check('the credit is written to the ledger, in cents', Number(led.amount) === 1250);

  // A non-admin must not be able to do this.
  const { error } = await player.sb.rpc('dh_admin_adjust_cash', { p_user_id: player.id, p_cents: 999999, p_note: 'hack' });
  check('a player cannot credit their own cash', !!error, 'IT WORKED -- money printer!');

  // Cannot go below zero.
  const { error: neg } = await admin.sb.rpc('dh_admin_adjust_cash', { p_user_id: player.id, p_cents: -5000, p_note: 'over' });
  check('cannot debit below $0', !!neg);
  check('the balance is unchanged after a rejected debit', (await cash(player.id)) === 1250);
}

await db.query('DELETE FROM auth.users WHERE id = ANY($1)', [[player.id, admin.id]]);
await db.end();
console.log(`\n${passed} passed, ${failed} failed\n`);
process.exit(failed ? 1 : 0);
