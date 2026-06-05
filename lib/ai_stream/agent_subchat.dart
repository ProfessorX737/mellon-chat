import 'package:collection/collection.dart';
import 'package:matrix/matrix.dart';

import 'package:fluffychat/utils/matrix_sdk_extensions/display_event_extension.dart';

import 'ai_stream_model.dart';

const agentSubchatContentKey = 'org.mellonchat.subchat';
const defaultAgentSubchatTitle = 'New subchat';
const agentSubchatsRoomAccountDataKey = 'org.mellonchat.agent_subchats';
const archivedAgentSubchatsAccountDataKey = 'org.mellonchat.archived_subchats';
const aiStreamActivityStaleAfter = Duration(minutes: 5);

const _knownAgentLocalparts = {
  'alfred',
  'jarvis',
  'tars',
  'friday',
  'oracle',
  'social',
  'herald',
  'c3po',
  'case',
  'xavier2',
};

const _agentNameHints = {
  'openclaw',
  'assistant',
  'agent',
  'bot',
  'claude',
  'gpt',
};

class AgentSubchat {
  final String threadRootEventId;
  final String title;
  final String preview;
  final DateTime updatedAt;
  final int replyCount;
  final bool canRename;
  final bool isRunning;

  const AgentSubchat({
    required this.threadRootEventId,
    required this.title,
    required this.preview,
    required this.updatedAt,
    required this.replyCount,
    required this.canRename,
    this.isRunning = false,
  });
}

class AgentSubchatIndexEntry {
  final String threadRootEventId;
  final String title;
  final bool isTitleManual;
  final String preview;
  final DateTime updatedAt;
  final DateTime? createdAt;
  final int replyCount;
  final bool canRename;

  const AgentSubchatIndexEntry({
    required this.threadRootEventId,
    required this.title,
    required this.isTitleManual,
    required this.preview,
    required this.updatedAt,
    required this.replyCount,
    required this.canRename,
    this.createdAt,
  });

  AgentSubchat toSubchat() => AgentSubchat(
    threadRootEventId: threadRootEventId,
    title: title,
    preview: preview,
    updatedAt: updatedAt,
    replyCount: replyCount,
    canRename: canRename,
  );
}

Map<String, dynamic>? agentSubchatMeta(Event event) {
  final raw = event.content[agentSubchatContentKey];
  if (raw is! Map) return null;
  return raw.cast<String, dynamic>();
}

String? agentSubchatTitleFromEvent(Event event) {
  final metaTitle = agentSubchatMeta(event)?['title'];
  if (metaTitle is String && metaTitle.trim().isNotEmpty) {
    return metaTitle.trim();
  }
  final body = event.body.trim();
  return body.isEmpty ? null : body;
}

bool isDefaultAgentSubchatTitle(String? title) =>
    title?.trim().toLowerCase() == defaultAgentSubchatTitle.toLowerCase();

String? _contentThreadId(Event event) {
  final explicitThreadId =
      event.content['thread_root_event_id'] ??
      event.content['threadRootEventId'] ??
      event.content['thread_id'];
  if (explicitThreadId is String) return explicitThreadId;

  final relatesTo = event.content['m.relates_to'];
  if (relatesTo is Map &&
      relatesTo['rel_type'] == RelationshipTypes.thread &&
      relatesTo['event_id'] is String) {
    return relatesTo['event_id'] as String;
  }
  return null;
}

bool _belongsToConversation(Event event, String? threadRootEventId) {
  final contentThreadId = _contentThreadId(event);
  if (threadRootEventId == null) {
    return event.relationshipType != RelationshipTypes.thread &&
        contentThreadId == null;
  }
  if (event.eventId == threadRootEventId) return true;
  if (contentThreadId == threadRootEventId) return true;
  return event.relationshipType == RelationshipTypes.thread &&
      event.relationshipEventId == threadRootEventId;
}

AIStreamContent? aiStreamContentForEvent(Event event, {Timeline? timeline}) {
  final displayEvent = timeline == null
      ? event
      : event.getMellonDisplayEvent(timeline);
  final directContent = displayEvent.content.aiStreamContent;
  if (directContent != null) return directContent;

  final newContent = displayEvent.content['m.new_content'];
  if (newContent is Map) {
    return newContent.cast<String, dynamic>().aiStreamContent;
  }
  return null;
}

AIStreamContent? activeAiStreamContentForEvent(
  Event event, {
  Timeline? timeline,
  Duration staleAfter = aiStreamActivityStaleAfter,
}) {
  final displayEvent = timeline == null
      ? event
      : event.getMellonDisplayEvent(timeline);
  final aiStream = aiStreamContentForEvent(displayEvent);
  if (aiStream == null || !aiStream.isStreaming) return null;

  final age = DateTime.now().difference(displayEvent.originServerTs);
  return age <= staleAfter ? aiStream : null;
}

AIStreamContent? activeAiStreamContentForTimeline(
  Timeline timeline, {
  String? threadRootEventId,
  Duration staleAfter = aiStreamActivityStaleAfter,
}) {
  final displayEvents =
      timeline.events
          .where(
            (event) =>
                !{
                  RelationshipTypes.edit,
                  RelationshipTypes.reaction,
                }.contains(event.relationshipType) &&
                _belongsToConversation(event, threadRootEventId),
          )
          .map((event) => event.getMellonDisplayEvent(timeline))
          .toList()
        ..sort((a, b) => b.originServerTs.compareTo(a.originServerTs));

  for (final event in displayEvents) {
    final aiStream = aiStreamContentForEvent(event);
    if (aiStream == null) continue;
    if (!aiStream.isStreaming) return null;

    return activeAiStreamContentForEvent(event, staleAfter: staleAfter);
  }
  return null;
}

bool hasActiveAiStreamForTimeline(
  Timeline timeline, {
  String? threadRootEventId,
  Duration staleAfter = aiStreamActivityStaleAfter,
}) =>
    activeAiStreamContentForTimeline(
      timeline,
      threadRootEventId: threadRootEventId,
      staleAfter: staleAfter,
    ) !=
    null;

String _summarizeSubchatTitle(String body) {
  final collapsed = body.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (collapsed.length <= 48) return collapsed;
  return '${collapsed.substring(0, 45).trimRight()}...';
}

String agentSubchatTitleForTimeline({
  required Event rootEvent,
  required Timeline timeline,
}) {
  final displayEvent = rootEvent.getMellonDisplayEvent(timeline);
  final rootTitle =
      agentSubchatTitleFromEvent(displayEvent) ?? defaultAgentSubchatTitle;
  if (!isDefaultAgentSubchatTitle(rootTitle)) {
    return rootTitle;
  }

  final threadChildren =
      rootEvent.aggregatedEvents(timeline, RelationshipTypes.thread).toList()
        ..sort((a, b) => a.originServerTs.compareTo(b.originServerTs));
  final ownUserId = timeline.room.client.userID;
  final firstOwnMessage = threadChildren
      .map((event) => event.getMellonDisplayEvent(timeline))
      .firstWhereOrNull(
        (event) => event.senderId == ownUserId && event.body.trim().isNotEmpty,
      );
  final firstMessage =
      firstOwnMessage ??
      threadChildren
          .map((event) => event.getMellonDisplayEvent(timeline))
          .firstWhereOrNull((event) => event.body.trim().isNotEmpty);
  final body = firstMessage?.body.trim();
  return body == null || body.isEmpty
      ? defaultAgentSubchatTitle
      : _summarizeSubchatTitle(body);
}

Map<String, dynamic> buildAgentSubchatRootContent({
  String title = defaultAgentSubchatTitle,
  String? agentUserId,
}) {
  final now = DateTime.now().toUtc().toIso8601String();
  return {
    'msgtype': MessageTypes.Text,
    'body': title,
    agentSubchatContentKey: {
      'type': 'agent_subchat',
      'title': title,
      if (agentUserId != null) 'agentUserId': agentUserId,
      'createdAt': now,
    },
  };
}

Map<String, dynamic> buildAgentSubchatRenameContent({
  required Event currentDisplayEvent,
  required String title,
}) {
  final now = DateTime.now().toUtc().toIso8601String();
  final existingMeta = agentSubchatMeta(currentDisplayEvent);
  final meta = <String, dynamic>{
    if (existingMeta != null) ...existingMeta,
    'type': 'agent_subchat',
    'title': title,
    'updatedAt': now,
  };
  meta.putIfAbsent(
    'createdAt',
    () => currentDisplayEvent.originServerTs.toUtc().toIso8601String(),
  );

  return {
    'msgtype': MessageTypes.Text,
    'body': title,
    agentSubchatContentKey: meta,
  };
}

Map<String, dynamic> _stringKeyedMap(Object? value) {
  if (value is! Map) return {};
  return value.map((key, value) => MapEntry(key.toString(), value));
}

List<String> _stringList(Object? value) {
  if (value is! List) return const [];
  return value.whereType<String>().toList();
}

String? _nonEmptyString(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

DateTime? _dateTimeFromJson(Object? value) {
  final text = _nonEmptyString(value);
  if (text == null) return null;
  return DateTime.tryParse(text);
}

int _intFromJson(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return 0;
}

Map<String, dynamic> _agentSubchatIndexContent(Room room) => _stringKeyedMap(
  room.roomAccountData[agentSubchatsRoomAccountDataKey]?.content,
);

Map<String, dynamic> _agentSubchatIndexEntries(Room room) =>
    _stringKeyedMap(_agentSubchatIndexContent(room)['subchats']);

AgentSubchatIndexEntry? agentSubchatIndexEntryForRoom(
  Room room,
  String threadRootEventId,
) {
  final rawEntry = _agentSubchatIndexEntries(room)[threadRootEventId];
  final entry = _stringKeyedMap(rawEntry);
  if (entry.isEmpty) return null;

  final id = _nonEmptyString(entry['threadRootEventId']) ?? threadRootEventId;
  final title = _nonEmptyString(entry['title']) ?? defaultAgentSubchatTitle;
  final isTitleManual = entry['isTitleManual'] == true;
  final preview = _nonEmptyString(entry['preview']) ?? title;
  final createdAt = _dateTimeFromJson(entry['createdAt']);
  final updatedAt =
      _dateTimeFromJson(entry['updatedAt']) ??
      createdAt ??
      DateTime.fromMillisecondsSinceEpoch(0);

  return AgentSubchatIndexEntry(
    threadRootEventId: id,
    title: title,
    isTitleManual: isTitleManual,
    preview: preview,
    updatedAt: updatedAt,
    createdAt: createdAt,
    replyCount: _intFromJson(entry['replyCount']),
    canRename: entry['canRename'] == true,
  );
}

List<AgentSubchat> indexedAgentSubchatsForRoom(
  Room room, {
  Set<String> archivedThreadRootEventIds = const {},
}) {
  final entries = _agentSubchatIndexEntries(room);
  final subchats = <AgentSubchat>[];
  for (final entry in entries.entries) {
    if (archivedThreadRootEventIds.contains(entry.key)) continue;
    final subchat = agentSubchatIndexEntryForRoom(room, entry.key)?.toSubchat();
    if (subchat != null) subchats.add(subchat);
  }
  subchats.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  return subchats;
}

Map<String, dynamic> _subchatToIndexJson(
  AgentSubchat subchat, {
  String? agentUserId,
  DateTime? createdAt,
  bool isTitleManual = false,
}) {
  final created = createdAt ?? subchat.updatedAt;
  return {
    'threadRootEventId': subchat.threadRootEventId,
    'title': subchat.title,
    'isTitleManual': isTitleManual,
    'preview': subchat.preview,
    'createdAt': created.toUtc().toIso8601String(),
    'updatedAt': subchat.updatedAt.toUtc().toIso8601String(),
    'replyCount': subchat.replyCount,
    'canRename': subchat.canRename,
    if (agentUserId != null) 'agentUserId': agentUserId,
  };
}

Future<void> upsertAgentSubchatIndexEntry({
  required Room room,
  required String threadRootEventId,
  String? title,
  String? preview,
  DateTime? createdAt,
  DateTime? updatedAt,
  int? replyCount,
  bool? canRename,
  String? agentUserId,
  bool? isTitleManual,
}) async {
  final existing = agentSubchatIndexEntryForRoom(room, threadRootEventId);
  final now = DateTime.now().toUtc();
  final next = AgentSubchat(
    threadRootEventId: threadRootEventId,
    title: title ?? existing?.title ?? defaultAgentSubchatTitle,
    preview:
        preview ??
        existing?.preview ??
        title ??
        existing?.title ??
        defaultAgentSubchatTitle,
    updatedAt: updatedAt ?? existing?.updatedAt ?? now,
    replyCount: replyCount ?? existing?.replyCount ?? 0,
    canRename: canRename ?? existing?.canRename ?? false,
  );
  await upsertAgentSubchatIndexEntries(
    room: room,
    subchats: [next],
    createdAtByThreadRootEventId: {
      threadRootEventId: createdAt ?? existing?.createdAt ?? now,
    },
    manuallyTitledThreadRootEventIds: {
      if (isTitleManual == true) threadRootEventId,
    },
    agentUserId: agentUserId,
  );
}

Future<void> upsertAgentSubchatIndexEntries({
  required Room room,
  required Iterable<AgentSubchat> subchats,
  Map<String, DateTime> createdAtByThreadRootEventId = const {},
  Set<String> manuallyTitledThreadRootEventIds = const {},
  String? agentUserId,
}) async {
  final userId = room.client.userID;
  if (userId == null) return;

  final content = _agentSubchatIndexContent(room);
  final entries = _stringKeyedMap(content['subchats']);
  var changed = false;

  for (final subchat in subchats) {
    final existing = _stringKeyedMap(entries[subchat.threadRootEventId]);
    final existingTitle = _nonEmptyString(existing['title']);
    final existingIsTitleManual = existing['isTitleManual'] == true;
    final incomingIsTitleManual = manuallyTitledThreadRootEventIds.contains(
      subchat.threadRootEventId,
    );
    final title =
        existingIsTitleManual && !incomingIsTitleManual && existingTitle != null
        ? existingTitle
        : existingTitle != null &&
              !isDefaultAgentSubchatTitle(existingTitle) &&
              isDefaultAgentSubchatTitle(subchat.title)
        ? existingTitle
        : subchat.title;
    final isTitleManual = existingIsTitleManual || incomingIsTitleManual;
    final existingPreview = _nonEmptyString(existing['preview']);
    final preview =
        existingPreview != null &&
            subchat.preview == subchat.title &&
            !isDefaultAgentSubchatTitle(existingPreview)
        ? existingPreview
        : subchat.preview;
    final existingUpdatedAt = _dateTimeFromJson(existing['updatedAt']);
    final updatedAt =
        existingUpdatedAt != null &&
            existingUpdatedAt.isAfter(subchat.updatedAt)
        ? existingUpdatedAt
        : subchat.updatedAt;
    final existingReplyCount = _intFromJson(existing['replyCount']);
    final mergedSubchat = AgentSubchat(
      threadRootEventId: subchat.threadRootEventId,
      title: title,
      preview: preview,
      updatedAt: updatedAt,
      replyCount: subchat.replyCount > existingReplyCount
          ? subchat.replyCount
          : existingReplyCount,
      canRename: subchat.canRename || existing['canRename'] == true,
      isRunning: subchat.isRunning,
    );
    final createdAt =
        createdAtByThreadRootEventId[subchat.threadRootEventId] ??
        _dateTimeFromJson(existing['createdAt']) ??
        mergedSubchat.updatedAt;
    final next = {
      ...existing,
      ..._subchatToIndexJson(
        mergedSubchat,
        createdAt: createdAt,
        isTitleManual: isTitleManual,
        agentUserId: agentUserId ?? _nonEmptyString(existing['agentUserId']),
      ),
    };
    if (!const DeepCollectionEquality().equals(existing, next)) {
      entries[subchat.threadRootEventId] = next;
      changed = true;
    }
  }

  if (!changed) return;

  final nextContent = {...content, 'version': 1, 'subchats': entries};
  await room.client.setAccountDataPerRoom(
    userId,
    room.id,
    agentSubchatsRoomAccountDataKey,
    nextContent,
  );
  room.roomAccountData[agentSubchatsRoomAccountDataKey] = BasicEvent(
    type: agentSubchatsRoomAccountDataKey,
    content: nextContent,
  );
}

Set<String> archivedAgentSubchatIdsForRoom(Room room) {
  final content = _stringKeyedMap(
    room.client.accountData[archivedAgentSubchatsAccountDataKey]?.content,
  );
  final rooms = _stringKeyedMap(content['rooms']);
  final roomData = _stringKeyedMap(rooms[room.id]);
  return _stringList(roomData['threadRootEventIds']).toSet();
}

String _subchatTitleFromChildren({
  required Timeline timeline,
  required List<Event> threadChildren,
  required String? ownUserId,
}) {
  final firstOwnMessage = threadChildren
      .map((event) => event.getMellonDisplayEvent(timeline))
      .firstWhereOrNull(
        (event) => event.senderId == ownUserId && event.body.trim().isNotEmpty,
      );
  final firstMessage =
      firstOwnMessage ??
      threadChildren
          .map((event) => event.getMellonDisplayEvent(timeline))
          .firstWhereOrNull((event) => event.body.trim().isNotEmpty);
  final body = firstMessage?.body.trim();
  return body == null || body.isEmpty
      ? defaultAgentSubchatTitle
      : _summarizeSubchatTitle(body);
}

Future<void> archiveAgentSubchat({
  required Room room,
  required String threadRootEventId,
}) async {
  final client = room.client;
  final content = _stringKeyedMap(
    client.accountData[archivedAgentSubchatsAccountDataKey]?.content,
  );
  final rooms = _stringKeyedMap(content['rooms']);
  final roomData = _stringKeyedMap(rooms[room.id]);
  final ids = _stringList(roomData['threadRootEventIds']).toSet()
    ..add(threadRootEventId);
  final archivedAt = _stringKeyedMap(roomData['archivedAt']);

  archivedAt[threadRootEventId] = DateTime.now().toUtc().toIso8601String();
  roomData['threadRootEventIds'] = ids.toList()..sort();
  roomData['archivedAt'] = archivedAt;
  rooms[room.id] = roomData;
  content['rooms'] = rooms;

  await client.setAccountData(
    client.userID!,
    archivedAgentSubchatsAccountDataKey,
    content,
  );
}

bool isLikelyAgentRoom(Room room) {
  final directUserId = room.directChatMatrixID?.toLowerCase();
  final lastEvent = room.lastEvent;
  if (lastEvent?.content['org.mellonchat.ai_stream'] != null ||
      lastEvent?.content[agentSubchatContentKey] != null) {
    return true;
  }
  if (directUserId == null) return false;

  final localpart = directUserId.split(':').first.replaceFirst('@', '');
  if (_knownAgentLocalparts.contains(localpart)) return true;

  final displayName = room.name.toLowerCase();
  return _agentNameHints.any(
    (hint) => directUserId.contains(hint) || displayName.contains(hint),
  );
}

Event? _latestThreadEventFromBundledAggregations(Event rootEvent) {
  final relations = _stringKeyedMap(rootEvent.unsigned?['m.relations']);
  final thread = _stringKeyedMap(relations[RelationshipTypes.thread]);
  final latestRaw = thread['latest_event'];
  if (latestRaw is! Map) return null;
  try {
    return Event.fromMatrixEvent(
      MatrixEvent.fromJson(latestRaw.cast<String, dynamic>()),
      rootEvent.room,
    );
  } catch (_) {
    return null;
  }
}

int _threadReplyCountFromBundledAggregations(Event rootEvent) {
  final relations = _stringKeyedMap(rootEvent.unsigned?['m.relations']);
  final thread = _stringKeyedMap(relations[RelationshipTypes.thread]);
  return _intFromJson(thread['count']);
}

Future<List<AgentSubchat>> fetchServerAgentSubchats(
  Room room, {
  Set<String> archivedThreadRootEventIds = const {},
  int pageLimit = 100,
  int maxPages = 5,
}) async {
  final subchats = <AgentSubchat>[];
  String? nextBatch;

  for (var page = 0; page < maxPages; page++) {
    final response = await room.client.getThreadRoots(
      room.id,
      limit: pageLimit,
      from: nextBatch,
    );
    for (final matrixEvent in response.chunk) {
      final rootEvent = Event.fromMatrixEvent(matrixEvent, room);
      if (archivedThreadRootEventIds.contains(rootEvent.eventId)) continue;

      final title =
          agentSubchatTitleFromEvent(rootEvent) ?? defaultAgentSubchatTitle;
      final latestEvent = _latestThreadEventFromBundledAggregations(rootEvent);
      final latestBody = latestEvent?.body.trim();
      final preview = latestBody != null && latestBody.isNotEmpty
          ? latestBody
          : title;
      subchats.add(
        AgentSubchat(
          threadRootEventId: rootEvent.eventId,
          title: title,
          preview: preview,
          updatedAt: latestEvent?.originServerTs ?? rootEvent.originServerTs,
          replyCount: _threadReplyCountFromBundledAggregations(rootEvent),
          canRename: rootEvent.senderId == room.client.userID,
          isRunning: latestEvent == null
              ? false
              : activeAiStreamContentForEvent(latestEvent) != null,
        ),
      );
    }

    nextBatch = response.nextBatch;
    if (nextBatch == null) break;
  }

  subchats.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  return subchats;
}

List<AgentSubchat> mergeAgentSubchats({
  required Room room,
  Timeline? timeline,
  Iterable<AgentSubchat> serverSubchats = const {},
  Set<String> archivedThreadRootEventIds = const {},
}) {
  final byRootId = <String, AgentSubchat>{
    for (final subchat in indexedAgentSubchatsForRoom(
      room,
      archivedThreadRootEventIds: archivedThreadRootEventIds,
    ))
      subchat.threadRootEventId: subchat,
  };

  void merge(AgentSubchat incoming) {
    if (archivedThreadRootEventIds.contains(incoming.threadRootEventId)) {
      return;
    }
    final existing = byRootId[incoming.threadRootEventId];
    if (existing == null) {
      byRootId[incoming.threadRootEventId] = incoming;
      return;
    }

    final title = !isDefaultAgentSubchatTitle(existing.title)
        ? existing.title
        : incoming.title;
    final preview = incoming.preview.trim().isNotEmpty
        ? incoming.preview
        : existing.preview;
    byRootId[incoming.threadRootEventId] = AgentSubchat(
      threadRootEventId: incoming.threadRootEventId,
      title: title,
      preview: preview,
      updatedAt: incoming.updatedAt.isAfter(existing.updatedAt)
          ? incoming.updatedAt
          : existing.updatedAt,
      replyCount: incoming.replyCount > existing.replyCount
          ? incoming.replyCount
          : existing.replyCount,
      canRename: incoming.canRename || existing.canRename,
      isRunning: incoming.isRunning || existing.isRunning,
    );
  }

  for (final subchat in serverSubchats) {
    merge(subchat);
  }
  if (timeline != null) {
    for (final subchat in extractAgentSubchats(
      timeline,
      archivedThreadRootEventIds: archivedThreadRootEventIds,
    )) {
      merge(subchat);
    }
  }

  final subchats = byRootId.values.toList()
    ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  return subchats;
}

List<AgentSubchat> extractAgentSubchats(
  Timeline timeline, {
  Set<String> archivedThreadRootEventIds = const {},
}) {
  final subchats = <AgentSubchat>[];
  final threadChildrenByRoot = <String, List<Event>>{};
  final rootEventIds = <String>{};

  for (final event in timeline.events) {
    if (event.relationshipType == RelationshipTypes.thread) {
      final rootEventId = event.relationshipEventId;
      if (rootEventId == null ||
          archivedThreadRootEventIds.contains(rootEventId)) {
        continue;
      }
      (threadChildrenByRoot[rootEventId] ??= []).add(event);
      continue;
    }

    if (event.relationshipType != null) continue;
    if (archivedThreadRootEventIds.contains(event.eventId)) continue;
    if (event.type != EventTypes.Message && agentSubchatMeta(event) == null) {
      continue;
    }
    rootEventIds.add(event.eventId);

    final threadChildrenById = {
      for (final child in event.aggregatedEvents(
        timeline,
        RelationshipTypes.thread,
      ))
        child.eventId: child,
      for (final child
          in threadChildrenByRoot[event.eventId] ?? const <Event>[])
        child.eventId: child,
    };
    final threadChildren = threadChildrenById.values.toList()
      ..sort((a, b) => a.originServerTs.compareTo(b.originServerTs));
    if (threadChildren.isEmpty && agentSubchatMeta(event) == null) {
      continue;
    }

    final title = agentSubchatTitleForTimeline(
      rootEvent: event,
      timeline: timeline,
    );
    final lastEvent = threadChildren.lastOrNull?.getMellonDisplayEvent(
      timeline,
    );
    final lastBody = lastEvent?.body.trim();
    final preview = lastBody != null && lastBody.isNotEmpty ? lastBody : title;
    subchats.add(
      AgentSubchat(
        threadRootEventId: event.eventId,
        title: title,
        preview: preview,
        updatedAt: lastEvent?.originServerTs ?? event.originServerTs,
        replyCount: threadChildren.length,
        canRename: event.senderId == timeline.room.client.userID,
        isRunning:
            activeAiStreamContentForTimeline(
              timeline,
              threadRootEventId: event.eventId,
            ) !=
            null,
      ),
    );
  }

  final ownUserId = timeline.room.client.userID;
  for (final entry in threadChildrenByRoot.entries) {
    if (rootEventIds.contains(entry.key)) continue;
    final threadChildren = entry.value
      ..sort((a, b) => a.originServerTs.compareTo(b.originServerTs));
    final lastEvent = threadChildren.lastOrNull?.getMellonDisplayEvent(
      timeline,
    );
    if (lastEvent == null) continue;
    final lastBody = lastEvent.body.trim();
    final title = _subchatTitleFromChildren(
      timeline: timeline,
      threadChildren: threadChildren,
      ownUserId: ownUserId,
    );
    subchats.add(
      AgentSubchat(
        threadRootEventId: entry.key,
        title: title,
        preview: lastBody.isNotEmpty ? lastBody : title,
        updatedAt: lastEvent.originServerTs,
        replyCount: threadChildren.length,
        canRename: false,
        isRunning:
            activeAiStreamContentForTimeline(
              timeline,
              threadRootEventId: entry.key,
            ) !=
            null,
      ),
    );
  }

  subchats.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  return subchats;
}
