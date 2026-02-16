import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

/// A widget that displays streaming markdown text.
///
/// Simply renders the current text via [GptMarkdown] — new characters
/// appear instantly as they arrive. No animation.
class StreamingGptMarkdown extends StatelessWidget {
  /// The full markdown text to display
  final String text;

  /// Whether the message is currently streaming (kept for API compat)
  final bool isStreaming;

  /// Text style for the markdown
  final TextStyle? style;

  const StreamingGptMarkdown({
    super.key,
    required this.text,
    this.isStreaming = false,
    this.style,
    // fadeDuration kept for call-site compat but ignored
    Duration fadeDuration = const Duration(milliseconds: 200),
  });

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) {
      return const SizedBox.shrink();
    }

    return GptMarkdown(
      text,
      style: style,
    );
  }
}
