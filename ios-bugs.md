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
- **Severity:** High
- **Symptom:** Tapping a push notification does nothing — app opens but does not navigate to the relevant session.
- **Expected:** Tapping a notification should open the app and navigate directly to the session referenced in the notification payload.
- **Note:** Cold-launch notification handling was previously fixed (`ff54a6d`), but may be broken again or not working for warm-launch (app already in foreground/background).
