import { useEffect, useState } from 'react';

import { cardText } from '../components/PlayingCard';
import { api, type Card } from '../lib/api';

interface Played {
  round_id: number;
  played_at: string;
  room: string;
  buy_in: number;
  cards: Card[];
  score: number;
  place: number;
  won: number;
  net: number;
}

interface Leader {
  display_name: string;
  winnings: number;
  wins: number;
}

const ORDINALS = ['1st', '2nd', '3rd', '4th', '5th', '6th', '7th', '8th'];

export function HistoryPage() {
  const [rounds, setRounds] = useState<Played[] | null>(null);
  const [leaders, setLeaders] = useState<Leader[]>([]);

  useEffect(() => {
    void api.history().then(setRounds).catch(() => setRounds([]));
    void api.leaderboard().then(setLeaders).catch(() => {});
  }, []);

  return (
    <>
      <div className="section-title">Your last hands</div>
      <div className="panel">
        {rounds === null && <div className="muted">Loading…</div>}
        {rounds?.length === 0 && <div className="muted">You have not played a hand yet.</div>}

        {rounds?.map((round) => (
          <div key={round.round_id} className="row">
            <div className="hand hand-sm">
              {round.cards.map((card, i) => (
                <span key={i} className={`card-chip ${card.s === 'H' || card.s === 'D' ? 'red' : ''}`}>
                  {cardText(card)}
                </span>
              ))}
            </div>
            <div className="row-main">
              <div className="row-title">Score {round.score}</div>
              <div className="row-sub">
                {round.room} · {ORDINALS[round.place - 1] ?? `${round.place}th`} ·{' '}
                {new Date(round.played_at).toLocaleDateString()}
              </div>
            </div>
            <div className={`amount ${round.net > 0 ? 'up' : round.net < 0 ? 'down' : ''}`}>
              {round.net > 0 ? `+${round.net}` : round.net}
            </div>
          </div>
        ))}
      </div>

      <div className="section-title">Top winners</div>
      <div className="panel">
        {leaders.length === 0 && <div className="muted">No winners yet.</div>}
        {leaders.map((leader, i) => (
          <div key={leader.display_name + i} className="row">
            <div className="place">{['🥇', '🥈', '🥉'][i] ?? i + 1}</div>
            <div className="row-main">
              <div className="row-title">{leader.display_name}</div>
              <div className="row-sub">{leader.wins} winning hands</div>
            </div>
            <div className="amount up">+{leader.winnings}</div>
          </div>
        ))}
      </div>
    </>
  );
}
