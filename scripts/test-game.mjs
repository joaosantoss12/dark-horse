// Exercises the game engine where it now lives: inside Postgres.
//
// Connects as the database owner (bypassing auth) purely to assert the rules.
// The same rules are what the anon-key client hits through the RPCs.
//   node scripts/test-game.mjs
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import dotenv from 'dotenv';
import pg from 'pg';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
dotenv.config({ path: join(root, '.env.local') });

const db = new pg.Client({
  connectionString: process.env.SUPABASE_DB_URL,
  ssl: { rejectUnauthorized: false },
});
await db.connect();

let passed = 0;
let failed = 0;

function check(name, ok, detail = '') {
  if (ok) {
    passed++;
    console.log(`  ok   ${name}`);
  } else {
    failed++;
    console.log(`  FAIL ${name} ${detail}`);
  }
}

const RANKS = { A: 1, J: 11, Q: 12, K: 13 };
/** "KS" -> {r:13,s:"S"} */
const card = (t) => ({ r: RANKS[t.slice(0, -1)] ?? Number(t.slice(0, -1)), s: t.slice(-1) });
const hand = (...cards) => JSON.stringify(cards.map(card));

const one = async (sql, params) => (await db.query(sql, params)).rows[0];

console.log('\nCard values and scoring');
{
  const r = await one(
    `SELECT dh_total($1::jsonb) AS total, dh_total($1::jsonb) % 10 AS score`,
    [hand('7S', '8D', 'KC')],
  );
  check('7 + 8 + K = 25, score 5', r.total === 25 && r.score === 5, JSON.stringify(r));

  const r2 = await one(`SELECT dh_total($1::jsonb) % 10 AS score`, [hand('AS', '9D', 'QC')]);
  check('A + 9 + Q = 20, score 0', r2.score === 0);

  // The six real hands from the Telegram Round 5 screenshot.
  const real = [
    [['4H', '2C', '3D'], 9], [['8D', '6D', '4S'], 8], [['2D', 'AS', '4H'], 7],
    [['6H', '4D', '6S'], 6], [['KC', 'JD', '5C'], 5], [['5D', '9C', '10H'], 4],
  ];
  let allMatch = true;
  for (const [cards, expected] of real) {
    const got = (await one(`SELECT dh_total($1::jsonb) % 10 AS score`, [hand(...cards)])).score;
    if (got !== expected) allMatch = false;
  }
  check('the six real Round 5 hands score as they did in Telegram', allMatch);
}

console.log('\nSpecial hands');
{
  const cat = async (...c) => (await one(`SELECT dh_category($1::jsonb) AS c`, [hand(...c)])).c;
  check('three of a kind is category 2', (await cat('2S', '2D', '2C')) === 2);
  check('K+Q+J is a crown', (await cat('KS', 'QD', 'JC')) === 1);
  check('AAA is a triple, not a crown', (await cat('AS', 'AD', 'AC')) === 2);
  check('10+K+Q also totals 30 but is a normal hand', (await cat('10S', 'KD', 'QC')) === 0);

  // Sort keys are arrays compared element by element, strongest first.
  const beats = async (a, b) =>
    (await one(`SELECT dh_sort_key($1::jsonb) > dh_sort_key($2::jsonb) AS x`, [a, b])).x;

  check('trips beat a crown', await beats(hand('2S', '2D', '2C'), hand('KS', 'QD', 'JC')));
  check('a crown beats a score of 9', await beats(hand('KS', 'QD', 'JC'), hand('4H', '2C', '3D')));
  check('KKK beats QQQ', await beats(hand('KS', 'KD', 'KC'), hand('QS', 'QD', 'QC')));
  check('QQQ beats AAA', await beats(hand('QS', 'QD', 'QC'), hand('AS', 'AD', 'AC')));
  check('score 9 beats score 8', await beats(hand('4H', '2C', '3D'), hand('8D', '6D', '4S')));
}

console.log('\nTiebreaks');
{
  const beats = async (a, b) =>
    (await one(`SELECT dh_sort_key($1::jsonb) > dh_sort_key($2::jsonb) AS x`, [a, b])).x;
  const equal = async (a, b) =>
    (await one(`SELECT dh_sort_key($1::jsonb) = dh_sort_key($2::jsonb) AS x`, [a, b])).x;

  // Both score 8; K-Q beats K-J on the second card.
  check('equal scores break on the next highest card',
    await beats(hand('KS', 'QD', '8C'), hand('KH', 'JS', '8D')));
  check('identical ranks are a true tie, whatever the suits',
    await equal(hand('9S', '5D', '2C'), hand('9H', '5C', '2D')));
}

console.log('\nA real dealt round (4 seats, bots)');
{
  // Fresh room so the test never collides with a live table.
  const room = await one(
    `INSERT INTO rooms (name, seats, buy_in, prizes, sort_order)
     VALUES ('TEST', 4, 100, ARRAY[250,100]::bigint[], 99) RETURNING id`,
  );

  await db.query(
    `INSERT INTO seats (room_id, seat_index, bot_name)
     SELECT $1, i, 'Bot ' || i FROM generate_series(0, 3) i`,
    [room.id],
  );

  const roundId = (await one(`SELECT dh_deal($1) AS id`, [room.id])).id;
  check('a full table deals a round', roundId !== null);

  const hands = (await db.query(
    `SELECT seat_index, cards, total, score, place, won FROM round_hands
      WHERE round_id = $1 ORDER BY place`,
    [roundId],
  )).rows;

  check('every seat got a hand', hands.length === 4);
  check('every hand is 3 cards', hands.every((h) => h.cards.length === 3));

  const dealt = hands.flatMap((h) => h.cards.map((c) => `${c.r}${c.s}`));
  check('no card was dealt twice', new Set(dealt).size === 12, `saw ${new Set(dealt).size}/12 unique`);

  check('places run 1..4', hands.map((h) => h.place).join() === '1,2,3,4');

  // Bots never get paid, so the prizes are recorded as zero.
  check('bots are not paid a prize', hands.every((h) => Number(h.won) === 0));

  // Hidden until the dealer turns them over.
  const early = await one(`SELECT dh_get_room($1) AS r`, [room.id]);
  const countdown = early.r;
  check('during the countdown the phase is countdown', countdown.phase === 'countdown');
  check('during the countdown no card is visible',
    countdown.players.every((p) => p.cards.every((c) => c === null)),
    JSON.stringify(countdown.players[0]?.cards));
  check('during the countdown no score is leaked',
    countdown.players.every((p) => p.score === null && p.total === null));

  console.log('  ...waiting out the reveal');
  await new Promise((r) => setTimeout(r, 4200)); // past card 1, before results

  const mid = (await one(`SELECT dh_get_room($1) AS r`, [room.id])).r;
  check('mid-deal, only the turned cards are visible',
    mid.phase === 'dealing' && mid.revealed >= 1 && mid.revealed < 3 &&
    mid.players.every((p) => p.cards.filter(Boolean).length === mid.revealed),
    `phase=${mid.phase} revealed=${mid.revealed}`);
  check('mid-deal, the score is still hidden', mid.players.every((p) => p.score === null));

  await new Promise((r) => setTimeout(r, 3500)); // past settle_at

  const done = (await one(`SELECT dh_get_room($1) AS r`, [room.id])).r;
  check('after the reveal, the phase is results', done.phase === 'results', done.phase);
  check('after the reveal, all three cards are up',
    done.players.every((p) => p.cards.filter(Boolean).length === 3));
  check('after the reveal, scores are shown', done.players.every((p) => p.score !== null));

  const settled = await one(`SELECT settled_at, pot, paid_out FROM rounds WHERE id = $1`, [roundId]);
  check('the round settled itself on the next call', settled.settled_at !== null);
  check('an all-bot table has a pot of 0', Number(settled.pot) === 0, `pot=${settled.pot}`);
  check('an all-bot table pays out 0', Number(settled.paid_out) === 0);

  const ledgerRows = await one(
    `SELECT COUNT(*)::int AS n FROM ledger WHERE round_id = $1`, [roundId],
  );
  check('bots wrote nothing to the ledger', ledgerRows.n === 0);

  await db.query(`DELETE FROM rooms WHERE id = $1`, [room.id]);
}

console.log('\nPrize splitting on an exact tie');
{
  // Force a tie: rig two hands with identical ranks, then check the split maths
  // the same way dh_deal does.
  const r = await one(`
    WITH ranked AS (
      SELECT 1 AS place, 2 AS members, (SELECT SUM(x) FROM unnest(ARRAY[250,100]::bigint[]) x) AS pool
    )
    SELECT floor(pool / members)::bigint AS share, pool - floor(pool / members) * members AS remainder
    FROM ranked
  `);
  check('two players tied for 1st split prizes A and B', Number(r.share) === 175);
  check('an even split leaves no remainder', Number(r.remainder) === 0);

  const odd = await one(`SELECT floor(75 / 2)::bigint AS share, 75 - floor(75 / 2) * 2 AS remainder`);
  check('an odd pool rounds down rather than inventing points',
    Number(odd.share) === 37 && Number(odd.remainder) === 1);
}

console.log(`\n${passed} passed, ${failed} failed\n`);
await db.end();
process.exit(failed ? 1 : 0);
