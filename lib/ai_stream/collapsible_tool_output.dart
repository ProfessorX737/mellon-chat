import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'ai_stream_model.dart';

/// Returns the appropriate icon for a tool name.
IconData getToolIcon(String toolName) {
  switch (toolName.toLowerCase()) {
    case 'read':
      return Icons.description;
    case 'bash':
    case 'shell':
      return Icons.terminal;
    case 'grep':
      return Icons.search;
    case 'glob':
      return Icons.folder_open;
    case 'edit':
    case 'strreplace':
      return Icons.edit;
    case 'write':
      return Icons.save;
    case 'websearch':
      return Icons.public;
    case 'webfetch':
      return Icons.download;
    case 'task':
      return Icons.account_tree;
    default:
      return Icons.build;
  }
}

/// Collapsible widget for displaying completed tool outputs
class CollapsibleToolOutput extends StatefulWidget {
  final CompletedTool tool;
  final bool initiallyExpanded;

  const CollapsibleToolOutput({
    super.key,
    required this.tool,
    this.initiallyExpanded = false,
  });

  @override
  State<CollapsibleToolOutput> createState() => _CollapsibleToolOutputState();
}

class _CollapsibleToolOutputState extends State<CollapsibleToolOutput>
    with SingleTickerProviderStateMixin {
  late bool _isExpanded;

  @override
  void initState() {
    super.initState();
    // Always start collapsed — user explicitly expands if they want output
    _isExpanded = false;
  }

  bool get _hasOutput =>
      widget.tool.output != null && widget.tool.output!.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final mutedColor = colorScheme.onSurface.withValues(alpha: 0.45);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header row — minimal, no box, clickable only on text area
          GestureDetector(
            onTap: _hasOutput ? () => setState(() => _isExpanded = !_isExpanded) : null,
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Row(
                children: [
                  Icon(
                    getToolIcon(widget.tool.name),
                    size: 14,
                    color: mutedColor,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      widget.tool.shortDescription,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                        color: mutedColor,
                        fontSize: 12,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  // Chevron directly next to text, only when there's output
                  if (_hasOutput)
                    Padding(
                      padding: const EdgeInsets.only(left: 2),
                      child: Icon(
                        _isExpanded ? Icons.expand_less : Icons.expand_more,
                        size: 16,
                        color: mutedColor,
                      ),
                    ),
                ],
              ),
            ),
          ),
          // Expandable output (only if there's content)
          if (_hasOutput)
            AnimatedCrossFade(
              duration: const Duration(milliseconds: 200),
              crossFadeState: _isExpanded
                  ? CrossFadeState.showSecond
                  : CrossFadeState.showFirst,
              firstChild: const SizedBox.shrink(),
              secondChild: _buildContent(theme, colorScheme),
            ),
        ],
      ),
    );
  }

  Widget _buildContent(ThemeData theme, ColorScheme colorScheme) {
    final output = widget.tool.output!;
    final maxHeight = widget.tool.maxHeight?.toDouble() ?? 200.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(left: 32, right: 12, top: 2, bottom: 4),
            child: SelectableText(
              output,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                color: colorScheme.onSurface.withValues(alpha: 0.7),
                fontSize: 11,
              ),
            ),
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.only(right: 8, bottom: 2),
            child: IconButton(
              icon: const Icon(Icons.copy, size: 14),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: output));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Copied to clipboard'),
                    duration: Duration(seconds: 1),
                  ),
                );
              },
              tooltip: 'Copy output',
              visualDensity: VisualDensity.compact,
              style: IconButton.styleFrom(
                foregroundColor: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Widget for the currently executing (pending) tool.
///
/// Collapsed by default — just shows a spinner + active description.
class PendingToolIndicator extends StatelessWidget {
  final String toolName;
  final Map<String, dynamic>? toolArgs;

  const PendingToolIndicator({
    super.key,
    required this.toolName,
    this.toolArgs,
  });

  String get _activeDescription {
    return CompletedTool(name: toolName, args: toolArgs)
        .activeDescription;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accentColor = theme.colorScheme.primary.withValues(alpha: 0.7);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: accentColor,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              _activeDescription,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                color: accentColor,
                fontWeight: FontWeight.w500,
                fontSize: 12,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// A group of consecutive identical tool calls (e.g. "Read x5")
class _ToolGroup {
  final CompletedTool tool;
  final int count;
  const _ToolGroup(this.tool, this.count);
}

/// Widget that renders a list of completed tools.
/// Groups consecutive tools with the same name (e.g. "Read x12")
/// to avoid overwhelming the UI when agents make many tool calls.
///
/// When [isStreaming] is true, newly appearing tools are briefly shown
/// as "running" (with a spinner and expanded state) before transitioning
/// to completed. This compensates for the Matrix sync protocol coalescing
/// rapid edits, which causes tools to jump from non-existent to completed
/// without ever showing the intermediate "running" state.
class CompletedToolsList extends StatefulWidget {
  final List<CompletedTool> tools;

  /// Whether the parent message is currently streaming.
  /// When true, new tools get an introduction animation.
  final bool isStreaming;

  const CompletedToolsList({
    super.key,
    required this.tools,
    this.isStreaming = false,
  });

  @override
  State<CompletedToolsList> createState() => _CompletedToolsListState();
}

class _CompletedToolsListState extends State<CompletedToolsList> {
  /// Number of tools that have been "introduced" (shown as running, then
  /// transitioned to completed). Tools at index < _introducedCount are
  /// rendered normally; tools at index >= _introducedCount are shown as
  /// PendingToolIndicator briefly before being introduced.
  int _introducedCount = 0;

  /// Timer for the current introduction animation.
  Timer? _introTimer;

  @override
  void initState() {
    super.initState();
    if (widget.isStreaming) {
      // Message is actively streaming — animate tools: start at 0 so all
      // tools get the brief "running" introduction before flipping to completed.
      _introducedCount = 0;
      debugPrint('[tool-display] initState: streaming=true, tools=${widget.tools.length}, introducedCount=0 (will animate)');
      if (widget.tools.isNotEmpty) {
        _introTimer = Timer(const Duration(milliseconds: 1000), () {
          if (mounted) {
            setState(() {
              _introducedCount = widget.tools.length;
              debugPrint('[tool-display] intro timer fired: introducedCount=$_introducedCount');
            });
          }
        });
      }
    } else {
      // Message is NOT streaming (old/completed message, or navigated back) —
      // show all tools immediately as completed. No animation.
      _introducedCount = widget.tools.length;
      debugPrint('[tool-display] initState: streaming=false, tools=${widget.tools.length}, introducedCount=$_introducedCount (no animation)');
    }
  }

  @override
  void didUpdateWidget(CompletedToolsList oldWidget) {
    super.didUpdateWidget(oldWidget);

    final newToolCount = widget.tools.length;

    if (newToolCount > _introducedCount) {
      if (widget.isStreaming) {
        // Actively streaming — animate new tools with 1s "running" intro
        _introTimer?.cancel();
        _introTimer = Timer(const Duration(milliseconds: 1000), () {
          if (mounted) {
            setState(() {
              _introducedCount = widget.tools.length;
            });
          }
        });
      } else {
        // Not streaming — show new tools immediately, no animation
        _introducedCount = newToolCount;
      }
    }
  }

  @override
  void dispose() {
    _introTimer?.cancel();
    super.dispose();
  }

  /// Group consecutive tools with the same name.
  /// If a tool has output/args, is running, or is being "introduced", it stays as its own entry.
  List<_ToolGroup> _groupTools(List<CompletedTool> effectiveTools) {
    if (effectiveTools.isEmpty) return [];
    final groups = <_ToolGroup>[];
    int i = 0;
    while (i < effectiveTools.length) {
      final tool = effectiveTools[i];
      // Never group running tools — they need their own indicator
      if (tool.isRunning) {
        groups.add(_ToolGroup(tool, 1));
        i++;
        continue;
      }
      // Only group completed tools that have no output (collapsed with no detail)
      if (tool.output == null || tool.output!.isEmpty) {
        int count = 1;
        while (i + count < effectiveTools.length &&
            !effectiveTools[i + count].isRunning &&
            effectiveTools[i + count].name == tool.name &&
            (effectiveTools[i + count].output == null ||
                effectiveTools[i + count].output!.isEmpty)) {
          count++;
        }
        groups.add(_ToolGroup(tool, count));
        i += count;
      } else {
        groups.add(_ToolGroup(tool, 1));
        i++;
      }
    }
    return groups;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.tools.isEmpty) return const SizedBox.shrink();

    // Build effective tools list: tools beyond _introducedCount are
    // shown as "running" (pending introduction animation).
    final effectiveTools = <CompletedTool>[];
    for (int i = 0; i < widget.tools.length; i++) {
      final tool = widget.tools[i];
      if (i >= _introducedCount && !tool.isRunning) {
        // This tool appeared recently — show as running briefly
        effectiveTools.add(CompletedTool(
          name: tool.name,
          status: 'running', // Override to running for animation
          args: tool.args,
          output: tool.output,
          collapsed: false,
          maxHeight: tool.maxHeight,
          textPosition: tool.textPosition,
        ));
      } else {
        effectiveTools.add(tool);
      }
    }

    final groups = _groupTools(effectiveTools);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: groups.map((group) {
          // Running tool (real or introducing) → show pending indicator
          if (group.tool.isRunning) {
            return PendingToolIndicator(
              toolName: group.tool.name,
              toolArgs: group.tool.args,
            );
          }
          if (group.count > 1) {
            return _GroupedToolHeader(
              toolName: group.tool.name,
              count: group.count,
            );
          }
          return CollapsibleToolOutput(tool: group.tool);
        }).toList(),
    );
  }
}

/// Compact header for a group of identical tool calls (no expand)
class _GroupedToolHeader extends StatelessWidget {
  final String toolName;
  final int count;

  const _GroupedToolHeader({
    required this.toolName,
    required this.count,
  });

  @override
  Widget build(BuildContext context) {
    final mutedColor = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.45);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 1),
      child: Row(
        children: [
          Icon(
            getToolIcon(toolName),
            size: 14,
            color: mutedColor,
          ),
          const SizedBox(width: 6),
          Text(
            '$toolName x$count',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  color: mutedColor,
                  fontSize: 12,
                ),
          ),
        ],
      ),
    );
  }
}
