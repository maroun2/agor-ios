# Agor iOS — Native App Roadmap

## Overview

Native iPhone app for Agor — browse boards/worktrees/sessions, chat with AI agents, approve permissions inline, answer questions, send prompts, all with real-time streaming and markdown rendering.

Connects to the existing FeathersJS daemon (configurable URL) using the same REST + WebSocket APIs as the web UI.

---

## Prerequisites

### Network Access

The daemon binds to `*:3030` (all interfaces), so it's already reachable from any device on the local network. The iPhone connects via `http://<server-ip>:3030`.

For remote access: use a VPN, Tailscale, Cloudflare Tunnel, or similar.

No server-side changes needed — the existing API works as-is for native iOS clients.

### App Transport Security (ATS)

iOS blocks `http://` connections by default (requires `https://`). Since the daemon typically runs on `http://<ip>:3030`, you must add an ATS exception to `Info.plist`:

```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsArbitraryLoads</key>
    <true/>
</dict>
```

This is necessary because the daemon URL is user-configurable and will be plain HTTP in local/dev setups.

---

## Tech Stack

| Choice | Why |
|--------|-----|
| **SwiftUI** (iOS 17+) | `NavigationSplitView`, `@Observable`, declarative UI |
| **socket.io-client-swift** | Official Socket.IO iOS client, matches server protocol |
| **Textual** (swift-textual) | SwiftUI-native markdown rendering (successor to MarkdownUI) |
| **URLSession** | Native HTTP, no extra deps |
| **Keychain** | Secure JWT storage |

---

## Architecture

```
Views (SwiftUI) → ViewModels (@Observable) → Services → Network (REST / Socket.IO)
                                                ↑
                                          Models (Codable structs)
```

MVVM with a service layer. Services are singletons in the SwiftUI environment. ViewModels own state and call services. Views are pure UI.

---

## Project Structure

```
apps/agor-ios/
├── AgorApp/
│   ├── AgorApp.swift                     # @main entry point
│   │
│   ├── Models/                           # Codable structs (mirrors @agor/core/types)
│   │   ├── Session.swift                 # Session, SessionStatus, PermissionMode
│   │   ├── AgorTask.swift                # Task, TaskStatus
│   │   ├── Message.swift                 # Message, MessageContent, ContentBlock, MessageRole
│   │   ├── Board.swift                   # Board
│   │   ├── Worktree.swift                # Worktree
│   │   ├── User.swift                    # User, UserRole
│   │   ├── Permission.swift              # PermissionRequestContent, PermissionStatus, PermissionScope
│   │   ├── InputRequest.swift            # InputRequestContent, InputRequestQuestion
│   │   └── Streaming.swift               # StreamingMessage, chunk event types
│   │
│   ├── Services/
│   │   ├── AgorClient.swift              # REST client (URLSession + JWT headers)
│   │   ├── AuthService.swift             # Login/logout, Keychain token storage
│   │   ├── SocketService.swift           # Socket.IO connection + event routing
│   │   └── StreamingService.swift        # Chunk accumulation, streaming→created handoff
│   │
│   ├── ViewModels/
│   │   ├── AppViewModel.swift            # Root: auth, connection, daemon URL
│   │   ├── NavigationViewModel.swift     # Sidebar: boards → worktrees → sessions
│   │   └── ChatViewModel.swift           # Messages, streaming, prompts, permissions, input
│   │
│   ├── Views/
│   │   ├── App/
│   │   │   ├── ContentView.swift             # NavigationSplitView root
│   │   │   └── ConnectionSetupView.swift     # Daemon URL + login form
│   │   │
│   │   ├── Navigation/
│   │   │   ├── SidebarView.swift             # Board → Worktree → Session tree
│   │   │   ├── BoardRow.swift                # Board icon + name
│   │   │   ├── WorktreeRow.swift             # Worktree name + branch
│   │   │   └── SessionRow.swift              # Title, status badge, agent icon
│   │   │
│   │   ├── Chat/
│   │   │   ├── ChatView.swift                # Main conversation container
│   │   │   ├── MessageBubble.swift           # Single message (role-based styling)
│   │   │   ├── MessageContentView.swift      # Routes ContentBlock[] to subviews
│   │   │   ├── StreamingMessageView.swift    # Live-updating streaming content
│   │   │   ├── PromptInputBar.swift          # Text input + send button
│   │   │   └── TaskHeader.swift              # Task divider with prompt summary
│   │   │
│   │   ├── MessageBlocks/
│   │   │   ├── TextBlockView.swift           # Textual (markdown) rendered text
│   │   │   ├── ToolUseBlockView.swift        # Collapsible: tool name + input summary
│   │   │   ├── ToolResultBlockView.swift     # Collapsible: tool output
│   │   │   ├── ThinkingBlockView.swift       # Collapsible thinking content
│   │   │   ├── CodeBlockView.swift           # Syntax-highlighted code
│   │   │   ├── PermissionCardView.swift      # INLINE: tool name, input, approve/deny buttons
│   │   │   └── InputRequestCardView.swift    # INLINE: question, options, submit button
│   │   │
│   │   └── Common/
│   │       ├── StatusBadge.swift             # Colored dot + label
│   │       ├── AgentIcon.swift               # claude-code/codex/gemini icon
│   │       └── ConnectionIndicator.swift     # Toolbar connection dot
│   │
│   └── Utilities/
│       ├── KeychainHelper.swift
│       ├── DateFormatting.swift
│       └── JSONCoding.swift                  # Custom decoders for polymorphic content
│
├── AgorAppTests/
└── Package.swift                             # SPM dependencies
```

---

## API Endpoints

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/authentication` | POST | Login (email/password or anonymous) |
| `/boards` | GET | List boards |
| `/worktrees?board_id=X` | GET | Worktrees for a board |
| `/sessions?worktree_id=X` | GET | Sessions for a worktree |
| `/tasks?session_id=X&$sort[created_at]=1` | GET | Tasks for a session |
| `/messages?session_id=X&$sort[index]=1` | GET | Messages (paginated) |
| `/sessions/:id/prompt` | POST | Send prompt to session |
| `/sessions/:id/permission-decision` | POST | Approve/deny permission |
| `/sessions/:id/input-response` | POST | Answer input request |
| `/users` | GET | Current user info |

---

## WebSocket Events (Socket.IO)

FeathersJS emits events as `"<service> <action>"`:

| Event | Purpose |
|-------|---------|
| `sessions patched` | Update session status in sidebar + chat header |
| `tasks created` | New task divider in chat |
| `tasks patched` | Task status change (running → completed) |
| `messages created` | New message in chat; replaces streaming buffer entry |
| `messages patched` | Permission/input status resolved |
| `messages streaming:start` | Begin streaming placeholder |
| `messages streaming:chunk` | Append text chunk to streaming buffer |
| `messages streaming:end` | Finalize streaming |
| `messages streaming:error` | Show error |
| `messages thinking:start` | Begin thinking block |
| `messages thinking:chunk` | Append thinking text |
| `messages thinking:end` | End thinking block |

---

## Key Design Decisions

### 1. Message Content Polymorphism

`Message.content` varies by `message.type`:

```swift
enum MessageContent: Codable {
    case text(String)
    case blocks([ContentBlock])
    case permissionRequest(PermissionRequestContent)
    case inputRequest(InputRequestContent)
}

// Decode strategy: check message.type field first
// "permission_request" → PermissionRequestContent
// "input_request"      → InputRequestContent
// default              → try [ContentBlock], fallback String
```

### 2. Permissions & Input Requests — Inline in Chat

**No floating banners.** Permission requests and input requests render as **inline chat cards** in the message list, exactly where they appear in the conversation flow:

```
┌─────────────────────────────────────┐
│  [User message bubble]              │
│  "Add authentication to the app"    │
├─────────────────────────────────────┤
│  [Assistant text blocks...]         │
├─────────────────────────────────────┤
│  ┌─ Permission Request ───────────┐ │
│  │ 🔧 Bash                        │ │
│  │ npm install passport            │ │
│  │                                 │ │
│  │  [Allow Once] [Allow All] [Deny]│ │
│  └─────────────────────────────────┘ │
├─────────────────────────────────────┤
│  [Next assistant message...]        │
└─────────────────────────────────────┘
```

- **PermissionCardView**: Shows tool name, input preview (collapsed for long inputs), and action buttons
  - "Allow Once" → scope: `once`
  - "Allow Session" → scope: `session`
  - "Deny" → allow: false
  - After resolution: card collapses to one-line "✅ Approved" or "❌ Denied" with tool name
  - Pending cards auto-scroll into view and have a highlighted border (orange/yellow)

- **InputRequestCardView**: Shows question text, radio/checkbox options, optional free-text field, submit button
  - After answered: collapses to show selected answer
  - Pending cards auto-scroll into view

- **Chat header bar**: When session is `awaiting_permission` or `awaiting_input`, a thin colored bar at top says "Needs your attention ↓" — tapping scrolls to the pending card

### 3. Streaming: Plain Text While Streaming, Markdown After

Rendering markdown on every streaming chunk (arriving ~20x/sec) causes UI freezes. Instead:
- **While streaming**: render accumulated text as **plain monospaced text** (fast, no parsing)
- **On `streaming:end`**: switch to full markdown rendering (Textual)
- This is the same pattern ChatGPT iOS uses

Chunk accumulation mirrors web UI's `useStreamingMessages` pattern:
- `[String: StreamingMessage]` map keyed by message_id
- `streaming:chunk` → append to buffer
- `thinking:chunk` → append to thinking buffer
- `messages created` → remove from streaming map (DB message takes over)
- Debounce UI updates to ~50ms

### 4. Socket.IO Auth

```swift
// After REST login, authenticate socket
let manager = SocketManager(socketURL: url, config: [
    .extraHeaders(["Authorization": "Bearer \(token)"]),
    .forceWebsockets(true)
])
```

### 5. Plan Mode

When `session.permission_config.mode == "plan"`:
- "Plan Mode" badge on session row and chat header
- No permission cards appear (agent only reads, doesn't execute)
- Prompt bar still works for follow-up instructions

### 6. Background & Notifications

**iOS kills WebSocket connections ~5-30 seconds after backgrounding.** The app cannot maintain a persistent socket in the background (Apple only allows this for VoIP/audio/location apps).

**v1 strategy — foreground-only notifications:**
- When viewing a different session: fire local notifications for events on other sessions (permission needed, task done, etc.)
- When app returns from background: reconnect socket, re-fetch latest state for all visible data, show a "catch-up" summary if things changed while away
- No background notifications in v1

**Future (v2):** Add Apple Push Notification (APNs) support on the daemon side for real push notifications that work when the app is fully suspended. This requires server-side changes (APNs integration) and is out of scope for v1.

---

## Implementation Phases

### Phase 1: Foundation

**Goal**: App connects to daemon, authenticates, stores credentials.

- [ ] Create Xcode project with SPM at `apps/agor-ios/`
- [ ] Add dependencies: `SocketIO`, `Textual` (markdown rendering)
- [ ] **Models/**: All Codable structs matching backend types
  - Session, SessionStatus, PermissionMode
  - AgorTask, TaskStatus
  - Message, MessageContent, ContentBlock (text, tool_use, tool_result, thinking)
  - Board, Worktree, User
  - PermissionRequestContent, InputRequestContent
  - Streaming event types
- [ ] **AgorClient**: URLSession-based REST client
  - Configurable base URL
  - JWT `Authorization: Bearer` header injection
  - Generic `get<T>`, `post<T>`, `patch<T>` with Codable
  - Paginated response wrapper (`PaginatedResponse<T>`)
- [ ] **AuthService**: JWT login/logout + token refresh
  - `POST /authentication` with email/password
  - Keychain storage for access token, refresh token, + daemon URL
  - Remember last connection on app launch
  - Auto-refresh: intercept 401 responses → call `POST /authentication/refresh` with refresh token (30-day expiry) → retry original request → if refresh fails, redirect to login
- [ ] **ConnectionSetupView**: First-run setup
  - Daemon URL text field (with "http://", port hint)
  - Email + password fields
  - "Connect" button with loading state
  - Error display for connection failures
- [ ] **Verify**: App launches → enter URL → login → token persists across restarts

### Phase 2: Navigation Sidebar

**Goal**: Browse boards → worktrees → sessions in a side menu.

- [ ] **SocketService**: Socket.IO connection lifecycle
  - Connect after auth with JWT
  - Auto-reconnect on disconnect
  - Route CRUD events to callbacks
- [ ] **NavigationViewModel**: Hierarchical data loading
  - Fetch boards on connect
  - Lazy-load worktrees when board expanded
  - Lazy-load sessions when worktree expanded
  - Real-time updates via socket events
- [ ] **SidebarView**: Expandable tree
  - `List` with `DisclosureGroup` for boards and worktrees
  - **BoardRow**: icon/emoji + name + worktree count
  - **WorktreeRow**: name + branch ref + session count badge
  - **SessionRow**: title (or first prompt truncated) + status badge + agent icon
  - Status badges: green=idle, blue=running, orange=awaiting_permission/input, red=failed
  - Pull-to-refresh
- [ ] **ContentView**: `NavigationSplitView` with sidebar + detail
  - iPhone: push navigation (list → detail), standard iOS pattern — NOT a visible sidebar
  - iPad: persistent sidebar + detail side-by-side
- [ ] **"Needs Attention" section**: At the top of the sidebar, above boards
  - Shows all sessions across all boards that are `awaiting_permission` or `awaiting_input`
  - Badge count on each board/worktree row showing how many sessions need attention inside
  - Tapping a session here navigates directly to it
- [ ] **Verify**: Real data loads, expanding works, tapping session shows it selected

### Phase 3: Chat Core

**Goal**: View conversations with rich markdown, send prompts.

- [ ] **ChatViewModel**: Message management
  - Load messages for selected session (paginated, newest first → reversed for display)
  - Group messages by task_id for task headers
  - Combined `displayMessages` array merging persisted + streaming
  - Send prompt: `POST /sessions/:id/prompt` with `{ prompt: "..." }`
- [ ] **ChatView**: Conversation layout
  - `ScrollViewReader` + `LazyVStack` for performance
  - Auto-scroll to bottom on new messages
  - Load-more on scroll to top (pagination)
  - Session header: title, status badge, agent icon, branch name
  - Empty state: "Send a prompt to get started"
- [ ] **MessageBubble**: Role-based layout
  - User: right-aligned, accent-colored background
  - Assistant: left-aligned, secondary background, full-width for long content
  - System: centered, muted styling
- [ ] **MessageContentView**: Routes `ContentBlock[]` to appropriate views
- [ ] **TextBlockView**: Textual with dark-mode-aware theme
  - Code blocks with monospaced font + dark background + copy button (no syntax highlighting yet — Phase 7)
  - Tables, lists, headings, links
  - Inline code styling
- [ ] **ToolUseBlockView**: Collapsed by default
  - Shows: tool icon + name + one-line input summary
  - Expandable to show full input JSON
- [ ] **ToolResultBlockView**: Collapsed by default
  - Shows: success/error indicator + one-line preview
  - Expandable to show full output
- [ ] **TaskHeader**: Divider between tasks
  - Shows task prompt (truncated), status, duration
  - Collapsible to hide a completed task's messages
- [ ] **PromptInputBar**: Fixed at bottom
  - Multi-line `TextEditor` (grows up to 4 lines, then scrolls)
  - Send button (disabled when empty or session not in promptable state)
  - Visual states: "Session is running..." / "Type a prompt..." / disabled for non-idle
- [ ] **Verify**: Load real conversation, markdown renders, code highlighted, send prompt works

### Phase 4: Real-time Streaming

**Goal**: Messages stream in live, thinking blocks animate.

- [ ] **StreamingService**: Chunk buffer
  - `activeStreams: [String: StreamingMessage]` keyed by message_id
  - `handleStreamingChunk` → append text, debounce at 50ms
  - `handleThinkingChunk` → append to thinking buffer
  - `handleMessageCreated` → remove from activeStreams (handoff to persisted)
  - Handle `streaming:error` → show error state in message
- [ ] Wire Socket.IO streaming events → StreamingService → ChatViewModel
- [ ] **StreamingMessageView**: Live-updating content
  - Renders accumulated text as **plain monospaced text** while streaming (fast, no parsing)
  - On `streaming:end` → switch to full Textual markdown rendering
  - Animated cursor/pulse at end of text
  - Thinking indicator: pulsing "Thinking..." with elapsed time
- [ ] **ThinkingBlockView**: Collapsible
  - Collapsed: "Thinking (3.2s)" with chevron
  - Expanded: italic markdown content
  - Animates open while streaming, auto-collapses on `thinking:end`
- [ ] Handle the streaming→created transition smoothly
  - When `messages created` arrives, remove streaming entry
  - Content should not flicker (streaming text → identical persisted text)
- [ ] **Verify**: Send prompt, watch text stream in live, thinking block appears/collapses

### Phase 5: Inline Permissions & Input Requests

**Goal**: Approve permissions and answer questions directly in the chat flow.

- [ ] **PermissionCardView**: Inline message card
  - Renders in message list where `type == "permission_request"`
  - **Pending state**:
    - Orange/yellow left border accent
    - Tool name with icon (Bash, Edit, Write, etc.)
    - Input preview: collapsed with "Show details" toggle
      - Bash: shows command
      - Edit: shows file path + diff preview
      - Write: shows file path
      - Other: shows JSON summary
    - Action buttons row: `[Allow Once]` `[Allow Session]` `[Deny]`
    - Auto-scrolls into view when it appears
  - **Resolved state**:
    - Collapsed one-liner: "✅ Allowed Bash" or "❌ Denied Edit"
    - Tappable to expand and see original details
  - API call: `POST /sessions/:id/permission-decision`
    ```json
    {
      "requestId": "<request_id>",
      "taskId": "<task_id>",
      "allow": true,
      "scope": "once",
      "decidedBy": "<user_id>"
    }
    ```
- [ ] **InputRequestCardView**: Inline question card
  - Renders where `type == "input_request"`
  - **Pending state**:
    - Blue left border accent
    - Question header text
    - Option list: radio buttons (single select) or checkboxes (multi select)
    - Each option: label + description
    - Optional free-text field for custom answers
    - `[Submit]` button (disabled until selection made)
    - Auto-scrolls into view
  - **Answered state**:
    - Collapsed: "Answered: <selected option label>"
    - Tappable to expand
  - API call: `POST /sessions/:id/input-response`
    ```json
    {
      "requestId": "<request_id>",
      "taskId": "<task_id>",
      "answers": { "0": "selected_option" },
      "respondedBy": "<user_id>"
    }
    ```
- [ ] **Chat header attention bar**:
  - Thin bar at top of chat when session is `awaiting_permission` or `awaiting_input`
  - "⚠ Needs attention" — tap to scroll to the pending card
  - Disappears when resolved
- [ ] **Verify**: Permission card appears inline, approve works, card collapses. Input card appears, select option, submit, card collapses.

### Phase 6: Foreground Notifications & Background Recovery

**Goal**: Alert user about other sessions while in-app; recover gracefully from background.

- [ ] **In-app notifications** (while app is foregrounded, viewing a different session):
  - Use a toast/banner at top of screen (not iOS push notifications)
  - "Session 'fix-auth' needs permission to run Bash" — tap to navigate
  - "Session 'fix-auth' completed" — tap to navigate
  - "Session 'fix-auth' is asking a question" — tap to navigate
- [ ] **Background recovery** (when app returns from background):
  - Listen to `scenePhase` changes (`.background` → `.active`)
  - On return to foreground: reconnect Socket.IO, re-fetch current session state
  - If session status changed while away, show a "catch-up" indicator
  - Re-fetch sidebar data (sessions may have started/finished/need attention)
- [ ] **Badge count**: App icon badge = number of sessions in `awaiting_permission` or `awaiting_input` (updated while foregrounded, frozen when backgrounded)
- [ ] **Verify**: Switch between sessions, see toast for events on other session. Background app, return, state refreshes correctly.

### Phase 7: Polish

**Goal**: Production-quality experience.

- [ ] **Code syntax highlighting**: Evaluate Highlightr or TreeSitter for CodeBlockView
  - Language detection from code fence (```python, ```swift, etc.)
  - Dark/light theme matching system appearance
  - Note: Highlightr wraps Highlight.js via JavaScriptCore — heavy but feature-rich. TreeSitter is native but more work. Evaluate both before committing.
  - Phases 1-6 use simple monospaced font + dark background (no highlighting)
- [ ] **Plan mode**:
  - "Plan Mode" badge on SessionRow and chat header
  - Different styling (muted purple accent?)
  - Prompt bar still functional
- [ ] **Dark/light mode**: Follow system, test all views in both
- [ ] **Pull-to-refresh**: On sidebar lists and message list
- [ ] **Connection indicator**: Toolbar icon showing connected/disconnected/reconnecting
- [ ] **Error states**:
  - Lost connection banner in chat
  - Retry buttons on failed loads
  - Empty states for no boards/sessions
- [ ] **Session status badges** in sidebar update in real-time
- [ ] **Performance**:
  - Message list pagination (load 50 at a time)
  - Lazy image loading
  - Streaming debounce at 50ms
- [ ] **Haptic feedback**: Light haptic on permission approve/deny, prompt send
- [ ] **Verify**: Full end-to-end on real daemon, all edge cases handled

---

## Screen Flows

### First Launch
```
ConnectionSetupView → Enter daemon URL + credentials → Login → ContentView (sidebar + empty detail)
```

### Normal Use
```
Sidebar (boards tree) → Tap session → ChatView loads messages
                      → See streaming in real-time
                      → Permission card appears inline → Tap "Allow"
                      → Input card appears inline → Select option → Submit
                      → Send new prompt via input bar
```

### Background → Foreground Recovery
```
App backgrounded → iOS kills socket after ~5-30s
App reopened     → Reconnect socket
               → Re-fetch session state + sidebar
               → Show "catch-up" if status changed while away
```

---

## Data Model Quick Reference

```swift
// Key status values
enum SessionStatus: String, Codable {
    case idle, running, stopping
    case awaiting_permission, awaiting_input
    case timed_out, completed, failed
}

// Permission scope options for approve buttons
enum PermissionScope: String, Codable {
    case once, session, project
}

// Content blocks in assistant messages
enum ContentBlock: Codable {
    case text(TextContent)           // { type: "text", text: "..." }
    case toolUse(ToolUseContent)     // { type: "tool_use", id, name, input }
    case toolResult(ToolResultContent) // { type: "tool_result", tool_use_id, content }
    case thinking(ThinkingContent)   // { type: "thinking", thinking: "..." }
}

// Message types that determine content decoding
enum MessageType: String, Codable {
    case user, assistant, system
    case permission_request     // content is PermissionRequestContent
    case input_request          // content is InputRequestContent
}
```

---

## Reference Files

| File | Purpose |
|------|---------|
| `packages/core/src/types/message.ts` | Canonical message/content types |
| `packages/core/src/types/session.ts` | Session model with all statuses |
| `apps/agor-ui/src/hooks/useStreamingMessages.ts` | Streaming chunk accumulation pattern |
| `apps/agor-ui/src/components/MessageBlock/` | Message rendering reference |
| `apps/agor-ui/src/components/PermissionRequestBlock/` | Permission UI reference |
| `apps/agor-ui/src/components/InputRequestBlock/` | Input request UI reference |
| `apps/agor-daemon/src/index.ts` | Endpoint contracts (prompt, permission, input) |
