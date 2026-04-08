# Agor iOS — Bugs & Feature Requests

## Bugs

- [x] **MCP servers: "failed to load mcp servers"** — iOS used REST `GET /sessions/:id/mcp-servers` (nested route) which returned 500. Web UI uses Socket.IO top-level `session-mcp-servers` service instead. Fixed `MCPViewModel.loadSessionServers()` to use `socketService.serviceFind(service: "session-mcp-servers", query: ["session_id": sessionId])` matching web UI approach.
- [ ] **Archive & Reset loses agent permissions** — When using "Archive & Reset" (archive old session + create new one), the new session gets default permissions instead of inheriting the archived session's agent permissions. The new session should copy the same permission settings (e.g. allowed tools, MCP servers) from the archived session so the agent continues working with the same access level.
- [x] **Duplicate notifications for same session** — Socket reconnect + missed transition check both fire for the same running→idle transition. Fixed with `lastNotifiedStatus` tracking per session + stable notification ID (`session-{id}-idle` instead of timestamp-based). Clears on next running transition.
- [x] **No links or images in chat messages** — Three issues fixed:
  1. `.blocks` messages (most assistant messages) used plain `TextBlockView` instead of `EnhancedTextBlockView` — no file links, no session links, no inline images. Fixed `MessageContentView` to use `EnhancedTextBlockView` with all props.
  2. Markdown URLs not tappable — `StructuredText(markdown:)` rendered links but had no tap handler. Added `.environment(\.openURL, ...)` to `MarkdownTextView`.
  3. File path detection improvements — `FilePathDetector` now resolves bare filenames (e.g. `TODO.md`) against cached file list when unambiguous (exactly one match). Excludes matches inside URLs and domain TLDs. File list preloaded on session open.
