import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:gpt_markdown/gpt_markdown.dart';

import 'ai_stream_model.dart';
import 'claude_stream_parser.dart';

/// Simulates AI streaming for testing the UI without a real server.
///
/// Usage:
/// ```dart
/// final simulator = AIStreamSimulator();
/// simulator.onUpdate = (content) {
///   setState(() => currentContent = content);
/// };
/// simulator.startSimulation();
/// ```
class AIStreamSimulator {
  /// Callback when the AI stream content updates
  VoidCallback? onUpdate;

  /// The current simulated AI stream content
  AIStreamContent? currentContent;

  /// Whether simulation is currently running
  bool isRunning = false;

  Timer? _timer;
  String _accumulatedText = '';
  final Random _random = Random();

  /// Predefined simulation scenarios
  static const List<SimulationScenario> scenarios = [
    SimulationScenario.codeSearch,
    SimulationScenario.fileEdit,
    SimulationScenario.webSearch,
    SimulationScenario.multiTool,
  ];

  /// Start a simulation with a specific scenario
  void startSimulation([SimulationScenario scenario = SimulationScenario.codeSearch]) {
    stop();
    isRunning = true;
    _accumulatedText = '';

    _runScenario(scenario);
  }

  /// Stop the current simulation
  void stop() {
    _timer?.cancel();
    _timer = null;
    isRunning = false;
  }

  void _runScenario(SimulationScenario scenario) {
    final steps = _getScenarioSteps(scenario);
    _executeStep(steps, 0);
  }

  void _executeStep(List<SimulationStep> steps, int index) {
    if (index >= steps.length || !isRunning) {
      isRunning = false;
      return;
    }

    final step = steps[index];

    switch (step.type) {
      case StepType.tool:
        _simulateTool(step, () => _executeStep(steps, index + 1));
        break;
      case StepType.streaming:
        _simulateStreaming(step, () => _executeStep(steps, index + 1));
        break;
      case StepType.complete:
        _simulateComplete(step);
        break;
    }
  }

  void _simulateTool(SimulationStep step, VoidCallback onComplete) {
    // Show tool starting
    currentContent = AIStreamContent(
      status: AIStreamStatus.tool,
      toolName: step.toolName,
      toolArgs: step.toolArgs,
      progress: 0,
      completedTools: List.from(currentContent?.completedTools ?? []),
    );
    onUpdate?.call();

    // Simulate progress
    var progressStep = 0;
    _timer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      progressStep++;
      final progressPercent = (progressStep * 5).clamp(0, 100); // 2 seconds total (20 steps * 5%)

      if (progressPercent >= 100) {
        timer.cancel();

        // Move to completed tools
        final completedTools = List<CompletedTool>.from(currentContent?.completedTools ?? []);
        completedTools.add(CompletedTool(
          name: step.toolName!,
          args: step.toolArgs,
          output: step.toolOutput ?? 'Command completed successfully.',
          collapsed: true,
        ));

        currentContent = AIStreamContent(
          status: AIStreamStatus.complete,
          completedTools: completedTools,
        );
        onUpdate?.call();

        // Small delay before next step
        Future.delayed(const Duration(milliseconds: 300), onComplete);
      } else {
        currentContent = AIStreamContent(
          status: AIStreamStatus.tool,
          toolName: step.toolName,
          toolArgs: step.toolArgs,
          progress: progressPercent,
          completedTools: currentContent?.completedTools ?? [],
        );
        onUpdate?.call();
      }
    });
  }

  void _simulateStreaming(SimulationStep step, VoidCallback onComplete) {
    final text = step.text!;
    final words = text.split(' ');
    var wordIndex = 0;

    currentContent = AIStreamContent(
      status: AIStreamStatus.streaming,
      completedTools: currentContent?.completedTools ?? [],
    );
    _accumulatedText = '';
    onUpdate?.call();

    _timer = Timer.periodic(Duration(milliseconds: 50 + _random.nextInt(100)), (timer) {
      if (wordIndex >= words.length) {
        timer.cancel();

        currentContent = AIStreamContent(
          status: AIStreamStatus.complete,
          completedTools: currentContent?.completedTools ?? [],
        );
        onUpdate?.call();

        Future.delayed(const Duration(milliseconds: 200), onComplete);
        return;
      }

      _accumulatedText += (wordIndex > 0 ? ' ' : '') + words[wordIndex];
      wordIndex++;

      currentContent = AIStreamContent(
        status: AIStreamStatus.streaming,
        completedTools: currentContent?.completedTools ?? [],
      );
      onUpdate?.call();
    });
  }

  void _simulateComplete(SimulationStep step) {
    currentContent = AIStreamContent(
      status: AIStreamStatus.complete,
      completedTools: currentContent?.completedTools ?? [],
    );
    onUpdate?.call();
    isRunning = false;
  }

  List<SimulationStep> _getScenarioSteps(SimulationScenario scenario) {
    switch (scenario) {
      case SimulationScenario.codeSearch:
        return [
          SimulationStep.tool('Grep', {'pattern': 'TODO', 'path': 'lib/'},
            'lib/main.dart:42: // TODO: Add error handling\nlib/utils.dart:15: // TODO: Optimize this'),
          SimulationStep.streaming('Found 2 TODO comments in your codebase. The first one in main.dart needs error handling, and the second in utils.dart mentions optimization.'),
          SimulationStep.complete(),
        ];

      case SimulationScenario.fileEdit:
        return [
          SimulationStep.tool('Read', {'path': '/lib/example.dart'},
            'class Example {\n  void hello() {\n    print("Hello!");\n  }\n}'),
          SimulationStep.streaming('I can see the Example class. Let me add a new method for you.'),
          SimulationStep.tool('Edit', {'path': '/lib/example.dart', 'changes': 'Added goodbye() method'},
            'File updated successfully.'),
          SimulationStep.streaming('Done! I added a `goodbye()` method to the Example class.'),
          SimulationStep.complete(),
        ];

      case SimulationScenario.webSearch:
        return [
          SimulationStep.streaming('Let me search for the latest Flutter documentation on that topic.'),
          SimulationStep.tool('WebSearch', {'query': 'Flutter StreamBuilder best practices 2026'},
            '1. flutter.dev - StreamBuilder class documentation\n2. medium.com - 10 Tips for StreamBuilder\n3. stackoverflow.com - Common StreamBuilder mistakes'),
          SimulationStep.streaming('Based on my search, here are the best practices for using StreamBuilder in Flutter:\n\n1. **Always provide an initial value** using the `initialData` parameter\n2. **Handle all connection states** including waiting, active, and done\n3. **Dispose streams properly** to avoid memory leaks'),
          SimulationStep.complete(),
        ];

      case SimulationScenario.multiTool:
        return [
          SimulationStep.streaming("I'll help you set up the project. Let me check a few things first."),
          SimulationStep.tool('Bash', {'command': 'flutter --version'},
            'Flutter 3.32.0 • channel stable'),
          SimulationStep.tool('Read', {'path': 'pubspec.yaml'},
            'name: my_app\nversion: 1.0.0\ndependencies:\n  flutter:\n    sdk: flutter'),
          SimulationStep.tool('Bash', {'command': 'flutter pub get'},
            'Resolving dependencies...\nGot dependencies!'),
          SimulationStep.streaming('Great! Your project is set up correctly. You have Flutter 3.32.0 installed and all dependencies are resolved.'),
          SimulationStep.complete(),
        ];
    }
  }

  /// Get the current accumulated text (for streaming scenarios)
  String get streamingText => _accumulatedText;

  /// Start simulation from a captured Claude Code streaming JSONL file
  Future<void> startFromCapture(String assetPath) async {
    stop();
    isRunning = true;
    _accumulatedText = '';

    try {
      final jsonlContent = await rootBundle.loadString(assetPath);
      final events = ClaudeStreamParser.parseJsonl(jsonlContent);
      final steps = ClaudeStreamParser.eventsToSimulationSteps(events);
      _runCapturedSteps(steps);
    } catch (e) {
      debugPrint('Error loading capture: $e');
      isRunning = false;
    }
  }

  /// Run simulation steps from captured data
  void _runCapturedSteps(List<SimulationStepData> steps) {
    _executeCapturedStep(steps, 0);
  }

  void _executeCapturedStep(List<SimulationStepData> steps, int index) {
    if (index >= steps.length || !isRunning) {
      isRunning = false;
      return;
    }

    final step = steps[index];

    switch (step.type) {
      case 'tool':
        _simulateCapturedTool(step, () => _executeCapturedStep(steps, index + 1));
        break;
      case 'streaming':
        _simulateCapturedStreaming(step, () => _executeCapturedStep(steps, index + 1));
        break;
      case 'complete':
        _simulateComplete(SimulationStep.complete());
        break;
      default:
        _executeCapturedStep(steps, index + 1);
    }
  }

  void _simulateCapturedTool(SimulationStepData step, VoidCallback onComplete) {
    // Show tool starting
    currentContent = AIStreamContent(
      status: AIStreamStatus.tool,
      toolName: step.toolName,
      toolArgs: step.toolArgs,
      progress: 0,
      completedTools: List.from(currentContent?.completedTools ?? []),
    );
    onUpdate?.call();

    // Simulate progress (1 second total)
    var progressStep = 0;
    _timer = Timer.periodic(const Duration(milliseconds: 50), (timer) {
      progressStep++;
      final progressPercent = (progressStep * 5).clamp(0, 100);

      if (progressPercent >= 100) {
        timer.cancel();

        // Move to completed tools
        final completedTools = List<CompletedTool>.from(currentContent?.completedTools ?? []);
        completedTools.add(CompletedTool(
          name: step.toolName ?? 'Unknown',
          args: step.toolArgs,
          output: step.toolOutput ?? 'Completed',
          collapsed: true,
        ));

        currentContent = AIStreamContent(
          status: AIStreamStatus.complete,
          completedTools: completedTools,
        );
        onUpdate?.call();

        // Small delay before next step
        Future.delayed(const Duration(milliseconds: 200), onComplete);
      } else {
        currentContent = AIStreamContent(
          status: AIStreamStatus.tool,
          toolName: step.toolName,
          toolArgs: step.toolArgs,
          progress: progressPercent,
          completedTools: currentContent?.completedTools ?? [],
        );
        onUpdate?.call();
      }
    });
  }

  void _simulateCapturedStreaming(SimulationStepData step, VoidCallback onComplete) {
    final text = step.text ?? '';

    // Simulate token-by-token streaming
    // Split into small chunks (roughly word-sized with some variation)
    final tokens = _tokenize(text);
    var tokenIndex = 0;

    currentContent = AIStreamContent(
      status: AIStreamStatus.streaming,
      completedTools: currentContent?.completedTools ?? [],
    );
    onUpdate?.call();

    _timer = Timer.periodic(Duration(milliseconds: 30 + _random.nextInt(50)), (timer) {
      if (tokenIndex >= tokens.length) {
        timer.cancel();

        currentContent = AIStreamContent(
          status: AIStreamStatus.complete,
          completedTools: currentContent?.completedTools ?? [],
        );
        onUpdate?.call();

        Future.delayed(const Duration(milliseconds: 100), onComplete);
        return;
      }

      _accumulatedText += tokens[tokenIndex];
      tokenIndex++;

      currentContent = AIStreamContent(
        status: AIStreamStatus.streaming,
        completedTools: currentContent?.completedTools ?? [],
      );
      onUpdate?.call();
    });
  }

  /// Tokenize text into small chunks for realistic streaming
  List<String> _tokenize(String text) {
    final tokens = <String>[];
    final words = text.split(RegExp(r'(?<=\s)|(?=\s)'));

    for (final word in words) {
      // Sometimes split longer words
      if (word.length > 8 && _random.nextBool()) {
        final mid = word.length ~/ 2;
        tokens.add(word.substring(0, mid));
        tokens.add(word.substring(mid));
      } else {
        tokens.add(word);
      }
    }

    return tokens;
  }
}

/// Types of simulation steps
enum StepType { tool, streaming, complete }

/// A single step in a simulation scenario
class SimulationStep {
  final StepType type;
  final String? toolName;
  final Map<String, dynamic>? toolArgs;
  final String? toolOutput;
  final String? text;

  const SimulationStep._({
    required this.type,
    this.toolName,
    this.toolArgs,
    this.toolOutput,
    this.text,
  });

  factory SimulationStep.tool(String name, Map<String, dynamic> args, String output) {
    return SimulationStep._(
      type: StepType.tool,
      toolName: name,
      toolArgs: args,
      toolOutput: output,
    );
  }

  factory SimulationStep.streaming(String text) {
    return SimulationStep._(
      type: StepType.streaming,
      text: text,
    );
  }

  factory SimulationStep.complete() {
    return const SimulationStep._(type: StepType.complete);
  }
}

/// Predefined simulation scenarios
enum SimulationScenario {
  /// Searches for code patterns and explains results
  codeSearch,

  /// Reads a file, explains it, edits it
  fileEdit,

  /// Searches the web and summarizes findings
  webSearch,

  /// Uses multiple tools in sequence
  multiTool,
}

/// A widget that demonstrates AI streaming with a simulation
class AIStreamSimulatorDemo extends StatefulWidget {
  const AIStreamSimulatorDemo({super.key});

  @override
  State<AIStreamSimulatorDemo> createState() => _AIStreamSimulatorDemoState();
}

class _AIStreamSimulatorDemoState extends State<AIStreamSimulatorDemo> {
  final AIStreamSimulator _simulator = AIStreamSimulator();
  SimulationScenario _selectedScenario = SimulationScenario.codeSearch;
  bool _useCapture = false;

  @override
  void initState() {
    super.initState();
    _simulator.onUpdate = () => setState(() {});
  }

  @override
  void dispose() {
    _simulator.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI Streaming Simulator'),
        actions: [
          IconButton(
            key: const Key('ai_demo_play_stop'),
            icon: Icon(_simulator.isRunning ? Icons.stop : Icons.play_arrow),
            onPressed: () {
              if (_simulator.isRunning) {
                _simulator.stop();
                setState(() {});
              } else if (_useCapture) {
                _simulator.startFromCapture('assets/replay/claude_streaming_capture.jsonl');
              } else {
                _simulator.startSimulation(_selectedScenario);
              }
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // Source selector (capture vs scenario)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                ChoiceChip(
                  key: const Key('ai_demo_scenarios_chip'),
                  label: const Text('Scenarios'),
                  selected: !_useCapture,
                  onSelected: _simulator.isRunning ? null : (selected) {
                    if (selected) setState(() => _useCapture = false);
                  },
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  key: const Key('ai_demo_capture_chip'),
                  label: const Text('Real Capture'),
                  selected: _useCapture,
                  onSelected: _simulator.isRunning ? null : (selected) {
                    if (selected) setState(() => _useCapture = true);
                  },
                ),
              ],
            ),
          ),
          // Scenario selector (only shown when not using capture)
          if (!_useCapture)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: DropdownButton<SimulationScenario>(
                value: _selectedScenario,
                isExpanded: true,
                items: SimulationScenario.values.map((scenario) {
                  return DropdownMenuItem(
                    value: scenario,
                    child: Text(_scenarioLabel(scenario)),
                  );
                }).toList(),
                onChanged: _simulator.isRunning ? null : (scenario) {
                  setState(() => _selectedScenario = scenario!);
                },
              ),
            ),
          if (_useCapture)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Replays captured Claude Code CLI streaming output',
                style: TextStyle(color: Colors.grey.shade600, fontStyle: FontStyle.italic),
              ),
            ),

          // Simulated message display
          Expanded(
            child: Container(
              key: const Key('ai_demo_content'),
              margin: const EdgeInsets.all(16),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.green.shade50,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Bot name with indicator
                  Row(
                    children: [
                      const Text(
                        'SimBot',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Colors.green,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        Icons.bolt,
                        size: 16,
                        color: Colors.amber.shade700,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),

                  // Content based on current state
                  Expanded(
                    child: SingleChildScrollView(
                      child: _buildContent(),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    final content = _simulator.currentContent;
    if (content == null) {
      return const Text(
        'Press play to start simulation',
        style: TextStyle(color: Colors.grey),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Completed tools
        ...(content.completedTools ?? []).map((tool) => _buildCompletedTool(tool)),

        // Streaming text (rendered with GptMarkdown for rich formatting)
        if (_simulator.streamingText.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: GptMarkdown(_simulator.streamingText),
          ),

        // Status indicator
        if (content.status == AIStreamStatus.streaming)
          _buildStreamingIndicator(),
        if (content.status == AIStreamStatus.tool)
          _buildToolIndicator(content),
      ],
    );
  }

  Widget _buildCompletedTool(CompletedTool tool) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: ExpansionTile(
        leading: Icon(_getToolIcon(tool.name), size: 20),
        title: Text(
          '${tool.name} ${_formatToolArgs(tool.args)}',
          style: const TextStyle(fontSize: 14),
        ),
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                tool.output ?? '',
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStreamingIndicator() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.blue.shade50,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation(Colors.blue.shade400),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            'Thinking...',
            style: TextStyle(color: Colors.blue.shade700),
          ),
        ],
      ),
    );
  }

  Widget _buildToolIndicator(AIStreamContent content) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.amber.shade50,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.bolt, size: 16, color: Colors.amber.shade700),
          const SizedBox(width: 8),
          Text(
            '${content.toolName} ${_formatToolArgs(content.toolArgs)}',
            style: TextStyle(color: Colors.amber.shade900),
          ),
          if (content.progress != null) ...[
            const SizedBox(width: 12),
            SizedBox(
              width: 60,
              child: LinearProgressIndicator(
                value: (content.progress ?? 0) / 100.0,
                backgroundColor: Colors.amber.shade100,
                valueColor: AlwaysStoppedAnimation(Colors.amber.shade600),
              ),
            ),
          ],
        ],
      ),
    );
  }

  IconData _getToolIcon(String toolName) {
    switch (toolName.toLowerCase()) {
      case 'read':
        return Icons.description;
      case 'edit':
      case 'write':
        return Icons.edit;
      case 'bash':
        return Icons.terminal;
      case 'grep':
        return Icons.search;
      case 'websearch':
        return Icons.language;
      default:
        return Icons.build;
    }
  }

  String _formatToolArgs(Map<String, dynamic>? args) {
    if (args == null || args.isEmpty) return '';

    if (args.containsKey('path')) {
      return '`${args['path']}`';
    }
    if (args.containsKey('command')) {
      return '`${args['command']}`';
    }
    if (args.containsKey('pattern')) {
      return '`${args['pattern']}`';
    }
    if (args.containsKey('query')) {
      return '"${args['query']}"';
    }
    return '';
  }

  String _scenarioLabel(SimulationScenario scenario) {
    switch (scenario) {
      case SimulationScenario.codeSearch:
        return 'Code Search (Grep + explanation)';
      case SimulationScenario.fileEdit:
        return 'File Edit (Read + Edit)';
      case SimulationScenario.webSearch:
        return 'Web Search (Search + summary)';
      case SimulationScenario.multiTool:
        return 'Multi-Tool (Bash + Read + Bash)';
    }
  }
}
