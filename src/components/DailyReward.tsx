import { useEffect, useRef, useState } from 'react';

import { Modal } from './Modal';
import { api } from '../lib/api';
import { money } from '../lib/money';
import { useAuth } from '../lib/useAuth';

/**
 * Claims the daily login reward once per mount, right after a profile is
 * available. The server is the one that actually decides whether today has
 * already been claimed -- this just surfaces the result when it's a yes.
 */
export function DailyReward() {
  const { profile, refresh } = useAuth();
  const [amount, setAmount] = useState<number | null>(null);
  const claimedFor = useRef<string | null>(null);

  useEffect(() => {
    if (!profile?.id || claimedFor.current === profile.id) return;
    claimedFor.current = profile.id;

    void api
      .claimDaily()
      .then((r) => {
        if (r.claimed) {
          setAmount(r.amount);
          void refresh();
        }
      })
      .catch(() => {});
  }, [profile?.id, refresh]);

  if (amount == null) return null;

  return (
    <Modal title="🎁 Daily reward" onClose={() => setAmount(null)}>
      <p>
        You just earned <b className="gold">{money(amount)}</b> points for visiting today. Come
        back tomorrow for more.
      </p>
      <button className="btn btn-block" onClick={() => setAmount(null)}>
        Nice!
      </button>
    </Modal>
  );
}
