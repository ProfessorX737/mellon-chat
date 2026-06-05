# Agent sub-chats design

Date: 2026-05-15

## Goal

Make Mellon Chat feel closer to Codex's project/chat structure:

- A top-level "agent" maps to an OpenClaw agent identity and workspace.
- Each agent has a main chat.
- Each agent can have many simultaneous sub-chats.
- Sub-chats should keep independent OpenClaw session state while remaining easy to browse in Mellon Chat.

## Repository cleanup

The old side repositories were archived to avoid confusing them with the live OpenClaw code:

- `~/archive/openclaw-matrix-side-repos-2026-05-15/mellon-matrix`
- `~/archive/openclaw-matrix-side-repos-2026-05-15/openclaw-matrix-plugin`

The active OpenClaw checkout is `~/Documents/ai/openclaw`. That path is a symlink through `~/Documents/ai` to the external drive. The launch agent runs the built OpenClaw gateway from this checkout, and the active config enables the bundled `matrix` plugin entry. I found no active config reference to either archived side repo.

## Current state

### OpenClaw

The live Matrix extension already parses Matrix thread relations:

- `extensions/matrix/src/matrix/monitor/threads.ts`
- `extensions/matrix/src/matrix/monitor/handler.ts`

It also replies in a thread when `threadReplies` is `inbound` or `always`.

The important gap is that the Matrix handler currently resolves the agent session key from only:

- Matrix account id, such as `alfred` or `jarvis`
- peer kind, `dm` or `channel`
- peer id, usually sender id for DMs or room id for channels

It does not include `threadRootId` in the session key. So multiple Matrix threads inside the same agent DM are visually separate in the client, but they still hit the same OpenClaw session unless the handler is changed.

The router has `parentPeer` support for thread inheritance, but the Matrix handler does not currently use it.

### Mellon Chat

Mellon Chat already has useful building blocks:

- Matrix spaces are shown as folder-like items in the room list and nav rail.
- `SpaceView` can create child rooms/subspaces and attach them to a space.
- Chat state has `activeThreadId`.
- Sending messages, files, emoji, and several media paths pass `threadRootEventId`.
- The timeline filter hides thread replies in the main timeline and shows only a thread root plus its replies inside a thread.

The client gaps are mostly UX and keying:

- There is no first-class "new subchat" action.
- Thread entry is exposed only from selected messages or from messages that already have replies.
- The chat list does not show thread roots as nested sub-chat rows under an agent.
- Drafts are keyed by `roomId`, not `roomId + threadId`.
- The model catalog and model picker state are keyed by `roomId`, not `roomId + threadId`.
- The app bar labels an active thread generically as "reply in thread" rather than showing a sub-chat title.

## Feasibility

This is feasible. The lowest-risk MVP is to model sub-chats as Matrix threads inside one DM/room per agent.

That gives us:

- Natural Matrix compatibility.
- No explosion of rooms.
- A small OpenClaw change to split sessions by thread root.
- A moderate Mellon Chat UI change to display and create sub-chats.

Separate Matrix rooms per sub-chat are possible, but they are a more awkward first version. OpenClaw currently treats two-person rooms as DMs, and the default DM session scope collapses many DMs with the same sender into the agent's main session. Making separate-room sub-chats work reliably would require a room-state marker or direct-room override on the OpenClaw side, plus more room creation/invite behavior in Mellon Chat.

## Recommended architecture

Use Matrix threads for sub-chats.

### Data model

Main chat:

- Matrix room id identifies the agent conversation.
- OpenClaw session key remains the existing route session key.

Sub-chat:

- Matrix room id identifies the agent room.
- Matrix thread root event id identifies the sub-chat.
- OpenClaw session key becomes a derived key from base route session plus thread root id.

Suggested session key shape:

```text
<base-route-session-key>:thread:<sanitized-thread-root-event-id>
```

The handler should also carry parent context:

- `MessageThreadId`: Matrix thread root event id
- `ChatType`: `thread` or `direct-thread`
- `ConversationLabel`: agent room display name
- `ThreadLabel`: sub-chat title when available

Important: do not blindly set `ParentSessionKey` for every sub-chat. OpenClaw's session initialization can use `ParentSessionKey` to fork the parent transcript into the new session. That is useful for an explicit "branch from main chat" action, but it is not the right default for fresh Codex-style sub-chats. The default should be:

- Fresh sub-chat: unique thread session key, no parent transcript fork.
- Branch sub-chat: unique thread session key plus `ParentSessionKey` when the user explicitly wants existing conversation context copied in.

### Sub-chat title

For MVP, the thread root message body can be the title. Later, add a custom content block:

```json
{
  "msgtype": "m.text",
  "body": "Investigate notifications bug",
  "org.mellonchat.subchat": {
    "type": "agent_subchat",
    "title": "Investigate notifications bug",
    "agentUserId": "@jarvis:localhost",
    "createdAt": "2026-05-15T00:00:00.000Z"
  }
}
```

This keeps the event readable in normal Matrix clients while giving Mellon Chat a stable marker for nested lists.

## Implementation plan

### Phase 1: OpenClaw session split

1. In the Matrix handler, after `threadRootId` is resolved, derive a thread session key when present.
2. Use the derived key for `previousTimestamp`, inbound context, and `recordInboundSession`.
3. Preserve the base route session as non-forking metadata for navigation/return routing. Only set `ParentSessionKey` for an explicit branch/fork mode.
4. Keep `MessageThreadId` unchanged so replies remain Matrix-threaded.
5. Add tests proving two thread roots in the same Matrix room produce two separate session keys and inherit the same agent binding.

This is the main server-side blocker.

### Phase 2: Mellon Chat thread-aware state

1. Add a helper for the active conversation key:

```text
roomId when activeThreadId is null
roomId:thread:activeThreadId when activeThreadId is set
```

2. Use that key for drafts.
3. Use that key for model catalog cache and auto-fetch attempts.
4. Send `/model` and `/model <id>` with `threadRootEventId` when inside a sub-chat.
5. Update the model request state event if per-thread catalog/selection needs to become independent. If catalog is shared per agent but current selection is per session, use a separate thread-aware current-selection event or command response.

### Phase 3: Mellon Chat sub-chat UI

1. Add a "new subchat" action on agent DM rooms.
2. Create a thread root event with `org.mellonchat.subchat` metadata and enter that thread immediately.
3. Add a nested list under each detected agent room:
   - Main chat
   - Sub-chat thread roots
   - Last reply preview
   - Unread/notification indicator where available
4. Update the chat app bar to show the sub-chat title while `activeThreadId` is set.
5. Add rename/archive affordances for sub-chat roots using custom metadata or a local account-data index.

### Phase 4: Optional agent folders

There are two reasonable folder strategies:

- Matrix spaces: use one space per agent and put the agent main room plus related rooms inside it.
- Virtual folders: derive agents from OpenClaw Matrix account ids, bot user ids, and bot metadata, then render a custom agent list in Mellon Chat.

Virtual folders are better for the thread-based MVP because sub-chats are events, not rooms. Matrix spaces become more valuable if we later choose separate rooms per sub-chat.

## Open questions

- Should sub-chat titles be encrypted Matrix message content only, or also mirrored into unencrypted room/account state for faster list rendering?
- Should model selection be per sub-chat, per agent, or inherited from the main chat until changed?
- Should an agent's workspace path be shown in the Mellon Chat UI, or only used as metadata?
- Should archived sub-chats be hidden by client-side account data, redacted root events, or a custom state/index event?

## Recommendation

Build the thread-based MVP first. It fits the Matrix protocol, requires the least room-management machinery, and uses Mellon Chat code that already exists. The critical first patch is OpenClaw session splitting by `threadRootId`; without that, the UI can look like sub-chats but the agent memory will still be shared.
