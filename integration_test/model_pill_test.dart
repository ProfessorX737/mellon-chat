import 'dart:convert';
import 'dart:io';

import 'package:fluffychat/pages/chat/chat_view.dart';
import 'package:fluffychat/pages/chat/model_picker_pill.dart';
import 'package:fluffychat/pages/chat_list/chat_list_body.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fluffychat/main.dart' as app;
import 'package:shared_preferences/shared_preferences.dart';

import 'extensions/default_flows.dart';
import 'extensions/wait_for.dart';

/// Integration test for the model picker pill.
///
/// Verifies that the model pill appears in bot DM rooms when the
/// bot's messages contain `org.mellonchat.ai_stream` metadata
/// with a `model` field.
///
/// Uses an unencrypted room (tars ↔ xaviertest) so messages are
/// readable without E2E encryption setup.
///
/// Run:
///   fvm flutter drive \
///     --driver=test_driver/integration_test.dart \
///     --target=integration_test/model_pill_test.dart \
///     -d chrome \
///     --dart-define=USER1_NAME=xaviertest \
///     --dart-define=USER1_PW=fhiewa432 \
///     --dart-define=HOMESERVER=localhost:6167
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // TARS bot — unencrypted DM room with xaviertest
  const homeserverUrl = 'http://localhost:6167';
  const botToken = '7l3nw5ybDgXuDjDXmhifed4ksyUWIupD';
  const dmRoomId = '!RP0ly5MgQmT_kkFvFZRsaRc-Ct7D_NO4YQ2NNRiF2Gk';
  const testProvider = 'openai';
  const testModel = 'claude-opus-4-6';

  /// Send a message as TARS with ai_stream model metadata.
  Future<bool> injectBotMessageWithModel() async {
    final client = HttpClient();
    try {
      final txnId = 'test_pill_${DateTime.now().millisecondsSinceEpoch}';
      final encodedRoom = dmRoomId.replaceAll('!', '%21');
      final req = await client.openUrl(
        'PUT',
        Uri.parse(
          '$homeserverUrl/_matrix/client/v3/rooms/$encodedRoom'
          '/send/m.room.message/$txnId',
        ),
      );
      req.headers.set('Authorization', 'Bearer $botToken');
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({
        'msgtype': 'm.text',
        'body': 'Hello! I am using claude-opus-4-6.',
        'org.mellonchat.ai_stream': {
          'status': 'complete',
          'model': {
            'provider': testProvider,
            'model': testModel,
          },
        },
      }));
      final resp = await req.close();
      final body = jsonDecode(await resp.transform(utf8.decoder).join());
      return body['event_id'] != null;
    } catch (e) {
      // ignore: avoid_print
      print('Failed to inject bot message: $e');
      return false;
    } finally {
      client.close();
    }
  }

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({
      'chat.fluffy.show_no_google': false,
    });

    // Inject a bot message with model metadata before the test
    final ok = await injectBotMessageWithModel();
    // ignore: avoid_print
    print('Bot message injection: ${ok ? "SUCCESS" : "FAILED"}');
  });

  testWidgets('Model pill shows correct model from ai_stream metadata',
      (WidgetTester tester) async {
    app.main();
    await tester.ensureAppStartedHomescreen();

    // Wait for chat list to fully load
    await tester.waitFor(find.byType(ChatListViewBody));
    await tester.pumpAndSettle();
    await binding.takeScreenshot('model_pill_01_chat_list');

    // The injected message should make the TARS DM room appear at the
    // top of the chat list (most recent). Tap the first room.
    final chatItems = find.byType(ListTile);
    expect(chatItems, findsWidgets,
        reason: 'Should have at least one chat room');
    await tester.tap(chatItems.first);
    await tester.pumpAndSettle();

    // Wait for chat view to load
    await tester.waitFor(
      find.byType(ChatView),
      timeout: const Duration(seconds: 10),
    );
    await tester.pumpAndSettle();

    // Allow time for timeline scan and model catalog init
    await Future.delayed(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    await binding.takeScreenshot('model_pill_02_chat_view');

    // Wait for model picker pill to appear
    await tester.waitFor(
      find.byType(ModelPickerPill),
      timeout: const Duration(seconds: 15),
    );

    // Verify the pill exists
    expect(find.byType(ModelPickerPill), findsOneWidget);

    // Verify model data
    final pillWidget = tester.widget<ModelPickerPill>(
      find.byType(ModelPickerPill),
    );
    expect(pillWidget.currentSelection, isNotNull,
        reason: 'Pill should have a model selection');
    expect(pillWidget.currentSelection!.provider, equals(testProvider),
        reason: 'Provider should be "$testProvider"');
    expect(pillWidget.currentSelection!.model, equals(testModel),
        reason: 'Model should be "$testModel"');

    // Verify the display label is visible
    expect(
      find.text('$testProvider / $testModel'),
      findsOneWidget,
      reason: 'Pill should display "provider / model"',
    );

    await binding.takeScreenshot('model_pill_03_pill_correct');
  });
}
