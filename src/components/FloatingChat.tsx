import { useEffect, useRef, useState } from 'react';

import { Chat } from './Chat';

interface Pos {
  x: number;
  y: number;
}

/**
 * A floating, draggable, collapsible chat dock.
 *
 * Starts as a small launcher in the bottom-right. Click to open a panel you can
 * drag by its header and resize from its corner; collapse it back to the header
 * bar, or close it to the launcher. Position and open/collapsed state persist per
 * scope (global vs a given table) so it stays where you left it.
 */
export function FloatingChat({ roomId, title }: { roomId: number | null; title: string }) {
  const scope = roomId == null ? 'global' : `t${roomId}`;
  const openKey = `dh.chat.open.${scope}`;
  const posKey = `dh.chat.pos.${scope}`;

  const [open, setOpen] = useState(() => localStorage.getItem(openKey) === '1');
  const [collapsed, setCollapsed] = useState(false);
  const [unread, setUnread] = useState(false);
  const [pos, setPos] = useState<Pos | null>(() => {
    try {
      const raw = localStorage.getItem(posKey);
      return raw ? (JSON.parse(raw) as Pos) : null;
    } catch {
      return null;
    }
  });

  const drag = useRef<{ dx: number; dy: number } | null>(null);

  useEffect(() => {
    localStorage.setItem(openKey, open ? '1' : '0');
    if (open) setUnread(false);
  }, [open, openKey]);

  // Drag the panel by its header, clamped to the viewport.
  const onPointerDown = (e: React.PointerEvent) => {
    const panel = (e.currentTarget as HTMLElement).closest('.fchat') as HTMLElement;
    const rect = panel.getBoundingClientRect();
    drag.current = { dx: e.clientX - rect.left, dy: e.clientY - rect.top };
    (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
  };
  const onPointerMove = (e: React.PointerEvent) => {
    if (!drag.current) return;
    const w = 320;
    const x = Math.min(Math.max(8, e.clientX - drag.current.dx), window.innerWidth - w - 8);
    const y = Math.min(Math.max(8, e.clientY - drag.current.dy), window.innerHeight - 60);
    setPos({ x, y });
  };
  const onPointerUp = () => {
    if (pos) localStorage.setItem(posKey, JSON.stringify(pos));
    drag.current = null;
  };

  if (!open) {
    return (
      <button className="fchat-launcher" onClick={() => setOpen(true)}>
        💬 Chat
        {unread && <span className="fchat-dot" />}
      </button>
    );
  }

  const style = pos ? { left: pos.x, top: pos.y, right: 'auto', bottom: 'auto' } : undefined;

  return (
    <div className={`fchat ${collapsed ? 'collapsed' : ''}`} style={style}>
      <div
        className="fchat-head"
        onPointerDown={onPointerDown}
        onPointerMove={onPointerMove}
        onPointerUp={onPointerUp}
      >
        <span className="fchat-title">{title}</span>
        <div className="fchat-controls">
          <button
            className="fchat-btn"
            onClick={() => setCollapsed((c) => !c)}
            aria-label={collapsed ? 'Expand' : 'Collapse'}
            title={collapsed ? 'Expand' : 'Collapse'}
          >
            {collapsed ? '▢' : '—'}
          </button>
          <button
            className="fchat-btn"
            onClick={() => setOpen(false)}
            aria-label="Close chat"
            title="Close"
          >
            ✕
          </button>
        </div>
      </div>

      {!collapsed && (
        <div className="fchat-body">
          <Chat roomId={roomId} title={title} showHeader={false} />
        </div>
      )}
    </div>
  );
}
