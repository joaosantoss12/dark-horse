import { useEffect, useRef, useState } from 'react';

import { PlayingCard } from '../components/PlayingCard';
import { api, MAX_AVATAR_BYTES, type Stats } from '../lib/api';
import { useAuth } from '../lib/useAuth';

const HAND_LABEL: Record<number, string> = { 2: 'Three of a Kind', 1: 'Crown' };

function Avatar({ url, name, size = 84 }: { url: string | null; name: string; size?: number }) {
  if (url) {
    return <img className="avatar-lg" src={url} alt="" style={{ width: size, height: size }} />;
  }
  return (
    <div className="avatar-lg placeholder" style={{ width: size, height: size }}>
      {name.charAt(0).toUpperCase()}
    </div>
  );
}

export function ProfilePage() {
  const { profile, refresh, signOut } = useAuth();
  const [stats, setStats] = useState<Stats | null>(null);
  const [name, setName] = useState(profile?.display_name ?? '');
  const [avatarUrl, setAvatarUrl] = useState(profile?.avatar_url ?? null);
  const [busy, setBusy] = useState(false);
  const [uploading, setUploading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [saved, setSaved] = useState(false);
  const fileInput = useRef<HTMLInputElement>(null);

  useEffect(() => {
    void api.stats().then(setStats).catch(() => {});
  }, []);

  useEffect(() => {
    if (!profile) return;
    setName(profile.display_name);
    setAvatarUrl(profile.avatar_url);
  }, [profile?.id]); // eslint-disable-line react-hooks/exhaustive-deps

  if (!profile) return null;

  const pickImage = async (file: File | undefined) => {
    if (!file) return;

    setError(null);
    setSaved(false);

    if (file.size > MAX_AVATAR_BYTES) {
      setError('That image is over 2 MB. Pick a smaller one.');
      return;
    }

    setUploading(true);
    try {
      const url = await api.uploadAvatar(file);
      setAvatarUrl(url);
      // Save straight away: an uploaded picture that vanishes because you forgot
      // to press Save is just confusing.
      await api.updateProfile(name.trim() || profile.display_name, url);
      await refresh();
      setSaved(true);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not upload that image.');
    } finally {
      setUploading(false);
    }
  };

  const save = async () => {
    setBusy(true);
    setError(null);
    setSaved(false);
    try {
      await api.updateProfile(name.trim(), avatarUrl);
      await refresh();
      setSaved(true);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not save your profile.');
    } finally {
      setBusy(false);
    }
  };

  const removeImage = async () => {
    setAvatarUrl(null);
    setBusy(true);
    try {
      await api.updateProfile(name.trim() || profile.display_name, null);
      await refresh();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not remove your picture.');
    } finally {
      setBusy(false);
    }
  };

  const played = stats?.handsPlayed ?? 0;
  const winRate = played > 0 ? Math.round(((stats?.handsWon ?? 0) / played) * 100) : 0;
  const net = stats?.net ?? 0;

  return (
    <>
      <div className="section-title">Profile</div>

      {error && <div className="error">{error}</div>}
      {saved && <div className="notice">Saved.</div>}

      <div className="panel profile-head">
        <button
          className="avatar-button"
          onClick={() => fileInput.current?.click()}
          disabled={uploading}
          title="Change picture"
        >
          <Avatar url={avatarUrl} name={profile.display_name} />
          <span className="avatar-overlay">{uploading ? '…' : 'Change'}</span>
        </button>

        <input
          ref={fileInput}
          type="file"
          accept="image/png, image/jpeg, image/webp"
          hidden
          onChange={(e) => {
            void pickImage(e.target.files?.[0]);
            e.target.value = '';
          }}
        />

        <div className="profile-id">
          <div className="profile-name">{profile.display_name}</div>
          <div className="muted">
            <b className="gold">{profile.balance.toLocaleString()}</b> points
            {profile.is_admin && <span className="tag" style={{ marginLeft: 8 }}>Admin</span>}
          </div>
          {avatarUrl && (
            <button className="link profile-remove" onClick={() => void removeImage()}>
              Remove picture
            </button>
          )}
        </div>
      </div>

      <div className="section-title">Career</div>
      <div className="panel grid-4 stats">
        <div className="stat">
          <b>{played}</b>
          <span>Hands</span>
        </div>
        <div className="stat">
          <b>{stats?.firstPlaces ?? 0}</b>
          <span>Wins</span>
        </div>
        <div className="stat">
          <b>{winRate}%</b>
          <span>In the money</span>
        </div>
        <div className="stat">
          <b className={net > 0 ? 'up' : net < 0 ? 'down' : ''}>
            {net > 0 ? `+${net}` : net}
          </b>
          <span>Net points</span>
        </div>
      </div>

      <div className="panel" style={{ marginTop: 12 }}>
        <div className="row">
          <div className="row-main">
            <div className="row-title">Total wagered</div>
            <div className="row-sub">Buy-ins across every hand</div>
          </div>
          <div className="amount">{stats?.wagered ?? 0}</div>
        </div>
        <div className="row">
          <div className="row-main">
            <div className="row-title">Total won</div>
            <div className="row-sub">Prizes collected</div>
          </div>
          <div className="amount up">+{stats?.won ?? 0}</div>
        </div>
        <div className="row">
          <div className="row-main">
            <div className="row-title">Special hands</div>
            <div className="row-sub">Three of a Kind or a Crown</div>
          </div>
          <div className="amount">{stats?.specials ?? 0}</div>
        </div>

        {stats?.bestHand && (
          <div className="row">
            <div className="row-main">
              <div className="row-title">Best hand</div>
              <div className="row-sub">
                {HAND_LABEL[stats.bestHand.category] ?? `Score ${stats.bestHand.score}`}
              </div>
            </div>
            <div className="hand">
              {stats.bestHand.cards.map((card, i) => (
                <PlayingCard key={i} card={card} size="sm" />
              ))}
            </div>
          </div>
        )}
      </div>

      <div className="section-title">Display name</div>
      <div className="panel">
        <div className="field">
          <label htmlFor="display-name">How you appear at the table</label>
          <input
            id="display-name"
            className="input"
            value={name}
            maxLength={24}
            onChange={(e) => setName(e.target.value)}
          />
        </div>
        <button className="btn" disabled={busy || name.trim() === profile.display_name} onClick={save}>
          {busy ? 'Saving…' : 'Save'}
        </button>
      </div>

      {/* The top bar's sign-out icon is hidden on small screens, so this is the
          way out on a phone. Kept away from the other actions on purpose. */}
      <div className="sign-out-row">
        <button className="btn btn-ghost" onClick={() => void signOut()}>
          Sign out
        </button>
      </div>
    </>
  );
}
