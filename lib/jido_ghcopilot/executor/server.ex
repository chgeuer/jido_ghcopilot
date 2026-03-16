defmodule Jido.GHCopilot.Executor.Server do
  @moduledoc """
  CLI Server protocol executor for GitHub Copilot CLI.

  Spawns `copilot --server --stdio` as a Port, creates a session via the
  CLI Server JSON-RPC protocol, and runs a StreamRunner that forwards raw
  session events — including `assistant.usage` — as signals to the agent.

  This executor provides the same multi-turn capabilities as the ACP executor
  but additionally surfaces token usage, cost, and quota data.
  """

  @behaviour Jido.GHCopilot.Executor

  require Logger

  alias Jido.GHCopilot.Executor.CliArgs
  alias Jido.GHCopilot.Server.Connection
  alias Jido.GHCopilot.Server.StreamRunner

  @impl true
  def start(args) do
    cli_args = CliArgs.build(args)
    model = args[:model]

    create_opts =
      %{}
      |> maybe_put(:model, model)
      |> maybe_put(:system_message, args[:system_message])

    with {:ok, conn} <- Connection.start_link(cli_args: cli_args),
         {:ok, session_id} <- Connection.create_session(conn, create_opts) do
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
        model: model,
        cwd: args[:cwd]
      }

      Logger.info("Started Server session #{session_id} with runner #{inspect(runner_pid)}")
      {:ok, runner_ref, metadata}
    end
  end

  @impl true
  def cancel(%{conn: conn, session_id: session_id, pid: pid}) do
    Connection.destroy_session(conn, session_id)

    if is_pid(pid) and Process.alive?(pid) do
      Process.exit(pid, :shutdown)
    end

    :ok
  rescue
    _ -> :ok
  end

  def cancel(%{pid: pid}) do
    if is_pid(pid) and Process.alive?(pid) do
      Process.exit(pid, :shutdown)
    end

    :ok
  end

  def cancel(_), do: :ok

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
