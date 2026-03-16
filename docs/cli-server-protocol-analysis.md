# CLI Server Protocol Analysis

> What the `copilot --server --stdio` protocol exposes, what it doesn't,
> and what that means for building a Phoenix LiveView copilot terminal.

## Background

The GitHub Copilot CLI supports two distinct JSON-RPC protocols for
programmatic access:

| Property | ACP Protocol | CLI Server Protocol |
|---|---|---|
| **Flag** | `--acp --stdio` | `--server --stdio` |
| **Method naming** | Slash-separated (`session/new`) | Dot-separated (`session.create`) |
| **Transport** | Newline-delimited JSON | LSP Content-Length framing |
| **Event delivery** | Curated `session/update` (8 types) | Raw `session.event` (27+ types) |
| **Usage/tokens** | ❌ Not available | ✅ `assistant.usage` events |
| **Permission model** | Client-driven (`session/request_permission`) | Auto-approve (no callback) |
| **Prompt lifecycle** | Blocking (`session/prompt` returns on completion) | Fire-and-forget (`session.send` returns `messageId`, completion via `session.idle`) |
| **Visibility** | Documented in ACP spec | Hidden flag (`hideHelp()` in Commander.js) |

This document focuses on the **CLI Server protocol** — the richer of the two —
and analyzes its completeness for building a full copilot session UI.

## Event Forwarding Architecture

The Server protocol forwards **all** session events using a wildcard listener:

```javascript
// From CLIServer.setupSessionEventForwarding() in index.js
let handler = session.on("*", event => {
  let payload = { sessionId, event };
  for (let conn of this.connections) {
    conn.sendNotification("session.event", payload);
  }
});
```

This means every event the session emits — persistent and ephemeral — is
forwarded to the client in real-time. On session resume, non-ephemeral events
are replayed; ephemeral events (like `assistant.usage`) are only available
during the live session.

## Complete Event Type Reference

All 27 event types defined in `schemas/session-events.schema.json`, plus
additional types observed at runtime:

### Session Lifecycle

#### `session.start`

Emitted when a new session is created.

| Field | Type | Description |
|---|---|---|
| `sessionId` | `string` | UUID of the session |
| `selectedModel` | `string` | Model selected for this session |
| `copilotVersion` | `string` | CLI version |
| `producer` | `string` | Producer identifier |
| `startTime` | `string` | ISO 8601 timestamp |
| `version` | `number` | Schema version |

#### `session.idle`

Emitted when the model finishes processing and is waiting for user input.
**No data fields** — the event itself is the signal. This is the primary
mechanism for detecting turn completion in the Server protocol (replacing
ACP's blocking `session/prompt` response).

#### `session.resume`

Emitted when a previous session is resumed.

| Field | Type | Description |
|---|---|---|
| `resumeTime` | `string` | ISO 8601 timestamp |
| `eventCount` | `number` | Number of events in the resumed session |

#### `session.error`

| Field | Type | Description |
|---|---|---|
| `errorType` | `string` | Error classification |
| `message` | `string` | Human-readable error message |
| `stack` | `string` | Stack trace |

#### `session.info`

General informational messages from the session.

| Field | Type | Description |
|---|---|---|
| `infoType` | `string` | Info classification |
| `message` | `string` | Info message |

#### `session.model_change`

| Field | Type | Description |
|---|---|---|
| `previousModel` | `string` | Previous model identifier |
| `newModel` | `string` | New model identifier |

#### `session.truncation`

Emitted when the context window is truncated to fit within token limits.

| Field | Type | Description |
|---|---|---|
| `performedBy` | `string` | Who triggered truncation |
| `preTruncationMessagesLength` | `number` | Message count before |
| `postTruncationMessagesLength` | `number` | Message count after |
| `preTruncationTokensInMessages` | `number` | Token count before |
| `postTruncationTokensInMessages` | `number` | Token count after |
| `tokensRemovedDuringTruncation` | `number` | Tokens removed |
| `messagesRemovedDuringTruncation` | `number` | Messages removed |
| `tokenLimit` | `number` | Current token limit |

#### `session.handoff`

Emitted when a session is handed off to a remote session (e.g., Codespaces).

| Field | Type | Description |
|---|---|---|
| `remoteSessionId` | `string` | Remote session identifier |
| `sourceType` | `string` | Source type |
| `summary` | `string` | Session summary |
| `context` | `string` | Handoff context |
| `repository` | `object` | Repository info |
| `handoffTime` | `string` | ISO 8601 timestamp |

#### `session.import_legacy`

| Field | Type | Description |
|---|---|---|
| `sourceFile` | `string` | Legacy session file path |
| `legacySession` | `object` | Legacy session data |
| `importTime` | `string` | ISO 8601 timestamp |

### User Input

#### `user.message`

| Field | Type | Description |
|---|---|---|
| `content` | `string` | Raw user input |
| `transformedContent` | `string` | Processed input (with expansions) |
| `attachments` | `array` | File/directory attachments |
| `source` | `string` | Input source |

Each attachment has `type` (`"file"` or `"directory"`) and `path`.

### Assistant Output

#### `assistant.turn_start`

| Field | Type | Description |
|---|---|---|
| `turnId` | `string` | UUID for this turn |

#### `assistant.message`

The primary text output event. Emitted as both streaming chunks and final
content.

| Field | Type | Description |
|---|---|---|
| `messageId` | `string` | Message identifier |
| `content` | `string` | Full accumulated content |
| `chunkContent` | `string` | Incremental chunk (for streaming) |
| `totalResponseSizeBytes` | `number` | Total response size |
| `toolRequests` | `array` | Tool calls the model wants to make |
| `parentToolCallId` | `string` | If this message is within a tool call |

Each entry in `toolRequests` has:
- `toolCallId` — unique identifier for the tool call
- `name` — tool name (e.g., `"read_file"`, `"shell"`, `"write_file"`)
- `arguments` — tool-specific arguments (arbitrary JSON)

#### `assistant.intent`

The model's declared intent / thinking narration.

| Field | Type | Description |
|---|---|---|
| `intent` | `string` | Intent text |

#### `assistant.turn_end`

| Field | Type | Description |
|---|---|---|
| `turnId` | `string` | UUID matching the `turn_start` |

#### `assistant.usage` *(ephemeral)*

Token usage and cost data. Emitted on every successful model API call.
Ephemeral — not replayed on session resume.

| Field | Type | Description |
|---|---|---|
| `model` | `string` | Model identifier (e.g., `"claude-opus-4.6"`) |
| `inputTokens` | `number` | Input tokens consumed |
| `outputTokens` | `number` | Output tokens generated |
| `cacheReadTokens` | `number` | Tokens read from cache |
| `cacheWriteTokens` | `number` | Tokens written to cache |
| `cost` | `number` | Cost multiplier (Premium request units) |
| `duration` | `number` | API call duration in milliseconds |
| `initiator` | `string` | What triggered the call |
| `apiCallId` | `string` | API call identifier |
| `providerCallId` | `string` | Provider-side call ID |
| `quotaSnapshots` | `object` | Quota state at time of call |

### Tool Execution

The tool execution lifecycle is fully captured:

```
assistant.message (with toolRequests[])
  → tool.execution_start (toolName, arguments)
    → tool.execution_partial_result (streaming output)
  → tool.execution_complete (result or error)
```

#### `tool.execution_start`

| Field | Type | Description |
|---|---|---|
| `toolCallId` | `string` | Unique call identifier |
| `toolName` | `string` | Tool name (e.g., `"read_file"`, `"shell"`, `"write_file"`) |
| `arguments` | `any` | **Full tool arguments** — file paths, shell commands, edit content, etc. |
| `parentToolCallId` | `string` | Parent call if nested |

#### `tool.execution_partial_result` *(ephemeral)*

Streaming partial output from long-running tools (e.g., shell commands).

| Field | Type | Description |
|---|---|---|
| `toolCallId` | `string` | Matching call identifier |
| `partialOutput` | `string` | Incremental output chunk |

#### `tool.execution_complete`

| Field | Type | Description |
|---|---|---|
| `toolCallId` | `string` | Matching call identifier |
| `success` | `boolean` | Whether the tool succeeded |
| `result` | `object` | `{content: string}` — **full tool output** |
| `error` | `object` | `{message: string, code?: string}` if failed |
| `isUserRequested` | `boolean` | Whether user explicitly requested this tool |
| `toolTelemetry` | `object` | Additional telemetry data |
| `parentToolCallId` | `string` | Parent call if nested |

#### `tool.user_requested`

Emitted when the user explicitly requests a tool call (rather than the model
deciding to use one).

| Field | Type | Description |
|---|---|---|
| `toolCallId` | `string` | Call identifier |
| `toolName` | `string` | Tool name |
| `arguments` | `any` | Tool arguments |

### System Messages

#### `system.message`

Internal system prompts injected into the session.

| Field | Type | Description |
|---|---|---|
| `content` | `string` | System message content |
| `role` | `string` | `"system"` or `"developer"` |
| `name` | `string` | Message name/identifier |
| `metadata` | `object` | `{promptVersion, variables}` |

### Custom Agents

#### `custom_agent.selected`

| Field | Type | Description |
|---|---|---|
| `agentName` | `string` | Agent identifier |
| `agentDisplayName` | `string` | Display name |
| `tools` | `any` | Agent's available tools |

#### `custom_agent.started`

| Field | Type | Description |
|---|---|---|
| `agentName` | `string` | Agent identifier |
| `agentDisplayName` | `string` | Display name |
| `agentDescription` | `string` | Description |
| `toolCallId` | `string` | Associated tool call |

#### `custom_agent.completed` / `custom_agent.failed`

| Field | Type | Description |
|---|---|---|
| `agentName` | `string` | Agent identifier |
| `toolCallId` | `string` | Associated tool call |
| `error` | `string` | Error message (failed only) |

### Hooks

#### `hook.start` / `hook.end`

| Field | Type | Description |
|---|---|---|
| `hookInvocationId` | `string` | Hook invocation identifier |
| `hookType` | `string` | Hook type |
| `input` / `output` | `any` | Hook input (start) or output (end) |
| `success` | `boolean` | Whether hook succeeded (end only) |
| `error` | `object` | Error details (end only) |

### Other

#### `abort`

| Field | Type | Description |
|---|---|---|
| `reason` | `string` | Why the session was aborted |

### Runtime-Only Events (Not in Schema)

These event types were observed during live sessions but are not defined in
the JSON schema. They appear to be dynamically emitted:

| Event | Observed Context |
|---|---|
| `assistant.reasoning` | Model reasoning/thinking chunks (distinct from `assistant.intent`) |
| `pending_messages.modified` | Internal message queue changes |
| `session.usage_info` | Session-level usage summary |

## Capability Assessment for LiveView Terminal

### What You Can Build ✅

| Feature | How |
|---|---|
| **Multi-turn conversations** | `session.send` + wait for `session.idle` |
| **Streaming text output** | `assistant.message` with `chunkContent` |
| **Thinking/reasoning display** | `assistant.intent` + `assistant.reasoning` |
| **Tool call visualization** | `tool.execution_start` → `tool.execution_partial_result` → `tool.execution_complete` |
| **File read/write tracking** | `tool.execution_start` args contain paths; `tool.execution_complete` has full content |
| **Shell command display** | Same tool lifecycle — args have command, result has output |
| **Token usage dashboard** | `assistant.usage` events with per-call breakdown |
| **Cost tracking** | `cost` field = Premium request multiplier |
| **Session resume** | `session.resume` + `session.getMessages` replays history |
| **Model switching** | `session.model_change` events |
| **Context window monitoring** | `session.truncation` events show token pressure |
| **Turn boundary detection** | `assistant.turn_start` / `assistant.turn_end` + `session.idle` |
| **Full session persistence** | `session.getMessages` returns all non-ephemeral events |
| **Custom agent tracking** | `custom_agent.*` events |

### What You Cannot Build ❌

| Feature | Why | Workaround |
|---|---|---|
| **Interactive permission prompts** | Server mode does not set `requestPermission` callback — all tools auto-approve | Use `--allow-all-tools` (already required) or patch CLI |
| **Selective tool approval** | No mechanism to intercept tool execution | Accept auto-approve or use ACP protocol (loses usage data) |
| **Usage data on session resume** | `assistant.usage` is ephemeral — not replayed | Persist usage events yourself during live sessions |

### The Permission Gap in Detail

In the CLI's interactive terminal, when a tool requires confirmation, the
session calls its `requestPermission` callback, which shows a prompt like
"Run shell command `rm -rf /tmp/foo`? [y/n]".

The **ACP protocol** implements this — it sends `session/request_permission`
as a JSON-RPC request back to the client, blocking until the client responds.
This enables client-driven approval UIs.

The **Server protocol** does not set a `requestPermission` callback when
creating sessions:

```javascript
// From Session constructor (index.js):
permissions: this.requestPermission
  ? { requestRequired: true, request: this.requestPermission }
  : { requestRequired: false }
// Server mode: requestPermission is undefined → auto-approve
```

This means in server mode, every tool executes without asking. For a LiveView
terminal, you'd need to either:

1. **Accept auto-approve** — use `--allow-all-tools` (what we do now)
2. **Patch the CLI** — inject a `requestPermission` callback that sends a
   custom notification to the client and blocks until the client responds
3. **Dual protocol** — use ACP for the permission flow and Server for usage
   data (complex, two separate subprocesses)

## Session Persistence & Replay

The Server protocol supports full session reconstruction:

### Live Session Recording

During a live session, capture all `session.event` notifications. Each event
has:

```json
{
  "sessionId": "uuid",
  "event": {
    "id": "uuid",
    "type": "assistant.message",
    "data": { ... },
    "timestamp": "2025-02-20T...",
    "parentId": "uuid or null",
    "ephemeral": false
  }
}
```

Store all events (including ephemeral ones like `assistant.usage`) to build
a complete audit log.

### Session Replay via API

The `session.getMessages` request returns all **non-ephemeral** events:

```json
{"jsonrpc": "2.0", "id": 1, "method": "session.getMessages",
 "params": {"sessionId": "..."}}
```

Response:
```json
{"jsonrpc": "2.0", "id": 1, "result": {"events": [...]}}
```

This gives you every user message, assistant response, tool call with
arguments and results, system messages, and session lifecycle events —
everything needed to render a full session transcript.

### What's Missing from Replay

Ephemeral events are **not** included in `session.getMessages`:

- `assistant.usage` — token counts and costs
- `tool.execution_partial_result` — streaming tool output
- `assistant.message` chunks — only the final accumulated content persists
- `session.idle` — turn completion signals

To get a complete log including these, you must capture events in real-time
during the live session.

## Elixir Implementation

The `Jido.GHCopilot.Server.Connection` module implements the client side of
this protocol:

- **Transport**: LSP Content-Length framing over Erlang Port (`:stream` mode)
- **Init**: `ping` request to verify server readiness
- **Event routing**: `session.event` notifications dispatched to subscribers
  via `{:server_event, %SessionEvent{}}` messages
- **Turn lifecycle**: `send_prompt/5` returns `{:ok, message_id}` immediately;
  callers wait for `session.idle` event

See `lib/jido_ghcopilot/server/connection.ex` and
`lib/jido_ghcopilot/server/protocol.ex` for the implementation.

## Source References

All findings are based on analysis of the installed Copilot CLI at
`/usr/lib/node_modules/@github/copilot/`:

- `schemas/session-events.schema.json` — canonical event type definitions
  (27 types in `SessionEvent.anyOf`)
- `sdk/index.d.ts` — TypeScript type definitions including
  `AssistantUsageEventSchema` (lines 307-395)
- `index.js` — minified source containing:
  - `CLIServer.setupSessionEventForwarding()` — wildcard `session.on("*")`
    event forwarding
  - `CLIServer.registerMethods()` — JSON-RPC method handlers
  - `Session.requestPermission` — permission callback (unset in server mode)
  - `emitEphemeral("assistant.usage", ...)` — usage event emission on
    `model_call_success`
