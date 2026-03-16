defmodule Jido.GHCopilot.Test.StubsTest do
  use ExUnit.Case, async: true

  alias Jido.GHCopilot.Test.{StubAdapter, StubCLI, StubCommand, StubCompatibility, StubMapper, StubExecutor}

  setup do
    keys = [
      :stub_adapter_run,
      :stub_adapter_cancel,
      :stub_cli_resolve_path,
      :stub_command_run,
      :stub_compat_check,
      :stub_compat_status,
      :stub_mapper_map_line,
      :stub_executor_start,
      :stub_executor_cancel
    ]

    old = Enum.map(keys, fn k -> {k, Application.get_env(:jido_ghcopilot, k)} end)

    on_exit(fn ->
      Enum.each(old, fn {k, v} ->
        if v, do: Application.put_env(:jido_ghcopilot, k, v), else: Application.delete_env(:jido_ghcopilot, k)
      end)
    end)

    :ok
  end

  describe "StubAdapter" do
    test "defaults return {:ok, []}" do
      assert {:ok, []} = StubAdapter.run(%{}, [])
    end

    test "defaults cancel returns :ok" do
      assert :ok = StubAdapter.cancel("sess")
    end

    test "run is overridable" do
      Application.put_env(:jido_ghcopilot, :stub_adapter_run, fn req, _opts -> {:ok, req} end)
      assert {:ok, :test_req} = StubAdapter.run(:test_req, [])
    end

    test "cancel is overridable" do
      Application.put_env(:jido_ghcopilot, :stub_adapter_cancel, fn id -> {:cancelled, id} end)
      assert {:cancelled, "s1"} = StubAdapter.cancel("s1")
    end
  end

  describe "StubCLI" do
    test "default returns /tmp/copilot" do
      assert "/tmp/copilot" = StubCLI.resolve_path()
    end

    test "overridable" do
      Application.put_env(:jido_ghcopilot, :stub_cli_resolve_path, fn -> "/custom/path" end)
      assert "/custom/path" = StubCLI.resolve_path()
    end
  end

  describe "StubCommand" do
    test "default returns {:ok, \"ok\"}" do
      assert {:ok, "ok"} = StubCommand.run("prog", ["arg"])
    end

    test "overridable" do
      Application.put_env(:jido_ghcopilot, :stub_command_run, fn p, a, _o -> {:ok, "#{p} #{Enum.join(a, " ")}"} end)
      assert {:ok, "copilot --version"} = StubCommand.run("copilot", ["--version"])
    end
  end

  describe "StubCompatibility" do
    test "default check returns :ok" do
      assert :ok = StubCompatibility.check()
    end

    test "default status returns metadata" do
      assert {:ok, %{program: _, version: _}} = StubCompatibility.status()
    end
  end

  describe "StubMapper" do
    test "delegates to real mapper by default" do
      assert {:ok, _} = StubMapper.map_line("test output", "sess")
    end
  end

  describe "StubExecutor" do
    test "default start sends message and returns ok" do
      args = %{prompt: "hello"}
      assert {:ok, %{marker: :stub_runner}, %{session_id: "stub-session-1"}} = StubExecutor.start(args)
      assert_receive {:stub_executor_started, ^args}
    end

    test "default cancel sends message and returns ok" do
      ref = %{pid: self()}
      assert :ok = StubExecutor.cancel(ref)
      assert_receive {:stub_executor_cancelled, ^ref}
    end

    test "start is overridable" do
      Application.put_env(:jido_ghcopilot, :stub_executor_start, fn _args -> {:error, :nope} end)
      assert {:error, :nope} = StubExecutor.start(%{})
    end
  end
end
