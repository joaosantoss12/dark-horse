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
    line: 'To add real money, message us on Telegram and we will send you the details to pay to.',
  },
  withdraw: {
    title: '🏧 Withdraw',
    verb: 'cash out',
    line: 'To withdraw your winnings, message us on Telegram with where you want to be paid.',
  },
};

function PaymentModal({ flow, onClose }: { flow: Flow; onClose: () => void }) {
  const copy = COPY[flow];
  const [logged, setLogged] = useState(false);

  const go = async () => {
    try {
      await api.requestPayment(flow);
      setLogged(true);
    } catch {
      // Still let them reach a human even if logging fails.
    } finally {
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
            <span className="pay-method-icon crypto">₿</span>
            <div>
              <div className="pay-method-name">Cryptocurrency</div>
              <div className="pay-method-note">BTC, ETH, USDT and more</div>
            </div>
          </div>
          <div className="pay-method">
            <span className="pay-method-icon bank">🏦</span>
            <div>
              <div className="pay-method-name">Bank transfer</div>
              <div className="pay-method-note">Local banking options in many countries</div>
            </div>
          </div>
          <p className="muted pay-more">
            We support deposits and withdrawals worldwide. Ask on Telegram which options are
            available in your country.
          </p>
        </div>

        <a
          className="btn btn-block"
          href={SUPPORT_URL}
          target="_blank"
          rel="noreferrer noopener"
          onClick={() => void go()}
        >
          <TelegramIcon />
          Message @DH_Support to {copy.verb}
        </a>

        {logged && (
          <p className="notice" style={{ marginTop: 12, marginBottom: 0 }}>
            We have flagged your request — send us a message and we will sort it out.
          </p>
        )}
      </div>
    </Modal>
  );
}

/** The three balances and the funnel that connects them. */
export function Wallet() {
  const { profile } = useAuth();
  const [flow, setFlow] = useState<Flow | null>(null);

  if (!profile) return null;

  const canWithdraw = profile.cash_balance > 0;

  return (
    <>
      <div className="section-title">Wallet</div>

      <div className="wallet-row">
        {/* Real money */}
        <div className="wallet-chip cash">
          <div className="wallet-chip-label">Real money</div>
          <div className="wallet-chip-amount">{cash(profile.cash_balance)}</div>
        </div>

        {/* Points */}
        <div className="wallet-chip points">
          <div className="wallet-chip-label">Points</div>
          <div className="wallet-chip-amount">{money(profile.balance)}</div>
        </div>
      </div>

      <div className="wallet-buttons">
        <button className="btn btn-sm" onClick={() => setFlow('deposit')}>
          Deposit
        </button>
        <button
          className="btn btn-ghost btn-sm"
          onClick={() => setFlow('withdraw')}
          disabled={!canWithdraw}
          title={!canWithdraw ? 'Nothing to withdraw yet' : undefined}
        >
          Withdraw
        </button>
      </div>

      <div className="wallet-rules">
        <div className="wallet-rules-title">How the balances work</div>
        <ul>
          <li>
            <b>Points</b> are free play — everyone gets 2,000 for visiting from 10am Friday, once
            a week. They can&apos;t be withdrawn or converted into real money.
          </li>
          <li>
            <b>Real money</b> is yours — withdraw it any time.
          </li>
        </ul>
      </div>

      {flow && <PaymentModal flow={flow} onClose={() => setFlow(null)} />}
    </>
  );
}
