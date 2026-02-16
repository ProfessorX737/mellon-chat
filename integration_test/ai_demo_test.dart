import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fluffychat/ai_stream/ai_stream_simulator.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('AI Demo - Scenario simulation with screenshots',
      (WidgetTester tester) async {
    // Launch the AI demo widget directly (no login/Matrix needed)
    await tester.pumpWidget(
      MaterialApp(
        home: const AIStreamSimulatorDemo(),
      ),
    );
    await tester.pumpAndSettle();

    // Screenshot 1: Initial state
    await binding.takeScreenshot('ai_demo_01_initial');

    // Select "Scenarios" tab (should already be selected)
    expect(find.text('Scenarios'), findsOneWidget);
    expect(find.text('Real Capture'), findsOneWidget);

    // Screenshot 2: Press play to start simulation (codeSearch scenario)
    await tester.tap(find.byKey(const Key('ai_demo_play_stop')));
    await tester.pump();

    // Wait a moment for the tool to start
    await tester.pump(const Duration(milliseconds: 500));
    await binding.takeScreenshot('ai_demo_02_tool_running');

    // Wait for tool to complete (2 seconds for progress)
    await tester.pump(const Duration(milliseconds: 2000));
    await tester.pump(const Duration(milliseconds: 100));
    await binding.takeScreenshot('ai_demo_03_tool_complete');

    // Wait for streaming text to appear
    await tester.pump(const Duration(milliseconds: 1000));
    await binding.takeScreenshot('ai_demo_04_streaming_text');

    // Wait for streaming to finish
    await tester.pump(const Duration(milliseconds: 3000));
    await tester.pump(const Duration(milliseconds: 500));
    await binding.takeScreenshot('ai_demo_05_complete');

    // Now try the multiTool scenario
    // Stop current simulation if running
    final playStopButton = find.byKey(const Key('ai_demo_play_stop'));

    // Wait for simulation to finish completely
    await tester.pump(const Duration(milliseconds: 2000));
    await tester.pumpAndSettle();

    // Select multiTool scenario from dropdown
    final dropdown = find.byType(DropdownButton<SimulationScenario>);
    if (dropdown.evaluate().isNotEmpty) {
      await tester.tap(dropdown);
      await tester.pumpAndSettle();

      // Find and tap "Multi-Tool" option
      final multiToolOption = find.text('Multi-Tool (Bash + Read + Bash)').last;
      await tester.tap(multiToolOption);
      await tester.pumpAndSettle();
    }

    // Start multi-tool simulation
    await tester.tap(playStopButton);
    await tester.pump();

    // Wait for first streaming
    await tester.pump(const Duration(milliseconds: 2000));
    await binding.takeScreenshot('ai_demo_06_multi_streaming');

    // Wait for first tool
    await tester.pump(const Duration(milliseconds: 3000));
    await binding.takeScreenshot('ai_demo_07_multi_tool1');

    // Wait for more tools
    await tester.pump(const Duration(milliseconds: 3000));
    await binding.takeScreenshot('ai_demo_08_multi_tool2');

    // Wait for completion
    await tester.pump(const Duration(milliseconds: 5000));
    await tester.pump(const Duration(milliseconds: 2000));
    await binding.takeScreenshot('ai_demo_09_multi_complete');

    // Now try Real Capture
    await tester.pump(const Duration(milliseconds: 2000));
    await tester.pumpAndSettle();

    // Switch to Real Capture tab
    await tester.tap(find.byKey(const Key('ai_demo_capture_chip')));
    await tester.pumpAndSettle();
    await binding.takeScreenshot('ai_demo_10_capture_tab');

    // Start capture replay
    await tester.tap(playStopButton);
    await tester.pump();

    // Take screenshots during capture replay
    await tester.pump(const Duration(milliseconds: 2000));
    await binding.takeScreenshot('ai_demo_11_capture_running');

    await tester.pump(const Duration(milliseconds: 4000));
    await binding.takeScreenshot('ai_demo_12_capture_progress');

    await tester.pump(const Duration(milliseconds: 6000));
    await binding.takeScreenshot('ai_demo_13_capture_later');

    // Wait a bit more for completion
    await tester.pump(const Duration(milliseconds: 5000));
    await tester.pump(const Duration(milliseconds: 3000));
    await binding.takeScreenshot('ai_demo_14_capture_final');
  });
}
