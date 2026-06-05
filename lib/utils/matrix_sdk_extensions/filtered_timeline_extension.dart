import 'package:matrix/matrix.dart';

import 'package:fluffychat/ai_stream/agent_subchat.dart';
import 'package:fluffychat/ai_stream/mellon_response.dart';
import 'package:fluffychat/config/setting_keys.dart';

extension VisibleInGuiExtension on List<Event> {
  List<Event> filterByVisibleInGui({
    String? exceptionEventId,
    String? threadId,
  }) {
    final latestResponseEventIds = latestMellonResponseEvents(
      this,
      isCandidate: (event) => _isVisibleInGuiBase(
        event,
        exceptionEventId: exceptionEventId,
        threadId: threadId,
      ),
    ).values.map((event) => event.eventId).toSet();

    return where((event) {
      if (!_isVisibleInGuiBase(
        event,
        exceptionEventId: exceptionEventId,
        threadId: threadId,
      )) {
        return false;
      }
      if (event.eventId == exceptionEventId) {
        return true;
      }

      final responseMeta = directMellonResponseMetaForEvent(event);
      if (responseMeta != null && responseMeta.isVisibleSnapshot) {
        return latestResponseEventIds.contains(event.eventId);
      }

      return true;
    }).toList();
  }
}

bool _isVisibleInGuiBase(
  Event event, {
  String? exceptionEventId,
  String? threadId,
}) {
  if (threadId != null &&
      event.relationshipType != RelationshipTypes.reaction) {
    if ((event.relationshipType != RelationshipTypes.thread ||
            event.relationshipEventId != threadId) &&
        event.eventId != threadId) {
      return false;
    }
  } else if (event.relationshipType == RelationshipTypes.thread) {
    return false;
  } else if (event.content[agentSubchatContentKey] != null) {
    return false;
  }
  return event.isVisibleInGui || event.eventId == exceptionEventId;
}

extension IsStateExtension on Event {
  bool get isVisibleInGui =>
      // always filter out edit and reaction relationships
      !{
        RelationshipTypes.edit,
        RelationshipTypes.reaction,
      }.contains(relationshipType) &&
      // always filter out m.key.* and other known but unimportant events
      !isKnownHiddenStates &&
      // event types to hide: redaction and reaction events
      // if a reaction has been redacted we also want it to be hidden in the timeline
      !{EventTypes.Reaction, EventTypes.Redaction}.contains(type) &&
      // if we enabled to hide all redacted events, don't show those
      (!AppSettings.hideRedactedEvents.value || !redacted) &&
      // if we enabled to hide all unknown events, don't show those
      (!AppSettings.hideUnknownEvents.value || isEventTypeKnown);

  bool get isState => !{
    EventTypes.Message,
    EventTypes.Sticker,
    EventTypes.Encrypted,
  }.contains(type);

  bool get isCollapsedState => !{
    EventTypes.Message,
    EventTypes.Sticker,
    EventTypes.Encrypted,
    EventTypes.RoomCreate,
    EventTypes.RoomTombstone,
  }.contains(type);

  bool get isKnownHiddenStates =>
      {PollEventContent.responseType}.contains(type) ||
      type.startsWith('m.key.verification.') ||
      type.startsWith('org.mellonchat.model_');
}
