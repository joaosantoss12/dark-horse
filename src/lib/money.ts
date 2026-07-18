/**
 * Free-play points, shown as a plain thousands-separated number from one place
 * so a prize, a balance and a buy-in can never drift into different formats.
 *
 * These are internal points, not real currency -- they carry no $ sign so they
 * can never be mistaken for the cash balance, which uses `cash()` below.
 */
export function money(amount: number | null | undefined): string {
  return (amount ?? 0).toLocaleString();
}

/** A prize or a win: "+$115". Zero comes back as a dash, not "+$0". */
export function moneyGain(amount: number | null | undefined): string {
  return amount && amount > 0 ? `+${money(amount)}` : '—';
}

/** A net figure that can go either way: "+$95" or "-$20". */
export function moneySigned(amount: number): string {
  if (amount > 0) return `+${money(amount)}`;
  if (amount < 0) return `-${money(Math.abs(amount))}`;
  return money(0);
}

/**
 * The real-money balance is held in cents, so it can carry $12.50 without the
 * floating-point rounding that would eventually lose a cent. Shown to two
 * decimals unless it is a whole dollar.
 */
export function cash(cents: number | null | undefined): string {
  const dollars = (cents ?? 0) / 100;
  return `$${dollars.toLocaleString(undefined, {
    minimumFractionDigits: Number.isInteger(dollars) ? 0 : 2,
    maximumFractionDigits: 2,
  })}`;
}

/**
 * A table's buy-in or prize. Free-play tables are counted in points;
 * real-money tables in cents. The unit follows the table's mode.
 */
export function stake(mode: 'free' | 'cash', amount: number): string {
  return mode === 'free' ? `${amount.toLocaleString()} pts` : cash(amount);
}
