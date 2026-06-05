import 'package:matrix/matrix.dart';

import 'ai_stream_model.dart';

const mellonResponseContentKey = 'org.mellonchat.response';

class MellonResponseMeta {
  final String responseId;
  final int sequence;
  final String? threadRootEventId;
  final String kind;
  final String? status;
  final bool visible;

  const MellonResponseMeta({
    required this.responseId,
    required this.sequence,
    required this.kind,
    required this.visible,
    this.threadRootEventId,
    this.status,
  });

  bool get isVisibleSnapshot =>
      visible && {'snapshot', 'checkpoint', 'final'}.contains(kind);
}

MellonResponseMeta? mellonResponseMetaFromContent(
  Map<String, dynamic> content,
) {
  final rawBlock = content[mellonResponseContentKey];
  final block = rawBlock is Map ? rawBlock.cast<String, dynamic>() : null;
  final responseId = _nonEmptyString(
    block?['response_id'] ??
        block?['responseId'] ??
        content['org.mellonchat.response_id'] ??
        content['response_id'] ??
        content['responseId'],
  );
  if (responseId == null) return null;

  final kind = _nonEmptyString(block?['kind'] ?? block?['type']) ?? 'snapshot';
  final visible =
      _boolFromJson(block?['visible']) ??
      !{'chunk', 'delta'}.contains(kind.toLowerCase());
  final aiStatus = content.aiStreamContent?.status.name;

  return MellonResponseMeta(
    responseId: responseId,
    sequence:
        _intFromJson(
          block?['sequence'] ??
              block?['seq'] ??
              content['org.mellonchat.sequence'] ??
              content['sequence'] ??
              content['seq'],
        ) ??
        0,
    threadRootEventId: _nonEmptyString(
      block?['thread_root_event_id'] ??
          block?['threadRootEventId'] ??
          content['thread_root_event_id'] ??
          content['threadRootEventId'] ??
          content['thread_id'],
    ),
    kind: kind.toLowerCase(),
    status: _nonEmptyString(block?['status']) ?? aiStatus,
    visible: visible,
  );
}

MellonResponseMeta? directMellonResponseMetaForEvent(Event event) =>
    mellonResponseMetaFromContent(event.content);

MellonResponseMeta? mellonResponseMetaForEvent(Event event) {
  final direct = directMellonResponseMetaForEvent(event);
  if (direct != null) return direct;

  final newContent = event.content['m.new_content'];
  if (newContent is! Map) return null;
  return mellonResponseMetaFromContent(newContent.cast<String, dynamic>());
}

String mellonResponseGroupKey(Event event, MellonResponseMeta meta) =>
    '${event.senderId}\u0000${meta.responseId}';

Map<String, Event> latestMellonResponseEvents(
  Iterable<Event> events, {
  bool Function(Event event)? isCandidate,
}) {
  final latest = <String, Event>{};

  for (final event in events) {
    if (event.redacted) continue;
    if (isCandidate != null && !isCandidate(event)) continue;
    if ({
      RelationshipTypes.edit,
      RelationshipTypes.reaction,
    }.contains(event.relationshipType)) {
      continue;
    }
    final meta = directMellonResponseMetaForEvent(event);
    if (meta == null || !meta.isVisibleSnapshot) continue;

    final key = mellonResponseGroupKey(event, meta);
    final current = latest[key];
    if (current == null || compareMellonResponseEvents(current, event) < 0) {
      latest[key] = event;
    }
  }

  return latest;
}

Event? latestMellonResponseEventFor(Event event, Timeline timeline) {
  final meta = mellonResponseMetaForEvent(event);
  if (meta == null) return null;

  final key = mellonResponseGroupKey(event, meta);
  Event? latest;
  for (final candidate in timeline.events) {
    final candidateMeta = directMellonResponseMetaForEvent(candidate);
    if (candidateMeta == null || !candidateMeta.isVisibleSnapshot) continue;
    if (mellonResponseGroupKey(candidate, candidateMeta) != key) continue;
    if (latest == null || compareMellonResponseEvents(latest, candidate) < 0) {
      latest = candidate;
    }
  }

  return latest;
}

int compareMellonResponseEvents(Event a, Event b) {
  final aMeta =
      directMellonResponseMetaForEvent(a) ?? mellonResponseMetaForEvent(a);
  final bMeta =
      directMellonResponseMetaForEvent(b) ?? mellonResponseMetaForEvent(b);

  final sequenceComparison = (aMeta?.sequence ?? 0).compareTo(
    bMeta?.sequence ?? 0,
  );
  if (sequenceComparison != 0) return sequenceComparison;

  final statusComparison = _statusRank(
    aMeta?.status,
  ).compareTo(_statusRank(bMeta?.status));
  if (statusComparison != 0) return statusComparison;

  final timestampComparison = a.originServerTs.compareTo(b.originServerTs);
  if (timestampComparison != 0) return timestampComparison;

  final bodyLengthComparison = a.body.length.compareTo(b.body.length);
  if (bodyLengthComparison != 0) return bodyLengthComparison;

  return a.eventId.compareTo(b.eventId);
}

String? _nonEmptyString(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

int? _intFromJson(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

bool? _boolFromJson(Object? value) {
  if (value is bool) return value;
  if (value is String) {
    final lower = value.toLowerCase();
    if (lower == 'true') return true;
    if (lower == 'false') return false;
  }
  return null;
}

int _statusRank(String? status) {
  switch (status) {
    case 'complete':
    case 'completed':
    case 'final':
    case 'failed':
    case 'error':
    case 'cancelled':
      return 3;
    case 'tool':
      return 2;
    case 'streaming':
      return 1;
    default:
      return 0;
  }
}
