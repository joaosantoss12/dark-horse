import { PlayingCard } from './PlayingCard';
import type { Room, TablePlayer } from '../lib/api';

const MEDALS = ['🥇', '🥈', '🥉', '🏅'];
const HAND_LABEL: Record<number, string> = { 2: 'Three of a Kind', 1: 'Crown' };

/**
 * Seats laid out around an oval, the way you would actually sit at a table.
 *
 * Seat 0 is bottom-centre -- where you sit -- and the rest run clockwise from
 * there, so every player sees the same table from their own chair. Positions are
 * a point on an ellipse rather than a hand-written list, so a 4-seat and an
 * 8-seat table both come out evenly spaced.
 */
function seatPosition(index: number, total: number): { left: string; top: string } {
  // Start at the bottom (90 degrees) and go clockwise.
  const angle = Math.PI / 2 + (index / total) * Math.PI * 2;

  // The oval is wider than it is tall, like a real card table.
  const x = 50 + Math.cos(angle) * 42;
  const y = 50 + Math.sin(angle) * 40;

  return { left: `${x}%`, top: `${y}%` };
}

function Seat({
  player,
  index,
  total,
  room,
  isYou,
}: {
  player: TablePlayer | null;
  index: number;
  total: number;
  room: Room;
  isYou: boolean;
}) {
  const pos = seatPosition(index, total);
  const results = room.phase === 'results';

  if (!player) {
    return (
      <div className="pt-seat pt-empty" style={pos}>
        <div className="pt-chair">
          <span>Empty</span>
        </div>
      </div>
    );
  }

  // The deal being turned over right now, or the last one at the reveal.
  const current = player.deals[Math.max(0, (room.deal || 1) - 1)];
  const won = player.won ?? 0;

  // The dealer is at this seat right now: the chair lifts and the next card is
  // about to land here.
  const beingDealt = room.dealingSeat === player.seat && room.phase === 'dealing';

  return (
    <div
      className={`pt-seat ${isYou ? 'you' : ''} ${results && won > 0 ? 'winner' : ''} ${
        beingDealt ? 'dealing' : ''
      }`}
      style={pos}
    >
      {/* Only the cards the dealer has actually laid down are on the felt. One
          that has landed but not yet turned shows its back. */}
      <div className="pt-hand">
        {[0, 1, 2].map((i) => (
          <PlayingCard
            key={i}
            card={current?.cards[i] ?? null}
            present={(current?.laid ?? 0) > i}
            size="sm"
          />
        ))}
      </div>

      <div className="pt-chair">
        <div className="pt-who">
          {player.avatarUrl ? (
            <img className="pt-avatar" src={player.avatarUrl} alt="" />
          ) : (
            <span className="pt-avatar">{player.name.charAt(0).toUpperCase()}</span>
          )}
          <span className="pt-name">{player.name}</span>
          {results && <span className="pt-medal">{MEDALS[(player.place ?? 9) - 1] ?? ''}</span>}
        </div>

        {/* One chip per deal: its value, or blank until that deal is scored. */}
        <div className="pt-deals">
          {[0, 1, 2].map((i) => {
            const deal = player.deals[i];
            const special = deal?.category ? HAND_LABEL[deal.category] : null;

            return (
              <span
                key={i}
                className={`pt-chip ${deal?.value != null ? 'on' : ''} ${special ? 'special' : ''}`}
                title={special ?? undefined}
              >
                {deal?.value ?? '·'}
              </span>
            );
          })}

          <span className="pt-total" title="Total across the three deals">
            {player.totalValue ?? 0}
          </span>
        </div>

        {results && (
          <div className={`pt-won ${won > 0 ? '' : 'zero'}`}>
            {won > 0 ? `+${won}` : '—'}
            {player.isSplit && <span className="tag">Split</span>}
          </div>
        )}
      </div>
    </div>
  );
}

export function PokerTable({
  room,
  youId,
  children,
}: {
  room: Room;
  youId: string;
  /** The dealer's spot in the middle: countdown, deal number, status. */
  children: React.ReactNode;
}) {
  const bySeat = new Map(room.players.map((p) => [p.seat, p]));

  // Rotate so that your own chair is always the one at the bottom.
  const mySeat = room.players.find((p) => p.userId === youId)?.seat ?? 0;

  return (
    <div className={`pt seats-${room.seats}`}>
      <div className="pt-felt">
        <div className="pt-rail" />
        <div className="pt-centre">{children}</div>
      </div>

      {Array.from({ length: room.seats }, (_, i) => {
        const seatIndex = (mySeat + i) % room.seats;
        const player = bySeat.get(seatIndex) ?? null;

        return (
          <Seat
            key={seatIndex}
            player={player}
            index={i}
            total={room.seats}
            room={room}
            isYou={player?.userId === youId}
          />
        );
      })}
    </div>
  );
}
