import 'dart:convert';

/// Parses Claude Code CLI streaming JSON output.
///
/// The streaming format includes event types:
/// - `system/init`: Session initialization
/// - `stream_event/content_block_start`: Start of text or tool_use block
/// - `stream_event/content_block_delta`: Incremental text deltas
/// - `stream_event/content_block_stop`: End of content block
/// - `assistant`: Full message snapshot with content
/// - `user`: Tool result message
/// - `result`: Final completion with full response
class ClaudeStreamParser {
  /// Parse a JSONL file content into a list of replay events
  static List<ReplayEvent> parseJsonl(String jsonlContent) {
    final lines = jsonlContent.split('\n').where((l) => l.trim().isNotEmpty);
    final events = <ReplayEvent>[];
    var accumulatedText = '';
    String? currentToolName;
    Map<String, dynamic>? currentToolArgs;
    String? currentToolId;

    for (final line in lines) {
      try {
        final json = jsonDecode(line) as Map<String, dynamic>;
        final type = json['type'] as String?;

        if (type == 'stream_event') {
          final event = json['event'] as Map<String, dynamic>?;
          if (event == null) continue;

          final eventType = event['type'] as String?;

          // Text streaming delta
          if (eventType == 'content_block_delta') {
            final delta = event['delta'] as Map<String, dynamic>?;
            if (delta != null && delta['type'] == 'text_delta') {
              final text = delta['text'] as String? ?? '';
              accumulatedText += text;
              events.add(ReplayEvent(
                type: ReplayEventType.textDelta,
                text: text,
                accumulatedText: accumulatedText,
              ));
            }
            // Tool input streaming
            else if (delta != null && delta['type'] == 'input_json_delta') {
              // Tool arguments being streamed - we'll get the full args in assistant message
            }
          }

          // Content block start
          else if (eventType == 'content_block_start') {
            final contentBlock = event['content_block'] as Map<String, dynamic>?;
            if (contentBlock != null && contentBlock['type'] == 'tool_use') {
              currentToolName = contentBlock['name'] as String?;
              currentToolId = contentBlock['id'] as String?;
              currentToolArgs = {};
              events.add(ReplayEvent(
                type: ReplayEventType.toolStart,
                toolName: currentToolName,
                toolId: currentToolId,
              ));
            }
          }

          // Message stop with tool_use
          else if (eventType == 'message_delta') {
            final delta = event['delta'] as Map<String, dynamic>?;
            if (delta != null && delta['stop_reason'] == 'tool_use') {
              // Tool execution about to happen
            }
          }
        }

        // Full assistant message - extract complete tool info
        else if (type == 'assistant') {
          final message = json['message'] as Map<String, dynamic>?;
          if (message != null) {
            final content = message['content'] as List?;
            if (content != null) {
              for (final block in content) {
                if (block is Map<String, dynamic>) {
                  if (block['type'] == 'tool_use') {
                    final toolName = block['name'] as String?;
                    final toolId = block['id'] as String?;
                    final input = block['input'] as Map<String, dynamic>?;
                    events.add(ReplayEvent(
                      type: ReplayEventType.toolExecuting,
                      toolName: toolName,
                      toolId: toolId,
                      toolArgs: input,
                    ));
                    currentToolName = toolName;
                    currentToolArgs = input;
                    currentToolId = toolId;
                  }
                }
              }
            }
          }
        }

        // Tool result from user message
        else if (type == 'user') {
          final message = json['message'] as Map<String, dynamic>?;
          final toolUseResult = json['tool_use_result'] as Map<String, dynamic>?;

          if (message != null) {
            final content = message['content'] as List?;
            if (content != null) {
              for (final block in content) {
                if (block is Map<String, dynamic> && block['type'] == 'tool_result') {
                  final toolId = block['tool_use_id'] as String?;
                  var output = block['content'] as String?;

                  // Also check tool_use_result for stdout
                  if (toolUseResult != null) {
                    output = toolUseResult['stdout'] as String? ?? output;
                  }

                  events.add(ReplayEvent(
                    type: ReplayEventType.toolComplete,
                    toolId: toolId,
                    toolName: currentToolName,
                    toolArgs: currentToolArgs,
                    toolOutput: output,
                  ));
                }
              }
            }
          }
        }

        // Final result
        else if (type == 'result') {
          final result = json['result'] as String?;
          events.add(ReplayEvent(
            type: ReplayEventType.complete,
            text: result,
            accumulatedText: accumulatedText,
          ));
        }
      } catch (e) {
        // Skip malformed lines
        continue;
      }
    }

    return events;
  }

  /// Create simulation steps from replay events for use with AIStreamSimulator
  static List<SimulationStepData> eventsToSimulationSteps(List<ReplayEvent> events) {
    final steps = <SimulationStepData>[];
    final textBuffer = StringBuffer();
    CompletedToolData? pendingTool;

    for (final event in events) {
      switch (event.type) {
        case ReplayEventType.textDelta:
          textBuffer.write(event.text ?? '');
          break;

        case ReplayEventType.toolStart:
          // Flush any accumulated text first
          if (textBuffer.isNotEmpty) {
            steps.add(SimulationStepData.streaming(textBuffer.toString()));
            textBuffer.clear();
          }
          pendingTool = CompletedToolData(
            name: event.toolName ?? 'Unknown',
            args: event.toolArgs ?? {},
          );
          break;

        case ReplayEventType.toolExecuting:
          // Update pending tool with full args
          if (pendingTool != null) {
            pendingTool = CompletedToolData(
              name: event.toolName ?? pendingTool.name,
              args: event.toolArgs ?? pendingTool.args,
            );
          } else {
            // Flush any accumulated text first
            if (textBuffer.isNotEmpty) {
              steps.add(SimulationStepData.streaming(textBuffer.toString()));
              textBuffer.clear();
            }
            pendingTool = CompletedToolData(
              name: event.toolName ?? 'Unknown',
              args: event.toolArgs ?? {},
            );
          }
          break;

        case ReplayEventType.toolComplete:
          if (pendingTool != null) {
            steps.add(SimulationStepData.tool(
              pendingTool.name,
              pendingTool.args,
              event.toolOutput ?? 'Completed',
            ));
            pendingTool = null;
          }
          break;

        case ReplayEventType.complete:
          // Flush remaining text
          if (textBuffer.isNotEmpty) {
            steps.add(SimulationStepData.streaming(textBuffer.toString()));
            textBuffer.clear();
          }
          steps.add(SimulationStepData.complete());
          break;
      }
    }

    // Handle any remaining state
    if (textBuffer.isNotEmpty) {
      steps.add(SimulationStepData.streaming(textBuffer.toString()));
    }

    return steps;
  }
}

/// Types of replay events
enum ReplayEventType {
  textDelta,
  toolStart,
  toolExecuting,
  toolComplete,
  complete,
}

/// A parsed replay event
class ReplayEvent {
  final ReplayEventType type;
  final String? text;
  final String? accumulatedText;
  final String? toolName;
  final String? toolId;
  final Map<String, dynamic>? toolArgs;
  final String? toolOutput;

  ReplayEvent({
    required this.type,
    this.text,
    this.accumulatedText,
    this.toolName,
    this.toolId,
    this.toolArgs,
    this.toolOutput,
  });

  @override
  String toString() {
    return 'ReplayEvent($type, tool: $toolName, text: ${text?.substring(0, text!.length.clamp(0, 30))}...)';
  }
}

/// Data for a completed tool (used during parsing)
class CompletedToolData {
  final String name;
  final Map<String, dynamic> args;

  CompletedToolData({
    required this.name,
    required this.args,
  });
}

/// Simulation step data compatible with AIStreamSimulator
class SimulationStepData {
  final String type; // 'tool', 'streaming', 'complete'
  final String? toolName;
  final Map<String, dynamic>? toolArgs;
  final String? toolOutput;
  final String? text;

  const SimulationStepData._({
    required this.type,
    this.toolName,
    this.toolArgs,
    this.toolOutput,
    this.text,
  });

  factory SimulationStepData.tool(String name, Map<String, dynamic> args, String output) {
    return SimulationStepData._(
      type: 'tool',
      toolName: name,
      toolArgs: args,
      toolOutput: output,
    );
  }

  factory SimulationStepData.streaming(String text) {
    return SimulationStepData._(
      type: 'streaming',
      text: text,
    );
  }

  factory SimulationStepData.complete() {
    return const SimulationStepData._(type: 'complete');
  }
}
