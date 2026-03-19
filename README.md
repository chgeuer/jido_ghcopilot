# Jido.GHCopilot

`Jido.GHCopilot` is the GitHub Copilot CLI adapter for [Jido.Harness](https://github.com/agentjido/jido_harness).
It wraps the `copilot` CLI binary and exposes it through Jido's adapter and agent interfaces.

## Installation

```elixir
defp deps do
  [
    {:jido_ghcopilot, github: "chgeuer/jido_ghcopilot"}
  ]
end
```

## Requirements

- Elixir `~> 1.18`
- GitHub Copilot CLI installed and authenticated (`copilot` in PATH)

Verify your setup:

```bash
mix ghcopilot.compat
```

## Quick Start

### Validate the CLI

```elixir
Jido.GHCopilot.cli_installed?()
Jido.GHCopilot.compatible?()
```

### CLI Server mode — multi-turn sessions (recommended)

The CLI Server protocol is the **recommended** integration mode. It provides the
richest feature set: 27+ event types, token usage & cost tracking, mid-session model
switching, session listing, and external tool call handling.

```elixir
alias Jido.GHCopilot.Server.Connection

{:ok, conn} = Connection.start_link(cli_args: ["--allow-all-tools"])
{:ok, session_id} = Connection.create_session(conn, %{model: "gpt-5.1-codex"})
:ok = Connection.subscribe(conn, session_id)
{:ok, _message_id} = Connection.send_prompt(conn, session_id, "Fix the tests")

# Receive raw session events including assistant.usage with token counts
receive do
  {:server_event, event} -> IO.inspect(event)
end

Connection.stop(conn)
```

### Simple mode — single prompt

```elixir
{:ok, events} = Jido.GHCopilot.run("Summarize this repository")
Enum.each(events, &IO.inspect/1)
```

### ACP mode — multi-turn sessions (legacy)

ACP mode is still supported but provides fewer event types and no usage data.
Prefer CLI Server mode for new integrations.

```elixir
{:ok, conn, session_id} = Jido.GHCopilot.start_session(model: "claude-sonnet-4.6")
:ok = Jido.GHCopilot.subscribe(conn, session_id)
{:ok, :end_turn} = Jido.GHCopilot.send_prompt(conn, session_id, "Explain the auth module")

# Receive updates as {:acp_update, session_update} messages
receive do
  {:acp_update, update} -> IO.inspect(update)
end

Jido.GHCopilot.stop_session(conn)
```

## Three Execution Modes

### 1. CLI Server mode (recommended)

Spawns `copilot --server --stdio` as a long-lived Port. Communicates via JSON-RPC 2.0 with LSP-style `Content-Length` framing. Uses dot-separated method names (`session.create`, `session.send`).

This is the **recommended protocol** for new integrations. It provides the richest
feature set of all three modes:

- **27+ event types** — full visibility into session lifecycle, tool execution, permissions, and custom agents
- **Token usage & cost tracking** — `assistant.usage` events with input/output token counts, cache stats, cost, and quota
- **Mid-session model switching** — change the model without losing conversation context
- **Session management** — list, destroy, and resume sessions
- **External tool calls** — register custom tools and handle tool call requests
- **Fire-and-forget prompts** — `send_prompt/5` returns a `message_id` immediately; completion is signaled via `session.idle` events

Subscribers receive `{:server_event, session_event}` messages. Optionally uses a Node.js wrapper (`priv/copilot_wrapper/index.js`) for extended features like context-preserving model switching via `session.setModel`.

**Entry points:** `Jido.GHCopilot.Server.Connection`

### 2. Simple/Port mode

Spawns `copilot -p <prompt>` as an Erlang Port. Streams line-based output through `Mapper` into `Jido.Harness.Event` structs using `Stream.resource/3`. Single-prompt, fire-and-forget. Useful for quick one-off prompts where session management is not needed.

**Entry points:** `Jido.GHCopilot.run/2`, `Jido.GHCopilot.run_request/2`

### 3. ACP mode (Agent Client Protocol, legacy)

Spawns `copilot --acp --stdio` as a long-lived Port. Communicates via JSON-RPC 2.0 over stdin/stdout with newline-delimited JSON (NDJSON). Supports multi-turn sessions, thinking streams, tool calls, and session resume. Uses slash-separated method names (`session/new`, `session/prompt`).

ACP provides curated update types but lacks token usage data, cost tracking, session listing, and mid-session model switching. **Prefer CLI Server mode for new integrations.**

Subscribers receive `{:acp_update, session_update}` messages with curated update types:
`agent_message_chunk`, `agent_thought_chunk`, `tool_call`, `tool_call_update`, `plan`, `user_message_chunk`.

**Entry points:** `Jido.GHCopilot.start_session/1`, `send_prompt/4`, `subscribe/2`, `resume_session/3`

## Agent Mode

For Jido agent integration, `SessionAgent` provides a signal-driven state machine that mirrors `jido_claude`'s pattern. The `StartSession` action uses the CLI Server executor by default. Override via `:target`:

```elixir
# :server (default, recommended), :acp, or :port
{Jido.GHCopilot.Actions.StartSession, %{prompt: "Fix the bug"}}

# Explicitly select a different executor
{Jido.GHCopilot.Actions.StartSession, %{prompt: "Fix the bug", target: :acp}}
```

### Agent actions

- `StartSession` — initializes a session via the selected executor
- `HandleMessage` — processes streamed updates and emits signals to parent
- `CancelSession` — cancels a running session

### Parent agent actions

For multi-session orchestration, parent actions manage child `SessionAgent` processes:

- `Parent.SpawnSession` — registers and spawns a child session agent
- `Parent.HandleSessionEvent` — routes child signals to update the parent's session registry
- `Parent.CancelSession` — cancels a child session

## Signals

Signals use `Jido.Signal` with `type: "ghcopilot.<category>.<name>"` naming:

| Signal | Description |
|---|---|
| `ghcopilot.session.started` | Session initialized |
| `ghcopilot.session.success` | Session completed (includes result, turns, duration) |
| `ghcopilot.session.error` | Session failed or cancelled |
| `ghcopilot.turn.text` | Agent response text chunk |
| `ghcopilot.turn.thought` | Agent thinking/reasoning chunk |
| `ghcopilot.turn.tool_use` | Tool call requested |
| `ghcopilot.turn.tool_result` | Tool call status update |
| `ghcopilot.turn.plan` | Agent's structured plan |
| `ghcopilot.turn.usage` | Token/cost usage metrics |

## CLI Server Mode API (recommended)

- `Server.Connection.start_link/1` — start a connection
- `Server.Connection.create_session/3` — create a session (supports model, system message, tool config)
- `Server.Connection.send_prompt/5` — send a prompt (fire-and-forget, returns `message_id`)
- `Server.Connection.subscribe/2` / `unsubscribe/2` — event subscriptions
- `Server.Connection.resume_session/4` / `destroy_session/3` — session lifecycle
- `Server.Connection.list_sessions/2` — list all sessions
- `Server.Connection.set_model/4` — change model mid-session (requires Node.js wrapper)
- `Server.Connection.respond_to_tool_call/3` — respond to tool call requests
- `Server.Connection.respond_to_external_tool/4` — handle external tool calls

## Simple Mode API

- `Jido.GHCopilot.run/2` — run a prompt, returns `{:ok, event_stream}`
- `Jido.GHCopilot.run_request/2` — run a pre-built `%Jido.Harness.RunRequest{}`
- `Jido.GHCopilot.cancel/1` — cancel by session id

## ACP Mode API (legacy)

- `Jido.GHCopilot.start_session/1` — returns `{:ok, conn, session_id}`
- `Jido.GHCopilot.send_prompt/4` — returns `{:ok, stop_reason}`
- `Jido.GHCopilot.subscribe/2` — subscribe to session updates
- `Jido.GHCopilot.resume_session/3` — resume a previous session
- `Jido.GHCopilot.cancel_session/2` — cancel an ACP session
- `Jido.GHCopilot.stop_session/1` — stop the connection and subprocess

## Model Resolution

The model registry supports fuzzy matching so you don't need exact CLI IDs:

```elixir
Jido.GHCopilot.resolve_model("opus 4.6")    #=> {:ok, "claude-opus-4.6"}
Jido.GHCopilot.resolve_model("gemini")       #=> {:ok, "gemini-3-pro-preview"}
Jido.GHCopilot.models()                      # list all available models
```

```bash
mix ghcopilot.models                         # list models in terminal
mix ghcopilot.models --search opus            # filter by name
mix ghcopilot.models --resolve "Claude Opus"  # resolve to CLI ID
```

## Simple Mode Event Types

In simple/Port mode, CLI output lines are classified into `Jido.Harness.Event` structs:

| Event Type | Description |
|---|---|
| `:session_started` | Session initialized |
| `:output_text_delta` | Regular text output |
| `:ghcopilot_error` | Error output lines |
| `:ghcopilot_warning` | Warning output lines |
| `:ghcopilot_status` | Status indicators (●, ◐) |
| `:ghcopilot_separator` | Visual separators (─, ━) |
| `:ghcopilot_file_change_summary` | Git-style change summaries |
| `:session_completed` | Successful completion |
| `:session_failed` | Error or timeout |

## Metadata Contract (Simple Mode)

`request.metadata["ghcopilot"]` supports provider-specific overrides:

- `"model"` — LLM model name
- `"silent"` — suppress stats output (default `true`)
- `"continue"` — resume the most recent session
- `"resume"` — `true` or a session id string
- `"add_dirs"` — additional directories to allow
- `"env"` — environment variables

Precedence: runtime adapter opts > `metadata["ghcopilot"]` > defaults from `RunRequest`.

## Mix Tasks

```bash
mix ghcopilot.compat                           # validate CLI installation
mix ghcopilot.models                           # list available models
mix ghcopilot.smoke                            # ACP smoke test
mix ghcopilot.smoke --server                   # CLI Server smoke test (shows token usage)
mix ghcopilot.smoke --model claude-sonnet-4.6  # test with specific model
```

## Development

```bash
mix setup                       # install deps + git hooks
mix test                        # run tests (integration excluded)
mix test --include integration  # include integration tests (requires copilot CLI + auth)
mix quality                     # compile --warnings-as-errors, format, credo, dialyzer, doctor
```

## License

Apache-2.0. See [LICENSE](LICENSE).
