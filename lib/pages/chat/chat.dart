import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:collection/collection.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:file_picker/file_picker.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:matrix/matrix.dart';
import 'package:scroll_to_index/scroll_to_index.dart';

import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/config/themes.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/chat/chat_view.dart';
import 'package:fluffychat/pages/chat/event_info_dialog.dart';
import 'package:fluffychat/pages/chat/start_poll_bottom_sheet.dart';
import 'package:fluffychat/pages/chat_details/chat_details.dart';
import 'package:fluffychat/utils/adaptive_bottom_sheet.dart';
import 'package:fluffychat/utils/dev_log_sink.dart';
import 'package:fluffychat/utils/error_reporter.dart';
import 'package:fluffychat/utils/file_selector.dart';
import 'package:fluffychat/utils/matrix_sdk_extensions/display_event_extension.dart';
import 'package:fluffychat/utils/matrix_sdk_extensions/event_extension.dart';
import 'package:fluffychat/utils/matrix_sdk_extensions/filtered_timeline_extension.dart';
import 'package:fluffychat/utils/matrix_sdk_extensions/matrix_locals.dart';
import 'package:fluffychat/utils/other_party_can_receive.dart';
import 'package:fluffychat/utils/platform_infos.dart';
import 'package:fluffychat/utils/show_scaffold_dialog.dart';
import 'package:fluffychat/widgets/adaptive_dialogs/show_modal_action_popup.dart';
import 'package:fluffychat/widgets/adaptive_dialogs/show_ok_cancel_alert_dialog.dart';
import 'package:fluffychat/widgets/adaptive_dialogs/show_text_input_dialog.dart';
import 'package:fluffychat/widgets/future_loading_dialog.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:fluffychat/widgets/share_scaffold_dialog.dart';
import 'package:fluffychat/ai_stream/agent_subchat.dart';
import 'package:fluffychat/ai_stream/ai_stream_model.dart';
import 'package:fluffychat/ai_stream/mellon_response.dart';
import 'package:fluffychat/ai_stream/model_catalog.dart';
import 'package:fluffychat/ai_stream/mellonchat_channel_data.dart';
import 'package:fluffychat/pages/chat/model_picker_panel.dart';
import '../../utils/account_bundles.dart';
import '../../utils/localized_exception_extension.dart';
import 'send_file_dialog.dart';
import 'send_location_dialog.dart';

class ChatPage extends StatelessWidget {
  final String roomId;
  final List<ShareItem>? shareItems;
  final String? eventId;
  final String? threadId;
  final String? clientId;

  const ChatPage({
    super.key,
    required this.roomId,
    this.eventId,
    this.threadId,
    this.clientId,
    this.shareItems,
  });

  @override
  Widget build(BuildContext context) {
    final room = _roomForRoute(context);
    if (room == null) {
      return Scaffold(
        appBar: AppBar(title: Text(L10n.of(context).oopsSomethingWentWrong)),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(L10n.of(context).youAreNoLongerParticipatingInThisChat),
          ),
        ),
      );
    }

    return ChatPageWithRoom(
      key: Key('chat_page_${roomId}_${clientId}_${eventId}_$threadId'),
      room: room,
      shareItems: shareItems,
      eventId: eventId,
      threadId: threadId,
    );
  }

  Room? _roomForRoute(BuildContext context) {
    final matrix = Matrix.of(context);
    final preferredClient = matrix.widget.clients.firstWhereOrNull(
      (client) => client.userID == clientId,
    );
    final preferredRoom = preferredClient?.getRoomById(roomId);
    if (preferredRoom != null) return preferredRoom;

    final activeRoom = matrix.client.getRoomById(roomId);
    if (activeRoom != null) return activeRoom;

    for (final client in matrix.currentBundle ?? const <Client?>[]) {
      final room = client?.getRoomById(roomId);
      if (room != null) return room;
    }
    return null;
  }
}

class ChatPageWithRoom extends StatefulWidget {
  final Room room;
  final List<ShareItem>? shareItems;
  final String? eventId;
  final String? threadId;

  const ChatPageWithRoom({
    super.key,
    required this.room,
    this.shareItems,
    this.eventId,
    this.threadId,
  });

  @override
  ChatController createState() => ChatController();
}

enum _TimelineEventUpsertResult { inserted, updated, ignored }

const _subchatHydrationCacheTtl = Duration(minutes: 10);
const _subchatHydrationCacheRefreshGrace = Duration(seconds: 15);
const _subchatHydrationCacheEventLimit = 500;
const _subchatHydrationCacheMaxEntries = 24;

final _subchatHydrationCache = <String, _SubchatHydrationCacheEntry>{};

class _SubchatHydrationCacheEntry {
  const _SubchatHydrationCacheEntry({
    required this.storedAt,
    required this.eventJsons,
    required this.visibleEvents,
  });

  final DateTime storedAt;
  final List<Map<String, dynamic>> eventJsons;
  final int visibleEvents;
}

class _SubchatHydrationCacheRestoreResult {
  const _SubchatHydrationCacheRestoreResult({
    required this.outcome,
    this.cacheAgeMs,
    this.cachedEvents = 0,
    this.cachedVisibleEvents = 0,
    this.insertedEvents = 0,
    this.updatedEvents = 0,
    this.ignoredEvents = 0,
    this.visibleEventsBefore = 0,
    this.visibleEventsAfter = 0,
  });

  final String outcome;
  final int? cacheAgeMs;
  final int cachedEvents;
  final int cachedVisibleEvents;
  final int insertedEvents;
  final int updatedEvents;
  final int ignoredEvents;
  final int visibleEventsBefore;
  final int visibleEventsAfter;

  bool get restoredVisibleEvents =>
      outcome == 'restored' && visibleEventsAfter > 0;
}

class _EditHydrationCandidate {
  const _EditHydrationCandidate({
    required this.event,
    required this.selectionReason,
  });

  final Event event;
  final String selectionReason;
}

class _EditHydrationCandidateSelection {
  final List<_EditHydrationCandidate> candidates = [];
  int visibleEventsConsidered = 0;
  int skippedThreadRoot = 0;
  int skippedOwnSender = 0;
  int skippedNonMessage = 0;
  int skippedNativeResponse = 0;
  int skippedRedacted = 0;
  int skippedDuplicate = 0;
  int skippedOverLimit = 0;
}

class _NativeResponseSummary {
  const _NativeResponseSummary({
    this.responseEvents = 0,
    this.visibleSnapshotEvents = 0,
    this.responseGroups = 0,
    this.collapsedEvents = 0,
    this.latestEventId,
    this.latestResponseId,
    this.latestSequence,
    this.latestKind,
    this.latestStatus,
    this.latestBodyLength,
    this.latestSenderId,
  });

  final int responseEvents;
  final int visibleSnapshotEvents;
  final int responseGroups;
  final int collapsedEvents;
  final String? latestEventId;
  final String? latestResponseId;
  final int? latestSequence;
  final String? latestKind;
  final String? latestStatus;
  final int? latestBodyLength;
  final String? latestSenderId;

  Map<String, Object?> toLogFields() => {
    'native_response_events': responseEvents,
    'native_response_visible_snapshots': visibleSnapshotEvents,
    'native_response_groups': responseGroups,
    'native_response_collapsed_events': collapsedEvents,
    'native_response_latest_event_id': latestEventId,
    'native_response_latest_response_id': latestResponseId,
    'native_response_latest_sequence': latestSequence,
    'native_response_latest_kind': latestKind,
    'native_response_latest_status': latestStatus,
    'native_response_latest_body_length': latestBodyLength,
    'native_response_latest_sender_id': latestSenderId,
  };
}

class _EditHydratedCandidateResult {
  _EditHydratedCandidateResult({
    required this.eventId,
    required this.selectionReason,
  });

  final String eventId;
  final String selectionReason;
  final List<Event> validEvents = [];
  bool aborted = false;
  bool exhaustedRelations = false;
  int elapsedMs = 0;
  int fetched = 0;
  int inserted = 0;
  int updated = 0;
  int ignored = 0;
  int encryptedFetched = 0;
  int decrypted = 0;
  int undecrypted = 0;
  int relationPages = 0;
  int relationsWithMore = 0;
  int skippedNonEditRelations = 0;
  int skippedWrongSender = 0;
  int skippedInvalidType = 0;
  int skippedInvalidContent = 0;
  int relationRequestElapsedMs = 0;
  int eventDecodeElapsedMs = 0;
  int decryptElapsedMs = 0;
  int upsertElapsedMs = 0;
}

class ChatController extends State<ChatPageWithRoom>
    with WidgetsBindingObserver {
  Room get room => sendingClient.getRoomById(roomId) ?? widget.room;

  late Client sendingClient;

  Timeline? timeline;

  String? activeThreadId;

  late final String readMarkerEventId;

  String get roomId => widget.room.id;

  String get conversationKey {
    final threadId = activeThreadId;
    return threadId == null ? roomId : '$roomId:thread:$threadId';
  }

  String _roomRoute({
    String? routeRoomId,
    String? threadId,
    String? eventId,
    Client? client,
  }) {
    final queryParameters = <String, String>{};
    final clientUserId = (client ?? room.client).userID;
    if (clientUserId != null) queryParameters['client'] = clientUserId;
    if (threadId != null) queryParameters['thread'] = threadId;
    if (eventId != null) queryParameters['event'] = eventId;
    final query = Uri(queryParameters: queryParameters).query;
    final id = routeRoomId ?? roomId;
    return '/rooms/$id${query.isEmpty ? '' : '?$query'}';
  }

  final ValueNotifier<bool> _botRunningNotifier = ValueNotifier<bool>(false);

  ValueListenable<bool> get botRunningListenable => _botRunningNotifier;

  String get _draftKey => 'draft_$conversationKey';

  final AutoScrollController scrollController = AutoScrollController();

  late final FocusNode inputFocus;

  Timer? typingCoolDown;
  Timer? typingTimeout;
  Timer? _threadHydrationDebounce;
  bool _threadHydrationInFlight = false;
  bool _initialSubchatHydrationInFlight = false;
  Stopwatch? _initialSubchatHydrationIndicatorWatch;
  String? _lastInsertedTimelineEventId;

  bool get showInitialSubchatLoading =>
      activeThreadId != null && _initialSubchatHydrationInFlight;

  void _setInitialSubchatHydrationLoading(
    bool value, {
    required String threadId,
    required String reason,
  }) {
    if (_initialSubchatHydrationInFlight == value) return;
    int? visibleMs;
    if (value) {
      _initialSubchatHydrationIndicatorWatch = Stopwatch()..start();
    } else {
      visibleMs = _initialSubchatHydrationIndicatorWatch?.elapsedMilliseconds;
      _initialSubchatHydrationIndicatorWatch = null;
    }
    if (mounted) {
      setState(() {
        _initialSubchatHydrationInFlight = value;
      });
    } else {
      _initialSubchatHydrationInFlight = value;
    }
    _logSubchatTiming(
      value
          ? 'mellon.subchat_timing.initial_loading_indicator_show'
          : 'mellon.subchat_timing.initial_loading_indicator_hide',
      {
        'thread_root_event_id': threadId,
        'reason': reason,
        if (visibleMs != null) 'visible_ms': visibleMs,
      },
    );
  }

  bool currentlyTyping = false;
  bool dragging = false;

  void onDragEntered(dynamic _) => setState(() => dragging = true);

  void onDragExited(dynamic _) => setState(() => dragging = false);

  void onDragDone(DropDoneDetails details) async {
    setState(() => dragging = false);
    if (details.files.isEmpty) return;

    await showAdaptiveDialog(
      context: context,
      builder: (c) => SendFileDialog(
        files: details.files,
        room: room,
        outerContext: context,
        threadRootEventId: activeThreadId,
        threadLastEventId: threadLastEventId,
      ),
    );
  }

  bool get canSaveSelectedEvent =>
      selectedEvents.length == 1 &&
      {
        MessageTypes.Video,
        MessageTypes.Image,
        MessageTypes.Sticker,
        MessageTypes.Audio,
        MessageTypes.File,
      }.contains(selectedEvents.single.messageType);

  void saveSelectedEvent(BuildContext context) =>
      selectedEvents.single.saveFile(context);

  List<Event> selectedEvents = [];

  final Set<String> unfolded = {};

  Event? replyEvent;

  Event? editEvent;

  bool _scrolledUp = false;

  bool get showScrollDownButton =>
      _scrolledUp || timeline?.allowNewEvent == false;

  bool get selectMode => selectedEvents.isNotEmpty;

  final int _loadHistoryCount = 100;

  String pendingText = '';

  bool showEmojiPicker = false;

  // ── Model picker state ──
  /// Cached model catalog from the bot's /model response.
  /// Reads from and writes to the global per-conversation cache.
  ModelCatalog? get modelCatalog {
    final scopedCatalog = ModelCatalog.getForRoom(conversationKey);
    final threadId = activeThreadId;
    if (threadId == null) return scopedCatalog;

    final roomCatalog = ModelCatalog.getForRoom(roomId);
    if (scopedCatalog == null) return roomCatalog;
    if (_hasSelectableModelOptions(scopedCatalog)) return scopedCatalog;
    if (!_hasSelectableModelOptions(roomCatalog)) return scopedCatalog;

    return ModelCatalog(
      current: scopedCatalog.current,
      catalog: roomCatalog!.catalog,
      fetchedAt: roomCatalog.fetchedAt,
    );
  }

  set modelCatalog(ModelCatalog? value) {
    if (value != null) {
      ModelCatalog.cacheForRoom(conversationKey, value);
    }
  }

  /// Whether we are currently fetching the catalog
  bool isFetchingCatalog = false;

  /// Current model selection (from cached catalog)
  ModelSelection? get currentModelSelection => modelCatalog?.current;

  String get _modelStateKey => activeThreadId ?? '';

  String? get threadLastEventId {
    final threadId = activeThreadId;
    if (threadId == null) return null;
    return timeline?.events
        .filterByVisibleInGui(threadId: threadId)
        .firstOrNull
        ?.eventId;
  }

  String? get activeSubchatTitle {
    final threadId = activeThreadId;
    if (threadId == null) return null;
    final indexedTitle = agentSubchatIndexEntryForRoom(room, threadId)?.title;
    if (indexedTitle != null && !isDefaultAgentSubchatTitle(indexedTitle)) {
      return indexedTitle;
    }

    final timeline = this.timeline;
    if (timeline == null) return indexedTitle;
    final event = timeline.events.firstWhereOrNull(
      (event) => event.eventId == threadId,
    );
    if (event == null) return indexedTitle;
    final timelineTitle = agentSubchatTitleForTimeline(
      rootEvent: event,
      timeline: timeline,
    );
    return isDefaultAgentSubchatTitle(timelineTitle)
        ? indexedTitle ?? timelineTitle
        : timelineTitle;
  }

  bool get activeThreadIsAgentSubchat {
    final threadId = activeThreadId;
    if (threadId != null &&
        agentSubchatIndexEntryForRoom(room, threadId) != null) {
      return true;
    }
    final timeline = this.timeline;
    if (threadId == null || timeline == null) return false;
    final event = timeline.events.firstWhereOrNull(
      (event) => event.eventId == threadId,
    );
    if (event == null) return false;
    return agentSubchatMeta(event.getMellonDisplayEvent(timeline)) != null;
  }

  bool get activeThreadShouldUseAgentSubchatUi =>
      activeThreadId != null &&
      (activeThreadIsAgentSubchat || isLikelyAgentRoom(room));

  String _textRouteKind(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return 'empty';
    if (trimmed.toLowerCase() == 'status') return 'status';
    if (trimmed.startsWith('/')) return 'slash_command';
    return 'message';
  }

  int? _visibleTimelineEventCount() {
    final timeline = this.timeline;
    if (timeline == null) return null;
    return timeline.events
        .filterByVisibleInGui(threadId: activeThreadId)
        .length;
  }

  void _logChatStartup(String event, [Map<String, Object?> fields = const {}]) {
    DevLogSink.startup(event, {
      'room_id': roomId,
      'room_client_user_id': room.client.userID,
      'widget_room_client_user_id': widget.room.client.userID,
      'sending_client_user_id': sendingClient.userID,
      'thread_root_event_id': activeThreadId,
      'conversation_key': conversationKey,
      'widget_thread_id': widget.threadId,
      'initial_event_id': widget.eventId,
      'is_agent_room': isLikelyAgentRoom(widget.room),
      'is_direct_chat': widget.room.isDirectChat,
      'timeline_events': timeline?.events.length,
      'visible_events': _visibleTimelineEventCount(),
      ...fields,
    });
  }

  void _logSubchatTiming(
    String event, [
    Map<String, Object?> fields = const {},
  ]) {
    final fieldThreadId = fields['thread_root_event_id'];
    final threadId = fieldThreadId is String ? fieldThreadId : activeThreadId;
    if (threadId == null) return;
    DevLogSink.subchatTiming(event, {
      'room_id': roomId,
      'thread_root_event_id': threadId,
      'active_thread_id': activeThreadId,
      'conversation_key': '$roomId:thread:$threadId',
      'widget_thread_id': widget.threadId,
      'initial_event_id': widget.eventId,
      'is_agent_room': isLikelyAgentRoom(widget.room),
      'timeline_events': timeline?.events.length,
      'visible_events': _visibleTimelineEventCount(),
      ...fields,
    });
  }

  void _storeCurrentDraft() {
    _storeInputTimeoutTimer?.cancel();
    final prefs = Matrix.of(context).store;
    final text = sendController.text;
    if (text.isEmpty) {
      prefs.remove(_draftKey);
      return;
    }
    unawaited(prefs.setString(_draftKey, text));
  }

  void enterThread(String eventId) {
    _storeCurrentDraft();
    DevLogSink.subchatRoute('mellon.subchat.enter', {
      'room_id': roomId,
      'thread_root_event_id': eventId,
      'conversation_key': '$roomId:thread:$eventId',
      'is_agent_room': isLikelyAgentRoom(room),
    });
    DevLogSink.subchatTiming('mellon.subchat_timing.navigate_to_thread', {
      'room_id': roomId,
      'thread_root_event_id': eventId,
      'conversation_key': '$roomId:thread:$eventId',
      'source': 'chat_controller_enter_thread',
      'is_agent_room': isLikelyAgentRoom(room),
    });
    setState(() {
      activeThreadId = eventId;
      selectedEvents.clear();
      replyEvent = null;
      editEvent = null;
      pendingText = '';
      _loadDraft();
    });
    _refreshBotRunningState();
    context.go(_roomRoute(threadId: eventId));
  }

  void closeThread() {
    _storeCurrentDraft();
    DevLogSink.subchatRoute('mellon.subchat.close', {
      'room_id': roomId,
      'thread_root_event_id': activeThreadId,
      'conversation_key': conversationKey,
      'is_agent_room': isLikelyAgentRoom(room),
    });
    setState(() {
      activeThreadId = null;
      selectedEvents.clear();
      replyEvent = null;
      editEvent = null;
      pendingText = '';
      _loadDraft();
    });
    _refreshBotRunningState();
    context.go(_roomRoute());
  }

  void recreateChat() async {
    final room = this.room;
    final userId = room.directChatMatrixID;
    if (userId == null) {
      throw Exception(
        'Try to recreate a room with is not a DM room. This should not be possible from the UI!',
      );
    }
    await showFutureLoadingDialog(
      context: context,
      future: () => room.invite(userId),
    );
  }

  void leaveChat() async {
    final success = await showFutureLoadingDialog(
      context: context,
      future: room.leave,
    );
    if (success.error != null) return;
    context.go('/rooms');
  }

  void requestHistory([dynamic _]) async {
    Logs().v('Requesting history...');
    await timeline?.requestHistory(historyCount: _loadHistoryCount);
  }

  void requestFuture() async {
    final timeline = this.timeline;
    if (timeline == null) return;
    Logs().v('Requesting future...');

    final mostRecentEvent = timeline.events.filterByVisibleInGui().firstOrNull;

    await timeline.requestFuture(historyCount: _loadHistoryCount);

    if (mostRecentEvent != null) {
      setReadMarker(eventId: mostRecentEvent.eventId);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final index = timeline.events.filterByVisibleInGui().indexOf(
          mostRecentEvent,
        );
        if (index >= 0) {
          scrollController.scrollToIndex(
            index,
            preferPosition: AutoScrollPosition.begin,
          );
        }
      });
    }
  }

  _TimelineEventUpsertResult _upsertTimelineEvent(
    Timeline timeline,
    Event event,
  ) {
    final events = timeline.events;
    final existingIndex = events.indexWhere(
      (existing) =>
          existing.eventId == event.eventId ||
          (event.transactionId != null &&
              existing.transactionId == event.transactionId),
    );
    if (existingIndex >= 0) {
      final existing = events[existingIndex];
      if (event.type == EventTypes.Encrypted &&
          existing.type != EventTypes.Encrypted) {
        return _TimelineEventUpsertResult.ignored;
      }
      if (event.type == EventTypes.Encrypted &&
          existing.type == EventTypes.Encrypted &&
          existing.messageType == MessageTypes.BadEncrypted &&
          event.messageType != MessageTypes.BadEncrypted) {
        return _TimelineEventUpsertResult.ignored;
      }
      events[existingIndex] = event;
      timeline.addAggregatedEvent(event);
      return _TimelineEventUpsertResult.updated;
    }

    final insertIndex = events.indexWhere(
      (existing) => existing.originServerTs.isBefore(event.originServerTs),
    );
    events.insert(insertIndex == -1 ? events.length : insertIndex, event);
    timeline.addAggregatedEvent(event);
    return _TimelineEventUpsertResult.inserted;
  }

  String _subchatHydrationCacheKey(String threadId) {
    final userId = sendingClient.userID ?? room.client.userID ?? '';
    return '$userId\u0000$roomId\u0000$threadId';
  }

  bool _eventShouldBeCachedForThread(
    Event event, {
    required String threadId,
    required Set<String> threadEventIds,
  }) {
    if (threadEventIds.contains(event.eventId)) return true;
    if (event.relationshipType == RelationshipTypes.edit &&
        event.relationshipEventId != null &&
        threadEventIds.contains(event.relationshipEventId)) {
      return true;
    }
    final responseMeta = directMellonResponseMetaForEvent(event);
    if (responseMeta?.threadRootEventId == threadId) return true;
    return _contentThreadId(event) == threadId;
  }

  Map<String, dynamic>? _snapshotEventJson(Event event) {
    try {
      return (jsonDecode(jsonEncode(event.toJson())) as Map)
          .cast<String, dynamic>();
    } catch (e) {
      Logs().v('Unable to snapshot hydrated event ${event.eventId}: $e');
      return null;
    }
  }

  void _pruneSubchatHydrationCache() {
    if (_subchatHydrationCache.length <= _subchatHydrationCacheMaxEntries) {
      return;
    }
    final entries = _subchatHydrationCache.entries.toList()
      ..sort((a, b) => a.value.storedAt.compareTo(b.value.storedAt));
    final removeCount =
        _subchatHydrationCache.length - _subchatHydrationCacheMaxEntries;
    for (final entry in entries.take(removeCount)) {
      _subchatHydrationCache.remove(entry.key);
    }
  }

  void _storeSubchatHydrationCache(
    Timeline timeline,
    String threadId, {
    required String reason,
  }) {
    final visibleEvents = timeline.events.filterByVisibleInGui(
      threadId: threadId,
    );
    if (visibleEvents.isEmpty) {
      _logSubchatTiming('mellon.subchat_timing.hydration_cache_store_skip', {
        'thread_root_event_id': threadId,
        'reason': reason,
        'outcome': 'no_visible_events',
      });
      return;
    }

    final threadEventIds = <String>{};
    for (final event in timeline.events) {
      final responseMeta = directMellonResponseMetaForEvent(event);
      if (_eventBelongsToThread(event, threadId) ||
          _contentThreadId(event) == threadId ||
          responseMeta?.threadRootEventId == threadId) {
        threadEventIds.add(event.eventId);
      }
    }

    final eventJsons = <Map<String, dynamic>>[];
    for (final event in timeline.events) {
      if (eventJsons.length >= _subchatHydrationCacheEventLimit) break;
      if (!_eventShouldBeCachedForThread(
        event,
        threadId: threadId,
        threadEventIds: threadEventIds,
      )) {
        continue;
      }
      final eventJson = _snapshotEventJson(event);
      if (eventJson != null) eventJsons.add(eventJson);
    }

    if (eventJsons.isEmpty) {
      _logSubchatTiming('mellon.subchat_timing.hydration_cache_store_skip', {
        'thread_root_event_id': threadId,
        'reason': reason,
        'outcome': 'no_cacheable_events',
        'visible_events_to_cache': visibleEvents.length,
      });
      return;
    }

    _subchatHydrationCache[_subchatHydrationCacheKey(
      threadId,
    )] = _SubchatHydrationCacheEntry(
      storedAt: DateTime.now().toUtc(),
      eventJsons: eventJsons,
      visibleEvents: visibleEvents.length,
    );
    _pruneSubchatHydrationCache();
    _logSubchatTiming('mellon.subchat_timing.hydration_cache_store', {
      'thread_root_event_id': threadId,
      'reason': reason,
      'cached_events': eventJsons.length,
      'cached_visible_events': visibleEvents.length,
      'cache_entry_count': _subchatHydrationCache.length,
      'cache_event_limit': _subchatHydrationCacheEventLimit,
    });
  }

  _SubchatHydrationCacheRestoreResult _restoreSubchatHydrationCache(
    Timeline timeline,
    String threadId, {
    required String reason,
  }) {
    final entry = _subchatHydrationCache[_subchatHydrationCacheKey(threadId)];
    if (entry == null) {
      final result = const _SubchatHydrationCacheRestoreResult(outcome: 'miss');
      _logSubchatTiming('mellon.subchat_timing.hydration_cache_restore', {
        'thread_root_event_id': threadId,
        'reason': reason,
        'outcome': result.outcome,
      });
      return result;
    }

    final ageMs = DateTime.now()
        .toUtc()
        .difference(entry.storedAt)
        .inMilliseconds;
    if (ageMs > _subchatHydrationCacheTtl.inMilliseconds) {
      _subchatHydrationCache.remove(_subchatHydrationCacheKey(threadId));
      final result = _SubchatHydrationCacheRestoreResult(
        outcome: 'expired',
        cacheAgeMs: ageMs,
        cachedEvents: entry.eventJsons.length,
        cachedVisibleEvents: entry.visibleEvents,
      );
      _logSubchatTiming('mellon.subchat_timing.hydration_cache_restore', {
        'thread_root_event_id': threadId,
        'reason': reason,
        'outcome': result.outcome,
        'cache_age_ms': ageMs,
        'cached_events': entry.eventJsons.length,
        'cached_visible_events': entry.visibleEvents,
      });
      return result;
    }

    final beforeVisible = timeline.events
        .filterByVisibleInGui(threadId: threadId)
        .length;
    var inserted = 0;
    var updated = 0;
    var ignored = 0;
    for (final eventJson in entry.eventJsons) {
      final event = Event.fromJson(eventJson, room);
      final upsertResult = _upsertTimelineEvent(timeline, event);
      if (upsertResult == _TimelineEventUpsertResult.inserted) {
        inserted++;
      } else if (upsertResult == _TimelineEventUpsertResult.updated) {
        updated++;
      } else {
        ignored++;
      }
    }
    final afterVisible = timeline.events
        .filterByVisibleInGui(threadId: threadId)
        .length;
    final result = _SubchatHydrationCacheRestoreResult(
      outcome: 'restored',
      cacheAgeMs: ageMs,
      cachedEvents: entry.eventJsons.length,
      cachedVisibleEvents: entry.visibleEvents,
      insertedEvents: inserted,
      updatedEvents: updated,
      ignoredEvents: ignored,
      visibleEventsBefore: beforeVisible,
      visibleEventsAfter: afterVisible,
    );
    _logSubchatTiming('mellon.subchat_timing.hydration_cache_restore', {
      'thread_root_event_id': threadId,
      'reason': reason,
      'outcome': result.outcome,
      'cache_age_ms': ageMs,
      'cached_events': entry.eventJsons.length,
      'cached_visible_events': entry.visibleEvents,
      'inserted_events': inserted,
      'updated_events': updated,
      'ignored_events': ignored,
      'visible_events_before_restore': beforeVisible,
      'visible_events_after_restore': afterVisible,
    });
    return result;
  }

  Future<Event> _decryptHydratedEvent(Event event) async {
    if (event.type != EventTypes.Encrypted ||
        !room.client.encryptionEnabled ||
        room.client.encryption == null) {
      return event;
    }

    final decrypted = await room.client.encryption!.decryptRoomEvent(
      event,
      store: false,
      updateType: EventUpdateType.history,
    );
    if (decrypted.type == EventTypes.Encrypted &&
        decrypted.messageType == MessageTypes.BadEncrypted &&
        decrypted.content['can_request_session'] == true) {
      unawaited(decrypted.requestKey().catchError((_) {}));
    }
    return decrypted;
  }

  _NativeResponseSummary _summarizeNativeResponses(
    Iterable<Event> events, {
    required String threadId,
  }) {
    final latestByGroup = <String, Event>{};
    var responseEvents = 0;
    var visibleSnapshotEvents = 0;

    for (final event in events) {
      if (!_eventBelongsToThread(event, threadId)) continue;
      final meta = directMellonResponseMetaForEvent(event);
      if (meta == null) continue;

      responseEvents++;
      if (!meta.isVisibleSnapshot) continue;

      visibleSnapshotEvents++;
      final key = mellonResponseGroupKey(event, meta);
      final current = latestByGroup[key];
      if (current == null || compareMellonResponseEvents(current, event) < 0) {
        latestByGroup[key] = event;
      }
    }

    Event? latestEvent;
    for (final event in latestByGroup.values) {
      if (latestEvent == null ||
          latestEvent.originServerTs.isBefore(event.originServerTs)) {
        latestEvent = event;
      }
    }
    final latestMeta = latestEvent == null
        ? null
        : directMellonResponseMetaForEvent(latestEvent);

    return _NativeResponseSummary(
      responseEvents: responseEvents,
      visibleSnapshotEvents: visibleSnapshotEvents,
      responseGroups: latestByGroup.length,
      collapsedEvents: visibleSnapshotEvents - latestByGroup.length,
      latestEventId: latestEvent?.eventId,
      latestResponseId: latestMeta?.responseId,
      latestSequence: latestMeta?.sequence,
      latestKind: latestMeta?.kind,
      latestStatus: latestMeta?.status,
      latestBodyLength: latestEvent?.body.length,
      latestSenderId: latestEvent?.senderId,
    );
  }

  bool _eventBelongsToThread(Event event, String threadId) {
    return event.eventId == threadId ||
        event.relationshipType == RelationshipTypes.thread &&
            event.relationshipEventId == threadId;
  }

  _EditHydrationCandidateSelection _selectEditHydrationCandidates(
    Timeline timeline, {
    required String threadId,
    required int candidateLimit,
  }) {
    final selection = _EditHydrationCandidateSelection();
    final visibleEvents = timeline.events.filterByVisibleInGui(
      threadId: threadId,
    );
    final seenEventIds = <String>{};
    final ownUserId = room.client.userID;
    final preferBotOutput =
        activeThreadShouldUseAgentSubchatUi || isLikelyAgentRoom(room);

    for (final event in visibleEvents) {
      selection.visibleEventsConsidered++;
      if (!seenEventIds.add(event.eventId)) {
        selection.skippedDuplicate++;
        continue;
      }
      if (preferBotOutput && event.eventId == threadId) {
        selection.skippedThreadRoot++;
        continue;
      }
      if (event.redacted) {
        selection.skippedRedacted++;
        continue;
      }
      if (event.type != EventTypes.Message &&
          event.type != EventTypes.Encrypted) {
        selection.skippedNonMessage++;
        continue;
      }
      final responseMeta = directMellonResponseMetaForEvent(event);
      if (responseMeta != null && responseMeta.isVisibleSnapshot) {
        selection.skippedNativeResponse++;
        continue;
      }
      if (preferBotOutput && ownUserId != null && event.senderId == ownUserId) {
        selection.skippedOwnSender++;
        continue;
      }
      if (selection.candidates.length >= candidateLimit) {
        selection.skippedOverLimit++;
        continue;
      }

      selection.candidates.add(
        _EditHydrationCandidate(
          event: event,
          selectionReason: preferBotOutput
              ? event.content.aiStreamContent != null ||
                        isKnownBot(event.senderId)
                    ? 'visible_ai_output'
                    : 'visible_non_own_output'
              : 'visible_message',
        ),
      );
    }

    return selection;
  }

  Future<_EditHydratedCandidateResult> _fetchEditRelationsForCandidate(
    _EditHydrationCandidate candidate, {
    required int relationLimit,
    required int maxRelationPages,
    bool Function(String abortReason)? keepHydrating,
  }) async {
    final parent = candidate.event;
    final result = _EditHydratedCandidateResult(
      eventId: parent.eventId,
      selectionReason: candidate.selectionReason,
    );
    final candidateWatch = Stopwatch()..start();
    String? nextBatch;

    bool shouldContinue(String reason) {
      if (keepHydrating?.call(reason) ?? true) return true;
      result.aborted = true;
      return false;
    }

    for (var page = 0; page < maxRelationPages; page++) {
      if (!shouldContinue('aborted_before_edit_relation_page_fetch')) break;
      final relationRequestWatch = Stopwatch()..start();
      final response = await room.client.getRelatingEventsWithRelType(
        room.id,
        parent.eventId,
        RelationshipTypes.edit,
        from: nextBatch,
        limit: relationLimit,
        dir: Direction.b,
      );
      final relationRequestMs = relationRequestWatch.elapsedMilliseconds;
      result.relationRequestElapsedMs += relationRequestMs;
      result.relationPages++;
      if (!shouldContinue('aborted_after_edit_relation_page_fetch')) break;

      for (final matrixEvent in response.chunk) {
        if (!shouldContinue('aborted_before_edit_event_decrypt')) break;
        final decodeWatch = Stopwatch()..start();
        var event = Event.fromMatrixEvent(matrixEvent, room);
        final decodeMs = decodeWatch.elapsedMilliseconds;
        result.eventDecodeElapsedMs += decodeMs;
        result.fetched++;
        final wasEncrypted = event.type == EventTypes.Encrypted;
        if (wasEncrypted) result.encryptedFetched++;

        final decryptWatch = Stopwatch()..start();
        event = await _decryptHydratedEvent(event);
        final decryptMs = decryptWatch.elapsedMilliseconds;
        result.decryptElapsedMs += decryptMs;
        if (!shouldContinue('aborted_after_edit_event_decrypt')) break;

        if (wasEncrypted && event.type != EventTypes.Encrypted) {
          result.decrypted++;
        } else if (event.type == EventTypes.Encrypted) {
          result.undecrypted++;
        }

        if (event.relationshipType != RelationshipTypes.edit ||
            event.relationshipEventId != parent.eventId) {
          result.skippedNonEditRelations++;
          continue;
        }
        if (event.senderId != parent.senderId) {
          result.skippedWrongSender++;
          continue;
        }
        if (event.type != EventTypes.Message) {
          result.skippedInvalidType++;
          continue;
        }
        if (event.content['m.new_content'] is! Map) {
          result.skippedInvalidContent++;
          continue;
        }

        result.validEvents.add(event);
      }
      if (result.aborted) break;

      nextBatch = response.nextBatch;
      if (nextBatch == null || response.chunk.isEmpty) {
        result.exhaustedRelations = true;
        break;
      }
    }

    result.relationsWithMore = nextBatch != null ? 1 : 0;
    result.elapsedMs = candidateWatch.elapsedMilliseconds;
    return result;
  }

  Future<
    ({
      bool aborted,
      int candidateEvents,
      int fetched,
      int inserted,
      int updated,
      int ignored,
      int encryptedFetched,
      int decrypted,
      int undecrypted,
      int relationPages,
      int relationsWithMore,
      int eventsWithValidEdit,
      int eventsWithoutValidEdit,
      int eventsExhausted,
      int missingParentEvents,
      int validEditEvents,
      int skippedNonEditRelations,
      int skippedWrongSender,
      int skippedInvalidType,
      int skippedInvalidContent,
      int relationRequestElapsedMs,
      int eventDecodeElapsedMs,
      int decryptElapsedMs,
      int upsertElapsedMs,
      int parallelism,
      int parallelBatches,
      String? slowestEventId,
      int slowestEventElapsedMs,
      int slowestEventFetched,
      int slowestEventValid,
      int slowestEventRelationPages,
      int slowestEventRelationsWithMore,
      int slowestEventRelationRequestElapsedMs,
      int slowestEventDecryptElapsedMs,
      int slowestEventUpsertElapsedMs,
    })
  >
  _hydrateEditRelationsForEvents(
    Timeline timeline,
    Iterable<_EditHydrationCandidate> candidates, {
    int relationLimit = 25,
    int maxRelationPages = 1,
    int parallelism = 1,
    required String threadRootEventId,
    required String reason,
    bool Function(String abortReason)? keepHydrating,
  }) async {
    final candidateEvents = candidates.toList(growable: false);
    final effectiveParallelism = parallelism < 1 ? 1 : parallelism;
    var aborted = false;
    var fetched = 0;
    var inserted = 0;
    var updated = 0;
    var ignored = 0;
    var encryptedFetched = 0;
    var decrypted = 0;
    var undecrypted = 0;
    var relationPages = 0;
    var relationsWithMore = 0;
    var eventsWithValidEdit = 0;
    var eventsWithoutValidEdit = 0;
    var eventsExhausted = 0;
    final missingParentEvents = 0;
    var validEditEvents = 0;
    var skippedNonEditRelations = 0;
    var skippedWrongSender = 0;
    var skippedInvalidType = 0;
    var skippedInvalidContent = 0;
    var relationRequestElapsedMs = 0;
    var eventDecodeElapsedMs = 0;
    var decryptElapsedMs = 0;
    var upsertElapsedMs = 0;
    var parallelBatches = 0;
    String? slowestEventId;
    var slowestEventElapsedMs = 0;
    var slowestEventFetched = 0;
    var slowestEventValid = 0;
    var slowestEventRelationPages = 0;
    var slowestEventRelationsWithMore = 0;
    var slowestEventRelationRequestElapsedMs = 0;
    var slowestEventDecryptElapsedMs = 0;
    var slowestEventUpsertElapsedMs = 0;

    bool shouldAbort(String reason) {
      if (keepHydrating?.call(reason) ?? true) return false;
      aborted = true;
      return true;
    }

    for (
      var batchStart = 0;
      batchStart < candidateEvents.length;
      batchStart += effectiveParallelism
    ) {
      if (shouldAbort('aborted_before_edit_relations_fetch')) break;
      final batch = candidateEvents
          .skip(batchStart)
          .take(effectiveParallelism)
          .toList(growable: false);
      parallelBatches++;
      final results = await Future.wait(
        batch.map(
          (candidate) => _fetchEditRelationsForCandidate(
            candidate,
            relationLimit: relationLimit,
            maxRelationPages: maxRelationPages,
            keepHydrating: keepHydrating,
          ),
        ),
      );

      for (final result in results) {
        if (result.aborted) aborted = true;

        if (!aborted && !shouldAbort('aborted_before_edit_candidate_upsert')) {
          for (final event in result.validEvents) {
            if (shouldAbort('aborted_before_edit_event_upsert')) break;
            final upsertWatch = Stopwatch()..start();
            final upsertResult = _upsertTimelineEvent(timeline, event);
            final upsertMs = upsertWatch.elapsedMilliseconds;
            result.upsertElapsedMs += upsertMs;
            if (upsertResult == _TimelineEventUpsertResult.inserted) {
              result.inserted++;
            } else if (upsertResult == _TimelineEventUpsertResult.updated) {
              result.updated++;
            } else {
              result.ignored++;
            }
          }
        }

        fetched += result.fetched;
        inserted += result.inserted;
        updated += result.updated;
        ignored += result.ignored;
        encryptedFetched += result.encryptedFetched;
        decrypted += result.decrypted;
        undecrypted += result.undecrypted;
        relationPages += result.relationPages;
        relationsWithMore += result.relationsWithMore;
        validEditEvents += result.validEvents.length;
        skippedNonEditRelations += result.skippedNonEditRelations;
        skippedWrongSender += result.skippedWrongSender;
        skippedInvalidType += result.skippedInvalidType;
        skippedInvalidContent += result.skippedInvalidContent;
        relationRequestElapsedMs += result.relationRequestElapsedMs;
        eventDecodeElapsedMs += result.eventDecodeElapsedMs;
        decryptElapsedMs += result.decryptElapsedMs;
        upsertElapsedMs += result.upsertElapsedMs;
        if (result.validEvents.isNotEmpty) {
          eventsWithValidEdit++;
        } else {
          eventsWithoutValidEdit++;
        }
        if (result.exhaustedRelations) eventsExhausted++;

        if (result.elapsedMs > slowestEventElapsedMs) {
          slowestEventId = result.eventId;
          slowestEventElapsedMs = result.elapsedMs;
          slowestEventFetched = result.fetched;
          slowestEventValid = result.validEvents.length;
          slowestEventRelationPages = result.relationPages;
          slowestEventRelationsWithMore = result.relationsWithMore;
          slowestEventRelationRequestElapsedMs =
              result.relationRequestElapsedMs;
          slowestEventDecryptElapsedMs = result.decryptElapsedMs;
          slowestEventUpsertElapsedMs = result.upsertElapsedMs;
        }
        _logSubchatTiming('mellon.subchat_timing.edit_hydrate_candidate_done', {
          'thread_root_event_id': threadRootEventId,
          'reason': reason,
          'hydrated_event_id': result.eventId,
          'selection_reason': result.selectionReason,
          'elapsed_ms': result.elapsedMs,
          'relation_pages': result.relationPages,
          'relation_events': result.fetched,
          'valid_edit_events': result.validEvents.length,
          'inserted_events': result.inserted,
          'updated_events': result.updated,
          'ignored_events': result.ignored,
          'encrypted_fetched_events': result.encryptedFetched,
          'decrypted_events': result.decrypted,
          'undecrypted_events': result.undecrypted,
          'skipped_non_edit_relations': result.skippedNonEditRelations,
          'skipped_wrong_sender': result.skippedWrongSender,
          'skipped_invalid_type': result.skippedInvalidType,
          'skipped_invalid_content': result.skippedInvalidContent,
          'relation_request_elapsed_ms': result.relationRequestElapsedMs,
          'event_decode_elapsed_ms': result.eventDecodeElapsedMs,
          'decrypt_elapsed_ms': result.decryptElapsedMs,
          'upsert_elapsed_ms': result.upsertElapsedMs,
          'relations_with_more': result.relationsWithMore,
          'exhausted_relations': result.exhaustedRelations,
          'parallelism': effectiveParallelism,
          'parallel_batch': parallelBatches,
        });
        if (aborted) break;
      }
      if (aborted) break;
    }

    return (
      aborted: aborted,
      candidateEvents: candidateEvents.length,
      fetched: fetched,
      inserted: inserted,
      updated: updated,
      ignored: ignored,
      encryptedFetched: encryptedFetched,
      decrypted: decrypted,
      undecrypted: undecrypted,
      relationPages: relationPages,
      relationsWithMore: relationsWithMore,
      eventsWithValidEdit: eventsWithValidEdit,
      eventsWithoutValidEdit: eventsWithoutValidEdit,
      eventsExhausted: eventsExhausted,
      missingParentEvents: missingParentEvents,
      validEditEvents: validEditEvents,
      skippedNonEditRelations: skippedNonEditRelations,
      skippedWrongSender: skippedWrongSender,
      skippedInvalidType: skippedInvalidType,
      skippedInvalidContent: skippedInvalidContent,
      relationRequestElapsedMs: relationRequestElapsedMs,
      eventDecodeElapsedMs: eventDecodeElapsedMs,
      decryptElapsedMs: decryptElapsedMs,
      upsertElapsedMs: upsertElapsedMs,
      parallelism: effectiveParallelism,
      parallelBatches: parallelBatches,
      slowestEventId: slowestEventId,
      slowestEventElapsedMs: slowestEventElapsedMs,
      slowestEventFetched: slowestEventFetched,
      slowestEventValid: slowestEventValid,
      slowestEventRelationPages: slowestEventRelationPages,
      slowestEventRelationsWithMore: slowestEventRelationsWithMore,
      slowestEventRelationRequestElapsedMs:
          slowestEventRelationRequestElapsedMs,
      slowestEventDecryptElapsedMs: slowestEventDecryptElapsedMs,
      slowestEventUpsertElapsedMs: slowestEventUpsertElapsedMs,
    );
  }

  void _scheduleActiveThreadHydration(String reason) {
    if (activeThreadId == null || timeline == null) return;
    _threadHydrationDebounce?.cancel();
    _threadHydrationDebounce = Timer(
      const Duration(milliseconds: 250),
      () => unawaited(_hydrateActiveThreadTimeline(reason: reason)),
    );
  }

  void refreshActiveThread() {
    unawaited(_hydrateActiveThreadTimeline(reason: 'manual_refresh'));
  }

  void _onTimelineNewEvent() {
    final threadId = activeThreadId;
    final timeline = this.timeline;
    if (threadId == null || timeline == null) return;

    final insertedEventId = _lastInsertedTimelineEventId;
    final insertedEvent = insertedEventId == null
        ? null
        : timeline.events.firstWhereOrNull(
            (event) => event.eventId == insertedEventId,
          );
    final responseMeta = insertedEvent == null
        ? null
        : directMellonResponseMetaForEvent(insertedEvent);
    if (insertedEvent != null &&
        _eventBelongsToThread(insertedEvent, threadId) &&
        responseMeta != null &&
        responseMeta.isVisibleSnapshot) {
      _logSubchatTiming('mellon.subchat_timing.thread_hydrate_skip', {
        'thread_root_event_id': threadId,
        'reason': 'timeline_new_event_native_response',
        'inserted_event_id': insertedEvent.eventId,
        'native_response_id': responseMeta.responseId,
        'native_response_sequence': responseMeta.sequence,
        'native_response_kind': responseMeta.kind,
        'native_response_status': responseMeta.status,
        'native_response_body_length': insertedEvent.body.length,
      });
      _storeSubchatHydrationCache(
        timeline,
        threadId,
        reason: 'timeline_new_event_native_response',
      );
      _refreshBotRunningState();
      if (mounted) setState(() {});
      return;
    }

    _scheduleActiveThreadHydration('timeline_new_event');
  }

  Future<void> _hydrateActiveThreadTimeline({
    required String reason,
    int pageLimit = 100,
    int maxPages = 3,
  }) async {
    final threadId = activeThreadId;
    final timeline = this.timeline;
    if (!mounted ||
        threadId == null ||
        timeline == null ||
        _threadHydrationInFlight) {
      return;
    }
    bool isCurrentHydrationTarget() =>
        mounted && activeThreadId == threadId && this.timeline == timeline;

    final timingWatch = Stopwatch()..start();
    var timingOutcome = 'completed';
    _threadHydrationInFlight = true;
    final showInitialLoading = reason == 'initial_load';
    if (showInitialLoading) {
      _setInitialSubchatHydrationLoading(
        true,
        threadId: threadId,
        reason: reason,
      );
    }
    final beforeEvents = timeline.events.length;
    final beforeVisible = timeline.events
        .filterByVisibleInGui(threadId: threadId)
        .length;
    var nativeResponseSummary = _summarizeNativeResponses(
      timeline.events,
      threadId: threadId,
    );
    bool keepHydrating(String abortReason) {
      if (isCurrentHydrationTarget()) return true;
      timingOutcome = abortReason;
      return false;
    }

    DevLogSink.subchatRoute('mellon.subchat.thread_hydrate_start', {
      'room_id': roomId,
      'thread_root_event_id': threadId,
      'conversation_key': '$roomId:thread:$threadId',
      'reason': reason,
      'timeline_events': beforeEvents,
      'visible_events': beforeVisible,
      'allow_new_event': timeline.allowNewEvent,
      'can_request_future': timeline.canRequestFuture,
      'can_request_history': timeline.canRequestHistory,
      ...nativeResponseSummary.toLogFields(),
    });
    _logSubchatTiming('mellon.subchat_timing.thread_hydrate_start', {
      'thread_root_event_id': threadId,
      'reason': reason,
      'timeline_events': beforeEvents,
      'visible_events': beforeVisible,
      'allow_new_event': timeline.allowNewEvent,
      'can_request_future': timeline.canRequestFuture,
      'can_request_history': timeline.canRequestHistory,
      'page_limit': pageLimit,
      'max_pages': maxPages,
      ...nativeResponseSummary.toLogFields(),
    });

    var fetched = 0;
    var inserted = 0;
    var updated = 0;
    var encryptedFetched = 0;
    var decrypted = 0;
    var undecrypted = 0;
    var editFetched = 0;
    var editInserted = 0;
    var editUpdated = 0;
    var editIgnored = 0;
    var editEncryptedFetched = 0;
    var editDecrypted = 0;
    var editUndecrypted = 0;
    var editRelationPages = 0;
    var editRelationsWithMore = 0;
    var editCandidateCount = 0;
    var editEventsWithValidEdit = 0;
    var editEventsWithoutValidEdit = 0;
    var editEventsExhausted = 0;
    var editMissingParentEvents = 0;
    var editValidEvents = 0;
    var editSkippedNonEditRelations = 0;
    var editSkippedWrongSender = 0;
    var editSkippedInvalidType = 0;
    var editSkippedInvalidContent = 0;
    var editHydrationElapsedMs = 0;
    var editHydrationStrategy = 'not_started';
    var editRelationLimit = 0;
    var editRelationMaxPages = 0;
    var editHydrationParallelism = 0;
    var editHydrationParallelBatches = 0;
    var editRawThreadRelationCandidateEvents = 0;
    var editRawFullHistoryCandidateEvents = 0;
    var editVisibleEventsConsidered = 0;
    var editSkippedThreadRoot = 0;
    var editSkippedOwnSender = 0;
    var editSkippedNonMessage = 0;
    var editSkippedNativeResponse = 0;
    var editSkippedRedacted = 0;
    var editSkippedDuplicate = 0;
    var editSkippedOverLimit = 0;
    var editRelationRequestElapsedMs = 0;
    var editEventDecodeElapsedMs = 0;
    var editDecryptElapsedMs = 0;
    var editUpsertElapsedMs = 0;
    String? editSlowestEventId;
    var editSlowestEventElapsedMs = 0;
    var editSlowestEventFetched = 0;
    var editSlowestEventValid = 0;
    var editSlowestEventRelationPages = 0;
    var editSlowestEventRelationsWithMore = 0;
    var editSlowestEventRelationRequestElapsedMs = 0;
    var editSlowestEventDecryptElapsedMs = 0;
    var editSlowestEventUpsertElapsedMs = 0;
    String? nextBatch;
    Event? newestFetchedEvent;
    final threadRelationEventIds = <String>{};

    try {
      final hasRoot = timeline.events.any((event) => event.eventId == threadId);
      if (!hasRoot) {
        final rootEvent = await room.getEventById(threadId);
        if (!keepHydrating('aborted_after_root_fetch')) return;
        if (rootEvent != null) {
          final upsertResult = _upsertTimelineEvent(timeline, rootEvent);
          if (upsertResult == _TimelineEventUpsertResult.inserted) {
            inserted++;
          } else if (upsertResult == _TimelineEventUpsertResult.updated) {
            updated++;
          }
        }
      }

      final relationPageLimit = reason == 'manual_refresh' ? pageLimit : 50;
      final relationMaxPages = reason == 'manual_refresh' ? maxPages : 1;

      for (var page = 0; page < relationMaxPages; page++) {
        final response = await room.client.getRelatingEventsWithRelType(
          room.id,
          threadId,
          RelationshipTypes.thread,
          from: nextBatch,
          limit: relationPageLimit,
          dir: Direction.b,
        );
        if (!keepHydrating('aborted_after_thread_relations_fetch')) return;

        for (final matrixEvent in response.chunk) {
          var event = Event.fromMatrixEvent(matrixEvent, room);
          fetched++;
          final wasEncrypted = event.type == EventTypes.Encrypted;
          if (wasEncrypted) encryptedFetched++;
          event = await _decryptHydratedEvent(event);
          if (!keepHydrating('aborted_after_thread_event_decrypt')) return;
          if (wasEncrypted && event.type != EventTypes.Encrypted) {
            decrypted++;
          } else if (event.type == EventTypes.Encrypted) {
            undecrypted++;
          }
          if (newestFetchedEvent == null ||
              event.originServerTs.isAfter(newestFetchedEvent.originServerTs)) {
            newestFetchedEvent = event;
          }
          final upsertResult = _upsertTimelineEvent(timeline, event);
          if (upsertResult == _TimelineEventUpsertResult.inserted) {
            inserted++;
          } else if (upsertResult == _TimelineEventUpsertResult.updated) {
            updated++;
          }
          threadRelationEventIds.add(event.eventId);
        }

        nextBatch = response.nextBatch;
        if (nextBatch == null) break;
      }

      final isManualRefresh = reason == 'manual_refresh';
      final isInitialLoad = reason == 'initial_load';
      final editCandidateLimit = isManualRefresh
          ? 32
          : isInitialLoad
          ? 24
          : 16;
      final preferBotOutput =
          activeThreadShouldUseAgentSubchatUi || isLikelyAgentRoom(room);
      editHydrationStrategy = preferBotOutput
          ? 'visible_bot_output_full_history_parallel'
          : 'visible_full_history_parallel';
      editRelationLimit = isManualRefresh || isInitialLoad ? 100 : 50;
      editRelationMaxPages = isManualRefresh
          ? 12
          : isInitialLoad
          ? 8
          : 2;
      editHydrationParallelism = isManualRefresh || isInitialLoad ? 4 : 3;
      final visibleCandidateIds = timeline.events
          .filterByVisibleInGui(threadId: threadId)
          .map((event) => event.eventId);
      editRawThreadRelationCandidateEvents = threadRelationEventIds.length;
      editRawFullHistoryCandidateEvents = <String>{
        threadId,
        ...threadRelationEventIds,
        ...visibleCandidateIds,
      }.take(editCandidateLimit).length;
      final editCandidateSelection = _selectEditHydrationCandidates(
        timeline,
        threadId: threadId,
        candidateLimit: editCandidateLimit,
      );
      final editHydrationCandidates = editCandidateSelection.candidates;
      editCandidateCount = editHydrationCandidates.length;
      editVisibleEventsConsidered =
          editCandidateSelection.visibleEventsConsidered;
      editSkippedThreadRoot = editCandidateSelection.skippedThreadRoot;
      editSkippedOwnSender = editCandidateSelection.skippedOwnSender;
      editSkippedNonMessage = editCandidateSelection.skippedNonMessage;
      editSkippedNativeResponse = editCandidateSelection.skippedNativeResponse;
      editSkippedRedacted = editCandidateSelection.skippedRedacted;
      editSkippedDuplicate = editCandidateSelection.skippedDuplicate;
      editSkippedOverLimit = editCandidateSelection.skippedOverLimit;
      nativeResponseSummary = _summarizeNativeResponses(
        timeline.events,
        threadId: threadId,
      );

      _logSubchatTiming('mellon.subchat_timing.edit_hydrate_start', {
        'thread_root_event_id': threadId,
        'reason': reason,
        'strategy': editHydrationStrategy,
        'candidate_events': editCandidateCount,
        'candidate_limit': editCandidateLimit,
        'raw_thread_relation_candidate_events':
            editRawThreadRelationCandidateEvents,
        'raw_full_history_candidate_events': editRawFullHistoryCandidateEvents,
        'visible_events_considered': editVisibleEventsConsidered,
        'skipped_thread_root_candidates': editSkippedThreadRoot,
        'skipped_own_sender_candidates': editSkippedOwnSender,
        'skipped_non_message_candidates': editSkippedNonMessage,
        'skipped_native_response_candidates': editSkippedNativeResponse,
        'skipped_redacted_candidates': editSkippedRedacted,
        'skipped_duplicate_candidates': editSkippedDuplicate,
        'skipped_over_limit_candidates': editSkippedOverLimit,
        'relation_limit': editRelationLimit,
        'relation_max_pages': editRelationMaxPages,
        'parallelism': editHydrationParallelism,
        'select_best_recent_edit_only': false,
        ...nativeResponseSummary.toLogFields(),
      });
      final editHydrationWatch = Stopwatch()..start();
      final editStats = await _hydrateEditRelationsForEvents(
        timeline,
        editHydrationCandidates,
        relationLimit: editRelationLimit,
        maxRelationPages: editRelationMaxPages,
        parallelism: editHydrationParallelism,
        threadRootEventId: threadId,
        reason: reason,
        keepHydrating: keepHydrating,
      );
      editHydrationElapsedMs = editHydrationWatch.elapsedMilliseconds;
      editCandidateCount = editStats.candidateEvents;
      editFetched = editStats.fetched;
      editInserted = editStats.inserted;
      editUpdated = editStats.updated;
      editIgnored = editStats.ignored;
      editEncryptedFetched = editStats.encryptedFetched;
      editDecrypted = editStats.decrypted;
      editUndecrypted = editStats.undecrypted;
      editRelationPages = editStats.relationPages;
      editRelationsWithMore = editStats.relationsWithMore;
      editEventsWithValidEdit = editStats.eventsWithValidEdit;
      editEventsWithoutValidEdit = editStats.eventsWithoutValidEdit;
      editEventsExhausted = editStats.eventsExhausted;
      editMissingParentEvents = editStats.missingParentEvents;
      editValidEvents = editStats.validEditEvents;
      editSkippedNonEditRelations = editStats.skippedNonEditRelations;
      editSkippedWrongSender = editStats.skippedWrongSender;
      editSkippedInvalidType = editStats.skippedInvalidType;
      editSkippedInvalidContent = editStats.skippedInvalidContent;
      editRelationRequestElapsedMs = editStats.relationRequestElapsedMs;
      editEventDecodeElapsedMs = editStats.eventDecodeElapsedMs;
      editDecryptElapsedMs = editStats.decryptElapsedMs;
      editUpsertElapsedMs = editStats.upsertElapsedMs;
      editHydrationParallelism = editStats.parallelism;
      editHydrationParallelBatches = editStats.parallelBatches;
      editSlowestEventId = editStats.slowestEventId;
      editSlowestEventElapsedMs = editStats.slowestEventElapsedMs;
      editSlowestEventFetched = editStats.slowestEventFetched;
      editSlowestEventValid = editStats.slowestEventValid;
      editSlowestEventRelationPages = editStats.slowestEventRelationPages;
      editSlowestEventRelationsWithMore =
          editStats.slowestEventRelationsWithMore;
      editSlowestEventRelationRequestElapsedMs =
          editStats.slowestEventRelationRequestElapsedMs;
      editSlowestEventDecryptElapsedMs = editStats.slowestEventDecryptElapsedMs;
      editSlowestEventUpsertElapsedMs = editStats.slowestEventUpsertElapsedMs;
      nativeResponseSummary = _summarizeNativeResponses(
        timeline.events,
        threadId: threadId,
      );
      _logSubchatTiming('mellon.subchat_timing.edit_hydrate_done', {
        'thread_root_event_id': threadId,
        'reason': reason,
        'outcome': editStats.aborted ? timingOutcome : 'completed',
        'elapsed_ms': editHydrationElapsedMs,
        'strategy': editHydrationStrategy,
        'candidate_events': editCandidateCount,
        'relation_events': editFetched,
        'valid_edit_events': editValidEvents,
        'inserted_events': editInserted,
        'updated_events': editUpdated,
        'ignored_events': editIgnored,
        'encrypted_fetched_events': editEncryptedFetched,
        'decrypted_events': editDecrypted,
        'undecrypted_events': editUndecrypted,
        'relation_pages': editRelationPages,
        'relations_with_more': editRelationsWithMore,
        'parallelism': editHydrationParallelism,
        'parallel_batches': editHydrationParallelBatches,
        'raw_thread_relation_candidate_events':
            editRawThreadRelationCandidateEvents,
        'raw_full_history_candidate_events': editRawFullHistoryCandidateEvents,
        'visible_events_considered': editVisibleEventsConsidered,
        'skipped_thread_root_candidates': editSkippedThreadRoot,
        'skipped_own_sender_candidates': editSkippedOwnSender,
        'skipped_non_message_candidates': editSkippedNonMessage,
        'skipped_redacted_candidates': editSkippedRedacted,
        'skipped_duplicate_candidates': editSkippedDuplicate,
        'skipped_over_limit_candidates': editSkippedOverLimit,
        'events_with_valid_edit': editEventsWithValidEdit,
        'events_without_valid_edit': editEventsWithoutValidEdit,
        'events_exhausted': editEventsExhausted,
        'missing_parent_events': editMissingParentEvents,
        'skipped_non_edit_relations': editSkippedNonEditRelations,
        'skipped_wrong_sender': editSkippedWrongSender,
        'skipped_invalid_type': editSkippedInvalidType,
        'skipped_invalid_content': editSkippedInvalidContent,
        'relation_request_elapsed_ms': editRelationRequestElapsedMs,
        'event_decode_elapsed_ms': editEventDecodeElapsedMs,
        'decrypt_elapsed_ms': editDecryptElapsedMs,
        'upsert_elapsed_ms': editUpsertElapsedMs,
        'slowest_event_id': editSlowestEventId,
        'slowest_event_elapsed_ms': editSlowestEventElapsedMs,
        'slowest_event_relation_events': editSlowestEventFetched,
        'slowest_event_valid_edit_events': editSlowestEventValid,
        'slowest_event_relation_pages': editSlowestEventRelationPages,
        'slowest_event_relations_with_more': editSlowestEventRelationsWithMore,
        'slowest_event_relation_request_elapsed_ms':
            editSlowestEventRelationRequestElapsedMs,
        'slowest_event_decrypt_elapsed_ms': editSlowestEventDecryptElapsedMs,
        'slowest_event_upsert_elapsed_ms': editSlowestEventUpsertElapsedMs,
        ...nativeResponseSummary.toLogFields(),
      });
      if (editStats.aborted) return;
      if (!keepHydrating('aborted_after_edit_relations_fetch')) return;
      inserted += editInserted;
      updated += editUpdated;
      encryptedFetched += editEncryptedFetched;
      decrypted += editDecrypted;
      undecrypted += editUndecrypted;

      timeline.requestKeys(onlineKeyBackupOnly: false);

      if (!keepHydrating('aborted_after_key_request')) return;

      final visibleEvents = timeline.events.filterByVisibleInGui(
        threadId: threadId,
      );
      final latestVisibleEvent = visibleEvents.firstOrNull;
      final latestDisplayEvent = latestVisibleEvent?.getMellonDisplayEvent(
        timeline,
      );
      nativeResponseSummary = _summarizeNativeResponses(
        timeline.events,
        threadId: threadId,
      );
      DevLogSink.subchatRoute('mellon.subchat.native_response_summary', {
        'room_id': roomId,
        'thread_root_event_id': threadId,
        'conversation_key': '$roomId:thread:$threadId',
        'reason': reason,
        'timeline_events': timeline.events.length,
        'visible_events': visibleEvents.length,
        'edit_skipped_native_response_candidates': editSkippedNativeResponse,
        ...nativeResponseSummary.toLogFields(),
      });
      DevLogSink.subchatRoute('mellon.subchat.thread_hydrate_done', {
        'room_id': roomId,
        'thread_root_event_id': threadId,
        'conversation_key': '$roomId:thread:$threadId',
        'reason': reason,
        'fetched_events': fetched,
        'inserted_events': inserted,
        'updated_events': updated,
        'encrypted_fetched_events': encryptedFetched,
        'decrypted_events': decrypted,
        'undecrypted_events': undecrypted,
        'edit_relation_events': editFetched,
        'edit_valid_events': editValidEvents,
        'edit_inserted_events': editInserted,
        'edit_updated_events': editUpdated,
        'edit_ignored_events': editIgnored,
        'edit_encrypted_fetched_events': editEncryptedFetched,
        'edit_decrypted_events': editDecrypted,
        'edit_undecrypted_events': editUndecrypted,
        'edit_relation_pages': editRelationPages,
        'edit_relations_with_more': editRelationsWithMore,
        'edit_hydration_elapsed_ms': editHydrationElapsedMs,
        'edit_hydration_strategy': editHydrationStrategy,
        'edit_candidate_events': editCandidateCount,
        'edit_candidate_limit': editCandidateLimit,
        'edit_relation_limit': editRelationLimit,
        'edit_relation_max_pages': editRelationMaxPages,
        'edit_parallelism': editHydrationParallelism,
        'edit_parallel_batches': editHydrationParallelBatches,
        'edit_raw_thread_relation_candidate_events':
            editRawThreadRelationCandidateEvents,
        'edit_raw_full_history_candidate_events':
            editRawFullHistoryCandidateEvents,
        'edit_visible_events_considered': editVisibleEventsConsidered,
        'edit_skipped_thread_root_candidates': editSkippedThreadRoot,
        'edit_skipped_own_sender_candidates': editSkippedOwnSender,
        'edit_skipped_non_message_candidates': editSkippedNonMessage,
        'edit_skipped_native_response_candidates': editSkippedNativeResponse,
        'edit_skipped_redacted_candidates': editSkippedRedacted,
        'edit_skipped_duplicate_candidates': editSkippedDuplicate,
        'edit_skipped_over_limit_candidates': editSkippedOverLimit,
        'edit_events_with_valid_edit': editEventsWithValidEdit,
        'edit_events_without_valid_edit': editEventsWithoutValidEdit,
        'edit_events_exhausted': editEventsExhausted,
        'edit_missing_parent_events': editMissingParentEvents,
        'edit_skipped_non_edit_relations': editSkippedNonEditRelations,
        'edit_skipped_wrong_sender': editSkippedWrongSender,
        'edit_skipped_invalid_type': editSkippedInvalidType,
        'edit_skipped_invalid_content': editSkippedInvalidContent,
        'edit_relation_request_elapsed_ms': editRelationRequestElapsedMs,
        'edit_event_decode_elapsed_ms': editEventDecodeElapsedMs,
        'edit_decrypt_elapsed_ms': editDecryptElapsedMs,
        'edit_upsert_elapsed_ms': editUpsertElapsedMs,
        'edit_slowest_event_id': editSlowestEventId,
        'edit_slowest_event_elapsed_ms': editSlowestEventElapsedMs,
        'edit_slowest_event_relation_events': editSlowestEventFetched,
        'edit_slowest_event_valid_edit_events': editSlowestEventValid,
        'edit_slowest_event_relation_pages': editSlowestEventRelationPages,
        'edit_slowest_event_relations_with_more':
            editSlowestEventRelationsWithMore,
        'edit_slowest_event_relation_request_elapsed_ms':
            editSlowestEventRelationRequestElapsedMs,
        'edit_slowest_event_decrypt_elapsed_ms':
            editSlowestEventDecryptElapsedMs,
        'edit_slowest_event_upsert_elapsed_ms': editSlowestEventUpsertElapsedMs,
        'thread_relation_limit': relationPageLimit,
        'thread_relation_max_pages': relationMaxPages,
        'timeline_events_before': beforeEvents,
        'timeline_events_after': timeline.events.length,
        'visible_events_before': beforeVisible,
        'visible_events_after': visibleEvents.length,
        'latest_visible_event_id': latestVisibleEvent?.eventId,
        'latest_visible_body_length': latestVisibleEvent?.body.length,
        'latest_display_body_length': latestDisplayEvent?.body.length,
        'latest_visible_edit_count': latestVisibleEvent
            ?.aggregatedEvents(timeline, RelationshipTypes.edit)
            .length,
        'latest_display_ai_status':
            latestDisplayEvent?.content.aiStreamContent?.status.name,
        ...nativeResponseSummary.toLogFields(),
        'newest_fetched_event_id': newestFetchedEvent?.eventId,
        'has_more_thread_relations': nextBatch != null,
        'allow_new_event': timeline.allowNewEvent,
        'can_request_future': timeline.canRequestFuture,
        'elapsed_ms': timingWatch.elapsedMilliseconds,
      });

      _storeSubchatHydrationCache(timeline, threadId, reason: reason);
      if (inserted > 0 || updated > 0) {
        _refreshBotRunningState();
        setState(() {});
      }
    } catch (e, s) {
      timingOutcome = 'error';
      Logs().w('Unable to hydrate thread timeline $threadId', e, s);
      DevLogSink.subchatRoute('mellon.subchat.thread_hydrate_error', {
        'room_id': roomId,
        'thread_root_event_id': threadId,
        'conversation_key': '$roomId:thread:$threadId',
        'reason': reason,
        'error': e.toString(),
        'elapsed_ms': timingWatch.elapsedMilliseconds,
        ...nativeResponseSummary.toLogFields(),
      });
    } finally {
      _threadHydrationInFlight = false;
      if (showInitialLoading) {
        _setInitialSubchatHydrationLoading(
          false,
          threadId: threadId,
          reason: reason,
        );
      } else if (mounted) {
        setState(() {});
      }
      nativeResponseSummary = _summarizeNativeResponses(
        timeline.events,
        threadId: threadId,
      );
      _logSubchatTiming('mellon.subchat_timing.thread_hydrate_end', {
        'thread_root_event_id': threadId,
        'reason': reason,
        'outcome': timingOutcome,
        'elapsed_ms': timingWatch.elapsedMilliseconds,
        'fetched_events': fetched,
        'inserted_events': inserted,
        'updated_events': updated,
        'encrypted_fetched_events': encryptedFetched,
        'decrypted_events': decrypted,
        'undecrypted_events': undecrypted,
        'edit_relation_events': editFetched,
        'edit_valid_events': editValidEvents,
        'edit_inserted_events': editInserted,
        'edit_updated_events': editUpdated,
        'edit_ignored_events': editIgnored,
        'edit_relation_pages': editRelationPages,
        'edit_relations_with_more': editRelationsWithMore,
        'edit_hydration_elapsed_ms': editHydrationElapsedMs,
        'edit_hydration_strategy': editHydrationStrategy,
        'edit_candidate_events': editCandidateCount,
        'edit_relation_limit': editRelationLimit,
        'edit_relation_max_pages': editRelationMaxPages,
        'edit_parallelism': editHydrationParallelism,
        'edit_parallel_batches': editHydrationParallelBatches,
        'edit_raw_thread_relation_candidate_events':
            editRawThreadRelationCandidateEvents,
        'edit_raw_full_history_candidate_events':
            editRawFullHistoryCandidateEvents,
        'edit_visible_events_considered': editVisibleEventsConsidered,
        'edit_skipped_thread_root_candidates': editSkippedThreadRoot,
        'edit_skipped_own_sender_candidates': editSkippedOwnSender,
        'edit_skipped_non_message_candidates': editSkippedNonMessage,
        'edit_skipped_native_response_candidates': editSkippedNativeResponse,
        'edit_skipped_redacted_candidates': editSkippedRedacted,
        'edit_skipped_duplicate_candidates': editSkippedDuplicate,
        'edit_skipped_over_limit_candidates': editSkippedOverLimit,
        'edit_events_with_valid_edit': editEventsWithValidEdit,
        'edit_events_without_valid_edit': editEventsWithoutValidEdit,
        'edit_events_exhausted': editEventsExhausted,
        'edit_missing_parent_events': editMissingParentEvents,
        'edit_skipped_non_edit_relations': editSkippedNonEditRelations,
        'edit_skipped_wrong_sender': editSkippedWrongSender,
        'edit_skipped_invalid_type': editSkippedInvalidType,
        'edit_skipped_invalid_content': editSkippedInvalidContent,
        'edit_relation_request_elapsed_ms': editRelationRequestElapsedMs,
        'edit_event_decode_elapsed_ms': editEventDecodeElapsedMs,
        'edit_decrypt_elapsed_ms': editDecryptElapsedMs,
        'edit_upsert_elapsed_ms': editUpsertElapsedMs,
        'edit_slowest_event_id': editSlowestEventId,
        'edit_slowest_event_elapsed_ms': editSlowestEventElapsedMs,
        'edit_slowest_event_relation_events': editSlowestEventFetched,
        'edit_slowest_event_valid_edit_events': editSlowestEventValid,
        'edit_slowest_event_relation_pages': editSlowestEventRelationPages,
        'edit_slowest_event_relations_with_more':
            editSlowestEventRelationsWithMore,
        'edit_slowest_event_relation_request_elapsed_ms':
            editSlowestEventRelationRequestElapsedMs,
        'edit_slowest_event_decrypt_elapsed_ms':
            editSlowestEventDecryptElapsedMs,
        'edit_slowest_event_upsert_elapsed_ms': editSlowestEventUpsertElapsedMs,
        'timeline_events_before': beforeEvents,
        'timeline_events_after': timeline.events.length,
        'visible_events_before': beforeVisible,
        'visible_events_after': timeline.events
            .filterByVisibleInGui(threadId: threadId)
            .length,
        'has_more_thread_relations': nextBatch != null,
        ...nativeResponseSummary.toLogFields(),
      });
    }
  }

  void _updateScrollController() {
    if (!mounted) {
      return;
    }
    if (!scrollController.hasClients) return;
    if (timeline?.allowNewEvent == false ||
        scrollController.position.pixels > 0 && _scrolledUp == false) {
      setState(() => _scrolledUp = true);
    } else if (scrollController.position.pixels <= 0 && _scrolledUp == true) {
      setState(() => _scrolledUp = false);
      setReadMarker();
    }
  }

  void _loadDraft() {
    final prefs = Matrix.of(context).store;
    final draft = prefs.getString(_draftKey) ?? '';
    sendController.value = TextEditingValue(
      text: draft,
      selection: TextSelection.collapsed(offset: draft.length),
    );
    _inputTextIsEmpty = draft.isEmpty;
  }

  void _shareItems([dynamic _]) {
    final shareItems = widget.shareItems;
    if (shareItems == null || shareItems.isEmpty) return;
    if (!room.otherPartyCanReceiveMessages) {
      final theme = Theme.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: theme.colorScheme.errorContainer,
          closeIconColor: theme.colorScheme.onErrorContainer,
          content: Text(
            L10n.of(context).otherPartyNotLoggedIn,
            style: TextStyle(color: theme.colorScheme.onErrorContainer),
          ),
          showCloseIcon: true,
        ),
      );
      return;
    }
    for (final item in shareItems) {
      if (item is FileShareItem) continue;
      if (item is TextShareItem) room.sendTextEvent(item.value);
      if (item is ContentShareItem) room.sendEvent(item.value);
    }
    final files = shareItems
        .whereType<FileShareItem>()
        .map((item) => item.value)
        .toList();
    if (files.isEmpty) return;
    showAdaptiveDialog(
      context: context,
      builder: (c) => SendFileDialog(
        files: files,
        room: room,
        outerContext: context,
        threadRootEventId: activeThreadId,
        threadLastEventId: threadLastEventId,
      ),
    );
  }

  KeyEventResult _customEnterKeyHandling(FocusNode node, KeyEvent evt) {
    if (!HardwareKeyboard.instance.isShiftPressed &&
        evt.logicalKey.keyLabel == 'Enter' &&
        AppSettings.sendOnEnter.value) {
      if (evt is KeyDownEvent) {
        send();
      }
      return KeyEventResult.handled;
    } else if (evt.logicalKey.keyLabel == 'Enter' && evt is KeyDownEvent) {
      final currentLineNum =
          sendController.text
              .substring(0, sendController.selection.baseOffset)
              .split('\n')
              .length -
          1;
      final currentLine = sendController.text.split('\n')[currentLineNum];

      for (final pattern in [
        '- [ ] ',
        '- [x] ',
        '* [ ] ',
        '* [x] ',
        '- ',
        '* ',
        '+ ',
      ]) {
        if (currentLine.startsWith(pattern)) {
          if (currentLine == pattern) {
            return KeyEventResult.ignored;
          }
          sendController.text += '\n$pattern';
          return KeyEventResult.handled;
        }
      }

      return KeyEventResult.ignored;
    } else {
      return KeyEventResult.ignored;
    }
  }

  @override
  void initState() {
    inputFocus = FocusNode(onKeyEvent: _customEnterKeyHandling);
    activeThreadId = widget.threadId;

    scrollController.addListener(_updateScrollController);
    inputFocus.addListener(_inputFocusListener);

    _loadDraft();
    WidgetsBinding.instance.addPostFrameCallback(_shareItems);
    super.initState();
    _displayChatDetailsColumn = ValueNotifier(
      AppSettings.displayChatDetailsColumn.value,
    );

    sendingClient = widget.room.client;
    final matrix = Matrix.of(context);
    if (matrix.client != sendingClient) {
      matrix.setActiveClient(sendingClient);
    }
    final initialThreadId = activeThreadId;
    _logChatStartup('mellon.chat_startup.init', {
      'uri_path': Uri.base.path,
      'uri_query': Uri.base.query,
      'last_event_id': widget.room.lastEvent?.eventId,
      'has_new_messages': widget.room.hasNewMessages,
      'fully_read_event_id': widget.room.fullyRead,
    });
    if (initialThreadId != null) {
      DevLogSink.subchatRoute('mellon.subchat.open_route', {
        'room_id': roomId,
        'thread_root_event_id': initialThreadId,
        'conversation_key': conversationKey,
        'widget_thread_id': widget.threadId,
        'initial_event_id': widget.eventId,
        'room_client_user_id': room.client.userID,
        'widget_room_client_user_id': widget.room.client.userID,
        'sending_client_user_id': sendingClient.userID,
        'agent_user_id': room.directChatMatrixID,
        'is_agent_room': isLikelyAgentRoom(room),
      });
      _logSubchatTiming('mellon.subchat_timing.open_route', {
        'thread_root_event_id': initialThreadId,
        'uri_path': Uri.base.path,
        'uri_query': Uri.base.query,
      });
    }
    final lastEventThreadId =
        room.lastEvent?.relationshipType == RelationshipTypes.thread
        ? room.lastEvent?.relationshipEventId
        : null;
    readMarkerEventId = room.hasNewMessages
        ? lastEventThreadId ?? room.fullyRead
        : '';
    WidgetsBinding.instance.addObserver(this);
    _tryLoadTimeline();
  }

  final Set<String> expandedEventIds = {};

  void expandEventsFrom(Event event, bool expand) {
    final events = timeline!.events.filterByVisibleInGui(
      threadId: activeThreadId,
    );
    final start = events.indexOf(event);
    setState(() {
      for (var i = start; i < events.length; i++) {
        final event = events[i];
        if (!event.isCollapsedState) return;
        if (expand) {
          expandedEventIds.add(event.eventId);
        } else {
          expandedEventIds.remove(event.eventId);
        }
      }
    });
  }

  void _tryLoadTimeline() async {
    final startupWatch = Stopwatch()..start();
    void logStep(String event, [Map<String, Object?> fields = const {}]) {
      _logChatStartup(event, {
        'elapsed_ms': startupWatch.elapsedMilliseconds,
        ...fields,
      });
    }

    final initialEventId = widget.eventId;
    final initialThreadId = activeThreadId;
    final initialEventContextId =
        initialEventId ??
        (activeThreadShouldUseAgentSubchatUi ? null : initialThreadId);
    final openWatch = initialThreadId == null ? null : (Stopwatch()..start());
    void logSubchatTiming(
      String event, [
      Map<String, Object?> fields = const {},
    ]) {
      if (initialThreadId == null || openWatch == null) return;
      DevLogSink.subchatTiming(event, {
        'room_id': roomId,
        'thread_root_event_id': initialThreadId,
        'active_thread_id': activeThreadId,
        'conversation_key': '$roomId:thread:$initialThreadId',
        'widget_thread_id': widget.threadId,
        'initial_event_id': initialEventId,
        'initial_event_context_id': initialEventContextId,
        'uses_agent_subchat_ui': activeThreadShouldUseAgentSubchatUi,
        'is_agent_room': isLikelyAgentRoom(widget.room),
        'elapsed_ms': openWatch.elapsedMilliseconds,
        'timeline_events': timeline?.events.length,
        'visible_events': _visibleTimelineEventCount(),
        ...fields,
      });
    }

    logSubchatTiming('mellon.subchat_timing.open_start');
    logStep('mellon.chat_startup.try_load_start', {
      'initial_thread_id': initialThreadId,
      'initial_event_context_id': initialEventContextId,
      'uses_agent_subchat_ui': activeThreadShouldUseAgentSubchatUi,
      'read_marker_event_id': readMarkerEventId,
    });
    loadTimelineFuture = _getTimeline(eventContextId: initialEventContextId);
    try {
      await loadTimelineFuture;
      if (!mounted || activeThreadId != initialThreadId || timeline == null) {
        logSubchatTiming('mellon.subchat_timing.open_abort', {
          'reason': !mounted
              ? 'unmounted'
              : activeThreadId != initialThreadId
              ? 'thread_changed'
              : 'missing_timeline',
        });
        logStep('mellon.chat_startup.try_load_aborted', {
          'reason': !mounted
              ? 'unmounted'
              : activeThreadId != initialThreadId
              ? 'thread_changed'
              : 'missing_timeline',
        });
        return;
      }
      logStep('mellon.chat_startup.timeline_future_done', {
        'allow_new_event': timeline?.allowNewEvent,
        'can_request_future': timeline?.canRequestFuture,
        'can_request_history': timeline?.canRequestHistory,
      });
      logSubchatTiming('mellon.subchat_timing.open_timeline_ready', {
        'allow_new_event': timeline?.allowNewEvent,
        'can_request_future': timeline?.canRequestFuture,
        'can_request_history': timeline?.canRequestHistory,
      });
      if (initialThreadId != null) {
        final cacheRestore = _restoreSubchatHydrationCache(
          timeline!,
          initialThreadId,
          reason: 'initial_load',
        );
        if (cacheRestore.restoredVisibleEvents) {
          _refreshBotRunningState();
          setState(() {});
          logStep('mellon.chat_startup.initial_hydrate_skip_cache', {
            'cache_outcome': cacheRestore.outcome,
            'cache_age_ms': cacheRestore.cacheAgeMs,
            'cache_inserted_events': cacheRestore.insertedEvents,
            'cache_updated_events': cacheRestore.updatedEvents,
            'cache_visible_events_after_restore':
                cacheRestore.visibleEventsAfter,
          });
          logSubchatTiming(
            'mellon.subchat_timing.open_initial_hydrate_skip_cache',
            {
              'cache_outcome': cacheRestore.outcome,
              'cache_age_ms': cacheRestore.cacheAgeMs,
              'cache_inserted_events': cacheRestore.insertedEvents,
              'cache_updated_events': cacheRestore.updatedEvents,
              'cache_visible_events_after_restore':
                  cacheRestore.visibleEventsAfter,
            },
          );
          final cacheAgeMs = cacheRestore.cacheAgeMs;
          final shouldRefreshCache =
              cacheAgeMs == null ||
              cacheAgeMs > _subchatHydrationCacheRefreshGrace.inMilliseconds;
          if (shouldRefreshCache) {
            _scheduleActiveThreadHydration('cache_refresh');
          } else {
            logSubchatTiming(
              'mellon.subchat_timing.open_cache_refresh_skip_fresh',
              {
                'cache_age_ms': cacheAgeMs,
                'cache_refresh_grace_ms':
                    _subchatHydrationCacheRefreshGrace.inMilliseconds,
              },
            );
          }
        } else {
          logStep('mellon.chat_startup.initial_hydrate_start', {
            'cache_outcome': cacheRestore.outcome,
          });
          await _hydrateActiveThreadTimeline(reason: 'initial_load');
          if (!mounted ||
              activeThreadId != initialThreadId ||
              timeline == null) {
            logSubchatTiming('mellon.subchat_timing.open_abort', {
              'reason': !mounted
                  ? 'unmounted_after_hydrate'
                  : activeThreadId != initialThreadId
                  ? 'thread_changed_after_hydrate'
                  : 'missing_timeline_after_hydrate',
            });
            logStep('mellon.chat_startup.try_load_aborted', {
              'reason': !mounted
                  ? 'unmounted_after_hydrate'
                  : activeThreadId != initialThreadId
                  ? 'thread_changed_after_hydrate'
                  : 'missing_timeline_after_hydrate',
            });
            return;
          }
          logStep('mellon.chat_startup.initial_hydrate_done');
          logSubchatTiming('mellon.subchat_timing.open_initial_hydrate_done');
        }
      }

      // If the initial timeline has no visible events (e.g. flooded with
      // edit-stream updates), auto-fetch history until at least one
      // visible event appears. Caps at 5 rounds to avoid infinite loops.
      var activeTimeline = timeline;
      if (activeTimeline == null) return;
      var visibleEvents = activeTimeline.events.filterByVisibleInGui(
        threadId: activeThreadId,
      );
      var fetchRounds = 0;
      while (visibleEvents.isEmpty &&
          fetchRounds < 5 &&
          activeTimeline.canRequestHistory) {
        logStep('mellon.chat_startup.history_autofetch_start', {
          'fetch_round': fetchRounds + 1,
          'loaded_events': activeTimeline.events.length,
        });
        Logs().v(
          'No visible events after ${activeTimeline.events.length} loaded — '
          'requesting more history (round ${fetchRounds + 1})',
        );
        await activeTimeline.requestHistory(historyCount: _loadHistoryCount);
        if (!mounted ||
            activeThreadId != initialThreadId ||
            timeline != activeTimeline) {
          logSubchatTiming('mellon.subchat_timing.open_abort', {
            'reason': !mounted
                ? 'unmounted_after_history'
                : activeThreadId != initialThreadId
                ? 'thread_changed_after_history'
                : 'timeline_replaced_after_history',
            'fetch_round': fetchRounds + 1,
          });
          logStep('mellon.chat_startup.try_load_aborted', {
            'reason': !mounted
                ? 'unmounted_after_history'
                : activeThreadId != initialThreadId
                ? 'thread_changed_after_history'
                : 'timeline_replaced_after_history',
          });
          return;
        }
        visibleEvents = activeTimeline.events.filterByVisibleInGui(
          threadId: activeThreadId,
        );
        fetchRounds++;
        logStep('mellon.chat_startup.history_autofetch_done', {
          'fetch_round': fetchRounds,
          'loaded_events': activeTimeline.events.length,
          'visible_events_after_round': visibleEvents.length,
          'can_request_history': activeTimeline.canRequestHistory,
        });
      }
      if (fetchRounds > 0) {
        Logs().v(
          'Auto-fetched $fetchRounds rounds — '
          '${visibleEvents.length} visible events now',
        );
      }

      // Initialize model catalog (scan timeline + auto-fetch if needed)
      logStep('mellon.chat_startup.model_catalog_init_start');
      _initModelCatalog();
      if (!mounted || activeThreadId != initialThreadId) {
        logSubchatTiming('mellon.subchat_timing.open_abort', {
          'reason': !mounted
              ? 'unmounted_after_model_catalog_init'
              : 'thread_changed_after_model_catalog_init',
        });
        return;
      }
      logStep('mellon.chat_startup.model_catalog_init_done', {
        'has_model_catalog': modelCatalog != null,
        'model_provider_count': modelCatalog?.catalog.length,
      });
      logSubchatTiming('mellon.subchat_timing.open_model_catalog_done', {
        'has_model_catalog': modelCatalog != null,
        'model_provider_count': modelCatalog?.catalog.length,
      });

      // We launched the chat with a given initial event ID:
      if (initialEventId != null) {
        logStep('mellon.chat_startup.scroll_initial_event', {
          'scroll_event_id': initialEventId,
        });
        scrollToEventId(initialEventId);
        logSubchatTiming('mellon.subchat_timing.open_done', {
          'finish_reason': 'scrolled_to_initial_event',
        });
        return;
      }

      activeTimeline = timeline;
      if (activeTimeline == null) {
        logSubchatTiming('mellon.subchat_timing.open_abort', {
          'reason': 'missing_timeline_before_read_marker',
        });
        return;
      }
      var readMarkerEventIndex = readMarkerEventId.isEmpty
          ? -1
          : activeTimeline.events
                .filterByVisibleInGui(
                  exceptionEventId: readMarkerEventId,
                  threadId: activeThreadId,
                )
                .indexWhere((e) => e.eventId == readMarkerEventId);

      // Read marker is existing but not found in first events. Try a single
      // requestHistory call before opening timeline on event context:
      if (readMarkerEventId.isNotEmpty && readMarkerEventIndex == -1) {
        logStep('mellon.chat_startup.read_marker_history_start', {
          'read_marker_event_id': readMarkerEventId,
        });
        await activeTimeline.requestHistory(historyCount: _loadHistoryCount);
        if (!mounted ||
            activeThreadId != initialThreadId ||
            timeline != activeTimeline) {
          logSubchatTiming('mellon.subchat_timing.open_abort', {
            'reason': !mounted
                ? 'unmounted_after_read_marker_history'
                : activeThreadId != initialThreadId
                ? 'thread_changed_after_read_marker_history'
                : 'timeline_replaced_after_read_marker_history',
          });
          logStep('mellon.chat_startup.try_load_aborted', {
            'reason': !mounted
                ? 'unmounted_after_read_marker_history'
                : activeThreadId != initialThreadId
                ? 'thread_changed_after_read_marker_history'
                : 'timeline_replaced_after_read_marker_history',
          });
          return;
        }
        readMarkerEventIndex = activeTimeline.events
            .filterByVisibleInGui(
              exceptionEventId: readMarkerEventId,
              threadId: activeThreadId,
            )
            .indexWhere((e) => e.eventId == readMarkerEventId);
        logStep('mellon.chat_startup.read_marker_history_done', {
          'read_marker_event_index': readMarkerEventIndex,
          'loaded_events': timeline?.events.length,
        });
      }

      if (readMarkerEventIndex > 1) {
        Logs().v('Scroll up to visible event', readMarkerEventId);
        logStep('mellon.chat_startup.scroll_read_marker', {
          'read_marker_event_id': readMarkerEventId,
          'read_marker_event_index': readMarkerEventIndex,
        });
        scrollToEventId(readMarkerEventId, highlightEvent: false);
        logSubchatTiming('mellon.subchat_timing.open_done', {
          'finish_reason': 'scrolled_to_read_marker',
          'fetch_rounds': fetchRounds,
          'read_marker_event_index': readMarkerEventIndex,
        });
        return;
      } else if (readMarkerEventId.isNotEmpty && readMarkerEventIndex == -1) {
        logStep('mellon.chat_startup.show_scroll_banner', {
          'read_marker_event_id': readMarkerEventId,
        });
        _showScrollUpMaterialBanner(readMarkerEventId);
      }

      // Mark room as read on first visit if requirements are fulfilled
      setReadMarker();

      if (!mounted) {
        logSubchatTiming('mellon.subchat_timing.open_abort', {
          'reason': 'unmounted_before_done',
        });
        return;
      }
      logStep('mellon.chat_startup.try_load_done', {
        'fetch_rounds': fetchRounds,
        'read_marker_event_index': readMarkerEventIndex,
      });
      logSubchatTiming('mellon.subchat_timing.open_done', {
        'finish_reason': 'ready',
        'fetch_rounds': fetchRounds,
        'read_marker_event_index': readMarkerEventIndex,
      });
    } catch (e, s) {
      logSubchatTiming('mellon.subchat_timing.open_error', {
        'error': e.toString(),
      });
      logStep('mellon.chat_startup.try_load_error', {
        'error': e.toString(),
        'stack': s.toString().split('\n').take(8).join('\n'),
      });
      if (!mounted) return;
      ErrorReporter(context, 'Unable to load timeline').onErrorCallback(e, s);
    }
  }

  String? scrollUpBannerEventId;

  void discardScrollUpBannerEventId() {
    if (!mounted) return;
    setState(() {
      scrollUpBannerEventId = null;
    });
  }

  void _showScrollUpMaterialBanner(String eventId) {
    if (!mounted) return;
    setState(() {
      scrollUpBannerEventId = eventId;
    });
  }

  void updateView() {
    if (!mounted) return;
    setReadMarker();

    // Check latest events for model catalog data and ai_stream model info.
    // Model response events are intentionally hidden from the timeline UI, so
    // this scan uses conversation membership instead of visible-message filtering.
    for (final event in _modelMetadataEvents(limit: 6)) {
      _checkForModelCatalog(event);
      _checkForAiStreamModel(event);
    }

    _refreshBotRunningState();
    setState(() {});
  }

  Future<void>? loadTimelineFuture;

  int? animateInEventIndex;

  void onInsert(int i) {
    // setState will be called by updateView() anyway
    final timeline = this.timeline;
    final insertedEvent = timeline?.events.elementAtOrNull(i);
    _lastInsertedTimelineEventId = insertedEvent?.eventId;
    animateInEventIndex = null;
  }

  Future<void> _getTimeline({String? eventContextId}) async {
    final startupWatch = Stopwatch()..start();
    final originalEventContextId = eventContextId;
    void logStep(String event, [Map<String, Object?> fields = const {}]) {
      _logChatStartup(event, {
        'elapsed_ms': startupWatch.elapsedMilliseconds,
        'event_context_id': eventContextId,
        'original_event_context_id': originalEventContextId,
        ...fields,
      });
    }

    logStep('mellon.chat_startup.timeline_enter');
    _logSubchatTiming('mellon.subchat_timing.timeline_load_start', {
      'event_context_id': eventContextId,
      'original_event_context_id': originalEventContextId,
    });
    final client = Matrix.of(context).client;
    await client.roomsLoading;
    if (!mounted) {
      _logSubchatTiming('mellon.subchat_timing.timeline_load_abort', {
        'elapsed_ms': startupWatch.elapsedMilliseconds,
        'reason': 'unmounted_after_rooms_loading',
        'event_context_id': eventContextId,
        'original_event_context_id': originalEventContextId,
      });
      logStep('mellon.chat_startup.get_timeline_aborted', {
        'reason': 'unmounted_after_rooms_loading',
      });
      return;
    }
    logStep('mellon.chat_startup.rooms_loading_done');
    await client.accountDataLoading;
    if (!mounted) {
      _logSubchatTiming('mellon.subchat_timing.timeline_load_abort', {
        'elapsed_ms': startupWatch.elapsedMilliseconds,
        'reason': 'unmounted_after_account_data_loading',
        'event_context_id': eventContextId,
        'original_event_context_id': originalEventContextId,
      });
      logStep('mellon.chat_startup.get_timeline_aborted', {
        'reason': 'unmounted_after_account_data_loading',
      });
      return;
    }
    logStep('mellon.chat_startup.account_data_loading_done');
    _logSubchatTiming('mellon.subchat_timing.timeline_load_dependencies_done', {
      'elapsed_ms': startupWatch.elapsedMilliseconds,
      'event_context_id': eventContextId,
      'original_event_context_id': originalEventContextId,
    });
    if (eventContextId != null &&
        (!eventContextId.isValidMatrixId || eventContextId.sigil != '\$')) {
      logStep('mellon.chat_startup.invalid_event_context', {
        'invalid_event_context_id': eventContextId,
      });
      eventContextId = null;
    }
    try {
      final hadExistingTimeline = timeline != null;
      timeline?.cancelSubscriptions();
      logStep('mellon.chat_startup.get_timeline_start', {
        'had_existing_timeline': hadExistingTimeline,
      });
      _logSubchatTiming('mellon.subchat_timing.room_get_timeline_start', {
        'elapsed_ms': startupWatch.elapsedMilliseconds,
        'event_context_id': eventContextId,
        'original_event_context_id': originalEventContextId,
        'had_existing_timeline': hadExistingTimeline,
      });
      final loadedTimeline = await room.getTimeline(
        onUpdate: updateView,
        eventContextId: eventContextId,
        onInsert: onInsert,
        onNewEvent: _onTimelineNewEvent,
      );
      if (!mounted) {
        loadedTimeline.cancelSubscriptions();
        _logSubchatTiming('mellon.subchat_timing.timeline_load_abort', {
          'elapsed_ms': startupWatch.elapsedMilliseconds,
          'reason': 'unmounted_after_get_timeline',
          'event_context_id': eventContextId,
          'original_event_context_id': originalEventContextId,
          'loaded_events': loadedTimeline.events.length,
        });
        logStep('mellon.chat_startup.get_timeline_aborted', {
          'reason': 'unmounted_after_get_timeline',
          'loaded_events': loadedTimeline.events.length,
        });
        return;
      }
      timeline = loadedTimeline;
      _refreshBotRunningState();
      logStep('mellon.chat_startup.get_timeline_done', {
        'loaded_events': loadedTimeline.events.length,
        'allow_new_event': loadedTimeline.allowNewEvent,
        'can_request_future': loadedTimeline.canRequestFuture,
        'can_request_history': loadedTimeline.canRequestHistory,
      });
      _logSubchatTiming('mellon.subchat_timing.room_get_timeline_done', {
        'elapsed_ms': startupWatch.elapsedMilliseconds,
        'event_context_id': eventContextId,
        'original_event_context_id': originalEventContextId,
        'loaded_events': loadedTimeline.events.length,
        'allow_new_event': loadedTimeline.allowNewEvent,
        'can_request_future': loadedTimeline.canRequestFuture,
        'can_request_history': loadedTimeline.canRequestHistory,
      });
    } catch (e, s) {
      Logs().w('Unable to load timeline on event ID $eventContextId', e, s);
      _logSubchatTiming('mellon.subchat_timing.room_get_timeline_error', {
        'elapsed_ms': startupWatch.elapsedMilliseconds,
        'event_context_id': eventContextId,
        'original_event_context_id': originalEventContextId,
        'error': e.toString(),
      });
      logStep('mellon.chat_startup.get_timeline_error', {
        'error': e.toString(),
        'stack': s.toString().split('\n').take(8).join('\n'),
      });
      if (!mounted) return;
      try {
        logStep('mellon.chat_startup.get_timeline_fallback_start');
        _logSubchatTiming(
          'mellon.subchat_timing.room_get_timeline_fallback_start',
          {
            'elapsed_ms': startupWatch.elapsedMilliseconds,
            'event_context_id': eventContextId,
            'original_event_context_id': originalEventContextId,
          },
        );
        final fallbackTimeline = await room.getTimeline(
          onUpdate: updateView,
          onInsert: onInsert,
          onNewEvent: _onTimelineNewEvent,
        );
        if (!mounted) {
          fallbackTimeline.cancelSubscriptions();
          _logSubchatTiming('mellon.subchat_timing.timeline_load_abort', {
            'elapsed_ms': startupWatch.elapsedMilliseconds,
            'reason': 'unmounted_after_fallback_timeline',
            'event_context_id': eventContextId,
            'original_event_context_id': originalEventContextId,
            'loaded_events': fallbackTimeline.events.length,
          });
          logStep('mellon.chat_startup.get_timeline_aborted', {
            'reason': 'unmounted_after_fallback_timeline',
            'loaded_events': fallbackTimeline.events.length,
          });
          return;
        }
        timeline = fallbackTimeline;
        _refreshBotRunningState();
        logStep('mellon.chat_startup.get_timeline_fallback_done', {
          'loaded_events': fallbackTimeline.events.length,
          'allow_new_event': fallbackTimeline.allowNewEvent,
          'can_request_future': fallbackTimeline.canRequestFuture,
          'can_request_history': fallbackTimeline.canRequestHistory,
        });
        _logSubchatTiming(
          'mellon.subchat_timing.room_get_timeline_fallback_done',
          {
            'elapsed_ms': startupWatch.elapsedMilliseconds,
            'loaded_events': fallbackTimeline.events.length,
            'allow_new_event': fallbackTimeline.allowNewEvent,
            'can_request_future': fallbackTimeline.canRequestFuture,
            'can_request_history': fallbackTimeline.canRequestHistory,
          },
        );
      } catch (fallbackError, fallbackStackTrace) {
        _logSubchatTiming(
          'mellon.subchat_timing.room_get_timeline_fallback_error',
          {
            'elapsed_ms': startupWatch.elapsedMilliseconds,
            'error': fallbackError.toString(),
          },
        );
        logStep('mellon.chat_startup.get_timeline_fallback_error', {
          'error': fallbackError.toString(),
          'stack': fallbackStackTrace.toString().split('\n').take(8).join('\n'),
        });
        rethrow;
      }
      if (!mounted) return;
      if (eventContextId != null &&
          (e is TimeoutException || e is IOException)) {
        _showScrollUpMaterialBanner(eventContextId);
      } else if (e is TimeoutException || e is IOException) {
        logStep('mellon.chat_startup.scroll_banner_skipped_no_context', {
          'error_type': e.runtimeType.toString(),
        });
      }
    }
    final currentTimeline = timeline;
    if (!mounted || currentTimeline == null) {
      logStep('mellon.chat_startup.get_timeline_aborted', {
        'reason': !mounted ? 'unmounted_before_ready' : 'missing_timeline',
      });
      _logSubchatTiming('mellon.subchat_timing.timeline_load_abort', {
        'elapsed_ms': startupWatch.elapsedMilliseconds,
        'reason': !mounted ? 'unmounted_before_ready' : 'missing_timeline',
        'event_context_id': eventContextId,
        'original_event_context_id': originalEventContextId,
      });
      return;
    }
    currentTimeline.requestKeys(onlineKeyBackupOnly: false);
    if (room.markedUnread) room.markUnread(false);
    logStep('mellon.chat_startup.timeline_ready', {
      'loaded_events': currentTimeline.events.length,
      'allow_new_event': currentTimeline.allowNewEvent,
      'can_request_future': currentTimeline.canRequestFuture,
      'can_request_history': currentTimeline.canRequestHistory,
      'marked_unread': room.markedUnread,
    });
    _logSubchatTiming('mellon.subchat_timing.timeline_load_done', {
      'elapsed_ms': startupWatch.elapsedMilliseconds,
      'event_context_id': eventContextId,
      'original_event_context_id': originalEventContextId,
      'loaded_events': currentTimeline.events.length,
      'allow_new_event': currentTimeline.allowNewEvent,
      'can_request_future': currentTimeline.canRequestFuture,
      'can_request_history': currentTimeline.canRequestHistory,
      'marked_unread': room.markedUnread,
    });

    return;
  }

  String? scrollToEventIdMarker;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    if (!mounted) return;
    setReadMarker();
  }

  Future<void>? _setReadMarkerFuture;

  void setReadMarker({String? eventId}) {
    if (eventId?.isValidMatrixId == false) return;
    if (_setReadMarkerFuture != null) return;
    if (_scrolledUp) return;
    if (scrollUpBannerEventId != null) return;

    if (eventId == null &&
        !room.hasNewMessages &&
        room.notificationCount == 0) {
      return;
    }

    // Do not send read markers when app is not in foreground
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }

    final timeline = this.timeline;
    if (timeline == null || timeline.events.isEmpty) return;

    Logs().d('Set read marker...', eventId);
    // ignore: unawaited_futures
    _setReadMarkerFuture = timeline
        .setReadMarker(
          eventId: eventId,
          public: AppSettings.sendPublicReadReceipts.value,
        )
        .then((_) {
          _setReadMarkerFuture = null;
        });
    if (eventId == null || eventId == timeline.room.lastEvent?.eventId) {
      Matrix.of(context).backgroundPush?.cancelNotification(roomId);
    }
  }

  @override
  void dispose() {
    _logChatStartup('mellon.chat_startup.dispose');
    _threadHydrationDebounce?.cancel();
    timeline?.cancelSubscriptions();
    timeline = null;
    _botRunningNotifier.dispose();
    inputFocus.removeListener(_inputFocusListener);
    super.dispose();
  }

  TextEditingController sendController = TextEditingController();

  void setSendingClient(Client c) {
    // first cancel typing with the old sending client
    if (currentlyTyping) {
      // no need to have the setting typing to false be blocking
      typingCoolDown?.cancel();
      typingCoolDown = null;
      room.setTyping(false);
      currentlyTyping = false;
    }
    // then cancel the old timeline
    // fixes bug with read reciepts and quick switching
    loadTimelineFuture = _getTimeline(eventContextId: room.fullyRead).onError(
      ErrorReporter(
        context,
        'Unable to load timeline after changing sending Client',
      ).onErrorCallback,
    );

    // then set the new sending client
    setState(() => sendingClient = c);
  }

  void setActiveClient(Client c) => setState(() {
    Matrix.of(context).setActiveClient(c);
  });

  AIStreamContent? get activeAiStreamContent {
    final timeline = this.timeline;
    if (timeline == null) return null;
    return activeAiStreamContentForTimeline(
      timeline,
      threadRootEventId: activeThreadId,
    );
  }

  /// Whether the bot in this conversation is currently running.
  /// This is scoped to the active main chat or subchat via ai_stream metadata.
  bool get isBotRunning {
    return activeAiStreamContent != null;
  }

  void _refreshBotRunningState() {
    final running = isBotRunning;
    if (_botRunningNotifier.value != running) {
      _botRunningNotifier.value = running;
    }
  }

  /// Send /stop to abort the bot's current run.
  void stopBot() {
    room.sendTextEvent(
      '/stop',
      parseCommands: false,
      threadRootEventId: activeThreadId,
      threadLastEventId: threadLastEventId,
    );
  }

  Future<void> createAgentSubchat() async {
    final result = await showFutureLoadingDialog<String?>(
      context: context,
      future: () => room.sendEvent(
        buildAgentSubchatRootContent(agentUserId: room.directChatMatrixID),
        type: EventTypes.Message,
      ),
    );
    final eventId = result.result;
    if (eventId == null || !mounted) return;
    DevLogSink.subchatRoute('mellon.subchat.create_root_sent', {
      'room_id': roomId,
      'thread_root_event_id': eventId,
      'conversation_key': '$roomId:thread:$eventId',
      'is_agent_room': isLikelyAgentRoom(room),
      'agent_user_id': room.directChatMatrixID,
    });
    await upsertAgentSubchatIndexEntry(
      room: room,
      threadRootEventId: eventId,
      title: defaultAgentSubchatTitle,
      preview: defaultAgentSubchatTitle,
      createdAt: DateTime.now().toUtc(),
      updatedAt: DateTime.now().toUtc(),
      canRename: true,
      agentUserId: room.directChatMatrixID,
    );
    if (!mounted) return;
    enterThread(eventId);
  }

  Future<void> send() async {
    if (sendController.text.trim().isEmpty) return;

    // Intercept bare /model command — open picker instead of sending
    final trimmed = sendController.text.trim();
    if (trimmed == '/model' || trimmed == '/models') {
      sendController.clear();
      Matrix.of(context).store.remove(_draftKey);
      setState(() => _inputTextIsEmpty = true);
      openModelPicker();
      return;
    }

    _storeInputTimeoutTimer?.cancel();
    final prefs = Matrix.of(context).store;
    prefs.remove(_draftKey);
    var parseCommands = true;

    final commandMatch = RegExp(r'^\/(\w+)').firstMatch(sendController.text);
    if (commandMatch != null &&
        !sendingClient.commands.keys.contains(commandMatch[1]!.toLowerCase())) {
      final l10n = L10n.of(context);
      final dialogResult = await showOkCancelAlertDialog(
        context: context,
        title: l10n.commandInvalid,
        message: l10n.commandMissing(commandMatch[0]!),
        okLabel: l10n.sendAsText,
        cancelLabel: l10n.cancel,
      );
      if (dialogResult == OkCancelResult.cancel) return;
      parseCommands = false;
    }

    final outboundText = sendController.text;
    final outboundThreadId = activeThreadId;
    final outboundThreadLastEventId = threadLastEventId;
    DevLogSink.subchatRoute(
      outboundThreadId == null
          ? 'mellon.chat.send_text'
          : 'mellon.subchat.send_text',
      {
        'room_id': roomId,
        'conversation_key': conversationKey,
        'thread_root_event_id': outboundThreadId,
        'thread_last_event_id': outboundThreadLastEventId,
        'widget_thread_id': widget.threadId,
        'reply_event_id': replyEvent?.eventId,
        'edit_event_id': editEvent?.eventId,
        'room_client_user_id': room.client.userID,
        'widget_room_client_user_id': widget.room.client.userID,
        'sending_client_user_id': sendingClient.userID,
        'room_direct_chat_matrix_id': room.directChatMatrixID,
        'text_length': outboundText.length,
        'text_kind': _textRouteKind(outboundText),
        'parse_commands': parseCommands,
        'is_agent_room': isLikelyAgentRoom(room),
        'active_subchat_title': activeSubchatTitle,
      },
    );

    final sendFuture = room.sendTextEvent(
      outboundText,
      inReplyTo: replyEvent,
      editEventId: editEvent?.eventId,
      parseCommands: parseCommands,
      threadRootEventId: outboundThreadId,
      threadLastEventId: outboundThreadLastEventId,
    );
    unawaited(
      sendFuture
          .then((eventId) async {
            if (outboundThreadId == null) return;
            DevLogSink.subchatRoute('mellon.subchat.send_ack', {
              'room_id': roomId,
              'conversation_key': '$roomId:thread:$outboundThreadId',
              'thread_root_event_id': outboundThreadId,
              'sent_event_id': eventId,
              'active_thread_id': activeThreadId,
              'is_active_thread': activeThreadId == outboundThreadId,
            });
            if (!mounted || activeThreadId != outboundThreadId) return;
            await _hydrateActiveThreadTimeline(reason: 'send_ack');
          })
          .catchError((Object error, StackTrace stackTrace) {
            DevLogSink.subchatRoute('mellon.subchat.send_error', {
              'room_id': roomId,
              'conversation_key': outboundThreadId == null
                  ? roomId
                  : '$roomId:thread:$outboundThreadId',
              'thread_root_event_id': outboundThreadId,
              'error': error.toString(),
            });
            ErrorReporter(
              context,
              'Unable to send message',
            ).onErrorCallback(error, stackTrace);
          }),
    );
    if (outboundThreadId != null && isLikelyAgentRoom(room)) {
      unawaited(
        upsertAgentSubchatIndexEntry(
          room: room,
          threadRootEventId: outboundThreadId,
          preview: outboundText.trim(),
          updatedAt: DateTime.now().toUtc(),
          agentUserId: room.directChatMatrixID,
        ),
      );
    }
    sendController.value = TextEditingValue(
      text: pendingText,
      selection: const TextSelection.collapsed(offset: 0),
    );

    setState(() {
      sendController.text = pendingText;
      _inputTextIsEmpty = pendingText.isEmpty;
      replyEvent = null;
      editEvent = null;
      pendingText = '';
    });
  }

  void sendFileAction({FileType type = FileType.any}) async {
    final files = await selectFiles(context, allowMultiple: true, type: type);
    if (files.isEmpty) return;
    await showAdaptiveDialog(
      context: context,
      builder: (c) => SendFileDialog(
        files: files,
        room: room,
        outerContext: context,
        threadRootEventId: activeThreadId,
        threadLastEventId: threadLastEventId,
      ),
    );
  }

  void sendImageFromClipBoard(Uint8List? image) async {
    if (image == null) return;
    await showAdaptiveDialog(
      context: context,
      builder: (c) => SendFileDialog(
        files: [XFile.fromData(image)],
        room: room,
        outerContext: context,
        threadRootEventId: activeThreadId,
        threadLastEventId: threadLastEventId,
      ),
    );
  }

  void openCameraAction() async {
    // Make sure the textfield is unfocused before opening the camera
    FocusScope.of(context).requestFocus(FocusNode());
    final file = await ImagePicker().pickImage(source: ImageSource.camera);
    if (file == null) return;

    await showAdaptiveDialog(
      context: context,
      builder: (c) => SendFileDialog(
        files: [file],
        room: room,
        outerContext: context,
        threadRootEventId: activeThreadId,
        threadLastEventId: threadLastEventId,
      ),
    );
  }

  void openVideoCameraAction() async {
    // Make sure the textfield is unfocused before opening the camera
    FocusScope.of(context).requestFocus(FocusNode());
    final file = await ImagePicker().pickVideo(
      source: ImageSource.camera,
      maxDuration: const Duration(minutes: 1),
    );
    if (file == null) return;

    await showAdaptiveDialog(
      context: context,
      builder: (c) => SendFileDialog(
        files: [file],
        room: room,
        outerContext: context,
        threadRootEventId: activeThreadId,
        threadLastEventId: threadLastEventId,
      ),
    );
  }

  Future<void> onVoiceMessageSend(
    String path,
    int duration,
    List<int> waveform,
    String? fileName,
  ) async {
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    final audioFile = XFile(path);

    final bytesResult = await showFutureLoadingDialog(
      context: context,
      future: audioFile.readAsBytes,
    );
    final bytes = bytesResult.result;
    if (bytes == null) return;

    final file = MatrixAudioFile(
      bytes: bytes,
      name: fileName ?? audioFile.path,
    );

    room
        .sendFileEvent(
          file,
          inReplyTo: replyEvent,
          threadRootEventId: activeThreadId,
          extraContent: {
            'info': {...file.info, 'duration': duration},
            'org.matrix.msc3245.voice': {},
            'org.matrix.msc1767.audio': {
              'duration': duration,
              'waveform': waveform,
            },
          },
        )
        .catchError((e) {
          scaffoldMessenger.showSnackBar(
            SnackBar(content: Text((e as Object).toLocalizedString(context))),
          );
          return null;
        });
    setState(() {
      replyEvent = null;
    });
    return;
  }

  void hideEmojiPicker() {
    setState(() => showEmojiPicker = false);
  }

  // ── Model picker methods ──

  bool _hasSelectableModelOptions(ModelCatalog? catalog) {
    if (catalog == null) return false;
    return catalog.catalog.any(
      (entry) =>
          isMellonModelProvider(entry.provider) && entry.models.isNotEmpty,
    );
  }

  bool _belongsToActiveConversation(Event event) {
    final threadId = activeThreadId;
    final contentThreadId = _contentThreadId(event);
    if (threadId == null) {
      return event.relationshipType != RelationshipTypes.thread &&
          contentThreadId == null;
    }
    if (event.eventId == threadId) return true;
    if (contentThreadId == threadId) return true;
    return event.relationshipType == RelationshipTypes.thread &&
        event.relationshipEventId == threadId;
  }

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

  List<Event> _modelMetadataEvents({int? limit}) {
    final events = timeline?.events
        .where(_belongsToActiveConversation)
        .where(
          (event) =>
              event.type == 'org.mellonchat.model_response' ||
              event.type == EventTypes.Message ||
              event.type == EventTypes.Encrypted,
        )
        .toList();
    if (events == null || limit == null || events.length <= limit) {
      return events ?? const [];
    }
    return events.take(limit).toList();
  }

  Iterable<StrippedStateEvent> _modelResponseStateCandidates() sync* {
    final threadId = activeThreadId;
    if (threadId != null) {
      final threadState = room.getState(
        'org.mellonchat.model_response',
        threadId,
      );
      if (threadState != null) yield threadState;
    }

    final roomState = room.getState('org.mellonchat.model_response');
    if (roomState != null) yield roomState;
  }

  ModelCatalog _catalogWithScopedCurrent(ModelCatalog catalog) {
    final scopedCurrent = ModelCatalog.getForRoom(conversationKey)?.current;
    if (scopedCurrent == null) return catalog;
    return ModelCatalog(
      current: scopedCurrent,
      catalog: catalog.catalog,
      fetchedAt: catalog.fetchedAt,
    );
  }

  void _applyCurrentModel(ModelSelection selection) {
    modelCatalog = ModelCatalog(
      current: selection,
      catalog: modelCatalog?.catalog ?? [],
      fetchedAt: modelCatalog?.fetchedAt,
    );
  }

  /// Scan existing timeline events for model catalog data and auto-fetch
  /// if needed. Called once after the timeline first loads.
  void _initModelCatalog() {
    if (!mounted) return;
    // Already have a valid catalog with providers from the global cache
    if (_hasSelectableModelOptions(modelCatalog)) {
      debugPrint(
        '[model-pill] initModelCatalog: using cached catalog for $conversationKey (${modelCatalog!.catalog.length} providers)',
      );
      setState(() {}); // Trigger rebuild so pill shows
    }

    // Scan timeline events for model info (newest-first), including hidden
    // model_response events that should not render in the chat transcript.
    final events = _modelMetadataEvents();
    debugPrint(
      '[model-pill] initModelCatalog: scanning ${events.length} events for $conversationKey',
    );
    var foundCurrentModel = false;
    for (var i = 0; i < events.length; i++) {
      final event = events[i];
      // Check ai_stream model info from the newest bot message.
      // This gives us the current model for the pill, but NOT the full catalog.
      final aiStream = event.content.aiStreamContent;
      if (!foundCurrentModel && aiStream?.model != null) {
        final m = aiStream!.model!;
        foundCurrentModel = true;
        debugPrint(
          '[model-pill] found ai_stream model at event[$i]: ${m.provider}/${m.model}',
        );
        _applyCurrentModel(
          ModelSelection(provider: m.provider, model: m.model),
        );
        setState(() {});
      }
      // Check silent model response
      if (event.type == 'org.mellonchat.model_response' &&
          event.content['type'] == 'model_picker') {
        debugPrint('[model-pill] found model_response at event[$i]');
        try {
          final catalog = ModelCatalog.fromJson(event.content);
          modelCatalog = catalog;
          setState(() {});
          if (_hasSelectableModelOptions(catalog)) return;
        } catch (e) {
          debugPrint('[model-pill] model_response parse error: $e');
        }
      }
      // Check visible /model response
      final channelData = MellonchatChannelData.fromEventContent(event.content);
      if (channelData != null &&
          channelData.isModelPicker &&
          channelData.modelCatalog != null) {
        debugPrint('[model-pill] found channel_data model_picker at event[$i]');
        modelCatalog = channelData.modelCatalog;
        setState(() {});
        if (_hasSelectableModelOptions(channelData.modelCatalog)) return;
      }
      if (!foundCurrentModel &&
          channelData != null &&
          channelData.isCurrentModel &&
          channelData.currentModel != null) {
        foundCurrentModel = true;
        debugPrint(
          '[model-pill] found channel_data current_model at event[$i]: ${channelData.currentModel!.fullModelId}',
        );
        _applyCurrentModel(channelData.currentModel!);
        setState(() {});
      }
    }

    // Check room state for a previously cached model_response (state events
    // persist across syncs and are NOT encrypted in E2E rooms).
    final stateEvent = _modelResponseStateCandidates().firstWhereOrNull(
      (event) => event.content['type'] == 'model_picker',
    );
    if (stateEvent != null) {
      debugPrint('[model-pill] found model_response in room state');
      try {
        final catalog = ModelCatalog.fromJson(stateEvent.content);
        modelCatalog = activeThreadId == null
            ? catalog
            : _catalogWithScopedCurrent(catalog);
        setState(() {});
        if (_hasSelectableModelOptions(modelCatalog)) return;
      } catch (e) {
        debugPrint('[model-pill] state parse error: $e');
      }
    }

    final hasFullCatalog = _hasSelectableModelOptions(modelCatalog);
    debugPrint(
      '[model-pill] scan done: hasModel=${modelCatalog != null} hasFullCatalog=$hasFullCatalog isDirect=${room.isDirectChat} autoFetchAttempted=${ModelCatalog.wasAutoFetchAttempted(conversationKey)}',
    );
    // Auto-fetch if we have no catalog at all, or only a partial catalog
    // (e.g., ai_stream.model gave us `current` but no provider/model list).
    if (room.isDirectChat &&
        !hasFullCatalog &&
        !ModelCatalog.wasAutoFetchAttempted(conversationKey)) {
      ModelCatalog.markAutoFetchAttempted(conversationKey);
      unawaited(_autoFetchModelCatalog(forceRefresh: true));
    }
  }

  /// Silently send a custom event to fetch the model catalog.
  /// Uses a room state event (org.mellonchat.model_request) so it works
  /// in E2E encrypted rooms — state events are not encrypted.
  Future<bool> _autoFetchModelCatalog({bool forceRefresh = false}) async {
    if (!mounted) return false;
    final threadId = activeThreadId;
    final stateKey = _modelStateKey;
    final requestId = '${DateTime.now().microsecondsSinceEpoch}';
    debugPrint(
      '[model-pill] autoFetch: sending model_request to $conversationKey',
    );
    setState(() => isFetchingCatalog = true);
    var didLoadCatalog = false;
    try {
      // Use setRoomStateWithKey — state events bypass E2E encryption,
      // so the bot can always read them even in encrypted rooms.
      await room.client.setRoomStateWithKey(
        room.id,
        'org.mellonchat.model_request',
        stateKey,
        {
          'action': 'get_catalog',
          'request_id': requestId,
          'ts': DateTime.now().millisecondsSinceEpoch,
          if (threadId != null) 'thread_root_event_id': threadId,
          if (threadId != null && threadLastEventId != null)
            'thread_last_event_id': threadLastEventId,
        },
      );
      debugPrint(
        '[model-pill] autoFetch: model_request state event sent, waiting 4s for response...',
      );
      // Wait for sync to deliver the bot's state event response. A matching
      // request_id prevents old room state from masquerading as a fresh catalog.
      StrippedStateEvent? stateEvent;
      final deadline = DateTime.now().add(const Duration(seconds: 4));
      do {
        await Future.delayed(const Duration(milliseconds: 250));
        final candidate = _modelResponseStateCandidates().firstWhereOrNull(
          (event) => event.content['request_id'] == requestId,
        );
        if (candidate != null) {
          stateEvent = candidate;
          break;
        }
      } while (DateTime.now().isBefore(deadline));
      // Check room state for the response (state events aren't in timeline).
      // Also update if we only have a partial catalog (current model but no
      // provider/model list from ai_stream.model).
      final needsCatalog =
          forceRefresh || !_hasSelectableModelOptions(modelCatalog);
      if (needsCatalog) {
        if (stateEvent != null &&
            stateEvent.content['type'] == 'model_picker') {
          try {
            final catalog = ModelCatalog.fromJson(stateEvent.content);
            modelCatalog = threadId == null
                ? catalog
                : _catalogWithScopedCurrent(catalog);
            didLoadCatalog = _hasSelectableModelOptions(modelCatalog);
            debugPrint(
              '[model-pill] autoFetch: found model_response in room state (${modelCatalog!.catalog.length} providers)',
            );
          } catch (e) {
            debugPrint('[model-pill] autoFetch: state parse error: $e');
          }
        }
      }
      debugPrint(
        '[model-pill] autoFetch: wait complete, modelCatalog=${modelCatalog != null ? "${modelCatalog!.catalog.length} providers" : "null"}',
      );
    } catch (e) {
      debugPrint('[model-pill] autoFetch FAILED: $e');
    }
    if (mounted) {
      setState(() => isFetchingCatalog = false);
    }
    return didLoadCatalog || _hasSelectableModelOptions(modelCatalog);
  }

  /// Check if a timeline event contains model catalog data from the bot.
  /// Handles both:
  /// - org.mellonchat.model_response events (silent custom events)
  /// - m.room.message with org.mellonchat.channel_data (visible /model responses)
  void _checkForModelCatalog(Event event) {
    ModelCatalog? catalog;

    // Check for silent model response (custom event type)
    if (event.type == 'org.mellonchat.model_response') {
      final type = event.content['type'] as String?;
      if (type == 'model_picker') {
        try {
          catalog = ModelCatalog.fromJson(event.content);
        } catch (_) {}
      }
    }

    // Check for visible /model response (channel data in regular message)
    if (catalog == null) {
      final channelData = MellonchatChannelData.fromEventContent(event.content);
      if (channelData != null &&
          channelData.isModelPicker &&
          channelData.modelCatalog != null) {
        catalog = channelData.modelCatalog;
      }
    }

    if (catalog != null) {
      setState(() {
        modelCatalog = catalog;
        isFetchingCatalog = false;
      });
      return;
    }

    final channelData = MellonchatChannelData.fromEventContent(event.content);
    if (channelData != null &&
        channelData.isCurrentModel &&
        channelData.currentModel != null) {
      setState(() {
        _applyCurrentModel(channelData.currentModel!);
        isFetchingCatalog = false;
      });
    }
  }

  /// Check if a bot message's ai_stream metadata contains model info.
  /// Updates the model pill to always reflect the most recent model in use,
  /// without needing an explicit /model command.
  void _checkForAiStreamModel(Event event) {
    if (event.type != 'm.room.message') return;
    final aiStream = event.content.aiStreamContent;
    if (aiStream == null || aiStream.model == null) return;

    final m = aiStream.model!;
    final current = modelCatalog?.current;
    // Only update if the model actually changed (or no catalog exists yet)
    if (current == null ||
        current.provider != m.provider ||
        current.model != m.model) {
      setState(() {
        _applyCurrentModel(
          ModelSelection(provider: m.provider, model: m.model),
        );
      });
    }
  }

  /// Open the model picker panel.
  void openModelPicker() async {
    // If no catalog yet or stale, fetch first
    if (modelCatalog == null ||
        modelCatalog!.isStale ||
        !_hasSelectableModelOptions(modelCatalog)) {
      final loadedSilently = await _autoFetchModelCatalog(forceRefresh: true);

      if (!loadedSilently && !_hasSelectableModelOptions(modelCatalog)) {
        setState(() => isFetchingCatalog = true);
        try {
          await room.sendTextEvent(
            '/model',
            parseCommands: false,
            threadRootEventId: activeThreadId,
            threadLastEventId: threadLastEventId,
          );
        } catch (e) {
          Logs().w('Failed to send /model command', e);
          if (mounted) setState(() => isFetchingCatalog = false);
          return;
        }
        // Wait briefly for the bot response to arrive via sync.
        // _checkForModelCatalog will set modelCatalog when it arrives.
        await Future.delayed(const Duration(seconds: 3));
        for (final event in _modelMetadataEvents(limit: 8)) {
          _checkForModelCatalog(event);
          _checkForAiStreamModel(event);
        }
      }

      if (!_hasSelectableModelOptions(modelCatalog) && mounted) {
        setState(() => isFetchingCatalog = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not load model catalog.')),
        );
        return;
      }
      if (mounted) setState(() => isFetchingCatalog = false);
    }

    final catalog = modelCatalog;
    if (!mounted || catalog == null) return;

    final selectedModelId = await showModelPickerPanel(
      context: context,
      catalog: catalog,
    );

    if (selectedModelId != null && mounted) {
      // Send the model switch command as a message
      room.sendTextEvent(
        '/model $selectedModelId',
        parseCommands: false,
        threadRootEventId: activeThreadId,
        threadLastEventId: threadLastEventId,
      );
      // Optimistically update the pill display
      final parts = selectedModelId.split('/');
      if (parts.length == 2) {
        setState(() {
          modelCatalog = ModelCatalog(
            current: ModelSelection(provider: parts[0], model: parts[1]),
            catalog: catalog.catalog,
            fetchedAt: catalog.fetchedAt,
          );
        });
      }
    }
  }

  void emojiPickerAction() {
    if (showEmojiPicker) {
      inputFocus.requestFocus();
    } else {
      inputFocus.unfocus();
    }
    setState(() => showEmojiPicker = !showEmojiPicker);
  }

  void _inputFocusListener() {
    if (showEmojiPicker && inputFocus.hasFocus) {
      setState(() => showEmojiPicker = false);
    }
  }

  void sendLocationAction() async {
    await showAdaptiveDialog(
      context: context,
      builder: (c) => SendLocationDialog(room: room),
    );
  }

  String _getSelectedEventString() {
    var copyString = '';
    if (selectedEvents.length == 1) {
      return selectedEvents.first
          .getMellonDisplayEvent(timeline!)
          .calcLocalizedBodyFallback(MatrixLocals(L10n.of(context)));
    }
    for (final event in selectedEvents) {
      if (copyString.isNotEmpty) copyString += '\n\n';
      copyString += event
          .getMellonDisplayEvent(timeline!)
          .calcLocalizedBodyFallback(
            MatrixLocals(L10n.of(context)),
            withSenderNamePrefix: true,
          );
    }
    return copyString;
  }

  void copyEventsAction() {
    Clipboard.setData(ClipboardData(text: _getSelectedEventString()));
    setState(() {
      showEmojiPicker = false;
      selectedEvents.clear();
    });
  }

  void reportEventAction() async {
    final event = selectedEvents.single;
    final score = await showModalActionPopup<int>(
      context: context,
      title: L10n.of(context).reportMessage,
      message: L10n.of(context).howOffensiveIsThisContent,
      cancelLabel: L10n.of(context).cancel,
      actions: [
        AdaptiveModalAction(
          value: -100,
          label: L10n.of(context).extremeOffensive,
        ),
        AdaptiveModalAction(value: -50, label: L10n.of(context).offensive),
        AdaptiveModalAction(value: 0, label: L10n.of(context).inoffensive),
      ],
    );
    if (score == null) return;
    final reason = await showTextInputDialog(
      context: context,
      title: L10n.of(context).whyDoYouWantToReportThis,
      okLabel: L10n.of(context).ok,
      cancelLabel: L10n.of(context).cancel,
      hintText: L10n.of(context).reason,
    );
    if (reason == null || reason.isEmpty) return;
    final result = await showFutureLoadingDialog(
      context: context,
      future: () => Matrix.of(context).client.reportEvent(
        event.roomId!,
        event.eventId,
        reason: reason,
        score: score,
      ),
    );
    if (result.error != null) return;
    setState(() {
      showEmojiPicker = false;
      selectedEvents.clear();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(L10n.of(context).contentHasBeenReported)),
    );
  }

  void deleteErrorEventsAction() async {
    try {
      if (selectedEvents.any((event) => event.status != EventStatus.error)) {
        throw Exception(
          'Tried to delete failed to send events but one event is not failed to sent',
        );
      }
      for (final event in selectedEvents) {
        await event.cancelSend();
      }
      setState(selectedEvents.clear);
    } catch (e, s) {
      ErrorReporter(
        context,
        'Error while delete error events action',
      ).onErrorCallback(e, s);
    }
  }

  void redactEventsAction() async {
    final reasonInput = selectedEvents.any((event) => event.status.isSent)
        ? await showTextInputDialog(
            context: context,
            title: L10n.of(context).redactMessage,
            message: L10n.of(context).redactMessageDescription,
            isDestructive: true,
            hintText: L10n.of(context).optionalRedactReason,
            maxLength: 255,
            maxLines: 3,
            minLines: 1,
            okLabel: L10n.of(context).remove,
            cancelLabel: L10n.of(context).cancel,
          )
        : null;
    if (reasonInput == null) return;
    final reason = reasonInput.isEmpty ? null : reasonInput;
    await showFutureLoadingDialog(
      context: context,
      futureWithProgress: (onProgress) async {
        final count = selectedEvents.length;
        for (final (i, event) in selectedEvents.indexed) {
          onProgress(i / count);
          if (event.status.isSent) {
            if (event.canRedact) {
              await event.redactEvent(reason: reason);
            } else {
              final client = currentRoomBundle.firstWhere(
                (cl) => selectedEvents.first.senderId == cl!.userID,
                orElse: () => null,
              );
              if (client == null) {
                return;
              }
              final room = client.getRoomById(roomId)!;
              await Event.fromJson(
                event.toJson(),
                room,
              ).redactEvent(reason: reason);
            }
          } else {
            await event.cancelSend();
          }
        }
      },
    );
    setState(() {
      showEmojiPicker = false;
      selectedEvents.clear();
    });
  }

  List<Client?> get currentRoomBundle {
    final clients = Matrix.of(context).currentBundle!;
    clients.removeWhere((c) => c!.getRoomById(roomId) == null);
    return clients;
  }

  bool get canRedactSelectedEvents {
    if (isArchived) return false;
    final clients = Matrix.of(context).currentBundle;
    for (final event in selectedEvents) {
      if (!event.status.isSent) return false;
      if (event.canRedact == false &&
          !(clients!.any((cl) => event.senderId == cl!.userID))) {
        return false;
      }
    }
    return true;
  }

  bool get canPinSelectedEvents {
    if (isArchived ||
        !room.canChangeStateEvent(EventTypes.RoomPinnedEvents) ||
        selectedEvents.length != 1 ||
        !selectedEvents.single.status.isSent ||
        activeThreadId != null) {
      return false;
    }
    return true;
  }

  bool get canEditSelectedEvents {
    if (isArchived ||
        selectedEvents.length != 1 ||
        !selectedEvents.first.status.isSent) {
      return false;
    }
    return currentRoomBundle.any(
      (cl) => selectedEvents.first.senderId == cl!.userID,
    );
  }

  void forwardEventsAction() async {
    if (selectedEvents.isEmpty) return;
    final timeline = this.timeline;
    if (timeline == null) return;

    final forwardEvents = List<Event>.from(
      selectedEvents,
    ).map((event) => event.getMellonDisplayEvent(timeline)).toList();

    await showScaffoldDialog(
      context: context,
      builder: (context) => ShareScaffoldDialog(
        items: forwardEvents
            .map((event) => ContentShareItem(event.content))
            .toList(),
      ),
    );
    if (!mounted) return;
    setState(() => selectedEvents.clear());
  }

  void sendAgainAction() {
    final event = selectedEvents.first;
    if (event.status.isError) {
      event.sendAgain();
    }
    final allEditEvents = event
        .aggregatedEvents(timeline!, RelationshipTypes.edit)
        .where((e) => e.status.isError);
    for (final e in allEditEvents) {
      e.sendAgain();
    }
    setState(() => selectedEvents.clear());
  }

  void replyAction({Event? replyTo}) {
    setState(() {
      replyEvent = replyTo ?? selectedEvents.first;
      selectedEvents.clear();
    });
    inputFocus.requestFocus();
  }

  void scrollToEventId(String eventId, {bool highlightEvent = true}) async {
    final foundEvent = timeline!.events.firstWhereOrNull(
      (event) => event.eventId == eventId,
    );

    final eventIndex = foundEvent == null
        ? -1
        : timeline!.events
              .filterByVisibleInGui(
                exceptionEventId: eventId,
                threadId: activeThreadId,
              )
              .indexOf(foundEvent);

    if (eventIndex == -1) {
      setState(() {
        timeline = null;
        _scrolledUp = false;
        loadTimelineFuture = _getTimeline(eventContextId: eventId).onError(
          ErrorReporter(
            context,
            'Unable to load timeline after scroll to ID',
          ).onErrorCallback,
        );
      });
      await loadTimelineFuture;
      WidgetsBinding.instance.addPostFrameCallback((timeStamp) {
        scrollToEventId(eventId);
      });
      return;
    }
    if (highlightEvent) {
      setState(() {
        scrollToEventIdMarker = eventId;
      });
    }
    await scrollController.scrollToIndex(
      eventIndex + 1,
      duration: FluffyThemes.animationDuration,
      preferPosition: AutoScrollPosition.middle,
    );
    _updateScrollController();
  }

  void scrollDown() async {
    if (!timeline!.allowNewEvent) {
      setState(() {
        timeline = null;
        _scrolledUp = false;
        loadTimelineFuture = _getTimeline().onError(
          ErrorReporter(
            context,
            'Unable to load timeline after scroll down',
          ).onErrorCallback,
        );
      });
      await loadTimelineFuture;
    }
    scrollController.jumpTo(0);
  }

  void onEmojiSelected(dynamic _, Emoji? emoji) {
    typeEmoji(emoji);
    onInputBarChanged(sendController.text);
  }

  void typeEmoji(Emoji? emoji) {
    if (emoji == null) return;
    final text = sendController.text;
    final selection = sendController.selection;
    final newText = sendController.text.isEmpty
        ? emoji.emoji
        : text.replaceRange(selection.start, selection.end, emoji.emoji);
    sendController.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(
        // don't forget an UTF-8 combined emoji might have a length > 1
        offset: selection.baseOffset + emoji.emoji.length,
      ),
    );
  }

  void emojiPickerBackspace() {
    sendController
      ..text = sendController.text.characters.skipLast(1).toString()
      ..selection = TextSelection.fromPosition(
        TextPosition(offset: sendController.text.length),
      );
  }

  void clearSelectedEvents() => setState(() {
    selectedEvents.clear();
    showEmojiPicker = false;
  });

  void clearSingleSelectedEvent() {
    if (selectedEvents.length <= 1) {
      clearSelectedEvents();
    }
  }

  void editSelectedEventAction() {
    final client = currentRoomBundle.firstWhere(
      (cl) => selectedEvents.first.senderId == cl!.userID,
      orElse: () => null,
    );
    if (client == null) {
      return;
    }
    setSendingClient(client);
    setState(() {
      pendingText = sendController.text;
      editEvent = selectedEvents.first;
      sendController.text = editEvent!
          .getMellonDisplayEvent(timeline!)
          .calcLocalizedBodyFallback(
            MatrixLocals(L10n.of(context)),
            withSenderNamePrefix: false,
            hideReply: true,
          );
      selectedEvents.clear();
    });
    inputFocus.requestFocus();
  }

  void goToNewRoomAction() async {
    final result = await showFutureLoadingDialog(
      context: context,
      future: () async {
        final users = await room.requestParticipants(
          [Membership.join, Membership.leave],
          true,
          false,
        );
        users.sort((a, b) => a.powerLevel.compareTo(b.powerLevel));
        final via = users
            .map((user) => user.id.domain)
            .whereType<String>()
            .toSet()
            .take(10)
            .toList();
        return room.client.joinRoom(
          room
              .getState(EventTypes.RoomTombstone)!
              .parsedTombstoneContent
              .replacementRoom,
          via: via,
        );
      },
    );
    if (result.error != null) return;
    if (!mounted) return;
    context.go(_roomRoute(routeRoomId: result.result!, client: room.client));

    await showFutureLoadingDialog(context: context, future: room.leave);
  }

  void onSelectMessage(Event event) {
    if (!event.redacted) {
      if (selectedEvents.contains(event)) {
        setState(() => selectedEvents.remove(event));
      } else {
        setState(() => selectedEvents.add(event));
      }
      selectedEvents.sort(
        (a, b) => a.originServerTs.compareTo(b.originServerTs),
      );
    }
  }

  int? findChildIndexCallback(Key key, Map<String, int> thisEventsKeyMap) {
    // this method is called very often. As such, it has to be optimized for speed.
    if (key is! ValueKey) {
      return null;
    }
    final eventId = key.value;
    if (eventId is! String) {
      return null;
    }
    // first fetch the last index the event was at
    final index = thisEventsKeyMap[eventId];
    if (index == null) {
      return null;
    }
    // we need to +1 as 0 is the typing thing at the bottom
    return index + 1;
  }

  void onInputBarSubmitted(String _) {
    send();
    FocusScope.of(context).requestFocus(inputFocus);
  }

  void onAddPopupMenuButtonSelected(AddPopupMenuActions choice) {
    room.client.getConfig();

    switch (choice) {
      case AddPopupMenuActions.image:
        sendFileAction(type: FileType.image);
        return;
      case AddPopupMenuActions.video:
        sendFileAction(type: FileType.video);
        return;
      case AddPopupMenuActions.file:
        sendFileAction();
        return;
      case AddPopupMenuActions.poll:
        showAdaptiveBottomSheet(
          context: context,
          builder: (context) => StartPollBottomSheet(room: room),
        );
        return;
      case AddPopupMenuActions.photoCamera:
        openCameraAction();
        return;
      case AddPopupMenuActions.videoCamera:
        openVideoCameraAction();
        return;
      case AddPopupMenuActions.location:
        sendLocationAction();
        return;
    }
  }

  void unpinEvent(String eventId) async {
    final response = await showOkCancelAlertDialog(
      context: context,
      title: L10n.of(context).unpin,
      message: L10n.of(context).confirmEventUnpin,
      okLabel: L10n.of(context).unpin,
      cancelLabel: L10n.of(context).cancel,
    );
    if (response == OkCancelResult.ok) {
      final events = room.pinnedEventIds
        ..removeWhere((oldEvent) => oldEvent == eventId);
      showFutureLoadingDialog(
        context: context,
        future: () => room.setPinnedEvents(events),
      );
    }
  }

  void pinEvent() {
    final pinnedEventIds = room.pinnedEventIds;
    final selectedEventIds = selectedEvents.map((e) => e.eventId).toSet();
    final unpin =
        selectedEventIds.length == 1 &&
        pinnedEventIds.contains(selectedEventIds.single);
    if (unpin) {
      pinnedEventIds.removeWhere(selectedEventIds.contains);
    } else {
      pinnedEventIds.addAll(selectedEventIds);
    }
    showFutureLoadingDialog(
      context: context,
      future: () => room.setPinnedEvents(pinnedEventIds),
    );
  }

  Timer? _storeInputTimeoutTimer;
  static const Duration _storeInputTimeout = Duration(milliseconds: 500);

  void onInputBarChanged(String text) {
    if (_inputTextIsEmpty != text.isEmpty) {
      setState(() {
        _inputTextIsEmpty = text.isEmpty;
      });
    }

    _storeInputTimeoutTimer?.cancel();
    _storeInputTimeoutTimer = Timer(_storeInputTimeout, () async {
      final prefs = Matrix.of(context).store;
      if (text.isEmpty) {
        await prefs.remove(_draftKey);
      } else {
        await prefs.setString(_draftKey, text);
      }
    });
    if (text.endsWith(' ') && Matrix.of(context).hasComplexBundles) {
      final clients = currentRoomBundle;
      for (final client in clients) {
        final prefix = client!.sendPrefix;
        if ((prefix.isNotEmpty) &&
            text.toLowerCase() == '${prefix.toLowerCase()} ') {
          setSendingClient(client);
          setState(() {
            sendController.clear();
          });
          return;
        }
      }
    }
    if (AppSettings.sendTypingNotifications.value) {
      typingCoolDown?.cancel();
      typingCoolDown = Timer(const Duration(seconds: 2), () {
        typingCoolDown = null;
        currentlyTyping = false;
        room.setTyping(false);
      });
      typingTimeout ??= Timer(const Duration(seconds: 30), () {
        typingTimeout = null;
        currentlyTyping = false;
      });
      if (!currentlyTyping) {
        currentlyTyping = true;
        room.setTyping(
          true,
          timeout: const Duration(seconds: 30).inMilliseconds,
        );
      }
    }
  }

  bool _inputTextIsEmpty = true;

  bool get isArchived =>
      {Membership.leave, Membership.ban}.contains(room.membership);

  void showEventInfo([Event? event]) =>
      (event ?? selectedEvents.single).showInfoDialog(context);

  void onPhoneButtonTap() async {
    // VoIP required Android SDK 21
    if (PlatformInfos.isAndroid) {
      DeviceInfoPlugin().androidInfo.then((value) {
        if (value.version.sdkInt < 21) {
          Navigator.pop(context);
          showOkAlertDialog(
            context: context,
            title: L10n.of(context).unsupportedAndroidVersion,
            message: L10n.of(context).unsupportedAndroidVersionLong,
            okLabel: L10n.of(context).close,
          );
        }
      });
    }
    final callType = await showModalActionPopup<CallType>(
      context: context,
      title: L10n.of(context).warning,
      message: L10n.of(context).videoCallsBetaWarning,
      cancelLabel: L10n.of(context).cancel,
      actions: [
        AdaptiveModalAction(
          label: L10n.of(context).voiceCall,
          icon: const Icon(Icons.phone_outlined),
          value: CallType.kVoice,
        ),
        AdaptiveModalAction(
          label: L10n.of(context).videoCall,
          icon: const Icon(Icons.video_call_outlined),
          value: CallType.kVideo,
        ),
      ],
    );
    if (callType == null) return;

    final voipPlugin = Matrix.of(context).voipPlugin;
    try {
      await voipPlugin!.voip.inviteToCall(room, callType);
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.toLocalizedString(context))));
    }
  }

  void cancelReplyEventAction() => setState(() {
    if (editEvent != null) {
      sendController.text = pendingText;
      pendingText = '';
    }
    replyEvent = null;
    editEvent = null;
  });

  late final ValueNotifier<bool> _displayChatDetailsColumn;

  void toggleDisplayChatDetailsColumn() async {
    await AppSettings.displayChatDetailsColumn.setItem(
      !_displayChatDetailsColumn.value,
    );
    _displayChatDetailsColumn.value = !_displayChatDetailsColumn.value;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(child: ChatView(this)),
        ValueListenableBuilder(
          valueListenable: _displayChatDetailsColumn,
          builder: (context, displayChatDetailsColumn, _) =>
              !FluffyThemes.isThreeColumnMode(context) ||
                  room.membership != Membership.join ||
                  !displayChatDetailsColumn
              ? const SizedBox(height: double.infinity, width: 0)
              : Container(
                  width: FluffyThemes.columnWidth,
                  clipBehavior: Clip.hardEdge,
                  decoration: BoxDecoration(
                    border: Border(
                      left: BorderSide(width: 1, color: theme.dividerColor),
                    ),
                  ),
                  child: ChatDetails(
                    roomId: roomId,
                    embeddedCloseButton: IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: toggleDisplayChatDetailsColumn,
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

enum AddPopupMenuActions {
  image,
  video,
  file,
  poll,
  photoCamera,
  videoCamera,
  location,
}
