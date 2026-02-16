import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import 'ai_stream_model.dart';
import 'ai_todo_list.dart';
import 'collapsible_tool_output.dart';
import 'streaming_gpt_markdown.dart';

/// Wrapper that adds AI streaming features to bot messages.
///
/// When tools have [textPosition] data, renders an interleaved layout:
///   [text chunk] → [tool block] → [text chunk] → [tool block] → ...
///
/// Otherwise falls back to the legacy layout:
///   [all tools] → [todos] → [text]
class AIMessageWrapper extends StatelessWidget {
  final Event event;
  final Widget child;

  /// Text style for rendering split markdown chunks (needed for interleaving).
  /// If null, interleaving is disabled and the legacy layout is used.
  final TextStyle? textStyle;

  /// Whether the message is currently streaming (for the last text chunk).
  final bool isStreaming;

  const AIMessageWrapper({
    super.key,
    required this.event,
    required this.child,
    this.textStyle,
    this.isStreaming = false,
  });

  @override
  Widget build(BuildContext context) {
    final content = event.content;
    final senderId = event.senderId;
    final aiStream = content.aiStreamContent;
    final isBot = content.isBotMessage(senderId);

    if (!isBot && aiStream == null) {
      return child;
    }

    final tools = aiStream?.completedTools ?? [];
    final hasPositions = tools.any((t) => t.textPosition != null);

    // Use interleaved layout when we have position data and can render text
    if (hasPositions && textStyle != null && tools.isNotEmpty) {
      return _buildInterleaved(context, aiStream!, tools);
    }

    // Legacy layout: tools at top, todos, then text.
    // Running tools show as PendingToolIndicator within CompletedToolsList.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (tools.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: CompletedToolsList(tools: tools, isStreaming: isStreaming),
          ),
        if (aiStream?.todos != null && aiStream!.todos!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: AiTodoList(todos: aiStream.todos!),
          ),
        child,
      ],
    );
  }

  /// Build an interleaved layout: text chunks with tool blocks inserted
  /// at their invocation positions.
  Widget _buildInterleaved(
    BuildContext context,
    AIStreamContent aiStream,
    List<CompletedTool> tools,
  ) {
    final text = event.body;
    final style = textStyle!;

    // Sort tools by textPosition (nulls go to the end)
    final sorted = [...tools]
      ..sort((a, b) =>
          (a.textPosition ?? text.length).compareTo(b.textPosition ?? text.length));

    // Group tools that share the same position
    final groups = <int, List<CompletedTool>>{};
    for (final tool in sorted) {
      final pos = tool.textPosition ?? text.length;
      groups.putIfAbsent(pos, () => []).add(tool);
    }

    // Build interleaved widgets
    final positions = groups.keys.toList()..sort();
    final widgets = <Widget>[];
    int lastPos = 0;

    for (final pos in positions) {
      final clampedPos = pos.clamp(0, text.length);

      // Add text chunk before this tool group
      if (clampedPos > lastPos) {
        final chunk = text.substring(lastPos, clampedPos).trimRight();
        if (chunk.isNotEmpty) {
          widgets.add(
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: StreamingGptMarkdown(
                text: chunk,
                isStreaming: false, // Earlier chunks are complete
                style: style,
              ),
            ),
          );
        }
      }

      // Add tool block
      widgets.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 4, top: 4),
          child: CompletedToolsList(tools: groups[pos]!, isStreaming: isStreaming),
        ),
      );

      lastPos = clampedPos;
    }

    // Add remaining text after the last tool
    if (lastPos < text.length) {
      final remaining = text.substring(lastPos).trimLeft();
      if (remaining.isNotEmpty) {
        widgets.add(
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: StreamingGptMarkdown(
              text: remaining,
              isStreaming: isStreaming, // Only the last chunk can be streaming
              style: style,
            ),
          ),
        );
      }
    } else if (text.isEmpty || lastPos >= text.length) {
      // No remaining text — but if streaming, show empty streaming indicator
      if (isStreaming) {
        widgets.add(
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: StreamingGptMarkdown(
              text: '',
              isStreaming: true,
              style: style,
            ),
          ),
        );
      }
    }

    // Todos at the end (they represent overall task status)
    if (aiStream.todos != null && aiStream.todos!.isNotEmpty) {
      widgets.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: AiTodoList(todos: aiStream.todos!),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: widgets,
    );
  }
}

/// Extension to check if an event is from a known bot
extension BotEventExtension on Event {
  /// Check if this event is from a bot, using multiple signals:
  /// 1. Message contains org.mellonchat.ai_stream data (definitive)
  /// 2. Sender is in the cached known-bots set (from prior ai_stream detection)
  /// 3. Sender ID matches common bot name patterns (heuristic fallback)
  bool get isFromBot {
    // 1. Definitive: message has org.mellonchat.ai_stream metadata
    if (content['org.mellonchat.ai_stream'] != null) {
      registerKnownBot(senderId);
      return true;
    }

    // 2. Cached: we've previously seen ai_stream data from this sender
    if (isKnownBot(senderId)) {
      return true;
    }

    // 3. Heuristic: sender ID matches common bot name patterns
    final lowerSenderId = senderId.toLowerCase();
    for (final pattern in botPatterns) {
      if (lowerSenderId.contains(pattern)) {
        registerKnownBot(senderId);
        return true;
      }
    }

    return false;
  }

  /// Get AI stream content if present
  AIStreamContent? get aiStreamContent => content.aiStreamContent;

  /// Check if currently streaming.
  /// Considers message age — if the message is older than 30 seconds and
  /// still says "streaming", treat it as stale/complete. This prevents
  /// old messages from animating on refresh when the final "complete"
  /// edit was never received (e.g., due to encryption or sync issues).
  bool get isStreaming {
    final aiStream = aiStreamContent;
    if (aiStream == null || !aiStream.isStreaming) return false;

    // Check message age — stale messages aren't really streaming
    final age = DateTime.now().difference(originServerTs);
    if (age.inSeconds > 30) return false;

    return true;
  }
}
