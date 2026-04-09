defmodule Jido.GHCopilot.Executor.ACP do
  @moduledoc """
  ACP-based executor for GitHub Copilot CLI.

  Spawns `copilot --acp --stdio` as a Port, creates a session via JSON-RPC,
  and runs a `StreamRunner` that forwards ACP updates as signals to the agent.

  This executor supports multi-turn conversations, thinking streams, tool calls,
  and session resume — the full ACP feature set.
  """

  @behaviour Jido.GHCopilot.Executor

  require Logger

  alias Jido.GHCopilot.ACP.Connection
  alias Jido.GHCopilot.Executor.CliArgs
  alias Jido.GHCopilot.StreamRunner

  @impl true
  def start(args) do
    cli_args = CliArgs.build(args)
    cwd = args[:cwd] || File.cwd!()

    with {:ok, conn} <- Connection.start_link(cli_args: cli_args),
         {:ok, _init} <- Connection.initialize(conn),
         {:ok, session_id} <- Connection.new_session(conn, cwd, args[:mcp_servers] || []) do
      agent_pid = args.agent_pid

      {:ok, runner_pid} =
        Task.start_link(fn ->
          StreamRunner.run_with_forwarding(
            agent_pid,
            conn,
            session_id,
            args.prompt,
            args[:timeout_ms] || to_timeout(minute: 10)
          )
        end)

      runner_ref = %{
        pid: runner_pid,
        conn: conn,
        session_id: session_id
      }

      metadata = %{
        session_id: session_id,
        model: args[:model],
        cwd: cwd
      }

      Logger.info("Started ACP session #{session_id} with runner #{inspect(runner_pid)}")
      {:ok, runner_ref, metadata}
    end
  end

  @impl true
  def cancel(%{conn: conn, session_id: session_id, pid: pid}) do
    Connection.cancel(conn, session_id)

    if is_pid(pid) and Process.alive?(pid) do
      Process.exit(pid, :shutdown)
    end

    :ok
  end

  def cancel(%{pid: pid}) do
    if is_pid(pid) and Process.alive?(pid) do
      Process.exit(pid, :shutdown)
    end

    :ok
  end

  def cancel(_), do: :ok
end
