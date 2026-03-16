defmodule Jido.GHCopilot.Executor.Port do
  @moduledoc """
  Port-based executor for GitHub Copilot CLI.

  Spawns `copilot -p <prompt>` as a direct Port, streaming line-by-line output.
  Simpler than ACP — single prompt, no multi-turn, no thinking stream.

  Uses the existing `Jido.GHCopilot.Adapter` stream infrastructure.
  """

  @behaviour Jido.GHCopilot.Executor

  require Logger

  alias Jido.GHCopilot.Options

  @impl true
  def start(args) do
    prompt = args.prompt
    cwd = args[:cwd] || File.cwd!()

    attrs = %{
      prompt: prompt,
      cwd: cwd,
      model: args[:model],
      silent: true,
      autopilot: Map.get(args, :allow_all_tools, false) || Map.get(args, :yolo, false),
      timeout_ms: args[:timeout_ms] || to_timeout(minute: 10),
      add_dirs: [],
      env: %{}
    }

    with {:ok, options} <- Options.new(attrs) do
      cli_path = cli_module().resolve_path()

      if is_nil(cli_path) do
        {:error, :copilot_cli_not_found}
      else
        cli_args = build_cli_args(options)

        port =
          Port.open({:spawn_executable, cli_path}, [
            :binary,
            :exit_status,
            :use_stdio,
            :stderr_to_stdout,
            {:args, cli_args},
            {:cd, to_charlist(cwd)}
          ])

        port_pid =
          case Port.info(port, :os_pid) do
            {:os_pid, pid} -> pid
            _ -> nil
          end

        runner_ref = %{port: port, port_pid: port_pid}
        metadata = %{model: args[:model], cwd: cwd}

        Logger.info("Started Port session with PID #{port_pid}")
        {:ok, runner_ref, metadata}
      end
    end
  end

  @impl true
  def cancel(%{port: port}) when is_port(port) do
    try do
      Port.close(port)
    catch
      _, _ -> :ok
    end

    :ok
  end

  def cancel(_), do: :ok

  defp build_cli_args(%Options{} = options) do
    args = ["-p", options.prompt, "--no-color"]
    args = if options.autopilot, do: args ++ ["--allow-all-tools", "--autopilot"], else: args
    args = if options.silent, do: args ++ ["-s"], else: args
    args = if options.model, do: args ++ ["--model", options.model], else: args
    args
  end

  defp cli_module do
    Application.get_env(:jido_ghcopilot, :cli_module, Jido.GHCopilot.CLI)
  end
end
