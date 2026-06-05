import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fluffychat/ai_stream/ai_stream_model.dart';
import 'package:fluffychat/ai_stream/collapsible_tool_output.dart';

void main() {
  testWidgets('completed tools do not show a spinner while message streams', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CompletedToolsList(
            isStreaming: true,
            tools: [
              CompletedTool(
                name: 'Read',
                status: 'completed',
                args: const {'file_path': '/tmp/route.ts'},
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.textContaining('Read route.ts'), findsOneWidget);
  });

  testWidgets('running tools still show a spinner', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CompletedToolsList(
            isStreaming: true,
            tools: [
              CompletedTool(
                name: 'Read',
                status: 'running',
                args: const {'file_path': '/tmp/route.ts'},
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.textContaining('Reading route.ts'), findsOneWidget);
  });
}
