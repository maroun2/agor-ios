# iOS App Bug List (2026-06-28)

Compiled from debug logs and user reports.

## Critical

### 1. Socket never picks up refreshed JWT token
- **Symptom:** Socket reconnects with expired token for hours. All real-time events lost (messages, task patches, session status). App falls back to HTTP polling only.
- **Root cause:** Proactive token refresh updates HTTP client token but socket continues using the stale token from initial auth. Socket `onAuthFailure` / reconnect logic doesn't fetch the current token before reconnecting.
- **Impact:** No real-time updates, TTS never receives agent responses, chat feels broken/laggy.
- **Log evidence:** `jwt expired (expiredAt: 2026-06-28T18:25:54)` repeating at 19:43-19:48, over 1 hour after expiry. HTTP requests succeed with refreshed token.

### 2. TTS says "Working" but never reads agent response
- **Symptom:** Voice mode activates, TTS speaks "Working" status, then nothing — agent response never spoken.
- **Root cause:** Direct consequence of bug #1. TTS relies on real-time `messages created` socket events to know when to speak. Socket is dead, so events never arrive.
- **Fix:** Fixing bug #1 should resolve this. May also need fallback: poll for new messages when socket is disconnected and voice mode is active.

## High

### 3. Floating voice button hides on back arrow
- **Symptom:** When voice mode is active on session A and user navigates to session B via a link, floating button shows correctly. But pressing the back arrow from session A hides the button.
- **Expected:** Floating button should remain visible whenever voice mode is active on any session, regardless of navigation method.

### 4. Floating voice button tap does nothing
- **Symptom:** Tapping the floating voice button has no effect.
- **Expected:** Should navigate back to the voice mode session.

### 5. FileBrowser "Not authenticated" on socket calls
- **Symptom:** `[FileBrowser] loadFiles ERROR: Not authenticated` — file browser uses socket `find` which has the expired token.
- **Root cause:** Same as bug #1 — socket auth is stale.
- **Log evidence:** Lines 210, 324, 335 in debug log.

### 6. Error banners don't disappear on reconnect
- **Symptom:** Error messages shown during network issues persist on screen after connection is restored.
- **Expected:** Error/offline banners should auto-dismiss when connectivity and auth are restored.

## Medium

### 7. loadBoards retry storm (no backoff)
- **Symptom:** When server is unreachable, `loadBoards` fires 6+ times in 3 seconds with no exponential backoff.
- **Log evidence:** Lines 42-57 — rapid-fire `GET /boards` every ~0.5s, all failing.
- **Expected:** Exponential backoff on repeated failures.

### 8. Server switch loses auth / forces re-login
- **Symptom:** Switching from DuckDNS server to public IP server has no stored credentials for the new profile. Silent re-auth fails ("no stored credentials"), forces full logout + manual login.
- **Log evidence:** Lines 78-91 — switch to Vps1-public-ip → no token → silentReauth fails → logout.
- **Expected:** Credentials should be shared across server profiles for the same account, or at minimum the password should be stored per-profile.

### 9. 401 persists after successful token refresh
- **Symptom:** `POST /authentication/refresh` returns 201 (success), but the retried `GET /users/:id` still gets 401.
- **Log evidence:** Lines 157-161 — refresh succeeds, but next request fails with NotAuthenticated.
- **Possible cause:** Refreshed token not applied to the retry request, or race condition between refresh and retry.
