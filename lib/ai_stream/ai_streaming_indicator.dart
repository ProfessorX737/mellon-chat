import 'package:flutter/material.dart';

import 'package:fluffychat/config/app_config.dart';
import 'package:fluffychat/widgets/typing_dots.dart';

import 'ai_stream_model.dart';

/// Animated indicator showing current AI streaming/tool execution status
class AIStreamingIndicator extends StatelessWidget {
  final AIStreamContent aiStream;

  const AIStreamingIndicator({super.key, required this.aiStream});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Don't show if complete
    if (!aiStream.isStreaming) {
      return const SizedBox.shrink();
    }

    final mutedColor = theme.colorScheme.onSurface.withValues(alpha: 0.5);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Material(
            color: theme.colorScheme.surfaceContainerHigh,
            borderRadius: const BorderRadius.all(
              Radius.circular(AppConfig.borderRadius),
            ),
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: TypingDots(),
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              _getStatusText(aiStream),
              style: theme.textTheme.bodySmall?.copyWith(color: mutedColor),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  String _getStatusText(AIStreamContent aiStream) {
    if (aiStream.isExecutingTool) {
      return aiStream.currentToolActiveDescription ?? 'Executing...';
    }

    // Streaming text
    final progress = aiStream.progress;
    if (progress != null) {
      return 'Thinking... ($progress%)';
    }

    return 'Thinking...';
  }
}
