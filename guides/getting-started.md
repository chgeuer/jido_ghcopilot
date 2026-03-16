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

### Run a prompt

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

## Event Types

Events emitted during a session:

| Event Type | Description |
|---|---|
| `:session_started` | Session initialized |
| `:output_text_delta` | Regular text output |
| `:ghcopilot_error` | Error output |
| `:ghcopilot_warning` | Warning output |
| `:ghcopilot_status` | Status indicators |
| `:session_completed` | Successful completion |
| `:session_failed` | Error or timeout |
