defmodule Jido.GHCopilot.Executor.ACPTest do
  use ExUnit.Case

  alias Jido.GHCopilot.Test.StubConnection

  setup do
    old_conn = Application.get_env(:jido_ghcopilot, :acp_connection_module)
    old_events = Application.get_env(:jido_ghcopilot, :stub_conn_events)
    old_result = Application.get_env(:jido_ghcopilot, :stub_conn_prompt_result)
    old_session = Application.get_env(:jido_ghcopilot, :stub_conn_session_id)

    Application.put_env(:jido_ghcopilot, :acp_connection_module, StubConnection)

    on_exit(fn ->
      restore(:jido_ghcopilot, :acp_connection_module, old_conn)
      restore(:jido_ghcopilot, :stub_conn_events, old_events)
      restore(:jido_ghcopilot, :stub_conn_prompt_result, old_result)
      restore(:jido_ghcopilot, :stub_conn_session_id, old_session)
    end)

    :ok
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, val), do: Application.put_env(app, key, val)

  describe "CLI arg construction" do
    test "does not include --allow-all-tools by default" do
      args = Jido.GHCopilot.Executor.CliArgs.build(%{})
      refute "--allow-all-tools" in args
    end

    test "includes --model when provided" do
      args = Jido.GHCopilot.Executor.CliArgs.build(%{model: "claude-opus-4.6"})
      idx = Enum.find_index(args, &(&1 == "--model"))
      assert idx != nil
      assert Enum.at(args, idx + 1) == "claude-opus-4.6"
    end

    test "yolo sets all allow flags" do
      args =
        Jido.GHCopilot.Executor.CliArgs.build(%{
          allow_all_tools: true,
          allow_all_paths: true,
          allow_all_urls: true
        })

      assert "--allow-all-tools" in args
      assert "--allow-all-paths" in args
      assert "--allow-all-urls" in args
    end

    test "includes extra cli_args" do
      args = Jido.GHCopilot.Executor.CliArgs.build(%{cli_args: ["--verbose", "--debug"]})
      assert "--verbose" in args
      assert "--debug" in args
    end

    test "includes --add-dir when provided" do
      args = Jido.GHCopilot.Executor.CliArgs.build(%{cli_args: ["--add-dir", "/tmp"]})
      assert "--add-dir" in args
      assert "/tmp" in args
    end

    test "omits allow flags when not set" do
      args =
        Jido.GHCopilot.Executor.CliArgs.build(%{
          allow_all_tools: false,
          allow_all_paths: false,
          allow_all_urls: false
        })

      refute "--allow-all-tools" in args
      refute "--allow-all-paths" in args
      refute "--allow-all-urls" in args
    end
  end

  describe "start/1" do
    @tag :integration
    test "returns runner_ref with conn and session_id" do
      args = %{
        agent_pid: self(),
        prompt: "hello",
        model: nil,
        cwd: System.tmp_dir!(),
        mcp_servers: [],
        timeout_ms: 5_000,
        cli_args: [],
        allow_all_tools: true,
        allow_all_paths: false,
        allow_all_urls: false
      }

      case Jido.GHCopilot.Executor.ACP.start(args) do
        {:ok, runner_ref, metadata} ->
          assert is_map(runner_ref)
          assert Map.has_key?(runner_ref, :conn)
          assert is_binary(metadata.session_id)

        {:error, _reason} ->
          :ok
      end
    end
  end
end
