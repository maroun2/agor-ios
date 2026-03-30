# Agor iOS

Native iPhone app for [Agor](https://agor.live) — browse boards, worktrees, and sessions, chat with AI agents, approve permissions, answer questions, send prompts, and browse files, all with real-time streaming and markdown rendering.

Connects to the FeathersJS daemon using the same REST + WebSocket APIs as the web UI. Built entirely against the existing API — no server-side changes required. See [`context/concepts/api-reference.md`](../../context/concepts/api-reference.md) for the full API documentation.

---

## Features

### Navigation
- **Sidebar** with expandable board/worktree/session tree
- **Important Sessions** section — favorited, running, readyForPrompt, and recent sessions with board icons
- **Needs Attention** section — sessions awaiting permission or input (excludes scheduled sessions)
- **Sidebar caching** — instant display on launch from cached data, background refresh from API
- **Periodic polling** — sidebar stays fresh with 45-second refresh cycles for expanded nodes

### Chat
- **Rich markdown rendering** via Textual with syntax-highlighted code blocks (Highlightr)
- **Real-time streaming** — plain text while streaming (fast), full markdown after completion
- **Thinking blocks** — collapsible with elapsed time
- **Tool use/result blocks** — collapsible with tool icons and input/output previews
- **Task headers** — collapsible dividers grouping messages by task
- **Prompt input** — multi-line with draft persistence across session switches
- **Pagination** — load earlier messages on scroll

### Permissions & Input
- **Inline permission cards** — approve/deny tool execution directly in the chat flow
- **Inline input cards** — answer agent questions with radio/checkbox options or free text
- **Attention bar** — tappable banner that scrolls to the pending card
- **Plan mode** — visual indicator when session is in read-only plan mode

### Session Management
- **SF Symbol status icons** — idle, running (animated), stopping, awaiting permission/input, timed out, completed, failed
- **Stop button** — merged into the status icon position when session is running
- **Archive** and **reset** from the chat toolbar
- **Agent icons** — star for Claude Code, distinct icons for Codex, Gemini, OpenCode

### File Browser
- **Virtual directory tree** navigation built from the flat file API
- **Text files** displayed in monospaced font with text selection
- **Images** (png, jpg, gif, webp) displayed inline from base64
- Accessible from worktree context menu ("Browse Files") or folder icon in chat toolbar

### Settings
- Account info (emoji, name, email)
- Connection status and server URL
- Version and git commit hash
- Logout

### Notifications & Background Recovery
- **Local notifications** when favorited sessions finish (running -> idle)
- **Cross-session toasts** — permission needed, question asked, completed, failed
- **Reconnect banner** — phased "Reconnecting..." -> "Updating..." -> "Updated" on foreground resume
- **Smart URL handling** — auto-adds port 3030, tries https fallback, validates via `/health` before login

---

## Architecture

```
Views (SwiftUI) -> ViewModels (@Observable) -> Services -> Network (REST / Socket.IO)
                                                 |
                                           Models (Codable structs)
```

MVVM with a service layer. ViewModels own state and call services. Views are pure SwiftUI.

### Project Structure

```
AgorApp/
|-- AgorApp.swift                         # @main entry, notification permission
|
|-- Models/
|   |-- Session.swift                     # Session, SessionStatus, PermissionMode, GitState
|   |-- AgorTask.swift                    # Task, TaskStatus
|   |-- Message.swift                     # Message, MessageContent, ContentBlock, MessageRole
|   |-- Board.swift                       # Board
|   |-- Worktree.swift                    # Worktree
|   |-- User.swift                        # User, UserRole
|   |-- Permission.swift                  # PermissionRequestContent, PermissionStatus
|   |-- InputRequest.swift                # InputRequestContent, InputRequestQuestion
|   |-- Streaming.swift                   # StreamingMessage, chunk event types
|   |-- FileItem.swift                    # FileListItem, FileDetail
|   +-- Repo.swift                        # Repo
|
|-- Services/
|   |-- AgorClient.swift                  # REST client (URLSession + JWT)
|   |-- AuthService.swift                 # Login/logout, Keychain, smart URL, token refresh
|   |-- SocketService.swift               # Socket.IO connection + event routing + health check
|   |-- StreamingService.swift            # Chunk accumulation, 50ms debounce
|   +-- SidebarCache.swift                # JSON file cache with 1-hour TTL
|
|-- ViewModels/
|   |-- AppViewModel.swift                # Root: auth state, connection, daemon URL
|   |-- NavigationViewModel.swift         # Sidebar: boards -> worktrees -> sessions, polling
|   |-- ChatViewModel.swift               # Messages, streaming, prompts, permissions, input
|   +-- FileBrowserViewModel.swift        # Virtual directory tree from flat file list
|
|-- Views/
|   |-- App/
|   |   |-- ContentView.swift             # NavigationSplitView, reconnect banner, notifications
|   |   |-- ConnectionSetupView.swift     # Daemon URL + login form
|   |   +-- SettingsView.swift            # Account, connection, about
|   |
|   |-- Navigation/
|   |   |-- SidebarView.swift             # Board -> Worktree -> Session tree
|   |   |-- BoardRow.swift                # Board icon + name
|   |   |-- WorktreeRow.swift             # Worktree name + branch + project
|   |   +-- SessionRow.swift              # Title, status badge, agent icon
|   |
|   |-- Chat/
|   |   |-- ChatView.swift                # Conversation container, toolbar, file browser
|   |   |-- MessageBubble.swift           # Role-based message styling
|   |   |-- MessageContentView.swift      # Routes ContentBlock[] to subviews
|   |   |-- StreamingMessageView.swift    # Live-updating streaming content
|   |   |-- PromptInputBar.swift          # Text input + send button
|   |   +-- TaskHeader.swift              # Collapsible task divider
|   |
|   |-- MessageBlocks/
|   |   |-- TextBlockView.swift           # Markdown rendered text (Textual)
|   |   |-- ToolUseBlockView.swift        # Collapsible tool name + input
|   |   |-- ToolResultBlockView.swift     # Collapsible tool output
|   |   |-- ThinkingBlockView.swift       # Collapsible thinking content
|   |   |-- CodeBlockView.swift           # Syntax-highlighted code (Highlightr)
|   |   |-- PermissionCardView.swift      # Inline approve/deny card
|   |   +-- InputRequestCardView.swift    # Inline question card
|   |
|   |-- FileBrowser/
|   |   |-- FileBrowserView.swift         # Directory/file listing
|   |   +-- FileDetailView.swift          # File content display
|   |
|   +-- Common/
|       |-- StatusBadge.swift             # SF Symbol status icons
|       |-- AgentIcon.swift               # Agent tool icons
|       |-- ConnectionIndicator.swift     # Toolbar connection dot
|       +-- ToastView.swift               # Cross-session toast notifications
|
+-- Utilities/
    |-- KeychainHelper.swift
    |-- DateFormatting.swift
    |-- HapticFeedback.swift
    +-- JSONCoding.swift                  # Custom decoders for polymorphic content
```

---

## Tech Stack

| Dependency | Purpose |
|------------|---------|
| **SwiftUI** (iOS 18+) | `NavigationSplitView`, `@Observable`, declarative UI |
| **socket.io-client-swift** | Socket.IO client matching the FeathersJS server protocol |
| **Textual** | SwiftUI-native markdown rendering |
| **Highlightr** | Syntax highlighting via Highlight.js / JavaScriptCore |
| **URLSession** | Native HTTP, no extra deps |
| **Keychain** | Secure JWT + refresh token storage |

---

## API Endpoints

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/authentication` | POST | Login (email/password) |
| `/boards` | GET | List boards |
| `/worktrees?board_id=X` | GET | Worktrees for a board |
| `/sessions?worktree_id=X` | GET | Sessions for a worktree |
| `/tasks?session_id=X` | GET | Tasks for a session |
| `/messages?session_id=X` | GET | Messages (paginated) |
| `/sessions/:id/prompt` | POST | Send prompt |
| `/sessions/:id/permission-decision` | POST | Approve/deny permission |
| `/sessions/:id/input-response` | POST | Answer input request |
| `/sessions/:id/stop` | POST | Stop running session |
| `/sessions/:id` | PATCH | Archive/update session |
| `/file?worktree_id=X` | GET | List files in worktree |
| `/file/:path?worktree_id=X` | GET | Get file content |
| `/users` | GET | Current user info |
| `/health` | GET | Server health check |

---

## WebSocket Events

FeathersJS emits events as `"<service> <action>"`:

| Event | Purpose |
|-------|---------|
| `sessions patched` | Session status changes, cross-session notifications |
| `tasks created` | New task divider in chat |
| `tasks patched` | Task status update |
| `messages created` | New message (replaces streaming buffer) |
| `messages patched` | Permission/input status resolved |
| `messages streaming:start` | Begin streaming placeholder |
| `messages streaming:chunk` | Append text chunk |
| `messages streaming:end` | Finalize streaming, switch to markdown |
| `messages streaming:error` | Show error |
| `messages thinking:start` | Begin thinking block |
| `messages thinking:chunk` | Append thinking text |
| `messages thinking:end` | End thinking block |

---

## Build & Deploy

### Requirements

- macOS 15 (Sequoia) or later
- Xcode 16.x (NOT 26.x — requires macOS 26)
- Free Apple ID (no paid Developer Program needed for personal device)
- iPhone with iOS 18+
- [xcodegen](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`

### Xcode Setup

Download Xcode 16.x from [developer.apple.com/download/all](https://developer.apple.com/download/all).

Extract the `.xip` to a local APFS volume (not exFAT/NTFS):

```bash
cd /Applications   # or /Volumes/YourDrive
xip -x ~/Downloads/Xcode_16.x.xip
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -runFirstLaunch
xcodebuild -downloadPlatform iOS
```

### Signing Setup (one-time)

1. Open Xcode → Settings → Accounts → `+` → Apple ID
2. Click your account → Manage Certificates → `+` → Apple Development
3. Get your Team ID:
   ```bash
   security find-certificate -a | grep "Apple Development"
   # Look for the 10-character string in parentheses
   ```
4. Set it in `project.yml`:
   ```yaml
   settings:
     DEVELOPMENT_TEAM: "YOUR10CHARID"
   ```

### Generate Project & Build

```bash
cd apps/agor-ios
xcodegen generate
```

### Deploy to iPhone

The `deploy.sh` script handles build, signing, and install in one step:

```bash
cd apps/agor-ios
bash deploy.sh
```

Or build and install manually:

```bash
xcodebuild -project AgorApp.xcodeproj \
  -scheme AgorApp \
  -destination 'platform=iOS,id=<device-udid>' \
  -allowProvisioningUpdates \
  -derivedDataPath .build/DerivedData \
  build

xcrun devicectl device install app \
  --device <device-udid> \
  .build/DerivedData/Build/Products/Release-iphoneos/AgorApp.app
```

Find your device UDID with `xcrun devicectl list devices`.

### First-Time Device Setup

1. Enable **Developer Mode**: Settings → Privacy & Security → Developer Mode → ON (requires restart)
2. Pair: `xcrun devicectl manage pair --device <device-id>`
3. After first install, trust the certificate: Settings → General → VPN & Device Management → Apple Development → Trust

### Simulator

```bash
xcodebuild -project AgorApp.xcodeproj \
  -scheme AgorApp \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -derivedDataPath .build/DerivedData \
  build

# Find simulator UUIDs
xcrun simctl list devices available | grep iPhone

# Boot, install, launch
xcrun simctl boot <simulator-uuid>
xcrun simctl install <simulator-uuid> .build/DerivedData/Build/Products/Debug-iphonesimulator/AgorApp.app
xcrun simctl launch <simulator-uuid> com.agor.AgorApp
```

---

## Connecting to the Daemon

On the login screen, enter your daemon address:
- **Local network:** `192.168.x.x` (find your Mac's IP with `ipconfig getifaddr en0`)
- **Remote:** any URL you use to access the daemon

The app automatically adds `http://` and `:3030` if missing, tries https fallback, and validates via `/health` before login.

The daemon must be running (`pnpm dev` in `apps/agor-daemon`).

---

## Notes

- **Free Apple ID certificates expire after 7 days** — rebuild and re-trust on the device
- **Paid Apple Developer Program** ($99/yr) gives 1-year certificates and App Store distribution
- **Build artifacts** go to `.build/DerivedData/` (gitignored)
- **iOS kills WebSocket ~5-30s after backgrounding** — the app reconnects automatically on foreground resume with a visual reconnect banner
- **No background push notifications** — local notifications fire for in-app events only. APNs would require server-side changes
- **Xcode 26.x won't open on macOS 15** — it requires macOS 26 (Tahoe). Use Xcode 16.x
- If `xcodebuild` fails with "No Account for Team", open Xcode GUI and press Cmd+R once to refresh the session
