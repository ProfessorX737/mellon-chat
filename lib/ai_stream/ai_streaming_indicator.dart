import 'package:flutter/material.dart';

import 'ai_stream_model.dart';

/// Animated indicator showing current AI streaming/tool execution status
class AIStreamingIndicator extends StatefulWidget {
  final AIStreamContent aiStream;
  final VoidCallback? onStop;

  const AIStreamingIndicator({
    super.key,
    required this.aiStream,
    this.onStop,
  });

  @override
  State<AIStreamingIndicator> createState() => _AIStreamingIndicatorState();
}

class _AIStreamingIndicatorState extends State<AIStreamingIndicator>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    // Don't show if complete
    if (!widget.aiStream.isStreaming) {
      return const SizedBox.shrink();
    }

    // Muted gray styling for streaming indicator (ChatGPT-style)
    final mutedColor = colorScheme.onSurface.withValues(alpha: 0.5);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Animated indicator - muted
          _buildAnimatedIcon(colorScheme, mutedColor),
          const SizedBox(width: 8),

          // Status text - muted gray, smaller
          Flexible(
            child: Text(
              _getStatusText(),
              style: theme.textTheme.bodySmall?.copyWith(
                color: mutedColor,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),

          // Stop button
          if (widget.onStop != null) ...[
            const SizedBox(width: 8),
            _buildStopButton(colorScheme),
          ],
        ],
      ),
    );
  }

  Widget _buildAnimatedIcon(ColorScheme colorScheme, Color mutedColor) {
    final isExecutingTool = widget.aiStream.isExecutingTool;

    return AnimatedBuilder(
      animation: _animationController,
      builder: (context, child) {
        return Transform.rotate(
          angle: isExecutingTool ? 0 : _animationController.value * 2 * 3.14159,
          child: Icon(
            isExecutingTool ? Icons.bolt : Icons.auto_awesome,
            color: mutedColor,
            size: 16,
          ),
        );
      },
    );
  }

  Widget _buildStopButton(ColorScheme colorScheme) {
    return InkWell(
      onTap: widget.onStop,
      borderRadius: BorderRadius.circular(4),
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Icon(
          Icons.stop,
          color: colorScheme.onErrorContainer,
          size: 16,
        ),
      ),
    );
  }

  String _getStatusText() {
    if (widget.aiStream.isExecutingTool) {
      return widget.aiStream.currentToolDescription ?? 'Executing...';
    }

    // Streaming text
    final progress = widget.aiStream.progress;
    if (progress != null) {
      return 'Thinking... ($progress%)';
    }

    return 'Thinking...';
  }
}
