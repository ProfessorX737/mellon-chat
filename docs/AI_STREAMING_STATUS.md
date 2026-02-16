# Mellon Chat - AI Streaming Feature Status

## Overview

Mellon Chat is a fork of FluffyChat (Flutter Matrix chat client) with AI assistant streaming features. The goal is ChatGPT-style rendering for bot messages: no avatar, no bubble, full-width layout, collapsible tool sections, streaming markdown, and rich text rendering.

**Repo:** `/Users/xavier/mellon-chat` (GitHub: ProfessorX737/mellon-chat)
**Stack:** Flutter web (CanvasKit), Matrix protocol, FVM Flutter 3.38.9

---

## What's Been Built

### Phase 1: Bot Detection & ChatGPT-Style Layout (COMPLETE)

**Files modified:**
- `lib/pages/chat/events/message.dart` - ChatGPT-style layout for bot messages:
  - No avatar, no sender name, no colored bubble
  - Full-width messages (removed `maxTimelineWidth` and `columnWidth * 1.5` constraints)
  - Hidden "edited" pencil icon for bot messages (since streaming uses message edits)
- `lib/pages/chat/events/message_content.dart` - Routes bot messages to `AIMessageWrapper` and uses `GptMarkdown` for rendering instead of `HtmlMessage`

**Bot detection:** Checks sender user ID for patterns: `jarvis`, `alfred`, `tars`, `friday`, `bot`, `-ai`, `_ai`, `assistant`, `claude`, `agent` (see `BotEventExtension` in `ai_message_wrapper.dart`)

### Phase 1.5: AI Stream Model & Widgets (COMPLETE)

**New files in `lib/ai_stream/`:**

| File | Purpose |
|------|---------|
| `ai_stream.dart` | Library barrel file, exports all components |
| `ai_stream_model.dart` | Data models: `AIStreamStatus`, `CompletedTool`, `AIStreamContent`, `AIStreamExtension` for parsing `org.mellonchat.ai_stream` custom content |
| `ai_message_wrapper.dart` | Widget wrapper that detects bot messages and adds AI features (tool sections, streaming indicator) |
| `ai_streaming_indicator.dart` | Animated indicator showing "Thinking..." or tool execution status with pulsing/rotating icons |
| `collapsible_tool_output.dart` | Expandable tool output sections with copy button, monospace output, muted gray styling |
| `claude_stream_parser.dart` | Parses real Claude Code CLI JSONL streaming format for replay |
| `ai_stream_simulator.dart` | Standalone demo page (`/#/ai-demo`) with 4 scenarios + real capture replay |

### Phase 2: Markdown Rendering with gpt_markdown (COMPLETE)

**Dependency:** `gpt_markdown: ^1.1.5` in `pubspec.yaml`

**Integration:** Bot messages use `GptMarkdown(event.body)` instead of `HtmlMessage`. This renders:
- Tables (progressive rendering as rows stream in)
- Bold, italic, inline code
- Code blocks with language labels and "Copy code" button
- Numbered/bulleted lists
- Blockquotes
- Headers (H1-H6)

Regular user messages still use the original `HtmlMessage` widget.

### Matrix Streaming Protocol (COMPLETE)

**Custom content type:** `org.mellonchat.ai_stream` (MSC1767 extensible events)

**How streaming works:**
1. Bot sends initial message with `org.mellonchat.ai_stream` metadata
2. Bot repeatedly **edits** the message (Matrix `m.replace` relation) with updated text and metadata
3. Mellon Chat detects edits via `getDisplayEvent(timeline)` and re-renders
4. Each edit updates: `status` (streaming/tool/complete), `currentTool`, `completedTools[]`, and the message body text

**Metadata format (inside `m.new_content`):**
```json
{
  "org.mellonchat.ai_stream": {
    "status": "streaming|tool|complete",
    "currentTool": { "name": "Bash", "args": "flutter test", "progress": 0.5 },
    "completedTools": [
      { "name": "Read", "args": "/path/to/file", "output": "..." }
    ]
  }
}
```

**Key detail:** Messages must include `format: "org.matrix.custom.html"` and `formatted_body` for markdown to render (bold via `<b>` tags, etc.).

### Testing Infrastructure (COMPLETE)

| File | Purpose |
|------|---------|
| `test_driver/integration_test.dart` | Screenshot-enabled driver, saves to `screenshots/` |
| `integration_test/ai_demo_test.dart` | E2E test for AI demo page - runs all scenarios, takes 14 screenshots |
| `scripts/matrix_stream_simulator.sh` | Bash script to send streaming bot messages via Matrix API (3 scenarios: simple, tools, multi) |

**E2E test command:**
```bash
cd /Users/xavier/mellon-chat
PATH="/Users/xavier/bin:$PATH" fvm flutter drive \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/ai_demo_test.dart \
  -d chrome
```

**Matrix simulator command:**
```bash
cd /Users/xavier/mellon-chat
./scripts/matrix_stream_simulator.sh [simple|tools|multi]
```

### Real Claude Code Capture (COMPLETE)

**File:** `assets/replay/claude_streaming_capture.jsonl` (61KB, 169 lines)

Captured from a real Claude Code CLI session. Contains actual streaming JSON events: `system/init`, `stream_event/message_start`, `content_block_start`, `content_block_delta` (text tokens), `assistant` (snapshots), `user` (tool results), `result` (completion).

The `AIStreamSimulator` can replay this capture in the demo page (select "Real Capture" tab).

---

### Phase 2.5: Streaming Text Animation (COMPLETE)

**New file:** `lib/ai_stream/streaming_gpt_markdown.dart`

- `StreamingGptMarkdown` widget wraps `GptMarkdown` with character-by-character reveal
- 12ms per character animation speed (configurable via `msPerChar`)
- Blinking block cursor (`▌`) at the end while streaming
- Large deltas (>200 chars) render instantly to avoid animation lag
- Cursor and animation stop when `isStreaming` becomes false

**Integration:** Bot messages use `StreamingGptMarkdown` instead of plain `GptMarkdown` in `message_content.dart`.

---

## What's NOT Done Yet

### OpenClaw Server-Side Integration (NEXT - Option B)

The OpenClaw bot framework needs to emit AI stream metadata via Matrix messages. Plan uses **Option B: global event bus subscription**.

**Approach:** Uses the `onAgentEvent` callback in `GetReplyOptions` to capture tool start/end events alongside text streaming. Builds `org.mellonchat.ai_stream` metadata and includes it in every Matrix message edit.

**OpenClaw files created:**
- `extensions/matrix/src/matrix/ai-stream-types.ts` — `AiStreamMeta`, `AiStreamTool` types, `AI_STREAM_KEY` constant

**OpenClaw files modified:**
- `extensions/matrix/src/matrix/send/formatting.ts` — `buildTextContent()` accepts optional `aiStream` param
- `extensions/matrix/src/matrix/send.ts` — `sendMessageMatrix()` passes `aiStream` to `buildTextContent()`
- `extensions/matrix/src/matrix/actions/messages.ts` — `editMatrixMessage()` includes `aiStream` in both top-level and `m.new_content`
- `extensions/matrix/src/matrix/edit-stream.ts` — `update()` accepts `aiStream`, passes through to send/edit
- `extensions/matrix/src/matrix/monitor/handler.ts` — Tracks tool state via `onAgentEvent`, builds `AiStreamMeta`, sends with every edit

**How the handler works:**
1. Tool starts (`phase: "start"`) → sets `status: "tool"`, includes `tool_name`/`tool_meta` in metadata
2. Tool completes (`phase: "result"`) → adds to `completed_tools` array, sets `status: "streaming"`
3. Streaming finishes → sets `status: "complete"`, sends final edit
4. Every Matrix edit includes `org.mellonchat.ai_stream` metadata alongside the message body

**Status:** Code complete, build succeeds. Needs gateway restart to test live.

### Phase 3a: TodoWrite Rendering (COMPLETE)

**How it works:**
1. OpenClaw's `onAgentEvent` callback now includes `args` in tool start events
2. Handler detects `TodoWrite` tool by name, extracts `args.todos` array
3. Todo items are included in `org.mellonchat.ai_stream` metadata as `todos` field
4. Every Matrix edit carries the current todo state alongside tool/streaming metadata
5. Mellon Chat's `AIMessageWrapper` renders todos as a compact checklist via `AiTodoList` widget

**OpenClaw files modified:**
- `src/agents/pi-embedded-subscribe.handlers.tools.ts` — `onAgentEvent` callback now passes `args` in start phase
- `extensions/matrix/src/matrix/ai-stream-types.ts` — Added `AiStreamTodoItem` type and `todos` field to `AiStreamMeta`
- `extensions/matrix/src/matrix/monitor/handler.ts` — Captures TodoWrite args, tracks `currentTodos`, includes in metadata

**Mellon Chat files created/modified:**
- `lib/ai_stream/ai_stream_model.dart` — Added `AiTodoItem` class, `todos` field to `AIStreamContent` with JSON parsing
- NEW `lib/ai_stream/ai_todo_list.dart` — `AiTodoList` widget: compact checklist with status icons (green check for completed, blue dot for in-progress, gray circle for pending), strikethrough text for completed items, counter header
- `lib/ai_stream/ai_message_wrapper.dart` — Renders `AiTodoList` below completed tools, above message text
- `lib/ai_stream/ai_stream.dart` — Exported `ai_todo_list.dart`

**Todo metadata format (in `org.mellonchat.ai_stream`):**
```json
{
  "status": "streaming",
  "todos": [
    {"content": "Create theme provider", "status": "completed"},
    {"content": "Update navigation colors", "status": "in_progress"},
    {"content": "Add persistence", "status": "pending"}
  ]
}
```

**Simulator:** `./scripts/matrix_stream_simulator.sh todo` — 5-phase scenario showing progressive todo completion

**Remaining (future):**
| Feature | Status |
|---------|--------|
| AskUserQuestion rendering | Not started — needs interactive UI |
| Permission requests | Not started — needs bidirectional Matrix communication |

**Files to create:**
- NEW `lib/ai_stream/ai_question_buttons.dart` — AskUserQuestion button/chip row
- NEW `lib/ai_stream/ai_permission_request.dart` — Allow/Deny button pair

**Implementation order:**
1. ~~Tool events → Matrix metadata (edit stream enrichment)~~ DONE
2. ~~Todo list rendering~~ DONE
3. AskUserQuestion rendering (clickable choices in chat)
4. Permission requests (approve/deny buttons)

### Stop Button
The streaming indicator has an optional stop button UI, but the backend for `org.mellonchat.stop_stream` events isn't implemented yet.

### New Messages Per Tool Turn
Currently all streaming goes into a single message via edits. Claude's API has natural breaks between tool calls - after a tool result, Claude starts a new message. We could send each "turn" as a separate Matrix message rather than editing the same one. This would give a cleaner chat history.

---

## Key Architecture Decisions

1. **Fork FluffyChat** (not build from scratch) - speed to market, pull upstream updates via `upstream` remote
2. **`gpt_markdown` for rendering** (not custom renderer) - progressive table rendering, code blocks with copy, actively maintained (275 likes on pub.dev)
3. **Message edits for streaming** (not custom events) - compatible with Matrix spec, other clients see final text
4. **Custom content type `org.mellonchat.ai_stream`** - extensible events (MSC1767), other clients just see `body` text
5. **One animated indicator at a time** - active tool replaces previous; completed tools become static collapsed sections
6. **Bot detection by user ID patterns** - simple, reliable, no server-side coordination needed

---

## Matrix Setup

- **Homeserver:** `localhost:6167` (conduwuit)
- **Jarvis bot user:** `@jarvisbot:localhost`
- **Jarvis token:** `7hDyuZ6OinkuDZQpvuY9afTVucSnuHB0`
- **Test user:** `@aitest:localhost` (password: `aitest123`)
- **Xavier test user:** `@xaviertest:localhost` (password: `testpass123`)
- **Xavier DM room:** `!W130EiWtnl0qYCdSGlEnKJLrdBDGGFTVcVNHVBEIW4U`
- **AI Test Room:** `!mIC5L4LazQVDvHt-slkLajaU8A7BIaf2pa_B9d_BGhI`

---

## Running Mellon Chat

```bash
cd /Users/xavier/mellon-chat
fvm flutter run -d chrome --web-port=9000
```

**AI demo page:** `http://localhost:9000/#/ai-demo`

**Important:** Flutter CanvasKit on web has NO DOM elements - Playwright can't click buttons directly. Use keyboard navigation (Tab+Enter), enable accessibility mode, or use Flutter integration tests for automated interaction.

---

## Documentation

- `docs/AI_STREAMING_PROTOCOL.md` - Full spec for the streaming protocol
- `docs/AI_STREAMING_PLAN.md` - Original implementation plan (4 phases)
- `docs/AI_STREAMING_STATUS.md` - This file (current status)
