defmodule Jido.GHCopilot.Executor do
  @moduledoc """
  Behaviour for executing GitHub Copilot CLI sessions.

  Three implementations are provided:

  - `Jido.GHCopilot.Executor.Server` — CLI Server protocol over stdio JSON-RPC.
    **Recommended.** Provides 27+ event types, token usage & cost tracking,
    mid-session model switching, and external tool call handling.
  - `Jido.GHCopilot.Executor.ACP` — ACP (Agent Client Protocol) over stdio JSON-RPC.
    Legacy protocol. Supports multi-turn sessions, thinking streams, and
    structured tool calls but lacks usage data and advanced session management.
  - `Jido.GHCopilot.Executor.Port` — Direct Port-based CLI execution.
    Simpler, single-prompt mode with line-based output streaming.

  Executor implementations must emit `ghcopilot.internal.message` signals
  to the owning agent process, following the same contract as `StreamRunner`.
  """

  @type start_args :: %{
          agent_pid: pid(),
          prompt: String.t(),
          model: String.t() | nil,
          cwd: String.t(),
          mcp_servers: list(),
          timeout_ms: pos_integer(),
          cli_args: [String.t()],
          allow_all_tools: boolean(),
          allow_all_paths: boolean(),
          allow_all_urls: boolean(),
          yolo: boolean()
        }

  @type runner_ref :: map()
  @type metadata :: map()

  @doc """
  Start a new session. Returns a runner reference and metadata.

  The runner should begin executing asynchronously and deliver updates
  to `start_args.agent_pid` as `ghcopilot.internal.message` signals.
  """
  @callback start(start_args()) :: {:ok, runner_ref(), metadata()} | {:error, term()}

  @doc """
  Cancel a running session identified by `runner_ref`.
  """
  @callback cancel(runner_ref()) :: :ok | {:error, term()}
end
