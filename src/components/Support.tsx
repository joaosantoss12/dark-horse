/** Support lives on Telegram. */
export const SUPPORT_URL = 'https://telegram.me/DH_Support';

export function TelegramIcon() {
  return (
    <svg viewBox="0 0 24 24" width="16" height="16" fill="currentColor" aria-hidden="true">
      <path d="M21.9 4.3 18.7 19.4c-.24 1.06-.87 1.32-1.76.82l-4.87-3.59-2.35 2.26c-.26.26-.48.48-.98.48l.35-4.96 9.03-8.16c.39-.35-.09-.55-.61-.2L6.35 12.08l-4.8-1.5c-1.04-.33-1.06-1.04.22-1.54l18.78-7.24c.87-.32 1.63.2 1.35 2.5z" />
    </svg>
  );
}

/**
 * Shown wherever a player can get stuck: the sign-in screen, the menu, and the
 * suspended-account screen. A dead end with no way to reach a human is the worst
 * thing an account system can do.
 */
export function SupportLink({ label = 'Need help? Contact support on Telegram' }: { label?: string }) {
  return (
    <a className="support-link" href={SUPPORT_URL} target="_blank" rel="noreferrer noopener">
      <TelegramIcon />
      {label}
    </a>
  );
}
