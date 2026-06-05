import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/models/timeline_chunk.dart';

import 'package:fluffychat/ai_stream/agent_subchat.dart';
import 'package:fluffychat/ai_stream/ai_stream_model.dart';
import 'package:fluffychat/ai_stream/mellon_response.dart';
import 'package:fluffychat/utils/matrix_sdk_extensions/display_event_extension.dart';
import 'package:fluffychat/utils/matrix_sdk_extensions/filtered_timeline_extension.dart';

import 'utils/test_client.dart';

void main() {
  test('indexed subchats render without a loaded timeline', () async {
    final client = await prepareTestClient(loggedIn: true);
    final room = Room(
      id: '!agent:example.invalid',
      client: client,
      roomAccountData: {
        agentSubchatsRoomAccountDataKey: BasicEvent(
          type: agentSubchatsRoomAccountDataKey,
          content: {
            'version': 1,
            'subchats': {
              r'$root': {
                'threadRootEventId': r'$root',
                'title': 'Planning notes',
                'preview': 'Sketch the migration',
                'updatedAt': '2026-05-19T00:00:00Z',
                'replyCount': 3,
                'canRename': true,
              },
            },
          },
        ),
      },
    );

    final subchats = mergeAgentSubchats(room: room);

    expect(subchats, hasLength(1));
    expect(subchats.single.threadRootEventId, r'$root');
    expect(subchats.single.title, 'Planning notes');
    expect(subchats.single.preview, 'Sketch the migration');
    expect(subchats.single.replyCount, 3);
    expect(subchats.single.canRename, isTrue);
  });

  test('indexed rename wins over a default server title', () async {
    final client = await prepareTestClient(loggedIn: true);
    final room = Room(
      id: '!agent:example.invalid',
      client: client,
      roomAccountData: {
        agentSubchatsRoomAccountDataKey: BasicEvent(
          type: agentSubchatsRoomAccountDataKey,
          content: {
            'version': 1,
            'subchats': {
              r'$root': {
                'threadRootEventId': r'$root',
                'title': 'Renamed subchat',
                'preview': 'Old preview',
                'updatedAt': '2026-05-19T00:00:00Z',
                'replyCount': 1,
                'canRename': true,
              },
            },
          },
        ),
      },
    );

    final subchats = mergeAgentSubchats(
      room: room,
      serverSubchats: [
        AgentSubchat(
          threadRootEventId: r'$root',
          title: defaultAgentSubchatTitle,
          preview: 'Fresh reply',
          updatedAt: DateTime.parse('2026-05-19T01:00:00Z'),
          replyCount: 2,
          canRename: false,
        ),
      ],
    );

    expect(subchats.single.title, 'Renamed subchat');
    expect(subchats.single.preview, 'Fresh reply');
    expect(subchats.single.replyCount, 2);
    expect(subchats.single.canRename, isTrue);
  });

  test(
    'manual indexed rename survives generated timeline title sync',
    () async {
      final client = await prepareTestClient(loggedIn: true);
      FakeMatrixApi.client = client;
      final room = Room(
        id: '!agent:example.invalid',
        client: client,
        roomAccountData: {
          agentSubchatsRoomAccountDataKey: BasicEvent(
            type: agentSubchatsRoomAccountDataKey,
            content: {
              'version': 1,
              'subchats': {
                r'$root': {
                  'threadRootEventId': r'$root',
                  'title': 'Manual title',
                  'isTitleManual': true,
                  'preview': 'Old preview',
                  'updatedAt': '2026-05-19T00:00:00Z',
                  'replyCount': 1,
                  'canRename': true,
                },
              },
            },
          ),
        },
      );

      await upsertAgentSubchatIndexEntries(
        room: room,
        subchats: [
          AgentSubchat(
            threadRootEventId: r'$root',
            title: 'First user message became generated title',
            preview: 'Latest bot reply',
            updatedAt: DateTime.parse('2026-05-19T01:00:00Z'),
            replyCount: 3,
            canRename: true,
          ),
        ],
      );

      final entry = agentSubchatIndexEntryForRoom(room, r'$root');
      expect(entry?.title, 'Manual title');
      expect(entry?.isTitleManual, isTrue);
      expect(entry?.preview, 'Latest bot reply');
      expect(entry?.replyCount, 3);
    },
  );

  test('mellon display event prefers the completed stream edit', () async {
    final client = await prepareTestClient(loggedIn: true);
    final room = Room(id: '!agent:example.invalid', client: client);
    final source = Event.fromJson({
      'type': EventTypes.Message,
      'content': {'body': 'Starting...', 'msgtype': MessageTypes.Text},
      'event_id': r'$source',
      'sender': '@case:example.invalid',
      'origin_server_ts': 1000,
    }, room);

    Map<String, dynamic> editJson({
      required String eventId,
      required String body,
      required String status,
    }) => {
      'type': EventTypes.Message,
      'content': {
        'body': '* $body',
        'msgtype': MessageTypes.Text,
        'm.new_content': {
          'body': body,
          'msgtype': MessageTypes.Text,
          'org.mellonchat.ai_stream': {'status': status},
        },
        'm.relates_to': {
          'event_id': r'$source',
          'rel_type': RelationshipTypes.edit,
        },
      },
      'event_id': eventId,
      'sender': '@case:example.invalid',
      'origin_server_ts': 2000,
    };

    final completeEdit = Event.fromJson(
      editJson(
        eventId: r'$complete',
        body: 'Want full abstracts for any of these? I can pull them next.',
        status: 'complete',
      ),
      room,
    );
    final partialEdit = Event.fromJson(
      editJson(
        eventId: r'$partial',
        body: 'Want full abstracts for any of these? I',
        status: 'streaming',
      ),
      room,
    );
    final timeline = Timeline(
      chunk: TimelineChunk(events: [source, completeEdit, partialEdit]),
      room: room,
    );

    final displayEvent = source.getMellonDisplayEvent(timeline);

    expect(displayEvent.body, endsWith('I can pull them next.'));
    expect(
      displayEvent.content.aiStreamContent?.status,
      AIStreamStatus.complete,
    );
  });

  test(
    'native response snapshots collapse to the latest visible event',
    () async {
      final client = await prepareTestClient(loggedIn: true);
      final room = Room(id: '!agent:example.invalid', client: client);
      final root = Event.fromJson({
        'type': EventTypes.Message,
        'content': {'body': 'Research this', 'msgtype': MessageTypes.Text},
        'event_id': r'$root',
        'sender': '@alice:example.invalid',
        'origin_server_ts': 1000,
      }, room);

      Map<String, dynamic> snapshotJson({
        required String eventId,
        required String body,
        required int sequence,
        required String status,
      }) => {
        'type': EventTypes.Message,
        'content': {
          'body': body,
          'msgtype': MessageTypes.Text,
          mellonResponseContentKey: {
            'response_id': 'answer-1',
            'sequence': sequence,
            'thread_root_event_id': r'$root',
            'kind': 'snapshot',
            'status': status,
          },
          'org.mellonchat.ai_stream': {'status': status},
          'm.relates_to': {
            'event_id': r'$root',
            'rel_type': RelationshipTypes.thread,
          },
        },
        'event_id': eventId,
        'sender': '@case:example.invalid',
        'origin_server_ts': 2000 + sequence,
      };

      final partial = Event.fromJson(
        snapshotJson(
          eventId: r'$partial',
          body: 'The answer starts',
          sequence: 1,
          status: 'streaming',
        ),
        room,
      );
      final complete = Event.fromJson(
        snapshotJson(
          eventId: r'$complete',
          body: 'The answer starts and finishes.',
          sequence: 2,
          status: 'complete',
        ),
        room,
      );
      final timeline = Timeline(
        chunk: TimelineChunk(events: [root, partial, complete]),
        room: room,
      );

      final visible = timeline.events.filterByVisibleInGui(threadId: r'$root');

      expect(visible.map((event) => event.eventId), [r'$root', r'$complete']);
      expect(partial.getMellonDisplayEvent(timeline).eventId, r'$complete');
      expect(
        partial.getMellonDisplayEvent(timeline).body,
        endsWith('finishes.'),
      );
    },
  );
}
