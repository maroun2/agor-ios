# iOS Voice Mode, Queue, Reconnect, Widget Bug List — 2026-06-28

Scope: documentation-only triage from user interview, uploaded iOS debug log, and Voice Launcher widget screenshot. No app code changed.

## 1. Voice mode can miss final agent response when started mid-run

### User-observed behavior
- User starts voice mode while agent is already working in an existing session.
- Agent finishes, but voice mode remains in waiting/listening state and does not read final response.
- User restarts app; final message then appears.

### Desired behavior
- If voice mode is enabled mid-run, it should catch up to current running session state.
- It should immediately detect and read any pending/final agent response that arrived before voice mode subscription/listening became fully active.
- After catch-up, it should listen as if voice mode had been active from start of run.

### Evidence
- Log shows reconnect/data reload completing shortly before voice mode startup.
- Voice mode starts at `2026-06-28T19:44:27Z`, then WhisperKit/VAD/pre-roll become ready, while socket auth errors continue.

```text
[2026-06-28T19:44:27Z] [INFO] [Voice] [Voice] 🎙️ Using voice: Zoe (Premium) [com.apple.voice.premium.en-US.Zoe] quality=3
[2026-06-28T19:44:31Z] [ERROR] [Socket] [Socket] error: [REDACTED_DETAILS], "message": jwt expired]
[2026-06-28T19:44:33Z] [INFO] [Voice] [Voice] WhisperKit loaded model: openai_whisper-base.en
[2026-06-28T19:44:33Z] [INFO] [Voice] [Voice] WhisperKit ready
[2026-06-28T19:44:33Z] [INFO] [Voice] [VAD] FluidAudio Silero model loaded (threshold=0.70)
[2026-06-28T19:44:34Z] [INFO] [Voice] [VAD] FluidAudio streaming started (threshold=0.70, silenceDur=3.0s)
[2026-06-28T19:44:34Z] [INFO] [Voice] [Voice] VAD started (FluidAudio Silero)
[2026-06-28T19:44:34Z] [INFO] [Voice] [Voice] ✅ Pre-roll recorder started: voice-[UUID_REDACTED].m4a
```

## 2. Queued text message appears twice

### User-observed behavior
- Queued text message appears above input and also in normal chat history.
- This makes pending work look duplicated.

### Desired behavior
- While queued, message should show only in collapsible queue above input.
- When agent starts processing queued message, remove it from queue.
- At that point, show it once as normal user message in chat history.

## 3. Offline/reconnect errors stack and stale retry remains after reconnect

### User-observed behavior
- Offline/reconnect errors stack in UI.
- Stale `Failed to load session. Retry` remains visible after reconnect/session load succeeds.
- Error UI can remain in chat history or feel like persistent chat content.

### Desired behavior
- Show at most one reconnect/offline toast/banner.
- Auto-clear it after reconnect and successful session load.
- Do not render transient reconnect/load failures as chat history content.

### Evidence
- Repeated socket connectivity errors over session lifetime:

```text
[2026-06-28T17:43:45Z] [ERROR] [Socket] [Socket] error: A server with the specified hostname could not be found.
[2026-06-28T17:55:45Z] [ERROR] [Socket] [Socket] error: The request timed out.
[2026-06-28T17:55:45Z] [ERROR] [Socket] [Socket] error: A server with the specified hostname could not be found.
[2026-06-28T18:11:21Z] [ERROR] [Socket] [Socket] error: A server with the specified hostname could not be found.
```

- Reconnect succeeds at app/data level, but socket still reports expired JWT during same flow:

```text
[2026-06-28T19:43:44Z] [INFO] [App] [App] lifecycle: inactive → active (reconnecting)
[2026-06-28T19:43:44Z] [INFO] [Auth] [Auth] token expires in -4670s — proactive refresh
[2026-06-28T19:43:44Z] [DEBUG] [App] [App] reconnect: phase 1 — reconnecting socket
[2026-06-28T19:43:44Z] [INFO] [Socket] Connecting to [SERVER_URL_REDACTED]
[2026-06-28T19:43:44Z] [DEBUG] [Socket] [Socket] connecting with token [TOKEN_PREFIX_REDACTED]
[2026-06-28T19:43:44Z] [DEBUG] [HTTP] [HTTP] ← 201 POST /authentication/refresh (338ms, 1544 bytes)
[2026-06-28T19:43:44Z] [DEBUG] [App] [App] proactive token refresh: OK
[2026-06-28T19:43:44Z] [DEBUG] [App] [App] reconnect: phase 2 — refreshing data
[2026-06-28T19:43:44Z] [DEBUG] [HTTP] [HTTP] ← 200 GET /boards?$limit=50 (166ms, 49387 bytes)
[2026-06-28T19:43:44Z] [ERROR] [Socket] [Socket] error: [REDACTED_DETAILS], "message": jwt expired]
[2026-06-28T19:43:46Z] [DEBUG] [HTTP] [HTTP] ← 200 GET /sessions?$limit=10000&$sort%5Blast_updated%5D=-1 (1373ms, 1830540 bytes)
[2026-06-28T19:43:48Z] [DEBUG] [Chat] [Chat] loadTasks: 332 from server + 0 unconfirmed local
[2026-06-28T19:43:52Z] [DEBUG] [Chat] [Chat] loadTaskMessages: 3 msgs for task [TASK_ID_REDACTED]
[2026-06-28T19:43:52Z] [DEBUG] [App] [App] reconnect: complete
```

## 4. Voice floating button missing on most screens

### User-observed behavior
- Floating button for active voice mode is missing on most screens.

### Desired behavior
- Floating button appears only while voice mode is already running and user is away from active voice session.
- Tapping button navigates back to active voice session.
- Button must not start voice mode.
- Hide button when user is already in active voice-mode session screen.

## 5. iOS Voice Launcher widget cannot load sessions

### User-observed behavior
- Voice Launcher widget setup cannot load selectable sessions.
- Fails even when main app is open and logged in.
- Widget is unusable because session picker stays empty/placeholder.

### Desired behavior
- Widget configuration should load available sessions using shared/authenticated state or another widget-safe session source.
- User should be able to pick a session and launch voice mode from widget.
- If sessions cannot load, widget should show actionable auth/error state instead of placeholder picker.

### Evidence
- Uploaded screenshot shows Voice Launcher widget configuration with text `Tap to start voice mode for a session` and an empty/placeholder `Session` picker.
- Debug log also shows file/session-adjacent authenticated reads failing during reconnect, which may point to shared auth/session availability issues:

```text
[2026-06-28T19:43:46Z] [DEBUG] [FileBrowser] [FileBrowser] loadFiles worktreeId=[WORKTREE_ID_REDACTED] path="/"
[2026-06-28T19:43:46Z] [ERROR] [FileBrowser] [FileBrowser] loadFiles ERROR: Not authenticated
[2026-06-28T19:44:40Z] [ERROR] [FileBrowser] [FileBrowser] loadFiles ERROR: Not authenticated
[2026-06-28T19:44:45Z] [ERROR] [FileBrowser] [FileBrowser] loadFiles ERROR: Not authenticated
[2026-06-28T19:50:00Z] [ERROR] [FileBrowser] [FileBrowser] loadFiles ERROR: Not authenticated
```

## 6. Debug logs leak credentials, tokens, and session data

### User-observed / log-observed behavior
- Uploaded debug log includes sensitive data.
- Silent re-auth request logs password in `POST /authentication` body.
- Logs also expose token prefixes, auth response sizes, server URL, session IDs, worktree IDs, task IDs, and large request metadata.

### Desired behavior
- Redact passwords, tokens, token prefixes, authorization headers, refresh/access token payloads, session IDs, task IDs, worktree IDs, and server URL before writing/exporting logs.
- Keep enough metadata for debugging: endpoint name, status code, duration, byte count, high-level error message, and timestamp.
- Add export-time scrubber so existing verbose logs cannot leak secrets when shared.

### Evidence
- Sensitive original line redacted here; original log contained real email/password in request body:

```text
[2026-06-28T18:10:54Z] [DEBUG] [HTTP] [HTTP] → POST /authentication body={"email":"[EMAIL_REDACTED]","strategy":"local","password":"[PASSWORD_REDACTED]"}
```

- Token refresh/socket expiry race appears repeatedly:

```text
[2026-06-28T19:43:43Z] [INFO] [Auth] [Auth] token expires in -4669s — proactive refresh
[2026-06-28T19:43:43Z] [INFO] [Auth] Refreshing access token
[2026-06-28T19:43:44Z] [DEBUG] [HTTP] [HTTP] ← 201 POST /authentication/refresh (338ms, 1544 bytes)
[2026-06-28T19:43:44Z] [DEBUG] [App] [App] proactive token refresh: OK
[2026-06-28T19:43:44Z] [ERROR] [Socket] [Socket] error: [REDACTED_DETAILS], "message": jwt expired]
[2026-06-28T19:45:17Z] [ERROR] [Socket] [Socket] error: [REDACTED_DETAILS], "message": jwt expired]
[2026-06-28T19:46:51Z] [ERROR] [Socket] [Socket] error: [REDACTED_DETAILS], "message": jwt expired]
[2026-06-28T19:49:56Z] [ERROR] [Socket] [Socket] error: [REDACTED_DETAILS], "message": jwt expired]
```
