defmodule Jido.GHCopilot.Actions.StartSessionTest do
  use ExUnit.Case

  alias Jido.GHCopilot.Test.StubExecutor

  setup do
    old_acp = Application.get_env(:jido_ghcopilot, :executor_acp_module)
    old_port = Application.get_env(:jido_ghcopilot, :executor_port_module)
    old_start = Application.get_env(:jido_ghcopilot, :stub_executor_start)

    Application.put_env(:jido_ghcopilot, :executor_acp_module, StubExecutor)
    Application.put_env(:jido_ghcopilot, :executor_port_module, StubExecutor)

    on_exit(fn ->
      restore(:jido_ghcopilot, :executor_acp_module, old_acp)
      restore(:jido_ghcopilot, :executor_port_module, old_port)
      restore(:jido_ghcopilot, :stub_executor_start, old_start)
    end)

    :ok
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, val), do: Application.put_env(app, key, val)

  describe "run/2 with target: :acp" do
    test "calls ACP executor with start_args" do
      params = %{
        prompt: "hello",
        model: "claude-opus-4.6",
        cwd: "/tmp",
        mcp_servers: [],
        timeout_ms: 60_000,
        cli_args: [],
        target: :acp,
        allow_all_tools: true,
        allow_all_paths: false,
        allow_all_urls: false,
        yolo: false
      }

      result = Jido.GHCopilot.Actions.StartSession.run(params, [])

      assert {:ok, state} = result
      assert state.status == :running
      assert state.executor_module == StubExecutor
      assert_receive {:stub_executor_started, args}
      assert args.prompt == "hello"
      assert args.model == "claude-opus-4.6"
    end
  end

  describe "run/2 with target: :port" do
    test "calls Port executor" do
      params = %{
        prompt: "hello",
        model: nil,
        cwd: "/tmp",
        mcp_servers: [],
        timeout_ms: 60_000,
        cli_args: [],
        target: :port,
        allow_all_tools: true,
        allow_all_paths: false,
        allow_all_urls: false,
        yolo: false
      }

      {:ok, state} = Jido.GHCopilot.Actions.StartSession.run(params, [])

      assert state.status == :running
      assert_receive {:stub_executor_started, _args}
    end
  end

  describe "error handling" do
    @tag capture_log: true
    test "propagates executor failure" do
      Application.put_env(:jido_ghcopilot, :stub_executor_start, fn _args ->
        {:error, :connection_refused}
      end)

      params = %{
        prompt: "hello",
        model: nil,
        cwd: "/tmp",
        mcp_servers: [],
        timeout_ms: 60_000,
        cli_args: [],
        target: :acp,
        allow_all_tools: true,
        allow_all_paths: false,
        allow_all_urls: false,
        yolo: false
      }

      assert {:error, :connection_refused} = Jido.GHCopilot.Actions.StartSession.run(params, [])
    end
  end
end
