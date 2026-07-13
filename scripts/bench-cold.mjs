// Is the first request slow because the data is slow, or because the connection
// to Supabase has to be built from scratch (DNS + TCP + TLS)?
//   node scripts/bench-cold.mjs
import { connect } from 'node:tls';
import { lookup } from 'node:dns/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import dotenv from 'dotenv';

const root = dirname(dirname(fileURLToPath(import.meta.url)));
dotenv.config({ path: join(root, '.env.local') });

const URL_ = process.env.VITE_SUPABASE_URL;
const KEY = process.env.VITE_SUPABASE_ANON_KEY;
const host = new URL(URL_).hostname;

const time = async (fn) => {
  const t = performance.now();
  await fn();
  return performance.now() - t;
};

const median = (xs) => xs.sort((a, b) => a - b)[Math.floor(xs.length / 2)];

// 1. What does it cost just to open a secure connection to Supabase?
const handshakes = [];
for (let i = 0; i < 4; i++) {
  handshakes.push(
    await time(
      () =>
        new Promise((resolve, reject) => {
          const socket = connect({ host, port: 443, servername: host }, () => {
            socket.end();
            resolve();
          });
          socket.on('error', reject);
        }),
    ),
  );
}

const dns = [];
for (let i = 0; i < 3; i++) dns.push(await time(() => lookup(host)));

// 2. And what does the query itself cost, once the connection is warm?
const hit = () =>
  fetch(`${URL_}/rest/v1/rooms?select=id&limit=1`, {
    headers: { apikey: KEY, authorization: `Bearer ${KEY}` },
  }).then((r) => r.text());

const first = await time(hit);
const warm = [];
for (let i = 0; i < 5; i++) warm.push(await time(hit));

console.log(`\nDNS lookup                    ${median(dns).toFixed(0)}ms`);
console.log(`TCP + TLS handshake           ${median(handshakes).toFixed(0)}ms   <- paid once, on the first request`);
console.log(`\nFirst query (cold connection) ${first.toFixed(0)}ms`);
console.log(`Later queries (warm)          ${median(warm).toFixed(0)}ms`);
console.log(`\nHandshake is ~${(first - median(warm)).toFixed(0)}ms of that first request.\n`);
