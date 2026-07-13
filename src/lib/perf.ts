/**
 * Timing, printed to the console when the URL has ?perf=1.
 *
 * The database answers in ~80ms, so when the app feels slow the time is going
 * somewhere else -- and guessing at it from the outside wastes everyone's time.
 * This says exactly which step was slow, in the browser that felt slow.
 */
const ON = new URLSearchParams(location.search).has('perf');

const started = performance.now();

export function mark(label: string, sinceStart = false) {
  if (!ON) return;
  const now = performance.now();
  console.log(
    `%c[perf] ${label.padEnd(28)} ${(sinceStart ? now - started : now).toFixed(0)}ms`,
    'color:#d4a24c',
  );
}

/** Times one awaited call and prints how long it took. */
export async function timed<T>(label: string, fn: () => Promise<T>): Promise<T> {
  if (!ON) return fn();

  const t = performance.now();
  try {
    return await fn();
  } finally {
    console.log(
      `%c[perf] ${label.padEnd(28)} ${(performance.now() - t).toFixed(0)}ms`,
      'color:#4ade80',
    );
  }
}

/** Where the browser actually spent the page load, from the Navigation Timing API. */
export function reportPageLoad() {
  if (!ON) return;

  setTimeout(() => {
    const nav = performance.getEntriesByType('navigation')[0] as PerformanceNavigationTiming;
    if (!nav) return;

    console.log('%c[perf] ---- page load ----', 'color:#f0cd8c;font-weight:bold');
    console.log(`[perf] html downloaded        ${nav.responseEnd.toFixed(0)}ms`);
    console.log(`[perf] dom interactive        ${nav.domInteractive.toFixed(0)}ms`);
    console.log(`[perf] dom content loaded     ${nav.domContentLoadedEventEnd.toFixed(0)}ms`);
    console.log(`[perf] load complete          ${nav.loadEventEnd.toFixed(0)}ms`);

    // Which scripts took the longest? In dev this is where Vite's unbundled
    // modules show up; in production it should be one bundle.
    const scripts = performance
      .getEntriesByType('resource')
      .filter((r) => (r as PerformanceResourceTiming).initiatorType === 'script');

    console.log(`[perf] script requests        ${scripts.length}`);
    const slowest = scripts.sort((a, b) => b.duration - a.duration).slice(0, 5);
    for (const s of slowest) {
      console.log(`[perf]   ${s.duration.toFixed(0).padStart(5)}ms  ${s.name.split('/').pop()}`);
    }
  }, 1500);
}
