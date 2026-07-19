import { useEffect, useRef, useState } from 'react';

import { Modal } from './Modal';
import { api } from '../lib/api';
import { money } from '../lib/money';
import { useAuth } from '../lib/useAuth';

/**
 * Claims the weekly Friday reward once per mount, right after a profile is
 * available. The server is the one that decides whether this week's window
 * (Friday 10:00 German time onward) has already been claimed -- this just
 * surfaces the result when it's a yes.
 */
export function WeeklyReward() {
  const { profile, refresh } = useAuth();
  const [amount, setAmount] = useState<number | null>(null);
  const claimedFor = useRef<string | null>(null);

  useEffect(() => {
    if (!profile?.id || claimedFor.current === profile.id) return;
    claimedFor.current = profile.id;

    void api
      .claimWeekly()
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
    <Modal title="🎁 Weekly reward" onClose={() => setAmount(null)}>
      <p>
        You just earned <b className="gold">{money(amount)}</b> points — your weekly Friday
        bonus. Come back next Friday for more.
      </p>
      <button className="btn btn-block" onClick={() => setAmount(null)}>
        Nice!
      </button>
    </Modal>
  );
}
