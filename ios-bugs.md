# iOS App Bug List

Updated 2026-07-16. Original list compiled 2026-06-28 from debug logs and user reports.

## Fixed (verified in commit history)

### ~~1. Socket never picks up refreshed JWT token~~ FIXED
- Fixed by: `d5615af` correct refresh endpoint + proactive refresh, `39d476e` silent re-auth on JWT expiry, `4235909` force logout on refresh failure

### ~~2. TTS says "Working" but never reads agent response~~ FIXED
- Fixed by: consequence of #1 fix + `b086e11` socket real-time fix via FeathersJS auth + `9b86c56` speak intermediate messages immediately

### ~~3. Floating voice button hides on back arrow~~ FIXED
- Fixed by: `08941b3` background voice session + floating return button, `d06226f` move VoiceFloatingButton inside detail view

### ~~4. Floating voice button tap does nothing~~ FIXED
- Fixed by: `08941b3` floating return button implementation

### ~~5. FileBrowser "Not authenticated" on socket calls~~ FIXED
- Fixed by: consequence of #1 fix + `e9b153f` retry file browser load when socket connects

### ~~6. Error banners don't disappear on reconnect~~ FIXED
- Fixed by: `9cc1286` show task errors inline instead of top banner + general auth recovery chain in `d5615af`

### ~~7. loadBoards retry storm (no backoff)~~ FIXED
- Fixed by: `85dec38` guard loadBoards() against concurrent calls

### ~~8. Server switch loses auth / forces re-login~~ FIXED
- Fixed by: `7055f44` full server profile integration for auth state, `2ded412` cache clear on server switch

### ~~9. 401 persists after successful token refresh~~ FIXED
- Fixed by: `d5615af` proactive refresh + full recovery chain, `4235909` force logout stops 401 flood

---

## Open

### 10. Crash: SIGABRT — UI update from background thread (Swift Concurrency)
- **Fix attempt 2026-07-17:** Likely same root cause as #12 (see below) — crash log `AgorApp-2026-07-17-103130.ips` shows SIGABRT from UIKit state-restoration assertion triggered by mutating SwiftUI state inside the notification `didReceive` handler. Fixed in `84ef1db`. Verify no recurrence.
- **Severity:** Critical
- **Date:** 2026-07-14
- **Signal:** 6 (SIGABRT), Exception type 10 (EXC_CRASH)
- **Device:** iPhone15,4, iOS 26.5.2
- **Symptom:** App crashes. MetricKit crash report shows attributed thread going through `libswift_Concurrency.dylib` → 8 frames of `AgorApp.debug.dylib` → `UIKitCore` (3 frames, assertion failure) → `NSException` → `objc_exception_throw` → `abort()`.
- **Root cause:** An async function or `Task` is updating UI (UIKit/SwiftUI state) without being on `@MainActor`. UIKit asserts and aborts.
- **Note:** Existing `@MainActor` fixes (`1b544db` ChatViewModel, `5a0c17c` NavigationViewModel, `db48eda` FileBrowserViewModel) may not cover all paths. Needs dSYM symbolication to identify exact function.
- **Fix:** Symbolicate with dSYM from build, find the non-`@MainActor` path, add annotation.

### 11. Crash: SIGSEGV — null pointer dereference on main thread
- **Severity:** Critical
- **Date:** 2026-07-16
- **Signal:** 11 (SIGSEGV), Exception type 1 (EXC_BAD_ACCESS), Exception code 1
- **Device:** iPhone15,4, iOS 26.5.2
- **Symptom:** App crashes on main thread during normal UI rendering. MetricKit shows `EXC_BAD_ACCESS` at address `0x8` — accessing a property (offset 8) on a nil/deallocated object.
- **Stack:** `libswiftCore.dylib` → `AgorApp.debug.dylib` (6 frames) → `libdispatch.dylib` (5 frames, GCD) → `CoreFoundation` (RunLoop) → `UIKitCore` → `SwiftUI` → app entry. Background thread simultaneously running Swift Concurrency work with 6 AgorApp frames.
- **Root cause:** Force-unwrap of `nil` or use-after-free. Object accessed on main thread was deallocated or never initialized. Concurrent background work may be mutating shared state.
- **Fix:** Symbolicate with dSYM, find the force-unwrap or implicitly-unwrapped optional, guard it.

### 12. Notification tap does not navigate to session
- **Fix 2026-07-17 (pending verification):** Tap actually crashed the app (SIGABRT, same as #10): setting `pendingNavigationSessionId` synchronously inside `didReceive` ran a SwiftUI update during UIKit's state-restoration snapshot → NSAssertion → abort → app relaunched clean, looking like "nothing happened". Fixed in `3d3dc58` (direct navigation callback) + `84ef1db` (defer navigation until app is active, outside the response transaction).
- **Fix 2026-07-20 (`85521e2`):** `84ef1db` was insufficient — crash logs Jul 17–19 show the real cause: the *async* `userNotificationCenter(_:didReceive:)` variant resumes on a background executor, so the compiler-generated thunk invoked UIKit's completion handler off the main thread; UIKit's response completion runs a state-restoration snapshot that asserts → SIGABRT. Replaced async delegate variants with completion-handler forms, completing on the main queue.
- **Severity:** High
- **Symptom:** Tapping a push notification does nothing — app opens but does not navigate to the relevant session.
- **Expected:** Tapping a notification should open the app and navigate directly to the session referenced in the notification payload.
- **Note:** Cold-launch notification handling was previously fixed (`ff54a6d`), but may be broken again or not working for warm-launch (app already in foreground/background).

### 13. Voice mode auto-disables after sending prompt
- **Severity:** Critical
- **Date:** 2026-07-30
- **Symptom:** User enables voice mode, speaks, prompt is sent successfully, then voice mode silently turns itself off ("Continuous voice mode stopped" / "Voice mode disabled") ~6-13 seconds after send — with no user action. User must manually re-enable voice mode for each utterance.
- **Log evidence:** Three cycles in debug log:
  - 11:45:15 send → 11:45:28 auto-disabled (13s)
  - 11:46:29 send → 11:46:35 auto-disabled (6s)
  - No error or user action logged before disable — it just stops
- **Expected:** Voice mode must stay active continuously. After sending, state should go to `paused` (waiting for agent), then back to `listening` when agent finishes. Voice mode should NEVER auto-disable.
- **Root cause:** Unknown — no log explains why it stops. Likely a state machine bug: something in the send/pause/agent-running path calls `stopContinuousVoiceMode()` or sets `isVoiceModeEnabled = false`.
- **How to fix:**
  1. Search for all calls to `stopContinuousVoiceMode()` and all writes to `isVoiceModeEnabled = false` in VoiceService / ChatViewModel
  2. Each call site must be guarded — only disable voice mode on explicit user action (button tap), NEVER as a side effect of sending, session status change, or navigation
  3. Add a log line with a stack trace or caller tag right before every `stopContinuousVoiceMode()` call so next debug log shows exactly what triggers it
  4. The `paused` → `listening` transition on agent completion must NOT go through a disable/re-enable cycle

### 14. VAD silence timeout cuts user mid-speech (3s too short)
- **Severity:** High
- **Date:** 2026-07-30
- **Symptom:** User is actively speaking but VAD triggers "Speech END" after 3 seconds of perceived silence. User reports being cut off while still talking loudly.
- **Log evidence:** VAD threshold is 0.70, silence duration is 3.0s. Speech START fires at prob=0.37-0.44 (below threshold — M-of-N catches it), but any brief pause > 3s during natural speech triggers end-of-speech.
- **Expected:** Voice mode should NEVER have a hard timeout that cuts speech. User should be able to speak for as long as they want with natural pauses.
- **How to fix:**
  1. Remove or significantly increase the silence timeout — at minimum 8-10 seconds, or better: no timeout at all while VAD probability is above a low floor (e.g. 0.15)
  2. Add a "still speaking" heuristic: if VAD prob oscillates (dips briefly then returns), don't start the silence timer
  3. The silence timer should only trigger end-of-speech when VAD probability has been consistently near zero for the full duration — not just below the speech threshold
  4. Consider adding a manual "done speaking" button as the primary end-of-speech signal instead of relying on silence detection
  5. The `silenceDur` config should be user-adjustable in voice settings (already has a settings UI from `395deff`)
