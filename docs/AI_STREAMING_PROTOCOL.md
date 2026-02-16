# AI Streaming Protocol for Mellon Chat

## Overview

This document describes how to implement AI streaming with tool animations, stop buttons, and rich metadata display in Mellon Chat.

## Part 1: Matrix Custom Message Types (MSC1767)

Matrix supports **extensible events** through custom content blocks. We can add custom metadata to messages without breaking compatibility with other clients.

### Custom Content Block for AI Streaming

```json
{
  "type": "m.room.message",
  "content": {
    "msgtype": "m.text",
    "body": "I'll search for that file...\n\n⚡ Reading package.json...",

    "org.mellonchat.ai_stream": {
      "status": "streaming",      // "streaming" | "tool" | "complete" | "error"
      "tool_name": "Read",        // Current tool being executed
      "tool_args": {"path": "package.json"},
      "started_at": 1234567890,   // Unix timestamp
      "token_count": 150          // Tokens generated so far
    }
  }
}
```

### How Clients Interpret This

1. **Mellon Chat**: Sees `org.mellonchat.ai_stream` → Shows animated tool indicator, stop button
2. **Other clients**: Just see the plain `body` text → Works normally

## Part 2: Streaming Update Mechanism

### Option A: Message Edits (Recommended)

The bot sends an initial message, then **edits** it repeatedly as tokens arrive:

1. Bot sends: `{"body": "Let me", "org.mellonchat.ai_stream": {"status": "streaming"}}`
2. Bot edits: `{"body": "Let me check", "org.mellonchat.ai_stream": {"status": "streaming"}}`
3. Bot edits: `{"body": "Let me check...\n\n⚡ Reading file", "org.mellonchat.ai_stream": {"status": "tool", "tool_name": "Read"}}`
4. Bot final edit: `{"body": "The file contains...", "org.mellonchat.ai_stream": {"status": "complete"}}`

### Option B: Custom Event Type

Use a dedicated event type for streaming updates:

```json
{
  "type": "org.mellonchat.ai_chunk",
  "content": {
    "relates_to": {"event_id": "$initial_message_id"},
    "delta": "additional tokens",
    "tool_status": {"name": "Read", "progress": 50}
  }
}
```

## Part 3: Tool Display Lifecycle (When to Replace vs Show)

### The Scenarios

**Scenario 1: Single tool execution**
```
[Text] → [Tool executing] → [Text with result]
```
- Show text streaming
- When tool starts, show animated indicator
- When tool completes, hide indicator, show result inline

**Scenario 2: Multiple sequential tools**
```
[Text] → [Tool A] → [Text] → [Tool B] → [Text]
```
- **Tool A executes** → Show Tool A indicator
- **Tool A completes + text streams** → Hide indicator, show text
- **Tool B starts** → Show Tool B indicator (REPLACES any previous)
- **Tool B completes** → Hide indicator, show final text

**Key Rule: Only ONE active tool indicator at a time. Previous tools become static text.**

### The Data Model

```json
{
  "org.mellonchat.ai_stream": {
    "status": "streaming",
    "active_tool": {                    // NULL when not executing a tool
      "name": "Read",
      "args": {"path": "file.txt"},
      "started_at": 1234567890
    },
    "completed_tools": [                // History for reference, rendered as text
      {"name": "Bash", "output_preview": "npm install..."},
      {"name": "Read", "output_preview": "package.json contents"}
    ]
  }
}
```

### Rendering Rules

1. **`active_tool` is set** → Show animated tool indicator (spinning, pulsing)
2. **`active_tool` is null + status is streaming** → Show text cursor animation only
3. **`active_tool` is null + status is complete** → Static text, no animations
4. **`completed_tools`** → Render as collapsed sections in the message body

### Visual Example

```
┌─────────────────────────────────────────┐
│ I'll check those files for you.        │
│                                          │
│ ⚡ Reading package.json...  [⏳]        │ ← active_tool (animated)
│                                          │
│ ▼ Previous: Bash `npm install` ─────── │ ← completed_tools (collapsed)
└─────────────────────────────────────────┘
```

When Tool B replaces Tool A:
```
┌─────────────────────────────────────────┐
│ I'll check those files for you.        │
│                                          │
│ ▼ Bash `npm install` ───────────────── │ ← Tool A now in completed_tools
│                                          │
│ ⚡ Reading tsconfig.json... [⏳]        │ ← Tool B now active
└─────────────────────────────────────────┘
```

## Part 4: UI Components

### 4.1 Stop Button

Show when `status == "streaming"` or `status == "tool"`:

```dart
if (aiStream?.status == 'streaming' || aiStream?.status == 'tool') {
  return StopButton(
    onPressed: () => sendStopSignal(eventId),
  );
}
```

### 4.2 Tool Animation (Replacement, Not Stacking)

Only show the active tool, render completed tools as collapsed sections:

```dart
Widget buildToolSection(AiStreamMetadata meta) {
  return Column(
    children: [
      // Completed tools - collapsed, static
      for (var tool in meta.completedTools ?? [])
        CollapsibleToolResult(
          toolName: tool.name,
          outputPreview: tool.outputPreview,
          expanded: false,
        ),

      // Active tool - animated
      if (meta.activeTool != null)
        AnimatedToolIndicator(
          toolName: meta.activeTool!.name,
          toolArgs: meta.activeTool!.args,
          isAnimating: true,
        ),
    ],
  );
}
```

### 4.3 Collapsible Code Output

For tool results that should be scrollable:

```dart
if (isCodeBlock && content.length > 500) {
  return CollapsibleCodeBlock(
    code: content,
    maxHeight: 200,
    scrollable: true,
  );
}
```

## Part 5: Streaming Latency

### ChatGPT Comparison

Per [OpenAI docs](https://platform.openai.com/docs/guides/latency-optimization), streaming reduces perceived latency to under 1 second by showing tokens as they arrive.

### Recommended Settings

| Setting | Value | Reason |
|---------|-------|--------|
| UI throttle | 50ms | Smooth animation without excessive redraws |
| Tool transition | 200ms | Visible tool change without jarring |
| Stop button delay | 500ms | Don't show for quick completions |

80ms (OpenClaw's current setting) is fine, but 50ms would be smoother.

## Part 6: Implementation Order

### Phase 1: Bot Detection + Basic Streaming
1. Detect messages from bot users (by ID pattern or displayname)
2. Parse `org.mellonchat.ai_stream` metadata if present
3. Show "streaming" indicator when `status == "streaming"`

### Phase 2: Stop Button
1. Add stop button to streaming messages
2. Send stop signal via Matrix message or custom event
3. Bot receives signal and stops generation

### Phase 3: Tool Animation
1. Parse tool name and args from metadata
2. Animate tool transitions (fade/replace, not stack)
3. Show progress if available

### Phase 4: Rich Output
1. Collapsible code blocks with scrolling
2. Syntax highlighting
3. Markdown streaming with buffering

## Part 7: Bot-Side Changes (OpenClaw)

OpenClaw needs to:

1. **Add metadata to messages**:
```typescript
const content = {
  msgtype: 'm.text',
  body: currentText,
  'org.mellonchat.ai_stream': {
    status: 'streaming',
    tool_name: currentTool?.name,
    tool_args: currentTool?.args,
  }
};
```

2. **Edit message as tokens arrive** (instead of sending new messages)

3. **Listen for stop signals**:
```typescript
client.on('Room.timeline', (event) => {
  if (event.getContent()['org.mellonchat.stop_stream']?.target === streamEventId) {
    abortController.abort();
  }
});
```

## Sources

- [Matrix Extensible Events (MSC1767)](https://github.com/matrix-org/matrix-spec-proposals/blob/main/proposals/1767-extensible-events.md)
- [OpenAI Latency Optimization](https://platform.openai.com/docs/guides/latency-optimization)
- [Matrix Specification](https://spec.matrix.org/latest/)
