import 'package:flutter/material.dart';

import 'ai_stream_model.dart';

/// Renders a list of AI todo items as a compact checklist.
///
/// Styled to match the ChatGPT-style muted look of tool outputs:
/// subtle background, small text, checkbox indicators.
class AiTodoList extends StatelessWidget {
  final List<AiTodoItem> todos;

  const AiTodoList({super.key, required this.todos});

  @override
  Widget build(BuildContext context) {
    if (todos.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final mutedColor = colorScheme.onSurface.withValues(alpha: 0.5);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 2),
      decoration: BoxDecoration(
        color: colorScheme.surface.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: colorScheme.outline.withValues(alpha: 0.1),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Icon(
                  Icons.checklist,
                  size: 16,
                  color: mutedColor,
                ),
                const SizedBox(width: 8),
                Text(
                  'Tasks',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: mutedColor,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const Spacer(),
                Text(
                  '${todos.where((t) => t.isCompleted).length}/${todos.length}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: mutedColor,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          Divider(
            height: 1,
            color: colorScheme.outline.withValues(alpha: 0.1),
          ),
          // Todo items
          ...todos.map((todo) => _AiTodoItemRow(todo: todo)),
        ],
      ),
    );
  }
}

class _AiTodoItemRow extends StatelessWidget {
  final AiTodoItem todo;

  const _AiTodoItemRow({required this.todo});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final IconData icon;
    final Color iconColor;
    final TextStyle? textStyle;

    if (todo.isCompleted) {
      icon = Icons.check_circle;
      iconColor = Colors.green.withValues(alpha: 0.7);
      textStyle = theme.textTheme.bodySmall?.copyWith(
        color: colorScheme.onSurface.withValues(alpha: 0.4),
        decoration: TextDecoration.lineThrough,
      );
    } else if (todo.isInProgress) {
      icon = Icons.radio_button_checked;
      iconColor = Colors.blue.withValues(alpha: 0.7);
      textStyle = theme.textTheme.bodySmall?.copyWith(
        color: colorScheme.onSurface.withValues(alpha: 0.8),
      );
    } else {
      icon = Icons.radio_button_unchecked;
      iconColor = colorScheme.onSurface.withValues(alpha: 0.3);
      textStyle = theme.textTheme.bodySmall?.copyWith(
        color: colorScheme.onSurface.withValues(alpha: 0.6),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, size: 16, color: iconColor),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              todo.content,
              style: textStyle,
            ),
          ),
        ],
      ),
    );
  }
}
