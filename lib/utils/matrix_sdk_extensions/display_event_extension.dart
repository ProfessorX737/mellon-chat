import 'package:matrix/matrix.dart';

import 'package:fluffychat/ai_stream/mellon_response.dart';

extension MellonDisplayEventExtension on Event {
  Event getMellonDisplayEvent(Timeline timeline) {
    if (redacted) return this;

    final nativeResponseEvent = latestMellonResponseEventFor(this, timeline);
    if (nativeResponseEvent != null && nativeResponseEvent.eventId != eventId) {
      return nativeResponseEvent;
    }

    final editEvents = aggregatedEvents(timeline, RelationshipTypes.edit)
        .where(
          (event) =>
              event.senderId == senderId &&
              event.type == EventTypes.Message &&
              event.content['m.new_content'] is Map,
        )
        .toList();
    if (editEvents.isEmpty) return getDisplayEvent(timeline);

    editEvents.sort((a, b) => _compareEditEvents(a, b, timeline));
    final rawEvent = editEvents.last.toJson();
    final content = rawEvent['content'];
    final newContent = content is Map ? content['m.new_content'] : null;
    if (newContent is Map) {
      rawEvent['content'] = Map<String, dynamic>.from(newContent);
    }
    return Event.fromJson(rawEvent, room);
  }
}

int _compareEditEvents(Event a, Event b, Timeline timeline) {
  final timestampComparison = a.originServerTs.compareTo(b.originServerTs);
  if (timestampComparison != 0) return timestampComparison;

  final statusComparison = _aiStreamStatusRank(
    a,
  ).compareTo(_aiStreamStatusRank(b));
  if (statusComparison != 0) return statusComparison;

  final bodyLengthComparison = _newBodyLength(a).compareTo(_newBodyLength(b));
  if (bodyLengthComparison != 0) return bodyLengthComparison;

  final aIndex = _timelineIndex(a, timeline);
  final bIndex = _timelineIndex(b, timeline);
  if (aIndex != -1 && bIndex != -1 && aIndex != bIndex) {
    return aIndex.compareTo(bIndex);
  }

  return a.eventId.compareTo(b.eventId);
}

int _timelineIndex(Event event, Timeline timeline) =>
    timeline.events.indexWhere(
      (candidate) =>
          candidate.eventId == event.eventId ||
          event.transactionId != null &&
              candidate.transactionId == event.transactionId,
    );

Map<String, dynamic> _newContent(Event event) {
  final content = event.content['m.new_content'];
  if (content is! Map) return const {};
  return Map<String, dynamic>.from(content);
}

int _newBodyLength(Event event) {
  final body = _newContent(event)['body'];
  return body is String ? body.length : event.body.length;
}

int _aiStreamStatusRank(Event event) {
  final aiStream = _newContent(event)['org.mellonchat.ai_stream'];
  if (aiStream is! Map) return 0;

  return switch (aiStream['status']) {
    'complete' => 2,
    'tool' || 'streaming' => 1,
    _ => 0,
  };
}
