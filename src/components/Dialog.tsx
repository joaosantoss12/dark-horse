import { useState, type ReactNode } from 'react';

import { Modal } from './Modal';

/**
 * A confirm dialog: the modal replacement for window.confirm. `tone="danger"`
 * paints the confirm button red for destructive actions.
 */
export function ConfirmDialog({
  title,
  body,
  confirmLabel = 'Confirm',
  tone = 'default',
  onConfirm,
  onClose,
}: {
  title: string;
  body: ReactNode;
  confirmLabel?: string;
  tone?: 'default' | 'danger';
  onConfirm: () => void | Promise<void>;
  onClose: () => void;
}) {
  const [busy, setBusy] = useState(false);

  const confirm = async () => {
    setBusy(true);
    try {
      await onConfirm();
      onClose();
    } finally {
      setBusy(false);
    }
  };

  return (
    <Modal title={title} onClose={onClose}>
      <div className="dialog-body">{body}</div>
      <div className="dialog-actions">
        <button className="btn btn-ghost" onClick={onClose} disabled={busy}>
          Cancel
        </button>
        <button
          className={`btn ${tone === 'danger' ? 'btn-danger' : ''}`}
          onClick={() => void confirm()}
          disabled={busy}
        >
          {busy ? 'Working…' : confirmLabel}
        </button>
      </div>
    </Modal>
  );
}

/**
 * A prompt dialog: the modal replacement for window.prompt. Validates before it
 * will submit, so a bad value shows an inline error rather than silently doing
 * nothing.
 */
export function PromptDialog({
  title,
  body,
  label,
  placeholder,
  initial = '',
  type = 'text',
  confirmLabel = 'Save',
  validate,
  onSubmit,
  onClose,
}: {
  title: string;
  body?: ReactNode;
  label: string;
  placeholder?: string;
  initial?: string;
  type?: 'text' | 'number';
  confirmLabel?: string;
  /** Return an error string to block submit, or null when the value is good. */
  validate?: (value: string) => string | null;
  onSubmit: (value: string) => void | Promise<void>;
  onClose: () => void;
}) {
  const [value, setValue] = useState(initial);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const submit = async () => {
    const problem = validate?.(value.trim()) ?? null;
    if (problem) {
      setError(problem);
      return;
    }

    setBusy(true);
    try {
      await onSubmit(value.trim());
      onClose();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Something went wrong.');
      setBusy(false);
    }
  };

  return (
    <Modal title={title} onClose={onClose}>
      {body && <div className="dialog-body">{body}</div>}
      {error && <div className="error">{error}</div>}

      <div className="field">
        <label htmlFor="prompt-input">{label}</label>
        <input
          id="prompt-input"
          className="input"
          type={type}
          value={value}
          placeholder={placeholder}
          autoFocus
          onChange={(e) => {
            setValue(e.target.value);
            setError(null);
          }}
          onKeyDown={(e) => {
            if (e.key === 'Enter') void submit();
          }}
        />
      </div>

      <div className="dialog-actions">
        <button className="btn btn-ghost" onClick={onClose} disabled={busy}>
          Cancel
        </button>
        <button className="btn" onClick={() => void submit()} disabled={busy}>
          {busy ? 'Working…' : confirmLabel}
        </button>
      </div>
    </Modal>
  );
}
