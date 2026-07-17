import { useState } from 'react';

import { Modal } from './Modal';
import { SUPPORT_URL, TelegramIcon } from './Support';
import { api } from '../lib/api';
import { cash, money } from '../lib/money';
import { useAuth } from '../lib/useAuth';

type Flow = 'deposit' | 'withdraw';

const COPY: Record<Flow, { title: string; verb: string; line: string }> = {
  deposit: {
    title: '💰 Deposit',
    verb: 'add funds',
    line: 'To add real money to your account, message us on Telegram and we will send you the crypto address to pay to.',
  },
  withdraw: {
    title: '🏧 Withdraw',
    verb: 'cash out',
    line: 'To withdraw your balance, message us on Telegram with the wallet address you want to be paid to.',
  },
};

/**
 * Deposit / withdraw. This moves NO money -- it records that the player wants
 * to, and points them at a human on Telegram who settles it by hand. That is
 * deliberate: the moment the app itself moved funds it would need a licence and
 * a regulated processor. See the 0024 migration.
 */
function PaymentModal({ flow, onClose }: { flow: Flow; onClose: () => void }) {
  const copy = COPY[flow];
  const [logged, setLogged] = useState(false);
  const [busy, setBusy] = useState(false);

  // Record the intent when the player opens the modal, so it reaches the admin
  // queue whether or not they actually go through to Telegram.
  const openTelegram = async () => {
    setBusy(true);
    try {
      await api.requestPayment(flow);
      setLogged(true);
    } catch {
      // Even if logging fails, still let them talk to a human.
    } finally {
      setBusy(false);
      window.open(SUPPORT_URL, '_blank', 'noreferrer');
    }
  };

  return (
    <Modal title={copy.title} onClose={onClose}>
      <div className="wallet-flow">
        <p>{copy.line}</p>

        <div className="pay-methods">
          <div className="pay-methods-label">Accepted methods</div>
          <div className="pay-method">
            <span className="pay-method-icon">₿</span>
            <div>
              <div className="pay-method-name">Cryptocurrency</div>
              <div className="pay-method-note">BTC, ETH, USDT and more — ask on Telegram</div>
            </div>
          </div>
          <p className="muted pay-more">More methods coming soon.</p>
        </div>

        <a
          className="btn btn-block"
          href={SUPPORT_URL}
          target="_blank"
          rel="noreferrer noopener"
          onClick={() => void openTelegram()}
        >
          <TelegramIcon />
          Message @DH_Support to {copy.verb}
        </a>

        {logged && (
          <p className="notice" style={{ marginTop: 12, marginBottom: 0 }}>
            We have flagged your request. Send us a message on Telegram and we will sort it out.
          </p>
        )}

        <p className="muted wallet-disclaimer">
          {busy ? 'Recording your request…' : 'Real-money play requires a manual top-up for now.'}
        </p>
      </div>
    </Modal>
  );
}

/** The two balances, side by side, with deposit and withdraw. */
export function Wallet() {
  const { profile } = useAuth();
  const [flow, setFlow] = useState<Flow | null>(null);

  if (!profile) return null;

  return (
    <>
      <div className="section-title">Wallet</div>

      <div className="wallet">
        <div className="wallet-balance cash">
          <div className="wallet-label">Real money</div>
          <div className="wallet-amount">{cash(profile.cash_balance)}</div>
          <div className="wallet-actions">
            <button className="btn btn-sm" onClick={() => setFlow('deposit')}>
              Deposit
            </button>
            <button
              className="btn btn-ghost btn-sm"
              onClick={() => setFlow('withdraw')}
              disabled={profile.cash_balance <= 0}
              title={profile.cash_balance <= 0 ? 'Nothing to withdraw yet' : undefined}
            >
              Withdraw
            </button>
          </div>
        </div>

        <div className="wallet-balance points">
          <div className="wallet-label">Free-play points</div>
          <div className="wallet-amount">{money(profile.balance)}</div>
          <div className="wallet-sub">Play the free tables. No cash value.</div>
        </div>
      </div>

      {flow && <PaymentModal flow={flow} onClose={() => setFlow(null)} />}
    </>
  );
}