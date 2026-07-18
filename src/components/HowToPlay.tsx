import { PlayingCard } from './PlayingCard';
import type { Card } from '../lib/api';

const card = (r: number, s: Card['s']): Card => ({ r, s });

/**
 * The rules, in one place, shown both in the modal on the sign-in screen and in
 * the panel under the lobby. One copy so they can never drift apart.
 */
export function HowToPlay() {
  return (
    <div className="rules">
      <section className="rule-block">
        <h3>Three cards each</h3>
        <p>
          The dealer gives everyone three cards. Add them up — <b>only the last digit counts</b>.
          You make no decisions; the cards decide.
        </p>

        <div className="rule-examples">
          <div className="rule-example">
            <div className="hand">
              <PlayingCard card={card(7, 'S')} size="sm" />
              <PlayingCard card={card(8, 'D')} size="sm" />
              <PlayingCard card={card(13, 'C')} size="sm" />
            </div>
            <div className="rule-maths">
              7 + 8 + 10 = 25 → <b>Score 5</b>
            </div>
          </div>

          <div className="rule-example">
            <div className="hand">
              <PlayingCard card={card(1, 'H')} size="sm" />
              <PlayingCard card={card(9, 'C')} size="sm" />
              <PlayingCard card={card(12, 'S')} size="sm" />
            </div>
            <div className="rule-maths">
              1 + 9 + 10 = 20 → <b>Score 0</b>
            </div>
          </div>
        </div>

        <p className="muted">A score of 9 is the best; 0 is the worst.</p>
      </section>

      <section className="rule-block">
        <h3>Card values</h3>
        <ul className="rule-list">
          <li>
            <b>A</b> is worth 1
          </li>
          <li>
            <b>2–9</b> are worth their face value
          </li>
          <li>
            <b>10, J, Q, K</b> are all worth 10
          </li>
        </ul>
      </section>

      <section className="rule-block">
        <h3>Special hands</h3>
        <p>These beat any score, however high.</p>

        <div className="special">
          <div className="hand">
            <PlayingCard card={card(13, 'S')} size="sm" />
            <PlayingCard card={card(13, 'H')} size="sm" />
            <PlayingCard card={card(13, 'D')} size="sm" />
          </div>
          <div>
            <div className="special-name">Three of a Kind</div>
            <div className="special-note">
              Three of the same rank. KKK beats QQQ, all the way down to AAA.
            </div>
          </div>
        </div>

        <div className="special">
          <div className="hand">
            <PlayingCard card={card(13, 'C')} size="sm" />
            <PlayingCard card={card(12, 'D')} size="sm" />
            <PlayingCard card={card(11, 'S')} size="sm" />
          </div>
          <div>
            <div className="special-name">Crown</div>
            <div className="special-note">
              Exactly King, Queen and Jack. Beaten only by Three of a Kind.
            </div>
          </div>
        </div>
      </section>

      <section className="rule-block">
        <h3>Your balances</h3>
        <ul className="rule-list">
          <li>
            <b>Points</b> are free play — everyone gets 2,000 for visiting from 8am Friday
            (Portugal time), once a week. They can&apos;t be withdrawn or turned into real money.
          </li>
          <li>
            <b>Demo</b> starts at $20 when you join. It&apos;s practice money: grow it to $200
            and $20 of it converts to real cash — once — and you keep playing with the rest.
          </li>
          <li>
            <b>Real money</b> is yours. Withdraw it any time once you&apos;ve unlocked it.
          </li>
        </ul>
      </section>

      <section className="rule-block">
        <h3>Winning</h3>
        <p>
          When the last seat fills, the dealer deals. Everyone is ranked, strongest first:{' '}
          <b>Three of a Kind</b>, then <b>Crown</b>, then the highest score.
        </p>
        <ul className="rule-list">
          <li>
            A <b>4-seat table</b> pays the top 2
          </li>
          <li>
            An <b>8-seat table</b> pays the top 4
          </li>
        </ul>
        <p className="muted">
          Level scores are split by the highest card, then the second, then the third. Hands that
          are identical share the prize.
        </p>
      </section>
    </div>
  );
}
