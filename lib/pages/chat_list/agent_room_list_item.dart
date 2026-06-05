import 'dart:async';

import 'package:flutter/material.dart';

import 'package:collection/collection.dart';
import 'package:matrix/matrix.dart';

import 'package:fluffychat/ai_stream/agent_subchat.dart';
import 'package:fluffychat/config/app_config.dart';
import 'package:fluffychat/pages/chat_list/chat_list_item.dart';
import 'package:fluffychat/utils/date_time_extension.dart';
import 'package:fluffychat/utils/dev_log_sink.dart';
import 'package:fluffychat/utils/matrix_sdk_extensions/display_event_extension.dart';
import 'package:fluffychat/widgets/adaptive_dialogs/show_ok_cancel_alert_dialog.dart';
import 'package:fluffychat/widgets/adaptive_dialogs/show_text_input_dialog.dart';
import 'package:fluffychat/widgets/agent_subchat_icon.dart';
import 'package:fluffychat/widgets/future_loading_dialog.dart';

class AgentRoomListItem extends StatefulWidget {
  final Room room;
  final Room? space;
  final bool activeChat;
  final String? activeThreadId;
  final String? filter;
  final void Function() onTap;
  final void Function(BuildContext context)? onLongPress;
  final void Function(String threadId) onSubchatTap;

  const AgentRoomListItem(
    this.room, {
    super.key,
    this.space,
    this.activeChat = false,
    this.activeThreadId,
    this.filter,
    required this.onTap,
    required this.onSubchatTap,
    this.onLongPress,
  });

  @override
  State<AgentRoomListItem> createState() => _AgentRoomListItemState();
}

class _AgentRoomListItemState extends State<AgentRoomListItem> {
  Timeline? _timeline;
  Future<void>? _loadTimelineFuture;
  List<AgentSubchat> _serverSubchats = const [];
  final Set<String> _locallyArchivedSubchatIds = {};

  void _logTiming(String event, Map<String, Object?> fields) {
    DevLogSink.subchatTiming(event, {
      'room_id': widget.room.id,
      'active_thread_id': widget.activeThreadId,
      'active_chat': widget.activeChat,
      ...fields,
    });
  }

  @override
  void initState() {
    super.initState();
    _loadTimelineFuture = _loadTimeline();
  }

  @override
  void didUpdateWidget(covariant AgentRoomListItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.room.id != widget.room.id) {
      _serverSubchats = const [];
      _loadTimelineFuture = _loadTimeline();
    }
  }

  @override
  void dispose() {
    _timeline?.cancelSubscriptions();
    super.dispose();
  }

  void _timelineUpdated([int? _]) {
    final timeline = _timeline;
    if (timeline != null) {
      unawaited(_syncSubchatIndexFromTimeline(timeline));
    }
    if (mounted) setState(() {});
  }

  Future<void> _createSubchat() async {
    final result = await showFutureLoadingDialog<String?>(
      context: context,
      future: () => widget.room.sendEvent(
        buildAgentSubchatRootContent(
          agentUserId: widget.room.directChatMatrixID,
        ),
        type: EventTypes.Message,
      ),
    );
    final eventId = result.result;
    if (eventId == null || !mounted) return;
    await upsertAgentSubchatIndexEntry(
      room: widget.room,
      threadRootEventId: eventId,
      title: defaultAgentSubchatTitle,
      preview: defaultAgentSubchatTitle,
      createdAt: DateTime.now().toUtc(),
      updatedAt: DateTime.now().toUtc(),
      canRename: true,
      agentUserId: widget.room.directChatMatrixID,
    );
    if (!mounted) return;
    widget.onSubchatTap(eventId);
  }

  Future<void> _renameSubchat(AgentSubchat subchat) async {
    if (!subchat.canRename) return;
    final timeline = _timeline;
    final rootEvent = timeline?.events.firstWhereOrNull(
      (event) => event.eventId == subchat.threadRootEventId,
    );

    final input = await showTextInputDialog(
      context: context,
      title: 'Rename subchat',
      initialText: subchat.title,
      labelText: 'Name',
      okLabel: 'Rename',
      maxLength: 80,
      validator: (input) =>
          input.trim().isEmpty ? 'Enter a subchat name' : null,
    );
    final title = input?.trim();
    if (title == null || title.isEmpty || title == subchat.title.trim()) {
      return;
    }
    if (!mounted) return;

    await showFutureLoadingDialog<void>(
      context: context,
      future: () async {
        DevLogSink.subchatRoute('mellon.subchat.rename_start', {
          'room_id': widget.room.id,
          'thread_root_event_id': subchat.threadRootEventId,
          'previous_title': subchat.title,
          'next_title': title,
          'had_root_event': rootEvent != null,
        });
        if (timeline != null && rootEvent != null) {
          await widget.room.sendEvent(
            buildAgentSubchatRenameContent(
              currentDisplayEvent: rootEvent.getMellonDisplayEvent(timeline),
              title: title,
            ),
            type: EventTypes.Message,
            editEventId: rootEvent.eventId,
          );
        }
        await upsertAgentSubchatIndexEntry(
          room: widget.room,
          threadRootEventId: subchat.threadRootEventId,
          title: title,
          preview: subchat.preview == subchat.title ? title : subchat.preview,
          updatedAt: DateTime.now().toUtc(),
          replyCount: subchat.replyCount,
          canRename: true,
          agentUserId: widget.room.directChatMatrixID,
          isTitleManual: true,
        );
        DevLogSink.subchatRoute('mellon.subchat.rename_done', {
          'room_id': widget.room.id,
          'thread_root_event_id': subchat.threadRootEventId,
          'next_title': title,
        });
      },
    );
  }

  Future<void> _archiveSubchat(AgentSubchat subchat) async {
    final confirmed = await showOkCancelAlertDialog(
      context: context,
      title: 'Archive subchat?',
      message:
          'This hides the subchat from your sidebar. The messages are not deleted.',
      okLabel: 'Archive',
      cancelLabel: 'Cancel',
    );
    if (confirmed != OkCancelResult.ok || !mounted) return;

    final result = await showFutureLoadingDialog<void>(
      context: context,
      future: () => archiveAgentSubchat(
        room: widget.room,
        threadRootEventId: subchat.threadRootEventId,
      ),
    );
    if (result.error != null || !mounted) return;
    setState(() => _locallyArchivedSubchatIds.add(subchat.threadRootEventId));
    if (widget.activeThreadId == subchat.threadRootEventId) {
      widget.onTap();
    }
  }

  Future<void> _migrateSubchat(AgentSubchat subchat) async {
    final result = await showFutureLoadingDialog<void>(
      context: context,
      future: () => upsertAgentSubchatIndexEntry(
        room: widget.room,
        threadRootEventId: subchat.threadRootEventId,
        title: subchat.title,
        preview: subchat.preview,
        updatedAt: subchat.updatedAt,
        replyCount: subchat.replyCount,
        canRename: subchat.canRename,
        agentUserId: widget.room.directChatMatrixID,
      ),
    );
    if (result.error != null || !mounted) return;
    setState(() {});
  }

  Future<void> _loadTimeline() async {
    final watch = Stopwatch()..start();
    _logTiming('mellon.subchat_timing.sidebar_timeline_start', {'limit': 150});
    try {
      _timeline?.cancelSubscriptions();
      final timeline = await widget.room.getTimeline(
        limit: 150,
        onUpdate: _timelineUpdated,
        onInsert: _timelineUpdated,
        onChange: _timelineUpdated,
        onRemove: _timelineUpdated,
      );
      if (!mounted) {
        timeline.cancelSubscriptions();
        return;
      }
      setState(() => _timeline = timeline);
      _logTiming('mellon.subchat_timing.sidebar_timeline_done', {
        'elapsed_ms': watch.elapsedMilliseconds,
        'loaded_events': timeline.events.length,
        'can_request_history': timeline.canRequestHistory,
        'can_request_future': timeline.canRequestFuture,
        'allow_new_event': timeline.allowNewEvent,
      });
      unawaited(_syncSubchatIndexFromTimeline(timeline));
      unawaited(_loadServerSubchats());
    } catch (e) {
      _logTiming('mellon.subchat_timing.sidebar_timeline_error', {
        'elapsed_ms': watch.elapsedMilliseconds,
        'error': e.toString(),
      });
      if (mounted) setState(() => _timeline = null);
    }
  }

  Future<void> _loadServerSubchats() async {
    final watch = Stopwatch()..start();
    _logTiming('mellon.subchat_timing.sidebar_server_roots_start', {
      'page_limit': 100,
      'max_pages': 5,
    });
    try {
      final serverSubchats = await fetchServerAgentSubchats(
        widget.room,
        archivedThreadRootEventIds: {
          ...archivedAgentSubchatIdsForRoom(widget.room),
          ..._locallyArchivedSubchatIds,
        },
      );
      if (!mounted) return;
      setState(() => _serverSubchats = serverSubchats);
      _logTiming('mellon.subchat_timing.sidebar_server_roots_done', {
        'elapsed_ms': watch.elapsedMilliseconds,
        'subchat_count': serverSubchats.length,
      });
      await _refreshIndexedSubchatDetails(
        serverSubchats,
        source: 'server_roots',
      );
    } catch (e) {
      _logTiming('mellon.subchat_timing.sidebar_server_roots_error', {
        'elapsed_ms': watch.elapsedMilliseconds,
        'error': e.toString(),
      });
      if (mounted) setState(() => _serverSubchats = const []);
    }
  }

  Future<void> _syncSubchatIndexFromTimeline(Timeline timeline) async {
    final watch = Stopwatch()..start();
    try {
      final subchats = extractAgentSubchats(
        timeline,
        archivedThreadRootEventIds: {
          ...archivedAgentSubchatIdsForRoom(widget.room),
          ..._locallyArchivedSubchatIds,
        },
      );
      _logTiming('mellon.subchat_timing.sidebar_timeline_extract_done', {
        'elapsed_ms': watch.elapsedMilliseconds,
        'timeline_events': timeline.events.length,
        'subchat_count': subchats.length,
      });
      if (subchats.isEmpty) return;
      await _refreshIndexedSubchatDetails(subchats, source: 'timeline_extract');
    } catch (e) {
      _logTiming('mellon.subchat_timing.sidebar_timeline_extract_error', {
        'elapsed_ms': watch.elapsedMilliseconds,
        'timeline_events': timeline.events.length,
        'error': e.toString(),
      });
      // Best-effort cache warming; the live timeline should still render.
    }
  }

  Future<void> _refreshIndexedSubchatDetails(
    Iterable<AgentSubchat> subchats, {
    required String source,
  }) async {
    final watch = Stopwatch()..start();
    final indexedSubchats = subchats
        .where(
          (subchat) =>
              agentSubchatIndexEntryForRoom(
                widget.room,
                subchat.threadRootEventId,
              ) !=
              null,
        )
        .toList();
    if (indexedSubchats.isEmpty) {
      _logTiming('mellon.subchat_timing.sidebar_index_upsert_skipped', {
        'elapsed_ms': watch.elapsedMilliseconds,
        'source': source,
        'input_count': subchats.length,
        'indexed_count': 0,
      });
      return;
    }
    try {
      await upsertAgentSubchatIndexEntries(
        room: widget.room,
        subchats: indexedSubchats,
        agentUserId: widget.room.directChatMatrixID,
      );
      _logTiming('mellon.subchat_timing.sidebar_index_upsert_done', {
        'elapsed_ms': watch.elapsedMilliseconds,
        'source': source,
        'input_count': subchats.length,
        'indexed_count': indexedSubchats.length,
      });
    } catch (e) {
      _logTiming('mellon.subchat_timing.sidebar_index_upsert_error', {
        'elapsed_ms': watch.elapsedMilliseconds,
        'source': source,
        'input_count': subchats.length,
        'indexed_count': indexedSubchats.length,
        'error': e.toString(),
      });
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) {
    final timeline = _timeline;
    final archivedSubchatIds = {
      ...archivedAgentSubchatIdsForRoom(widget.room),
      ..._locallyArchivedSubchatIds,
    };
    var subchats = mergeAgentSubchats(
      room: widget.room,
      timeline: timeline,
      serverSubchats: _serverSubchats,
      archivedThreadRootEventIds: archivedSubchatIds,
    );
    final filter = widget.filter?.trim().toLowerCase();
    final parentMatches =
        filter == null ||
        filter.isEmpty ||
        widget.room.getLocalizedDisplayname().toLowerCase().contains(filter);
    if (filter != null && filter.isNotEmpty) {
      subchats = subchats
          .where(
            (subchat) =>
                subchat.title.toLowerCase().contains(filter) ||
                subchat.preview.toLowerCase().contains(filter),
          )
          .toList();
      if (!parentMatches && subchats.isEmpty) {
        return const SizedBox.shrink();
      }
    }
    final canCreateSubchat =
        widget.room.canSendDefaultMessages &&
        widget.room.membership == Membership.join &&
        (filter == null || filter.isEmpty || parentMatches);
    final mainChatRunning =
        timeline != null && hasActiveAiStreamForTimeline(timeline);
    final parentTrailing = mainChatRunning || canCreateSubchat
        ? Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (mainChatRunning) const _AgentRunningIndicator(),
              if (canCreateSubchat)
                _NewAgentSubchatButton(onPressed: _createSubchat),
            ],
          )
        : null;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ChatListItem(
          widget.room,
          space: widget.space,
          filter: parentMatches ? widget.filter : null,
          onTap: widget.onTap,
          onLongPress: widget.onLongPress,
          activeChat: widget.activeChat && widget.activeThreadId == null,
          suppressTypingText: isLikelyAgentRoom(widget.room),
          trailing: parentTrailing,
        ),
        FutureBuilder(
          future: _loadTimelineFuture,
          builder: (context, _) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final subchat in subchats)
                _AgentSubchatListTile(
                  subchat: subchat,
                  active:
                      widget.activeChat &&
                      widget.activeThreadId == subchat.threadRootEventId,
                  isRunning:
                      subchat.isRunning ||
                      timeline != null &&
                          hasActiveAiStreamForTimeline(
                            timeline,
                            threadRootEventId: subchat.threadRootEventId,
                          ),
                  onTap: () => widget.onSubchatTap(subchat.threadRootEventId),
                  onRename: subchat.canRename
                      ? () => _renameSubchat(subchat)
                      : null,
                  onMigrate:
                      agentSubchatIndexEntryForRoom(
                            widget.room,
                            subchat.threadRootEventId,
                          ) ==
                          null
                      ? () => _migrateSubchat(subchat)
                      : null,
                  onArchive: () => _archiveSubchat(subchat),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _NewAgentSubchatButton extends StatelessWidget {
  final void Function() onPressed;

  const _NewAgentSubchatButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return IconButton(
      tooltip: 'New subchat',
      iconSize: 20,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      color: theme.colorScheme.primary,
      onPressed: onPressed,
      icon: const AgentSubchatIcon(),
    );
  }
}

class _AgentSubchatListTile extends StatelessWidget {
  final AgentSubchat subchat;
  final bool active;
  final bool isRunning;
  final void Function() onTap;
  final VoidCallback? onRename;
  final VoidCallback? onMigrate;
  final VoidCallback onArchive;

  const _AgentSubchatListTile({
    required this.subchat,
    required this.active,
    required this.isRunning,
    required this.onTap,
    required this.onRename,
    required this.onMigrate,
    required this.onArchive,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final backgroundColor = active
        ? theme.colorScheme.secondaryContainer
        : null;
    final previewColor = active
        ? theme.colorScheme.onSecondaryContainer
        : theme.colorScheme.outline;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Material(
        borderRadius: BorderRadius.circular(AppConfig.borderRadius),
        clipBehavior: Clip.hardEdge,
        color: backgroundColor,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.only(
              left: 52,
              right: 4,
              top: 6,
              bottom: 6,
            ),
            child: Row(
              children: [
                Icon(
                  Icons.forum_outlined,
                  size: 18,
                  color: active
                      ? theme.colorScheme.onSecondaryContainer
                      : theme.colorScheme.outline,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              subchat.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: active ? FontWeight.w600 : null,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            subchat.updatedAt.localizedTimeShort(context),
                            style: TextStyle(fontSize: 11, color: previewColor),
                          ),
                        ],
                      ),
                      Row(
                        children: [
                          if (isRunning) ...[
                            const _AgentRunningIndicator(size: 12),
                            const SizedBox(width: 6),
                            Text(
                              'Thinking...',
                              style: TextStyle(
                                fontSize: 12,
                                color: theme.colorScheme.primary,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const SizedBox(width: 8),
                          ],
                          Expanded(
                            child: Text(
                              subchat.preview,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                color: previewColor,
                              ),
                            ),
                          ),
                          if (subchat.replyCount > 0) ...[
                            const SizedBox(width: 8),
                            Icon(
                              Icons.reply_outlined,
                              size: 14,
                              color: previewColor,
                            ),
                            const SizedBox(width: 2),
                            Text(
                              subchat.replyCount.toString(),
                              style: TextStyle(
                                fontSize: 11,
                                color: previewColor,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                _AgentSubchatMenuButton(
                  color: active
                      ? theme.colorScheme.onSecondaryContainer
                      : theme.colorScheme.onSurfaceVariant,
                  onRename: onRename,
                  onMigrate: onMigrate,
                  onArchive: onArchive,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AgentSubchatMenuButton extends StatelessWidget {
  final Color color;
  final VoidCallback? onRename;
  final VoidCallback? onMigrate;
  final VoidCallback onArchive;

  const _AgentSubchatMenuButton({
    required this.color,
    required this.onRename,
    required this.onMigrate,
    required this.onArchive,
  });

  @override
  Widget build(BuildContext context) => MenuAnchor(
    menuChildren: [
      MenuItemButton(
        leadingIcon: const Icon(Icons.edit_outlined),
        onPressed: onRename,
        child: const Text('Rename'),
      ),
      if (onMigrate != null)
        MenuItemButton(
          leadingIcon: const Icon(Icons.bookmark_add_outlined),
          onPressed: onMigrate,
          child: const Text('Save to sidebar'),
        ),
      MenuItemButton(
        leadingIcon: const Icon(Icons.archive_outlined),
        onPressed: onArchive,
        child: const Text('Archive'),
      ),
    ],
    builder: (context, controller, child) => SizedBox.square(
      dimension: 32,
      child: IconButton(
        tooltip: 'Subchat options',
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        icon: Icon(Icons.more_vert, size: 20, color: color),
        onPressed: () {
          if (controller.isOpen) {
            controller.close();
          } else {
            controller.open();
          }
        },
      ),
    ),
  );
}

class _AgentRunningIndicator extends StatelessWidget {
  final double size;

  const _AgentRunningIndicator({this.size = 16});

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return Tooltip(
      message: 'Agent is thinking',
      child: SizedBox.square(
        dimension: size,
        child: CircularProgressIndicator(strokeWidth: 1.7, color: color),
      ),
    );
  }
}
