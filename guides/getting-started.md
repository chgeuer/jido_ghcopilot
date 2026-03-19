# Getting Started with Jido.GHCopilot

## Prerequisites

- Elixir ~> 1.18
- GitHub Copilot CLI installed and authenticated

### Installing the Copilot CLI

The GitHub Copilot CLI can be installed via:

```bash
# Via gh CLI extension
gh copilot

# Or directly (if available as standalone)
# The `copilot` binary should be in your PATH
```

Verify installation:

```bash
copilot --version
```

## Add to your project

```elixir
# mix.exs
defp deps do
  [
    {:jido_harness, "~> 0.1"},
    {:jido_ghcopilot, "~> 0.1"}
  ]
end
```

## Basic Usage

### Check compatibility

```elixir
# Is the CLI installed?
Jido.GHCopilot.cli_installed?()

# Is it compatible with our requirements?
Jido.GHCopilot.compatible?()
```

## Multi-turn sessions with CLI Server mode (recommended)

The CLI Server protocol is the **recommended** way to integrate with the Copilot CLI.
It provides the richest feature set of all three modes:

- 27+ event types for full visibility into session lifecycle
- Token usage & cost tracking via `assistant.usage` events
- Mid-session model switching
- Session listing and management
- External tool call handling
- Fire-and-forget prompts (non-blocking)

```elixir
alias Jido.GHCopilot.Server.Connection

# Start a connection to the Copilot CLI
{:ok, conn} = Connection.start_link(cli_args: ["--allow-all-tools"])

# Create a session (optionally specifying a model)
{:ok, session_id} = Connection.create_session(conn, %{model: "gpt-5.1-codex"})

# Subscribe to receive session events
:ok = Connection.subscribe(conn, session_id)

# Send a prompt (returns immediately with a message_id)
{:ok, _message_id} = Connection.send_prompt(conn, session_id, "Explain this codebase")

# Collect events until the session goes idle
defmodule Collector do
  def collect(events \\\\ []) do
    receive do
      {:server_event, %{type: "session.idle"}} ->
        Enum.reverse(events)

      {:server_event, event} ->
        collect([event | events])
    after
      120_000 -> {:timeout, Enum.reverse(events)}
    end
  end
end

events = Collector.collect()
IO.inspect(events, label: "session events")

# Clean up
Connection.stop(conn)
```

### Multi-turn conversation

```elixir
alias Jido.GHCopilot.Server.Connection

{:ok, conn} = Connection.start_link(cli_args: ["--allow-all-tools"])
{:ok, session_id} = Connection.create_session(conn, %{model: "claude-sonnet-4.6"})
:ok = Connection.subscribe(conn, session_id)

# First turn
{:ok, _} = Connection.send_prompt(conn, session_id, "What files are in the src/ directory?")
# ... collect events until session.idle ...

# Second turn (same session, maintains context)
{:ok, _} = Connection.send_prompt(conn, session_id, "Now explain the main entry point")
# ... collect events until session.idle ...

Connection.stop(conn)
```

### Token usage tracking

CLI Server mode delivers `assistant.usage` events with detailed cost information:

```elixir
receive do
  {:server_event, %{type: "assistant.usage", data: usage}} ->
    IO.puts("Input tokens: #{usage["inputTokens"]}")
    IO.puts("Output tokens: #{usage["outputTokens"]}")
    IO.puts("Cost: #{usage["cost"]}")
end
```

## Simple mode — single prompt

For quick one-off prompts where you don't need session management:

```elixir
# Simple prompt
{:ok, events} = Jido.GHCopilot.run("Explain this codebase")
Enum.each(events, &IO.inspect/1)

# With options
{:ok, events} = Jido.GHCopilot.run("Fix the bug in main.js",
  cwd: "/path/to/project",
  model: "gpt-5"
)
```

### Using RunRequest

```elixir
{:ok, request} = Jido.Harness.RunRequest.new(%{
  prompt: "Refactor the auth module",
  cwd: "/path/to/project",
  model: "claude-sonnet-4",
  metadata: %{
    "ghcopilot" => %{
      "add_dirs" => ["/path/to/shared/lib"],
      "silent" => true
    }
  }
})

{:ok, events} = Jido.GHCopilot.run_request(request)
```

### Cancel a running session

```elixir
# Session ID is available from the :session_started event
:ok = Jido.GHCopilot.cancel("ghcopilot-A1B2C3D4")
```

## Choosing a Protocol

| Requirement | Recommended Mode | Entry Point |
|---|---|---|
| Multi-turn sessions | **CLI Server** | `Server.Connection` |
| Token usage & cost tracking | **CLI Server** | `Server.Connection` |
| Mid-session model switching | **CLI Server** | `Server.Connection.set_model/4` |
| Session listing | **CLI Server** | `Server.Connection.list_sessions/2` |
| External tool calls | **CLI Server** | `Server.Connection` |
| Quick one-off prompts | Simple/Port | `Jido.GHCopilot.run/2` |
| Agent integration | **CLI Server** (default) | `Actions.StartSession` |

## Simple Mode Event Types

Events emitted during a simple mode session:

| Event Type | Description |
|---|---|
| `:session_started` | Session initialized |
| `:output_text_delta` | Regular text output |
| `:ghcopilot_error` | Error output |
| `:ghcopilot_warning` | Warning output |
| `:ghcopilot_status` | Status indicators |
| `:session_completed` | Successful completion |
| `:session_failed` | Error or timeout |
