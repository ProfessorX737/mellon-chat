/// AI Stream model classes for Mellon Chat
///
/// This implements the custom Matrix content block `org.mellonchat.ai_stream`
/// for bot messages with streaming support.
library;


/// Global set of user IDs known to be bots, populated at runtime.
/// Once a user sends a message with org.mellonchat.ai_stream data,
/// they are remembered as a bot for the rest of the session.
final Set<String> _knownBotUserIds = {};

/// Register a user ID as a known bot (call when evidence is found).
void registerKnownBot(String userId) => _knownBotUserIds.add(userId);

/// Check if a user ID is a known bot.
bool isKnownBot(String userId) => _knownBotUserIds.contains(userId);

/// Common bot name patterns used for heuristic detection.
const List<String> botPatterns = [
  'bot',
  '-ai',
  '_ai',
  'assistant',
  'jarvis',
  'alfred',
  'tars',
  'agent',
  'claude',
  'gpt',
  'llm',
  'openai',
  'gemini',
  'mistral',
  'openclaw',
];

/// Status of an AI stream
enum AIStreamStatus {
  streaming,
  tool,
  complete;

  static AIStreamStatus? fromString(String? value) {
    if (value == null) return null;
    switch (value) {
      case 'streaming':
        return AIStreamStatus.streaming;
      case 'tool':
        return AIStreamStatus.tool;
      case 'complete':
        return AIStreamStatus.complete;
      default:
        return null;
    }
  }

  String toJson() => name;
}

/// A tool execution entry. Can be "running" (currently executing),
/// "completed", or "error".
class CompletedTool {
  /// Tool name (e.g., "Read", "Bash", "Grep")
  final String name;

  /// Execution status: "running", "completed", or "error"
  final String status;

  /// Tool arguments as a map
  final Map<String, dynamic>? args;

  /// Tool output/result
  final String? output;

  /// Whether to show as collapsed by default
  final bool collapsed;

  /// Max height for scrollable output
  final int? maxHeight;

  /// Character offset in the cleaned message text where this tool was invoked.
  /// Used by the client to interleave tool blocks with assistant text.
  final int? textPosition;

  CompletedTool({
    required this.name,
    this.status = 'completed',
    this.args,
    this.output,
    this.collapsed = true,
    this.maxHeight,
    this.textPosition,
  });

  /// Whether this tool is currently executing
  bool get isRunning => status == 'running';

  /// Whether this tool completed with an error
  bool get isError => status == 'error';

  factory CompletedTool.fromJson(Map<String, dynamic> json) {
    return CompletedTool(
      name: json['name'] as String,
      status: json['status'] as String? ?? 'completed',
      args: json['args'] as Map<String, dynamic>?,
      output: json['output'] as String?,
      collapsed: json['collapsed'] as bool? ?? true,
      maxHeight: json['max_height'] as int?,
      textPosition: json['textPosition'] as int?,
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'status': status,
        if (args != null) 'args': args,
        if (output != null) 'output': output,
        'collapsed': collapsed,
        if (maxHeight != null) 'max_height': maxHeight,
        if (textPosition != null) 'textPosition': textPosition,
      };

  /// Get a short description of the tool for display (past tense / completed).
  /// Truncation is generous — the UI's TextOverflow.ellipsis handles visual clipping.
  String get shortDescription {
    if (args == null) return name;

    switch (name.toLowerCase()) {
      case 'read':
        return 'Read ${_fileName(args!['path'] ?? args!['file_path'])}';
      case 'bash':
      case 'shell':
        final desc = args!['description'] ?? '';
        if (desc.toString().isNotEmpty) {
          return _truncate(desc.toString(), 200);
        }
        final cmd = args!['command'] ?? '';
        return 'Ran ${_truncate(cmd.toString(), 200)}';
      case 'grep':
        return 'Searched "${_truncate(args!['pattern']?.toString() ?? '', 120)}"';
      case 'glob':
        return 'Found "${_truncate((args!['glob_pattern'] ?? args!['pattern'] ?? '').toString(), 120)}"';
      case 'edit':
      case 'strreplace':
        return 'Edited ${_fileName(args!['path'] ?? args!['file_path'])}';
      case 'write':
        return 'Wrote ${_fileName(args!['path'] ?? args!['file_path'])}';
      case 'websearch':
        return 'Searched "${_truncate((args!['search_term'] ?? args!['query'] ?? '').toString(), 120)}"';
      case 'webfetch':
        return 'Fetched ${_truncate((args!['url'] ?? 'URL').toString(), 120)}';
      case 'task':
        final desc = args!['description'] ?? args!['prompt'] ?? '';
        return desc.toString().isNotEmpty
            ? _truncate(desc.toString(), 200)
            : 'Task';
      case 'todowrite':
        return 'Updated tasks';
      case 'semanticsearch':
        return 'Searched codebase';
      case 'readlints':
        return 'Checked lints';
      default:
        return name;
    }
  }

  /// Get an active description (present tense) for when the tool is running.
  /// Truncation is generous — the UI's TextOverflow.ellipsis handles visual clipping.
  String get activeDescription {
    if (args == null) return '$name...';

    switch (name.toLowerCase()) {
      case 'read':
        return 'Reading ${_fileName(args!['path'] ?? args!['file_path'])}';
      case 'bash':
      case 'shell':
        final desc = args!['description'] ?? '';
        if (desc.toString().isNotEmpty) {
          return _truncate(desc.toString(), 200);
        }
        final cmd = args!['command'] ?? '';
        return 'Running ${_truncate(cmd.toString(), 200)}';
      case 'grep':
        return 'Searching "${_truncate(args!['pattern']?.toString() ?? '', 120)}"';
      case 'glob':
        return 'Finding "${_truncate((args!['glob_pattern'] ?? args!['pattern'] ?? '').toString(), 120)}"';
      case 'edit':
      case 'strreplace':
        return 'Editing ${_fileName(args!['path'] ?? args!['file_path'])}';
      case 'write':
        return 'Writing ${_fileName(args!['path'] ?? args!['file_path'])}';
      case 'websearch':
        return 'Searching "${_truncate((args!['search_term'] ?? args!['query'] ?? '').toString(), 120)}"';
      case 'webfetch':
        return 'Fetching ${_truncate((args!['url'] ?? 'URL').toString(), 120)}';
      case 'task':
        final desc = args!['description'] ?? args!['prompt'] ?? '';
        return desc.toString().isNotEmpty
            ? _truncate(desc.toString(), 200)
            : 'Running task...';
      case 'todowrite':
        return 'Updating tasks...';
      case 'semanticsearch':
        return 'Searching codebase...';
      case 'readlints':
        return 'Checking lints...';
      default:
        return '$name...';
    }
  }

  /// Extract just the filename from a path.
  static String _fileName(dynamic path) {
    if (path == null) return 'file';
    final str = path.toString();
    final segments = str.split('/');
    return segments.last.isNotEmpty ? segments.last : str;
  }

  /// Truncate a string to [maxLen] characters with ellipsis.
  static String _truncate(String s, int maxLen) {
    if (s.length <= maxLen) return s;
    return '${s.substring(0, maxLen)}...';
  }
}

/// A single todo item from a TodoWrite tool call
class AiTodoItem {
  final String content;
  final String status; // "pending", "in_progress", "completed"

  AiTodoItem({required this.content, required this.status});

  factory AiTodoItem.fromJson(Map<String, dynamic> json) {
    return AiTodoItem(
      content: json['content'] as String? ?? '',
      status: json['status'] as String? ?? 'pending',
    );
  }

  bool get isCompleted => status == 'completed';
  bool get isInProgress => status == 'in_progress';
  bool get isPending => status == 'pending';
}

/// AI Stream content block from Matrix message
class AIStreamContent {
  /// Current status
  final AIStreamStatus status;

  /// Current tool being executed (if status == tool)
  final String? toolName;

  /// Current tool arguments
  final Map<String, dynamic>? toolArgs;

  /// Progress percentage (0-100)
  final int? progress;

  /// Estimated time remaining in seconds
  final int? etaSeconds;

  /// List of completed tools
  final List<CompletedTool>? completedTools;

  /// Current todo list (from TodoWrite tool calls)
  final List<AiTodoItem>? todos;

  /// Current model selection (provider + model), included on every bot message
  final ({String provider, String model})? model;

  AIStreamContent({
    required this.status,
    this.toolName,
    this.toolArgs,
    this.progress,
    this.etaSeconds,
    this.completedTools,
    this.todos,
    this.model,
  });

  factory AIStreamContent.fromJson(Map<String, dynamic> json) {
    final statusStr = json['status'] as String?;
    final status = AIStreamStatus.fromString(statusStr) ?? AIStreamStatus.complete;

    final completedToolsJson = json['completed_tools'] as List<dynamic>?;
    final completedTools = completedToolsJson
        ?.map((e) => CompletedTool.fromJson(e as Map<String, dynamic>))
        .toList();

    final todosJson = json['todos'] as List<dynamic>?;
    final todos = todosJson
        ?.map((e) => AiTodoItem.fromJson(e as Map<String, dynamic>))
        .toList();

    // Defensive fix: when the message is complete, force all "running"
    // tools to "completed". This handles cases where the final edit
    // (that would have marked them completed) failed to reach the client.
    final resolvedTools = (status == AIStreamStatus.complete && completedTools != null)
        ? completedTools.map((t) => t.isRunning
            ? CompletedTool(
                name: t.name,
                status: 'completed',
                args: t.args,
                output: t.output,
                collapsed: t.collapsed,
                maxHeight: t.maxHeight,
                textPosition: t.textPosition,
              )
            : t).toList()
        : completedTools;

    // Parse model selection if present
    final modelJson = json['model'] as Map<String, dynamic>?;
    final model = (modelJson != null &&
            modelJson['provider'] is String &&
            modelJson['model'] is String)
        ? (
            provider: modelJson['provider'] as String,
            model: modelJson['model'] as String,
          )
        : null;

    return AIStreamContent(
      status: status,
      toolName: json['tool_name'] as String?,
      toolArgs: json['tool_args'] as Map<String, dynamic>?,
      progress: json['progress'] as int?,
      etaSeconds: json['eta_seconds'] as int?,
      completedTools: resolvedTools,
      todos: todos,
      model: model,
    );
  }

  Map<String, dynamic> toJson() => {
        'status': status.toJson(),
        if (toolName != null) 'tool_name': toolName,
        if (toolArgs != null) 'tool_args': toolArgs,
        if (progress != null) 'progress': progress,
        if (etaSeconds != null) 'eta_seconds': etaSeconds,
        if (completedTools != null)
          'completed_tools': completedTools!.map((e) => e.toJson()).toList(),
        if (todos != null)
          'todos': todos!.map((e) => {'content': e.content, 'status': e.status}).toList(),
      };

  /// Whether currently executing a tool
  bool get isExecutingTool => status == AIStreamStatus.tool && toolName != null;

  /// Whether still streaming (not complete)
  bool get isStreaming =>
      status == AIStreamStatus.streaming || status == AIStreamStatus.tool;

  /// Get short description for current tool (completed form)
  String? get currentToolDescription {
    if (toolName == null) return null;
    return CompletedTool(name: toolName!, args: toolArgs).shortDescription;
  }

  /// Get active description for the currently executing tool (present tense)
  String? get currentToolActiveDescription {
    if (toolName == null) return null;
    return CompletedTool(name: toolName!, args: toolArgs).activeDescription;
  }
}

/// Extension to extract AI stream content from Matrix message content
extension AIStreamExtension on Map<String, dynamic> {
  /// Get AI stream content if present
  AIStreamContent? get aiStreamContent {
    final aiStream = this['org.mellonchat.ai_stream'];
    if (aiStream == null) return null;
    if (aiStream is! Map<String, dynamic>) return null;

    try {
      return AIStreamContent.fromJson(aiStream);
    } catch (e) {
      return null;
    }
  }

  /// Check if this message is from a bot, using multiple signals:
  /// 1. Message contains org.mellonchat.ai_stream data (definitive)
  /// 2. Sender is in the cached known-bots set (from prior detection)
  /// 3. Sender ID matches common bot name patterns (heuristic fallback)
  bool isBotMessage(String? senderId) {
    if (senderId == null) return false;

    // 1. Definitive: message has org.mellonchat.ai_stream metadata
    if (this['org.mellonchat.ai_stream'] != null) {
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
}
