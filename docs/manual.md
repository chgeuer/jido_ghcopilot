# jido_ghcopilot Integration Manual

How to use `jido_ghcopilot` from an Elixir application to interact with GitHub Copilot's LLM via the Server protocol (not by shelling out to the CLI).

## Dependencies

Add `jido_ghcopilot` and its required transitive path dependencies to your `mix.exs`:

```elixir
defp deps do
  [
    # ... your other deps ...

    # GitHub Copilot LLM integration
    {:jido_ghcopilot, path: "~/github/agentjido/jido_ghcopilot"},

    # Required transitive overrides (not on hex.pm)
    {:jido_shell, path: "~/github/agentjido/jido_shell", override: true},
    {:jido_harness, path: "~/github/agentjido/jido_harness", override: true},
    {:jido_vfs, path: "~/github/agentjido/jido_vfs", override: true},
    {:sprites, github: "mikehostetler/sprites-ex", override: true},
  ]
end
```

The `override: true` is needed because `jido_ghcopilot` declares these as local path deps — your app must re-declare them with the same paths so Mix can resolve them.

## Prerequisites

- **`copilot` CLI binary** in `PATH` (or set `COPILOT_CLI_PATH` env var)
- **GitHub authentication**: `GH_TOKEN` or `GITHUB_TOKEN` env var, or `gh auth` login
- **Node.js**: The default connection mode uses a Node.js wrapper script for the Server protocol

Check compatibility:

```bash
mix ghcopilot.compat
```

## Architecture: Three Modes

| Mode | Protocol | Use Case |
|------|----------|----------|
| **Simple/Port** | `copilot -p "prompt"` | One-shot prompts, no session state |
| **ACP** | JSON-RPC 2.0 over NDJSON | Multi-turn sessions, streaming |
| **Server** (recommended) | JSON-RPC 2.0 over LSP framing | Long-lived sessions, tool calling, usage tracking |

This manual covers the **Server** mode — it's the most capable and what `copilot_lv` uses in production.

## Core API: `Jido.GHCopilot.Server.Connection`

This is a GenServer that manages a long-lived Copilot CLI subprocess using the `--server --stdio` protocol.

### Starting a Connection

```elixir
alias Jido.GHCopilot.Server.Connection

{:ok, conn} = Connection.start_link(
  cli_args: ["--allow-all-tools", "--allow-all-paths", "--allow-all-urls"],
  cwd: File.cwd!()
)
```

**Options:**
- `cli_args` — extra CLI flags passed to `copilot --server --stdio <cli_args>`
- `cwd` — working directory for the copilot process
- `cli_path` — override path to the copilot binary (default: auto-detect)
- `use_wrapper` — use the Node.js wrapper script (default: `true`)
- `permission_handler` — `:auto_approve` (default) or custom handler

**Important:** `--allow-all-tools` is required for non-interactive use. Without it, Copilot blocks on permission prompts.

### Creating a Session

```elixir
{:ok, session_id} = Connection.create_session(conn, %{
  model: "claude-sonnet-4",   # optional, uses default if omitted
  tools: [my_custom_tool]     # optional, external tool definitions
})
```

### Subscribing to Events

Subscribe the current process to receive session events as messages:

```elixir
:ok = Connection.subscribe(conn, session_id)
```

After subscribing, you'll receive messages in two forms:
- `{:server_event, %{type: type, data: data}}` — session events (text, thinking, tool use, usage)
- `{:server_tool_call, %{tool_name: name, arguments: args, request_id: id}}` — external tool calls

### Sending a Prompt

```elixir
{:ok, message_id} = Connection.send_prompt(conn, session_id, "Explain transformers")
```

This is **non-blocking** — the response streams back as `:server_event` messages to subscribed processes.

**With file attachments:**

```elixir
{:ok, _} = Connection.send_prompt(conn, session_id, "Review this code", %{
  attachments: [
    %{type: :file, path: "/path/to/file.ex", display_name: "my_module.ex"}
  ]
})
```

### Receiving Events

Events arrive as Erlang messages to the subscribed process:

```elixir
def handle_info({:server_event, %{type: type, data: data}}, state) do
  case type do
    "assistant.message.chunk" ->
      # Streaming text chunk
      text = data["chunkContent"] || ""
      IO.write(text)

    "assistant.thought.chunk" ->
      # Thinking/reasoning chunk
      thought = data["chunkContent"] || ""
      Logger.debug("Thinking: #{thought}")

    "assistant.message.complete" ->
      # Full message assembled
      full_text = data["content"]
      IO.puts("\n\nComplete: #{full_text}")

    "tool.execution_start" ->
      Logger.info("Tool: #{data["toolName"]}")

    "tool.execution_complete" ->
      Logger.info("Tool done: #{data["toolName"]}")

    "assistant.usage" ->
      # Token usage and cost
      IO.puts("Tokens: #{data["inputTokens"]}in / #{data["outputTokens"]}out")
      IO.puts("Cost: #{data["cost"]}")

    "session.idle" ->
      # Turn complete, session is ready for next prompt
      IO.puts("Ready for next prompt")

    _ ->
      Logger.debug("Event: #{type}")
  end

  {:noreply, state}
end
```

### Responding to Tool Calls

If you registered custom tools, Copilot may call them:

```elixir
def handle_info({:server_tool_call, tool_call}, state) do
  result = case tool_call.tool_name do
    "my_tool" ->
      # Execute your tool logic
      %{"result" => "tool output"}

    _ ->
      %{"error" => "Unknown tool: #{tool_call.tool_name}"}
  end

  Connection.respond_to_tool_call(state.conn, tool_call.request_id, result)
  {:noreply, state}
end
```

### Other Operations

```elixir
# Resume a previous session
{:ok, session_id} = Connection.resume_session(conn, previous_session_id)

# Switch model (requires creating a new session)
{:ok, new_session_id} = Connection.create_session(conn, %{model: "gpt-4.1"})

# List all sessions
{:ok, sessions} = Connection.list_sessions(conn)

# Destroy a session
:ok = Connection.destroy_session(conn, session_id)

# Stop the connection (kills the subprocess)
:ok = Connection.stop(conn)
```

## Complete Example: Autonomous Agent

This is the pattern used by `copilot_lv` — a GenServer wrapping the Connection that can be used from LiveView or other processes:

```elixir
defmodule MyApp.CopilotSession do
  use GenServer
  require Logger

  alias Jido.GHCopilot.Server.Connection

  defstruct [:conn, :session_id, :model, status: :starting, text_buffer: ""]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def prompt(text) do
    GenServer.call(__MODULE__, {:prompt, text}, :infinity)
  end

  @impl true
  def init(opts) do
    model = Keyword.get(opts, :model, "claude-sonnet-4")
    state = %__MODULE__{model: model}
    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    {:ok, conn} = Connection.start_link(
      cli_args: ["--allow-all-tools", "--allow-all-paths", "--allow-all-urls",
                 "--model", state.model],
      cwd: File.cwd!()
    )

    {:ok, session_id} = Connection.create_session(conn, %{model: state.model})
    :ok = Connection.subscribe(conn, session_id)

    {:noreply, %{state | conn: conn, session_id: session_id, status: :idle}}
  end

  @impl true
  def handle_call({:prompt, text}, from, %{status: :idle} = state) do
    {:ok, _msg_id} = Connection.send_prompt(state.conn, state.session_id, text)
    {:noreply, %{state | status: {:waiting, from}, text_buffer: ""}}
  end

  @impl true
  def handle_info({:server_event, %{type: "assistant.message.chunk", data: data}}, state) do
    chunk = data["chunkContent"] || ""
    {:noreply, %{state | text_buffer: state.text_buffer <> chunk}}
  end

  def handle_info({:server_event, %{type: "session.idle"}}, %{status: {:waiting, from}} = state) do
    # Turn complete — reply to caller with accumulated text
    GenServer.reply(from, {:ok, state.text_buffer})
    {:noreply, %{state | status: :idle, text_buffer: ""}}
  end

  def handle_info({:server_event, _event}, state), do: {:noreply, state}

  def handle_info({:server_tool_call, tool_call}, state) do
    # Auto-deny any tool calls in this simple example
    Connection.respond_to_tool_call(state.conn, tool_call.request_id, %{
      "error" => "No tools available"
    })
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{conn: conn}) when not is_nil(conn) do
    Connection.stop(conn)
  end
  def terminate(_, _), do: :ok
end
```

Usage:

```elixir
{:ok, _} = MyApp.CopilotSession.start_link(model: "claude-sonnet-4")
{:ok, response} = MyApp.CopilotSession.prompt("What is 2 + 2?")
IO.puts(response)
# => "2 + 2 equals 4."
```

## Event Types Reference

Events received after subscribing (`{:server_event, %{type: type, data: data}}`):

| Type | Description | Key Data Fields |
|------|-------------|-----------------|
| `assistant.message.chunk` | Streaming text chunk | `chunkContent` |
| `assistant.message.complete` | Full assembled message | `content` |
| `assistant.thought.chunk` | Thinking/reasoning chunk | `chunkContent` |
| `assistant.turn_start` | Assistant begins responding | — |
| `assistant.usage` | Token usage & cost | `model`, `inputTokens`, `outputTokens`, `cost` |
| `tool.execution_start` | Tool begins executing | `toolName` |
| `tool.execution_complete` | Tool finished | `toolName`, `result`, `error` |
| `session.idle` | Turn complete, ready for next prompt | — |
| `user.message` | Echo of sent user message | `content` |

## Available Models

List models programmatically:

```elixir
Jido.GHCopilot.models()          # List all available models
Jido.GHCopilot.resolve_model("opus")  # Fuzzy match → {:ok, "claude-opus-4.6"}
```

Or via Mix task:

```bash
mix ghcopilot.models
mix ghcopilot.models --search claude
```

## Tips

1. **Always use `--allow-all-tools`** in `cli_args` for non-interactive use. Without it, the CLI blocks waiting for permission confirmation on stdin.

2. **`session.idle` is your turn boundary.** Wait for this event before sending the next prompt.

3. **Accumulate chunks.** Text arrives in small chunks via `assistant.message.chunk`. Buffer them until `session.idle`.

4. **Tool calls block the session.** If Copilot calls an external tool, you MUST respond via `respond_to_tool_call/3` or the session hangs.

5. **One session = one conversation thread.** Create new sessions for independent conversations. Use `resume_session/3` to continue a previous one.

6. **The Connection GenServer owns the subprocess.** When you `stop/1`, it kills the copilot process. Link it to your supervision tree.
