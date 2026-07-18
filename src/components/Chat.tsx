import { useEffect, useRef, useState } from 'react';

import { api } from '../lib/api';
import { supabase } from '../lib/supabase';
import { useAuth } from '../lib/useAuth';

interface Message {
  id: number;
  user_id: string;
  name: string;
  body: string;
  created_at: string;
}

// The casino one-liners the client asked for, plus a couple that fit.
const QUICK = ['Good luck! 🍀', 'Nice hand! 👏', "I'm coming for the top spot! 🔥", 'Well played', 'gg'];

/**
 * A chat panel. `roomId` null is the global lobby chat; a number is that table's
 * chat. History loads once, then Realtime streams new messages -- there is no
 * polling.
 */
export function Chat({
  roomId,
  title,
  showHeader = true,
}: {
  roomId: number | null;
  title: string;
  /** Off when a floating frame provides its own header. */
  showHeader?: boolean;
}) {
  const { profile } = useAuth();
  const [messages, setMessages] = useState<Message[]>([]);
  const [body, setBody] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [sending, setSending] = useState(false);
  const listRef = useRef<HTMLDivElement>(null);

  // Load history and subscribe. Re-runs if the room changes.
  useEffect(() => {
    let alive = true;

    void api.chatHistory(roomId).then((rows) => {
      if (alive) setMessages(rows);
    });

    // Realtime cannot filter on "IS NULL", so subscribe to all chat inserts and
    // keep the ones for this room. Volume is tiny.
    const channel = supabase
      .channel(`chat:${roomId ?? 'global'}`)
      .on(
        'postgres_changes',
        { event: 'INSERT', schema: 'public', table: 'chat_messages' },
        (payload) => {
          const msg = payload.new as Message & { room_id: number | null };
          if ((msg.room_id ?? null) !== roomId) return;
          setMessages((prev) =>
            prev.some((m) => m.id === msg.id) ? prev : [...prev, msg].slice(-50),
          );
        },
      )
      .subscribe();

    return () => {
      alive = false;
      void supabase.removeChannel(channel);
    };
  }, [roomId]);

  // Stick to the bottom as messages arrive.
  useEffect(() => {
    const el = listRef.current;
    if (el) el.scrollTop = el.scrollHeight;
  }, [messages]);

  const send = async (text: string) => {
    const trimmed = text.trim();
    if (!trimmed || sending) return;

    setSending(true);
    setError(null);
    try {
      await api.sendChat(roomId, trimmed);
      setBody('');
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not send.');
    } finally {
      setSending(false);
    }
  };

  return (
    <div className="chat">
      {showHeader && <div className="chat-head">{title}</div>}

      <div className="chat-list" ref={listRef}>
        {messages.length === 0 && <div className="chat-empty">No messages yet. Say hello 👋</div>}
        {messages.map((m) => (
          <div key={m.id} className={`chat-msg ${m.user_id === profile?.id ? 'mine' : ''}`}>
            <span className="chat-name">{m.name}</span>
            <span className="chat-body">{m.body}</span>
          </div>
        ))}
      </div>

      <div className="chat-quick">
        {QUICK.map((q) => (
          <button key={q} className="chat-chip" disabled={sending} onClick={() => void send(q)}>
            {q}
          </button>
        ))}
      </div>

      {error && <div className="chat-error">{error}</div>}

      <form
        className="chat-input"
        onSubmit={(e) => {
          e.preventDefault();
          void send(body);
        }}
      >
        <input
          className="input"
          value={body}
          maxLength={200}
          placeholder="Message…"
          onChange={(e) => setBody(e.target.value)}
        />
        <button className="btn btn-sm" type="submit" disabled={sending || !body.trim()}>
          Send
        </button>
      </form>
    </div>
  );
}
