// Does the dealer go round the table, one card at a time?
//   node scripts/test-dealing.mjs
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import dotenv from 'dotenv';
import pg from 'pg';

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

const one = async (sql, params) => (await db.query(sql, params)).rows[0];

// Rather than sit through a real deal, wind the clock: put dealt_at in the past
// by exactly the number of seconds we want to inspect.
async function viewAt(roomId, roundId, seconds) {
  await db.query(
    `UPDATE rounds SET dealt_at = now() - ($2 * interval '1 second') WHERE id = $1`,
    [roundId, seconds],
  );
  return (await one(`SELECT dh_get_room($1) AS r`, [roomId])).r;
}

/** Which cards are face up, as "seat:card" pairs. */
const faceUp = (view) =>
  view.players.flatMap((p) =>
    (p.deals[view.deal - 1]?.cards ?? []).flatMap((c, i) => (c ? [`${p.seat}:${i + 1}`] : [])),
  );

/** How many cards are on the felt in front of each seat, face down or up. */
const onFelt = (view) =>
  view.players.reduce((n, p) => n + (p.deals[view.deal - 1]?.laid ?? 0), 0);

for (const seats of [4, 8]) {
  console.log(`\nA ${seats}-seat table`);

  const room = await one(
    `INSERT INTO rooms (name, seats, buy_in, prizes, mode, sort_order)
     VALUES ($1, $2, 0, $3::bigint[], 'free', 95) RETURNING id`,
    [`DEALTEST${seats}`, seats, seats === 8 ? [4, 3, 2, 1] : [2, 1]],
  );
  await db.query(
    `INSERT INTO seats (room_id, seat_index, bot_name)
     SELECT $1, i, 'Bot ' || i FROM generate_series(0, $2::int) i`,
    [room.id, seats - 1],
  );

  const roundId = (await one(`SELECT dh_deal($1) AS id`, [room.id])).id;

  const gap = Number((await one('SELECT dh_seat_gap() g')).g);
  const flip = Number((await one('SELECT dh_flip_delay() f')).f);
  const hold = Number((await one('SELECT dh_score_hold() h')).h);
  const len = Number((await one('SELECT dh_deal_len($1) l', [seats])).l);

  check(`a deal is ${(seats * 3 * gap + hold).toFixed(1)}s: one card per seat per card, then the scores`,
    Math.abs(len - (seats * 3 * gap + hold)) < 0.01, `${len}s`);

  // The whole point: a card is put down, sits face down, and only then turns.
  const t0 = await viewAt(room.id, roundId, 0.15);
  check('the first card is on the felt straight away', onFelt(t0) === 1, `${onFelt(t0)} cards`);
  check('...but it is still face down', faceUp(t0).length === 0, faceUp(t0).join(' '));

  const tJustBefore = await viewAt(room.id, roundId, flip - 0.15);
  check('it stays face down for the whole pause', faceUp(tJustBefore).length === 0);

  const tJustAfter = await viewAt(room.id, roundId, flip + 0.15);
  check('then it turns over', faceUp(tJustAfter).join() === '0:1', faceUp(tJustAfter).join(' '));
  check('and the next player has nothing yet', onFelt(tJustAfter) === 1, `${onFelt(tJustAfter)}`);

  // Card k (1, 2, 3...) is laid at (k-1)*gap and turns at (k-1)*gap + flip.
  const turned = (k) => (k - 1) * gap + flip + 0.15;

  const t2 = await viewAt(room.id, roundId, turned(2));
  check('then the next seat gets its first card',
    faceUp(t2).sort().join() === '0:1,1:1', faceUp(t2).sort().join(' '));

  const tRound1 = await viewAt(room.id, roundId, turned(seats));
  const up1 = faceUp(tRound1);
  check('the dealer finishes the lap before starting the second card',
    up1.length === seats && up1.every((x) => x.endsWith(':1')),
    up1.sort().join(' '));

  const tNext = await viewAt(room.id, roundId, turned(seats + 1));
  check('the second card starts back at the first seat',
    faceUp(tNext).includes('0:2') &&
      faceUp(tNext).filter((x) => x.endsWith(':2')).length === 1,
    faceUp(tNext).sort().join(' '));

  // Mid-deal, no score has leaked -- the scores wait for the last card.
  const midScores = tNext.players.every((p) => p.deals[tNext.deal - 1].score === null);
  check('no score is read out until every card has turned', midScores);

  // After the last card of deal 1 turns, everyone has 3 cards and a score.
  const tScored = await viewAt(room.id, roundId, turned(seats * 3) + 0.1);
  check('once the lap is done, every seat holds 3 cards',
    faceUp(tScored).length === seats * 3, `${faceUp(tScored).length} cards`);
  check('and only then are the scores shown',
    tScored.players.every((p) => p.deals[0].score !== null));

  // Deal 2 starts, and deal 1 stays face up behind it.
  const tDeal2 = await viewAt(room.id, roundId, len + flip + 0.15);
  check('deal 2 begins with the first seat',
    tDeal2.deal === 2 && tDeal2.players.find((p) => p.seat === 0).deals[1].cards[0] !== null,
    `deal=${tDeal2.deal}`);
  check('deal 1 is still face up behind it',
    tDeal2.players.every((p) => p.deals[0].cards.every((c) => c !== null)));
  check('deal 3 has not leaked',
    tDeal2.players.every((p) => p.deals[2].cards.every((c) => c === null)));

  // And the table can point at whoever the dealer is serving.
  check('the table knows which seat the dealer is at',
    typeof tDeal2.dealingSeat === 'number', JSON.stringify(tDeal2.dealingSeat));

  await db.query('DELETE FROM rooms WHERE id = $1', [room.id]);
}

await db.end();
console.log(`\n${passed} passed, ${failed} failed\n`);
process.exit(failed ? 1 : 0);
