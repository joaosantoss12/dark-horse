# 🐎 Dark Horse

A card game as a website. Players sign up, take a seat at a 4- or 8-player
table, and when the table fills the dealer deals three cards to everyone. The
hands are scored, ranked, and the prizes pay out automatically.

React + TypeScript on Vercel, Supabase for auth, database and realtime. No
server to run, no bill at this scale.

## The rules

| | |
|---|---|
| **Card values** | `A = 1`, `2–9` face value, `10 J Q K = 10` |
| **Score** | Add the three cards, keep the **last digit**. `7 + 8 + K = 25 → 5` |
| **Special hands** | **Three of a Kind** (KKK > QQQ > … > AAA) beats a **Crown** (K+Q+J), which beats any score |
| **Normal ranking** | 9 is the best score, down to 0 |
| **Ties** | Highest card, then the second, then the third. An exact tie **splits the prize** |
| **4-seat table** | Top 2 paid |
| **8-seat table** | Top 4 paid |

Buy-ins and every prize amount are configurable per table from the admin panel.
Players make no decisions — the deal is the whole game.

## Where the game actually lives

**In the database.** The shuffle, the scoring, the ranking, the payouts and the
tie splitting are all Postgres functions (`supabase/migrations/0001_init.sql`).

That is not a stylistic choice. Vercel is serverless, so there is no always-on
process to be the dealer, and anything in the React app is under the player's
control — they can open devtools and call whatever they like. So the browser is
given no way to touch a card or a point directly:

- Every table has row level security on, and `round_hands` (the dealt cards) has
  **no read policy at all**. The cards are unreachable, full stop.
- Cards are only ever exposed through `dh_get_room()`, which returns `null` for
  any card the dealer has not turned over yet. An unrevealed hand cannot be read
  out of the network tab.
- The internal functions (`dh_deal`, `dh_tick`) are not granted to the browser
  roles. Only the player-facing RPCs are.
- Money moves only inside `dh_join_room` / `dh_tick`, in one transaction, with
  the balance check and the debit in the same statement — two tabs clicking
  "join" cannot spend the same points twice.

`npm run test:security` signs in as a real player and tries to cheat: hand
itself points, promote itself to admin, read another player's balance, force a
deal, write itself a winning hand, read the cards mid-deal. All 19 attempts must
fail. Run it after touching anything in `supabase/migrations/`.

### There is no cron, and it does not need one

A hand has to settle ~5 seconds after it is dealt, but nothing is running to do
it. So `dh_tick()` runs at the start of every RPC: any player loading the lobby
advances the world. If everyone closes the tab mid-hand, the next visitor
settles it. Prizes cannot be lost, only delayed until somebody looks.

## Running it

```bash
npm install
cp .env.example .env.local     # fill in from Supabase -> Project Settings
npm run migrate                # creates the schema and two starter tables
npm run dev                    # http://localhost:5173

npm run test:game              # the rules: 35 assertions
npm run test:security          # tries to cheat: 19 attempts, all must fail
```

`npm run migrate` applies every file in `supabase/migrations/` in order, and is
safe to re-run.

## Deploying to Vercel

1. Push this repo to GitHub.
2. Import it at [vercel.com/new](https://vercel.com/new). It detects Vite; the
   settings in `vercel.json` are already correct.
3. Add two environment variables (**Settings → Environment Variables**):
   - `VITE_SUPABASE_URL`
   - `VITE_SUPABASE_ANON_KEY`
4. Deploy. Then in Supabase (**Authentication → URL Configuration**) set the
   **Site URL** to your Vercel domain, or the confirmation and password-reset
   links in emails will point at `localhost`.

Do **not** put `SUPABASE_DB_URL` in Vercel. Nothing deployed needs it.

## Before real players arrive

**Email delivery.** Supabase's built-in mailer only sends a few messages an hour
and is meant for testing — real signups will silently fail to receive their
confirmation email. Two options:

- **Turn email confirmation off** (Authentication → Providers → Email →
  *Confirm email* off). Players are in as soon as they sign up. Simplest, and
  fine for a points game, but people can sign up with an address they do not own.
- **Add your own SMTP** (Authentication → Emails → SMTP Settings). Resend,
  Postmark, Brevo — all have free tiers. Needed for password resets to work at
  all, so this is the real answer eventually.

**Make yourself an admin.** Sign up through the site, then run this once:

```sql
UPDATE profiles SET is_admin = true WHERE id = (
  SELECT id FROM auth.users WHERE email = 'you@example.com'
);
```

The ⚙️ Admin tab then appears: create and retune tables (it shows you the pot,
the payout and what the house keeps, so you cannot accidentally build a table
that loses money every hand), top up or deduct player points, and ban accounts.

**Testing alone.** The smallest table is 4 seats and only deals when full. As an
admin, take a seat and a **Fill with bots** button appears. Bots are dealt in and
ranked like anyone else but pay no buy-in and collect no prize — they never touch
the ledger — and they are labelled *Bot* at the table.

## Points, not money

Balances are internal points. There is no deposit or cash-out path, deliberately:
adding one would make this a gambling product, with the licensing that implies.
The database is ready for it (every balance change is in `ledger`, with the
resulting balance), but that is a legal decision, not a technical one.

## The Telegram version

The original Telegram Mini App is in `TELEGRAM BOT - NOT USED/`. It is a Node
server with its own tested rules engine, kept as a reference. It is not wired to
anything and its schema was replaced by the one here.
