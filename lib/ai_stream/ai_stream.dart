/// AI Streaming module for Mellon Chat
///
/// This module provides AI-specific features for bot messages:
/// - Streaming indicator (animated "thinking..." status)
/// - Tool execution display (collapsible outputs)
/// - Bot detection (by user ID patterns)
///
/// Usage:
/// ```dart
/// import 'package:fluffychat/ai_stream/ai_stream.dart';
///
/// // Wrap message content with AI features
/// AIMessageWrapper(
///   event: event,
///   child: HtmlMessage(...),
///   onStop: () => sendStopSignal(event.eventId),
/// )
/// ```
///
/// ## Testing / Simulation
///
/// Use [AIStreamSimulator] to test the UI without a real server:
/// ```dart
/// final simulator = AIStreamSimulator();
/// simulator.onUpdate = () => setState(() {});
/// simulator.startSimulation(SimulationScenario.codeSearch);
/// ```
///
/// Or use [AIStreamSimulatorDemo] widget for a complete demo page.

library;

export 'ai_message_wrapper.dart';
export 'ai_stream_model.dart';
export 'ai_streaming_indicator.dart';
export 'ai_todo_list.dart';
export 'collapsible_tool_output.dart';
export 'ai_stream_simulator.dart';
export 'claude_stream_parser.dart';
export 'model_catalog.dart';
export 'mellonchat_channel_data.dart';
