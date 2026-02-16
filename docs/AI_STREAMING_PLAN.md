# AI Streaming Markdown Feature - Implementation Plan

## Overview

Add ChatGPT-style streaming markdown rendering for AI bot messages in Mellon Chat.

## Key Goals

1. **Bot Detection** — Identify messages from AI bots
2. **Streaming Markdown** — Render markdown progressively as tokens arrive
3. **Clean Display** — Hide raw markdown syntax, show formatted output
4. **Metadata Support** — Custom rendering for commands/structured data

---

## Architecture

### Message Flow

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   Matrix    │────▶│  Message    │────▶│   Widget    │
│   Event     │     │  Content    │     │  Renderer   │
└─────────────┘     └─────────────┘     └─────────────┘
                           │
                           ▼
                    ┌─────────────┐
                    │ Bot Check?  │
                    └─────────────┘
                        │     │
                   Yes ─┘     └─ No
                    ▼            ▼
             ┌────────────┐  ┌────────────┐
             │ Streaming  │  │   Static   │
             │  Markdown  │  │    HTML    │
             └────────────┘  └────────────┘
```

### Key Files to Modify

| File | Purpose | Changes |
|------|---------|---------|
| `lib/pages/chat/events/message_content.dart` | Message type dispatcher | Add bot detection, route to streaming widget |
| `lib/pages/chat/events/html_message.dart` | HTML/text rendering | Reference for markdown patterns |
| **NEW** `lib/pages/chat/events/streaming_markdown.dart` | Streaming markdown widget | New widget for AI messages |
| **NEW** `lib/utils/bot_detection.dart` | Bot identification | Utility for detecting AI bots |

---

## Phase 1: Bot Detection

### Approach

Detect bots via:
1. **User ID pattern** — `@*bot*:*`, `@*-ai:*`, `@*_ai:*`
2. **Display name** — Contains "bot", "AI", "assistant"
3. **Custom state event** — `m.bot` or `im.vector.bot` (future)
4. **Room-level config** — Mark specific users as bots

### Implementation

Create `lib/utils/bot_detection.dart`:

```dart
class BotDetection {
  static final _botPatterns = [
    RegExp(r'bot', caseSensitive: false),
    RegExp(r'[-_]ai$', caseSensitive: false),
    RegExp(r'^ai[-_]', caseSensitive: false),
    RegExp(r'assistant', caseSensitive: false),
  ];

  static bool isBot(User user) {
    final userId = user.id;
    final displayName = user.displayName ?? '';

    // Check user ID
    for (final pattern in _botPatterns) {
      if (pattern.hasMatch(userId)) return true;
    }

    // Check display name
    for (final pattern in _botPatterns) {
      if (pattern.hasMatch(displayName)) return true;
    }

    return false;
  }

  static bool isEventFromBot(Event event) {
    return isBot(event.senderFromMemoryOrFallback);
  }
}
```

### Integration Point

In `message_content.dart`, around line 237 (text message case):

```dart
case MessageTypes.Text:
case MessageTypes.Notice:
  // Check if this is from a bot
  if (BotDetection.isEventFromBot(event)) {
    return StreamingMarkdownMessage(
      event: event,
      textColor: textColor,
      linkColor: linkColor,
      fontSize: fontSize,
    );
  }
  // Existing HTML rendering for non-bot messages
  ...
```

---

## Phase 2: Basic Markdown Rendering

### Approach

Use a markdown library that supports progressive rendering.

### Libraries to Consider

1. **flutter_markdown** — Standard, but doesn't support streaming
2. **markdown** (dart package) — Parse-only, need custom renderer
3. **Custom solution** — Build our own for best control

### Recommended: Custom Streaming Renderer

Create `lib/pages/chat/events/streaming_markdown.dart`:

```dart
class StreamingMarkdownMessage extends StatefulWidget {
  final Event event;
  final Color textColor;
  final Color linkColor;
  final double fontSize;

  // ... constructor
}

class _StreamingMarkdownMessageState extends State<StreamingMarkdownMessage> {
  // Listen to message edits (Matrix uses edits for streaming)
  StreamSubscription? _subscription;
  String _currentContent = '';

  @override
  void initState() {
    super.initState();
    _currentContent = widget.event.body;
    _subscribeToEdits();
  }

  void _subscribeToEdits() {
    // Matrix streaming typically works via message edits
    // Subscribe to the room's edit events for this message
    _subscription = widget.event.room.onUpdate.stream.listen((_) {
      final latestEdit = widget.event.getDisplayEvent(widget.event.room.timeline);
      if (latestEdit.body != _currentContent) {
        setState(() {
          _currentContent = latestEdit.body;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return MarkdownBody(
      content: _currentContent,
      textColor: widget.textColor,
      fontSize: widget.fontSize,
    );
  }
}
```

### Markdown Elements to Support

Priority order:
1. **Text** — Plain text passthrough
2. **Bold/Italic** — `**bold**`, `*italic*`
3. **Code** — `` `inline` ``, ``` ```blocks``` ```
4. **Headers** — `# H1` through `###### H6`
5. **Lists** — `- item`, `1. item`
6. **Links** — `[text](url)`
7. **Blockquotes** — `> quote`
8. **Tables** — Later phase

---

## Phase 3: Streaming Support

### How Matrix Streaming Works

Matrix doesn't have native streaming. Bots typically:
1. Send initial message
2. Edit the message repeatedly as tokens arrive
3. Stop editing when complete

### Detecting "Still Streaming"

Options:
1. **Debounce edits** — If no edit for 2s, consider complete
2. **Marker text** — Bot appends `▌` while streaming, removes when done
3. **Custom field** — `content.streaming: true` in message

### Smooth Animation

```dart
class AnimatedMarkdownText extends StatefulWidget {
  final String markdown;
  // ...
}

class _AnimatedMarkdownTextState extends State<AnimatedMarkdownText> {
  String _displayedText = '';
  Timer? _timer;

  @override
  void didUpdateWidget(oldWidget) {
    if (widget.markdown != oldWidget.markdown) {
      _animateToNewText();
    }
  }

  void _animateToNewText() {
    // Append new characters smoothly
    final newChars = widget.markdown.substring(_displayedText.length);
    var index = 0;
    _timer?.cancel();
    _timer = Timer.periodic(Duration(milliseconds: 10), (timer) {
      if (index >= newChars.length) {
        timer.cancel();
        return;
      }
      setState(() {
        _displayedText += newChars[index];
      });
      index++;
    });
  }
}
```

### Buffering Incomplete Markdown

Key challenge: Don't render `**` until we have the closing `**`.

```dart
class MarkdownBuffer {
  final String input;

  String get safeToRender {
    // Find incomplete patterns
    final lastBold = input.lastIndexOf('**');
    final boldCount = '**'.allMatches(input).length;

    // If odd number of **, don't render the last one
    if (boldCount % 2 == 1) {
      return input.substring(0, lastBold);
    }

    // Similar for other patterns...
    return input;
  }

  String get pending {
    return input.substring(safeToRender.length);
  }
}
```

---

## Phase 4: Polish

### Visual Indicators

1. **Typing indicator** — Show pulse/dots while streaming
2. **Cursor** — Blinking `▌` at end of streaming text
3. **Completion** — Subtle animation when done

### Error Handling

1. **Timeout** — After 60s of no edits, consider complete
2. **Parse errors** — Fall back to plain text
3. **Large messages** — Virtualize rendering for >10KB

### Settings

Add to preferences:
- Enable/disable AI markdown rendering
- Animation speed
- Bot detection patterns (advanced)

---

## Testing

### Unit Tests

1. Bot detection patterns
2. Markdown buffering logic
3. Edit event handling

### Integration Tests

1. Message from bot renders with streaming widget
2. Message from human renders with standard HTML
3. Streaming updates animate smoothly
4. Incomplete markdown doesn't break rendering

### Manual Testing

1. Test with actual AI bot (OpenClaw, ChatGPT bridge)
2. Test with long messages (>4KB)
3. Test rapid edits (simulated fast streaming)
4. Test network interruption mid-stream

---

## Timeline

| Phase | Effort | Description |
|-------|--------|-------------|
| Phase 1 | 2-4 hours | Bot detection |
| Phase 2 | 4-8 hours | Basic markdown rendering |
| Phase 3 | 8-16 hours | Streaming support |
| Phase 4 | 4-8 hours | Polish and edge cases |

**Total: 2-4 days**

---

## Dependencies

### New Packages (optional)

```yaml
dependencies:
  # If using existing markdown library:
  flutter_markdown: ^0.6.x  # or markdown: ^7.x
```

### No Dependencies Needed If

We build a custom renderer using only Flutter's `Text.rich()` and `TextSpan`, similar to how `HtmlMessage` already works.

**Recommendation:** Start with custom renderer for full control, consider library later if needed.

---

## Next Steps

1. [ ] Create `lib/utils/bot_detection.dart`
2. [ ] Add bot check in `message_content.dart`
3. [ ] Create `lib/pages/chat/events/streaming_markdown.dart`
4. [ ] Test with a real AI bot
5. [ ] Iterate on UX
