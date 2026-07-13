import type { Card } from '../lib/api';

const RANKS: Record<number, string> = {
  1: 'A', 2: '2', 3: '3', 4: '4', 5: '5', 6: '6', 7: '7',
  8: '8', 9: '9', 10: '10', 11: 'J', 12: 'Q', 13: 'K',
};

const SUITS: Record<string, string> = { S: '♠', H: '♥', D: '♦', C: '♣' };

export const cardText = (card: Card) => `${RANKS[card.r]}${SUITS[card.s]}`;

/** A null card has not been turned over yet, so it shows its back. */
export function PlayingCard({ card, size = 'md' }: { card: Card | null; size?: 'sm' | 'md' }) {
  const red = card?.s === 'H' || card?.s === 'D';

  return (
    <div className={`pc pc-${size} ${card ? 'up' : ''}`}>
      <div className="pc-inner">
        <div className="pc-back" />
        <div className={`pc-face ${red ? 'red' : ''}`}>
          {card && (
            <>
              <span className="pc-rank">{RANKS[card.r]}</span>
              <span className="pc-suit">{SUITS[card.s]}</span>
            </>
          )}
        </div>
      </div>
    </div>
  );
}
