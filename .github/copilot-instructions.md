# Copilot Instructions — Jido.GHCopilot

## Build, Test, Lint

```bash
mix setup          # Install deps + git hooks
mix test           # Run all tests (integration tests excluded by default)
mix test test/jido/ghcopilot/mapper_test.exs           # Single test file
mix test test/jido/ghcopilot/mapper_test.exs:6          # Single test by line number
mix test --include integration                          # Include integration tests (requires `copilot` CLI + auth)
mix quality        # Full quality suite: compile --warnings-as-errors, format check, credo, dialyzer, doctor
mix format         # Auto-format code
```

Line length limit is 120 characters (enforced by formatter and Credo).

## Architecture

This is a GitHub Copilot CLI adapter for the [Jido.Harness](https://github.com/agentjido/jido_harness) framework. It wraps the `copilot` CLI binary and exposes it through Jido's adapter interface.

### Three execution modes

1. **Simple/Port mode** (`Jido.GHCopilot.run/2`, `Executor.Port`) — Spawns `copilot -p <prompt>` as an Erlang Port, streams line-based output through `Mapper` into `Jido.Harness.Event` structs. Uses `Stream.resource/3` for lazy event streaming. Single-prompt, fire-and-forget.

2. **ACP mode** (`Jido.GHCopilot.start_session/1`, `send_prompt/4`, `Executor.ACP`) — Spawns `copilot --acp --stdio` as a long-lived Port, communicates via JSON-RPC 2.0 over stdin/stdout with newline-delimited JSON (NDJSON). Supports multi-turn sessions, thinking streams, tool calls, and session resume. The `ACP.Connection` GenServer manages the Port and multiplexes concurrent sessions. Delivers curated `session/update` notifications. Uses slash-separated method names (`session/new`, `session/prompt`).

3. **CLI Server mode** (`Executor.Server`, `Server.Connection`) — Spawns `copilot --server --stdio` as a long-lived Port, communicates via JSON-RPC 2.0 with LSP-style `Content-Length` framing (not NDJSON). Provides the same multi-turn capabilities as ACP but additionally surfaces token usage, cost, and quota data via raw `session.event` notifications (27+ event types including `assistant.usage`). Uses dot-separated method names (`session.create`, `session.send`). Subscribers receive `{:server_event, session_event}` messages (vs ACP's `{:acp_update, ...}`). Optionally uses a Node.js wrapper script (`priv/copilot_wrapper/index.js`) for extended features like `session.setModel`.

### Key module roles

- `Jido.GHCopilot` — Public API facade; validates options with Zoi schemas, delegates to Adapter or ACP.Connection
- `Jido.GHCopilot.Adapter` — Implements `Jido.Harness.Adapter` behaviour (simple mode); builds CLI args, manages Port lifecycle
- `Jido.GHCopilot.Mapper` — Classifies raw CLI output lines into typed events (error, warning, separator, status, file_change_summary, output_text)
- `Jido.GHCopilot.Options` — Three-layer option merging: runtime opts > `metadata["ghcopilot"]` > request defaults
- `Jido.GHCopilot.ACP.Connection` — GenServer for ACP NDJSON connection; handles init handshake, session management, subscriber fan-out
- `Jido.GHCopilot.ACP.Protocol` — JSON-RPC 2.0 encode/decode for ACP messages
- `Jido.GHCopilot.Server.Connection` — GenServer for CLI Server LSP-framed connection; same role as ACP.Connection but with Content-Length framing and raw event passthrough
- `Jido.GHCopilot.Server.Protocol` — JSON-RPC 2.0 encode/decode for CLI Server messages (dot-separated methods, `session.event` notifications, `UsageEvent` decoding)
- `Jido.GHCopilot.SessionAgent` — Jido Agent with signal-driven state machine for session lifecycle (mirrors jido_claude's pattern)
- `Jido.GHCopilot.Executor` — Behaviour with three implementations: `Executor.Port`, `Executor.ACP`, and `Executor.Server`
- `Jido.GHCopilot.SessionRegistry` — ETS-backed registry for active sessions, used for cancellation

### Signals

Signals under `Jido.GHCopilot.Signals.*` use `Jido.Signal` with `type: "ghcopilot.<category>.<name>"` naming. Each signal module defines its own schema.

## Conventions

- **Validation**: Use [Zoi](https://hex.pm/packages/zoi) for option schemas and struct validation (not Ecto changesets).
- **Errors**: Use [Splode](https://hex.pm/packages/splode) structured errors via `Jido.GHCopilot.Error`. Error classes: `Invalid`, `Execution`, `Config`, `Internal`. Use the factory functions `Error.validation_error/2`, `Error.execution_error/2`, `Error.config_error/2`.
- **Testing**: Tests use Application env-based stubs (not Mox). Stubs are in `test/support/stubs.ex`. Configure stub behavior per-test via `Application.put_env(:jido_ghcopilot, :stub_*_fn, fn -> ... end)`. Tests that need real CLI are tagged `@tag :integration` and excluded by default.
- **Dependency injection**: Modules are swappable via Application config keys (`:adapter_module`, `:mapper_module`, `:compatibility_module`, `:cli_module`). Test config sets these to stub modules.
- **Conventional commits**: Use `feat`, `fix`, `docs`, `refactor`, `test`, `chore`, `ci` prefixes.
- **Coverage threshold**: 90% (ExCoveralls).
- **Jido patterns**: Follow jido_claude's patterns for agents, actions, and signals. `SessionAgent` uses `use Jido.Agent` with schema fields and `signal_routes/0`.
