defmodule Jido.GHCopilot.Actions.StartSession do
  @moduledoc """
  Initializes a GitHub Copilot session using a pluggable executor.

  By default uses the ACP executor. Override via `:target` option:

  - `:acp` — ACP JSON-RPC over stdio (default, full features)
  - `:port` — direct Port-based CLI execution (simple, single-prompt)
  """

  use Jido.Action,
    name: "ghcopilot_start_session",
    description: "Start a GitHub Copilot session",
    schema: [
      prompt: [type: :string, required: true],
      model: [type: :string, default: nil],
      cwd: [type: :string, default: nil],
      mcp_servers: [type: {:list, :any}, default: []],
      timeout_ms: [type: :integer, default: to_timeout(minute: 10)],
      cli_args: [type: {:list, :string}, default: []],
      target: [type: :atom, default: :acp],
      allow_all_tools: [type: :boolean, default: false],
      allow_all_paths: [type: :boolean, default: false],
      allow_all_urls: [type: :boolean, default: false],
      yolo: [type: :boolean, default: false]
    ]

  require Logger

  @impl true
  def run(params, context) do
    agent_pid = context[:self] || self()

    executor_module = resolve_executor(params.target)

    start_args = %{
      agent_pid: agent_pid,
      prompt: params.prompt,
      model: params.model,
      cwd: params.cwd || File.cwd!(),
      mcp_servers: params.mcp_servers,
      timeout_ms: params.timeout_ms,
      cli_args: params.cli_args,
      allow_all_tools: params.allow_all_tools,
      allow_all_paths: params.allow_all_paths,
      allow_all_urls: params.allow_all_urls,
      yolo: params.yolo
    }

    case executor_module.start(start_args) do
      {:ok, runner_ref, metadata} ->
        Logger.info("Started GHCopilot session #{metadata[:session_id]} via #{inspect(executor_module)}")

        {:ok,
         %{
           status: :running,
           session_id: metadata[:session_id],
           prompt: params.prompt,
           options: %{model: params.model, cwd: start_args.cwd, timeout_ms: params.timeout_ms},
           executor_module: executor_module,
           runner_ref: runner_ref,
           turns: 0,
           transcript: [],
           thinking: [],
           started_at: System.monotonic_time(:millisecond)
         }}

      {:error, reason} ->
        Logger.error("Failed to start GHCopilot session: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp resolve_executor(:acp) do
    Application.get_env(:jido_ghcopilot, :executor_acp_module, Jido.GHCopilot.Executor.ACP)
  end

  defp resolve_executor(:port) do
    Application.get_env(:jido_ghcopilot, :executor_port_module, Jido.GHCopilot.Executor.Port)
  end

  defp resolve_executor(:server) do
    Application.get_env(:jido_ghcopilot, :executor_server_module, Jido.GHCopilot.Executor.Server)
  end

  defp resolve_executor(other) do
    raise ArgumentError, "Unknown executor target: #{inspect(other)}. Use :acp, :port, or :server"
  end
end
