import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';

import { App } from './App';
import { prefetchLobby } from './lib/api';
import { mark, reportPageLoad } from './lib/perf';
import { supabase } from './lib/supabase';
import './styles.css';

// Kick the lobby request off now, before React mounts, so it overlaps with
// rendering instead of waiting in line behind it. Only worth doing if there is
// already a session -- a signed-out visitor sees the login screen.
void supabase.auth.getSession().then(({ data }) => {
  if (data.session) prefetchLobby();
});

mark('react mounting', true);
reportPageLoad();

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
