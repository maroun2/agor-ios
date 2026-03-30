# Agor iOS — TODO Implementation Plan

## Context

The iOS app (`apps/agor-ios/`) is a SwiftUI native iPhone client for Agor. It's substantially complete (phases 1-6 of the ROADMAP), but has 9 feature requests and 5 bugs tracked in `TODO.md`. This plan implements all 14 items, grouped into 6 batches.

---

## Batch 1: Quick Bug Fixes

### Bug 1: Claude agent icon should be a star
**File:** `Views/Common/AgentIcon.swift`
- Change `.claudeCode` case from `"brain.head.profile"` to `"star.fill"`

### Bug 4: Scheduled sessions excluded from "Needs Attention"
**Files:** `Models/Session.swift`, `ViewModels/NavigationViewModel.swift`
- Add computed property `var isScheduled: Bool` on `Session` — checks `scheduledFromWorktree == true` or `title?.hasPrefix("[Scheduled ") == true`
- In `attentionSessions` computed property, add `&& !$0.isScheduled` filter

### Bug 5: Board icon instead of agent icon in attention/important lists
**Files:** `ViewModels/NavigationViewModel.swift`, `Views/Navigation/SidebarView.swift`
- Extend `findContext(for:)` to also return `boardIcon: String`
- In attention/important session rows, show board emoji `Text(boardIcon)` instead of `AgentIcon`

---

## Batch 2: UI Polish

### Feature 5: SF Symbol icons for session status
**File:** `Views/Common/StatusBadge.swift`
- Replace `Circle().fill(color)` with `Image(systemName: icon)` per status:
  - idle → `checkmark.circle`, running → `arrow.trianglehead.2.clockwise.circle` (with rotation animation), stopping → `stop.circle`, awaitingPermission → `lock.fill`, awaitingInput → `questionmark.circle.fill`, timedOut → `clock.badge.exclamationmark`, completed → `checkmark.circle.fill`, failed → `xmark.circle.fill`
- Remove text label (icons are self-explanatory), keep color mapping
- Apply same to `TaskStatusBadge`

### Feature 6: Merge status icon with stop button when running
**File:** `Views/Chat/ChatView.swift`
- In toolbar, when session is running: replace `StatusBadge` with a tappable `stop.circle.fill` button calling `POST /sessions/:id/stop`
- When not running: show normal `StatusBadge` (non-tappable)
- Remove the separate stop button from toolbar

---

## Batch 3: Background/Reconnect UX

### Feature 2: Reconnecting/loading indicator
**Files:** `Views/App/ContentView.swift`
- Add `ReconnectPhase` enum: `.idle`, `.reconnecting`, `.updating`, `.done`
- In `handleScenePhaseChange`, track phase transitions: reconnecting → updating (socket connected) → done (data refreshed) → idle (after 0.5s)
- Overlay banner at top of NavigationSplitView: ProgressView + phase label, auto-dismiss

### Feature 3: Local notification when session finishes
**Files:** `AgorApp.swift`, `Views/App/ContentView.swift`
- Request `UNUserNotificationCenter` permission on launch
- Track previous session statuses in a dictionary
- On `sessions patched` socket event: if `running → idle` and session is favorited or last-viewed, fire local notification
- Only fire when app is backgrounded or user is viewing a different session
- Handle notification tap to navigate to the session

---

## Batch 4: Session List Improvements

### Feature 1: Cache sidebar for instant display
**Files:** `ViewModels/NavigationViewModel.swift`, new `Services/SidebarCache.swift`
- `SidebarCache`: serializes board/worktree/session hierarchy to JSON in caches directory
- On `loadBoards()`: load cache first (synchronous), populate sidebar, then fetch from API and overwrite cache
- TTL: discard cache older than 1 hour

### Bug 2: Session list not refreshed on expand
**Files:** `ViewModels/NavigationViewModel.swift`, `Views/Navigation/SidebarView.swift`
- On worktree DisclosureGroup expand: re-fetch sessions for that worktree
- On board DisclosureGroup expand: re-fetch worktrees for that board
- Add 45-second polling timer for expanded nodes only
- Start/stop polling on foreground/background transitions

---

## Batch 5: New Screens & Features

### Feature 4: File browser for worktrees
**New files:** `Views/FileBrowser/FileBrowserView.swift`, `Views/FileBrowser/FileDetailView.swift`, `ViewModels/FileBrowserViewModel.swift`, `Models/FileItem.swift`
**Modified:** `Services/AgorClient.swift`, `Views/Navigation/SidebarView.swift`, `Views/Chat/ChatView.swift`
- Add `listFiles(worktreeId:)` and `getFile(fileId:)` to AgorClient
- `FileBrowserViewModel`: loads flat file list from API, builds virtual directory tree, navigates in/out
- `FileBrowserView`: List of folders/files at current path, tap to navigate/view
- `FileDetailView`: monospaced text for code, rendered markdown, inline images
- Entry points: context menu on worktree rows ("Browse Files"), folder icon in chat toolbar → opens as sheet

### Feature 7: Account/connection controls
**New file:** `Views/App/SettingsView.swift`
**Modified:** `Views/Navigation/SidebarView.swift`
- Sections: Account (email, logout), Connection (daemon URL, state, switch server), About (version, git hash)
- Accessible from sidebar footer (gear icon or "Settings" row)
- Logout: clear Keychain, disconnect socket, return to ConnectionSetupView

### Feature 8: Clean/reset session button
**Files:** `ViewModels/ChatViewModel.swift`, `Views/Chat/ChatView.swift`
- Add "Reset" button in chat toolbar menu (alongside Archive)
- Action: confirmation alert → archive current session

### Feature 9: Smart URL handling
**Files:** `Views/App/ConnectionSetupView.swift`, `Services/AuthService.swift`
- Normalize URL: strip paths, add scheme if missing, add `:3030` if no port
- Validate via `GET /health` before login attempt
- Try http first, fallback to https
- Show "Checking server..." progress during validation

---

## Batch 6: Tool Expand Bug Fix

### Bug 3: Tool use/result blocks can't be expanded
**Files:** `Views/MessageBlocks/ToolUseBlockView.swift`, `Views/MessageBlocks/ToolResultBlockView.swift`
- Replace `DisclosureGroup` with manual expand/collapse: `Button` toggling `@State isExpanded` + conditional content
- Add `.contentShape(Rectangle())` on the label HStack for full-width tap target
- Use `.buttonStyle(.plain)` to avoid gesture conflicts with ScrollView/LazyVStack
