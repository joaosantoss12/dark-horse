import { useState } from 'react';

import { Modal } from './Modal';
import { SUPPORT_URL, TelegramIcon } from './Support';
import { api } from '../lib/api';
import { cash, money } from '../lib/money';
import { useAuth } from '../lib/useAuth';

type Flow = 'deposit' | 'withdraw';

// The funnel thresholds, mirrored from the DB settings for display. The database
// is the source of truth; these are only for the progress bars.
const DEMO_GOAL_CENTS = 3000; // $30 demo -> real bonus
const WITHDRAW_GOAL_CENTS = 5000; // $50 real -> withdraw unlocks

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

function Progress({ value, goal }: { value: number; goal: number }) {
  const pct = Math.min(100, Math.round((value / goal) * 100));
  return (
    <div className="wallet-progress">
      <div className="wallet-progress-bar" style={{ width: `${pct}%` }} />
    </div>
  );
}

/** The three balances and the funnel that connects them. */
export function Wallet() {
  const { profile } = useAuth();
  const [flow, setFlow] = useState<Flow | null>(null);

  if (!profile) return null;

  const canWithdraw = profile.withdraw_unlocked && profile.cash_balance > 0;

  return (
    <>
      <div className="section-title">Wallet</div>

      {/* Real money */}
      <div className="wallet-card cash">
        <div className="wallet-card-head">
          <div>
            <div className="wallet-label">Real money</div>
            <div className="wallet-amount cash">{cash(profile.cash_balance)}</div>
          </div>
          <div className="wallet-actions">
            <button className="btn btn-sm" onClick={() => setFlow('deposit')}>
              Deposit
            </button>
            <button
              className="btn btn-ghost btn-sm"
              onClick={() => setFlow('withdraw')}
              disabled={!canWithdraw}
              title={
                !profile.withdraw_unlocked
                  ? `Grow your real balance to ${cash(WITHDRAW_GOAL_CENTS)} to unlock withdrawals`
                  : profile.cash_balance <= 0
                    ? 'Nothing to withdraw yet'
                    : undefined
              }
            >
              Withdraw
            </button>
          </div>
        </div>

        {!profile.withdraw_unlocked && (
          <div className="wallet-goal">
            <div className="wallet-goal-line">
              <span>Withdrawals unlock at {cash(WITHDRAW_GOAL_CENTS)}</span>
              <b>
                {cash(profile.cash_balance)} / {cash(WITHDRAW_GOAL_CENTS)}
              </b>
            </div>
            <Progress value={profile.cash_balance} goal={WITHDRAW_GOAL_CENTS} />
          </div>
        )}
      </div>

      {/* Demo — the on-ramp to real money */}
      <div className="wallet-card demo">
        <div className="wallet-card-head">
          <div>
            <div className="wallet-label">Demo balance</div>
            <div className="wallet-amount demo">{cash(profile.demo_balance)}</div>
          </div>
          <div className="wallet-sub">Play the money tables risk-free.</div>
        </div>

        {!profile.demo_bonus_awarded ? (
          <div className="wallet-goal">
            <div className="wallet-goal-line">
              <span>Reach {cash(DEMO_GOAL_CENTS)} to earn a real cash bonus</span>
              <b>
                {cash(profile.demo_balance)} / {cash(DEMO_GOAL_CENTS)}
              </b>
            </div>
            <Progress value={profile.demo_balance} goal={DEMO_GOAL_CENTS} />
          </div>
        ) : (
          <div className="wallet-goal done">🎉 Bonus earned — it's in your real-money balance.</div>
        )}
      </div>

      {/* Free-play points */}
      <div className="wallet-card points">
        <div className="wallet-card-head">
          <div>
            <div className="wallet-label">Free-play points</div>
            <div className="wallet-amount points">{money(profile.balance)}</div>
          </div>
          <div className="wallet-sub">Play the free table. No cash value.</div>
        </div>
      </div>

      {flow && <PaymentModal flow={flow} onClose={() => setFlow(null)} />}
    </>
  );
}
