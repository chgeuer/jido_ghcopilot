defmodule Jido.GHCopilot.Test.StubAdapter do
  @moduledoc false

  def run(request, opts) do
    Application.get_env(:jido_ghcopilot, :stub_adapter_run, fn _request, _opts -> {:ok, []} end).(request, opts)
  end

  def cancel(session_id) do
    Application.get_env(:jido_ghcopilot, :stub_adapter_cancel, fn _session_id -> :ok end).(session_id)
  end
end

defmodule Jido.GHCopilot.Test.StubCLI do
  @moduledoc false

  def resolve_path do
    Application.get_env(:jido_ghcopilot, :stub_cli_resolve_path, fn -> "/tmp/copilot" end).()
  end
end

defmodule Jido.GHCopilot.Test.StubCommand do
  @moduledoc false

  def run(program, args, opts \\ []) do
    Application.get_env(:jido_ghcopilot, :stub_command_run, fn _program, _args, _opts -> {:ok, "ok"} end).(
      program,
      args,
      opts
    )
  end
end

defmodule Jido.GHCopilot.Test.StubCompatibility do
  @moduledoc false

  def check do
    Application.get_env(:jido_ghcopilot, :stub_compat_check, fn -> :ok end).()
  end

  def status do
    Application.get_env(:jido_ghcopilot, :stub_compat_status, fn ->
      {:ok, %{program: "/tmp/copilot", version: "0.0.412-0", required_tokens: ["-p", "--prompt"]}}
    end).()
  end
end

defmodule Jido.GHCopilot.Test.StubExecutor do
  @moduledoc false

  def start(args) do
    Application.get_env(:jido_ghcopilot, :stub_executor_start, fn a ->
      send(self(), {:stub_executor_started, a})

      {:ok, %{pid: self(), marker: :stub_runner}, %{session_id: "stub-session-1", executor: "stub"}}
    end).(args)
  end

  def cancel(runner_ref) do
    Application.get_env(:jido_ghcopilot, :stub_executor_cancel, fn ref ->
      send(self(), {:stub_executor_cancelled, ref})
      :ok
    end).(runner_ref)
  end
end

defmodule Jido.GHCopilot.Test.StubMapper do
  @moduledoc false

  def map_line(line, session_id) do
    Application.get_env(:jido_ghcopilot, :stub_mapper_map_line, fn l, sid ->
      Jido.GHCopilot.Mapper.map_line(l, sid)
    end).(line, session_id)
  end
end
