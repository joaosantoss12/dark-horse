import { useEffect, useState } from 'react';
import { BrowserRouter, Link, Navigate, Route, Routes, useLocation } from 'react-router-dom';

import { RulesGate } from './components/RulesGate';
import { SUPPORT_URL, SupportLink, TelegramIcon } from './components/Support';
import { WeeklyReward } from './components/WeeklyReward';
import { CloseIcon, HorseMark, MenuIcon, SignOutIcon } from './components/icons';
import { cash, money } from './lib/money';
import { startNotifier } from './lib/notify';
import { startPresence } from './lib/presence';
import { AuthProvider, useAuth } from './lib/useAuth';
import { AdminPage } from './pages/AdminPage';
import { AuthPage } from './pages/AuthPage';
import { HistoryPage } from './pages/HistoryPage';
import { LobbyPage } from './pages/LobbyPage';
import { ProfilePage } from './pages/ProfilePage';
import { TablePage } from './pages/TablePage';

function Shell() {
  const { profile, signOut } = useAuth();
  const { pathname } = useLocation();
  const [menuOpen, setMenuOpen] = useState(false);

  // Watches every table for the whole session, from whatever page you are on --
  // not just the lobby. A player who is told a game is forming while looking at
  // their profile is exactly the player this is for.
  useEffect(() => {
    if (!profile?.id) return;
    return startNotifier(profile.id);
  }, [profile?.id]);

  useEffect(() => {
    if (!profile?.id) return;
    return startPresence(profile.id);
  }, [profile?.id]);

  // Navigating is the whole point of the menu, so it must close when you do.
  useEffect(() => setMenuOpen(false), [pathname]);

  // Escape closes it, and the page behind must not scroll under the drawer.
  useEffect(() => {
    if (!menuOpen) return;

    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') setMenuOpen(false);
    };
    document.addEventListener('keydown', onKey);
    document.body.style.overflow = 'hidden';

    return () => {
      document.removeEventListener('keydown', onKey);
      document.body.style.overflow = '';
    };
  }, [menuOpen]);

  if (!profile) return null;

  const active = (path: string) =>
    path === '/' ? pathname === '/' || pathname.startsWith('/table') : pathname.startsWith(path);

  const links = [
    { to: '/', label: 'Play' },
    { to: '/history', label: 'History' },
    { to: '/profile', label: 'Profile' },
    ...(profile.is_admin ? [{ to: '/admin', label: 'Admin' }] : []),
  ];

  return (
    <>
      <header className="topbar">
        <Link to="/" className="brand" aria-label="Dark Horse — home">
          <span className="brand-mark" aria-hidden="true">
            <HorseMark />
          </span>
          <span className="brand-name">
            DARK<em>HORSE</em>
          </span>
        </Link>

        {/* Desktop navigation. On phones this is replaced by the drawer below. */}
        <nav className="nav" aria-label="Main">
          {links
            .filter((l) => l.to !== '/profile')
            .map((link) => (
              <Link
                key={link.to}
                to={link.to}
                className={`nav-link ${active(link.to) ? 'on' : ''}`}
              >
                {link.label}
              </Link>
            ))}
        </nav>

        <div className="topbar-right">
          <a
            className="icon-btn desktop-only"
            href={SUPPORT_URL}
            target="_blank"
            rel="noreferrer noopener"
            aria-label="Support on Telegram"
            title="Support on Telegram"
          >
            <TelegramIcon />
          </a>

          <div className="balances">
            <div className="balance cash" title="Real money">
              <span className="balance-value">{cash(profile.cash_balance)}</span>
            </div>
            <div className="balance" title="Free-play points">
              <span className="balance-value">{money(profile.balance)}</span>
              <span className="balance-unit">pts</span>
            </div>
          </div>

          <Link
            to="/profile"
            className={`avatar-link ${active('/profile') ? 'on' : ''}`}
            aria-label={`Profile — ${profile.display_name}`}
          >
            {profile.avatar_url ? (
              <img className="avatar-top" src={profile.avatar_url} alt="" />
            ) : (
              <span className="avatar-top">{profile.display_name.charAt(0).toUpperCase()}</span>
            )}
          </Link>

          <button className="icon-btn desktop-only" onClick={() => void signOut()} aria-label="Sign out">
            <SignOutIcon />
          </button>

          <button
            className="icon-btn mobile-only"
            onClick={() => setMenuOpen(true)}
            aria-label="Open menu"
            aria-expanded={menuOpen}
            aria-controls="mobile-menu"
          >
            <MenuIcon />
          </button>
        </div>
      </header>

      {menuOpen && (
        <div className="drawer-backdrop" onClick={() => setMenuOpen(false)}>
          {/* The drawer itself swallows clicks so tapping inside does not close it. */}
          <nav
            id="mobile-menu"
            className="drawer"
            aria-label="Menu"
            onClick={(e) => e.stopPropagation()}
          >
            <div className="drawer-head">
              <div className="drawer-who">
                {profile.avatar_url ? (
                  <img className="avatar-top" src={profile.avatar_url} alt="" />
                ) : (
                  <span className="avatar-top">
                    {profile.display_name.charAt(0).toUpperCase()}
                  </span>
                )}
                <div>
                  <div className="drawer-name">{profile.display_name}</div>
                  <div className="drawer-balance">
                    {cash(profile.cash_balance)} · {money(profile.balance)} pts
                  </div>
                </div>
              </div>

              <button
                className="icon-btn"
                onClick={() => setMenuOpen(false)}
                aria-label="Close menu"
              >
                <CloseIcon />
              </button>
            </div>

            <div className="drawer-links">
              {links.map((link) => (
                <Link
                  key={link.to}
                  to={link.to}
                  className={`drawer-link ${active(link.to) ? 'on' : ''}`}
                >
                  {link.label}
                </Link>
              ))}
            </div>

            <a
              className="drawer-link support"
              href={SUPPORT_URL}
              target="_blank"
              rel="noreferrer noopener"
            >
              <TelegramIcon />
              Support
            </a>

            {/* Kept apart from the navigation: signing out by mis-tap is miserable. */}
            <button className="drawer-signout" onClick={() => void signOut()}>
              <SignOutIcon />
              Sign out
            </button>
          </nav>
        </div>
      )}

      <main className="page">
        <Routes>
          <Route path="/" element={<LobbyPage />} />
          <Route path="/table/:id" element={<TablePage />} />
          <Route path="/history" element={<HistoryPage />} />
          <Route path="/profile" element={<ProfilePage />} />
          <Route path="/admin" element={<AdminPage />} />
          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      </main>

      <WeeklyReward />
    </>
  );
}

function Gate() {
  const { profile, loading } = useAuth();
  // With a cached profile there is nothing to wait for: paint the app now and
  // let the fresh copy arrive underneath. The spinner is only for a genuinely
  // cold start.
  if (loading && !profile) {
    return (
      <div className="center">
        <div className="spinner" />
      </div>
    );
  }

  if (!profile) return <AuthPage />;

  if (profile.is_banned) {
    return (
      <div className="center">
        <div>
          <h2>Account suspended</h2>
          <p className="muted">If you think this is a mistake, talk to us.</p>
          <SupportLink label="Contact support on Telegram" />
        </div>
      </div>
    );
  }

  // Nobody sees a table before they have seen the rules.
  if (!profile.rules_accepted_at) return <RulesGate />;

  return <Shell />;
}

export function App() {
  return (
    <BrowserRouter>
      <AuthProvider>
        <Gate />
      </AuthProvider>
    </BrowserRouter>
  );
}
