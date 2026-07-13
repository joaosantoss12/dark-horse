import { BrowserRouter, Link, Navigate, Route, Routes, useLocation } from 'react-router-dom';

import { HorseMark, SignOutIcon } from './components/icons';
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

  if (!profile) return null;

  const active = (path: string) =>
    path === '/' ? pathname === '/' || pathname.startsWith('/table') : pathname.startsWith(path);

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

        <nav className="nav" aria-label="Main">
          <Link to="/" className={`nav-link ${active('/') ? 'on' : ''}`}>
            Play
          </Link>
          <Link to="/history" className={`nav-link ${active('/history') ? 'on' : ''}`}>
            History
          </Link>
          {profile.is_admin && (
            <Link to="/admin" className={`nav-link ${active('/admin') ? 'on' : ''}`}>
              Admin
            </Link>
          )}
        </nav>

        <div className="topbar-right">
          <div className="balance" title={`${profile.balance.toLocaleString()} points`}>
            <span className="balance-value">{profile.balance.toLocaleString()}</span>
            <span className="balance-unit">pts</span>
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

          <button className="icon-btn" onClick={() => void signOut()} aria-label="Sign out">
            <SignOutIcon />
          </button>
        </div>
      </header>

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
          <p className="muted">Contact an admin if you think this is a mistake.</p>
        </div>
      </div>
    );
  }

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
