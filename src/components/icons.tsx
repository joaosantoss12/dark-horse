/**
 * SVG, not emoji. Emoji render differently on every platform, cannot be styled,
 * and are read aloud literally by screen readers -- fine as decoration inside a
 * sentence, wrong for the brand mark and the controls in the top bar.
 */

/** A knight/horse-head silhouette, drawn to sit inside the gold disc. */
export function HorseMark() {
  return (
    <svg viewBox="0 0 24 24" width="18" height="18" fill="currentColor" aria-hidden="true">
      <path d="M8.2 21.5c-.3-3 .5-5.2 2-6.9 1-1.2 2.3-2 3.4-2.7.6-.4.8-.8.7-1.3-.1-.5-.5-.8-1.1-.8-.9 0-1.5.5-2 1.2-.4.5-.7 1-1.3 1.2-.8.3-1.6 0-2-.7-.4-.6-.3-1.4.1-2.1L10.9 4c.5-.9 1.3-1.5 2.3-1.5.6 0 1 .2 1.5.5l.6.4c.3-.5.5-1 .6-1.4l1.8.7c-.2.7-.5 1.4-1 2.1.9 1 1.5 2.2 1.9 3.5.6 2.2.5 4.6-.4 6.9-1 2.5-2.8 4.4-5 5.6l-.5.3-.1-1.9c-.6.9-1.3 1.7-2.1 2.4l-2.3-.1z" />
    </svg>
  );
}

export function SignOutIcon() {
  return (
    <svg
      viewBox="0 0 24 24"
      width="18"
      height="18"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.8"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      <path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4" />
      <polyline points="16 17 21 12 16 7" />
      <line x1="21" y1="12" x2="9" y2="12" />
    </svg>
  );
}
