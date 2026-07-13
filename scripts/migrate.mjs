// Applies each SQL file in supabase/migrations exactly once, in order.
//
//   node scripts/migrate.mjs
//   node scripts/migrate.mjs --mark 0001_init.sql   (record as applied without running)
//
// Every applied file is recorded in schema_migrations, so re-running this is a
// no-op. It used to replay every file each time, which re-ran 0001 -- and 0001
// dropped the tables. That deleted a live player's profile. Never again.
import { readdir, readFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import dotenv from 'dotenv';
import pg from 'pg';

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const dir = join(root, 'supabase', 'migrations');

dotenv.config({ path: join(root, '.env.local') });

const url = process.env.SUPABASE_DB_URL;
if (!url) {
  console.error('SUPABASE_DB_URL is not set. See .env.example.');
  process.exit(1);
}

const markIndex = process.argv.indexOf('--mark');
const markOnly = markIndex !== -1 ? process.argv.slice(markIndex + 1) : null;

const db = new pg.Client({ connectionString: url, ssl: { rejectUnauthorized: false } });
await db.connect();

await db.query(`
  CREATE TABLE IF NOT EXISTS schema_migrations (
    name       TEXT PRIMARY KEY,
    applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
  )
`);

const applied = new Set(
  (await db.query('SELECT name FROM schema_migrations')).rows.map((r) => r.name),
);

// `--mark` records a file as applied without executing it: used once, to adopt a
// database whose schema was already built before this tracking existed.
if (markOnly) {
  for (const name of markOnly) {
    await db.query(
      'INSERT INTO schema_migrations (name) VALUES ($1) ON CONFLICT DO NOTHING',
      [name],
    );
    console.log(`marked ${name} as already applied`);
  }
  await db.end();
  process.exit(0);
}

const files = (await readdir(dir)).filter((f) => f.endsWith('.sql')).sort();
let ran = 0;

for (const file of files) {
  if (applied.has(file)) {
    console.log(`skip    ${file} (already applied)`);
    continue;
  }

  process.stdout.write(`apply   ${file} ... `);
  const sql = await readFile(join(dir, file), 'utf8');

  // One transaction per migration: a file that fails half way leaves nothing behind.
  try {
    await db.query('BEGIN');
    await db.query(sql);
    await db.query('INSERT INTO schema_migrations (name) VALUES ($1)', [file]);
    await db.query('COMMIT');
    console.log('ok');
    ran++;
  } catch (err) {
    await db.query('ROLLBACK');
    console.log('FAILED');
    console.error(`\n${err.message}\n`);
    await db.end();
    process.exit(1);
  }
}

console.log(ran === 0 ? 'database is up to date' : `applied ${ran} migration(s)`);
await db.end();
