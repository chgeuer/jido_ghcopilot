defmodule Jido.GHCopilot.StreamRunnerTest do
  use ExUnit.Case

  alias Jido.GHCopilot.Test.{Fixtures, StubConnection}

  setup do
    old_events = Application.get_env(:jido_ghcopilot, :stub_conn_events)
    old_result = Application.get_env(:jido_ghcopilot, :stub_conn_prompt_result)

    on_exit(fn ->
      restore(:jido_ghcopilot, :stub_conn_events, old_events)
      restore(:jido_ghcopilot, :stub_conn_prompt_result, old_result)
    end)

    {:ok, conn} = StubConnection.start_link()
    {:ok, session_id} = StubConnection.new_session(conn, "/tmp")

    %{conn: conn, session_id: session_id}
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, val), do: Application.put_env(app, key, val)

  describe "run/5" do
    test "dispatches completion signal on success", %{conn: conn, session_id: session_id} do
      Application.put_env(:jido_ghcopilot, :stub_conn_events, [])
      Application.put_env(:jido_ghcopilot, :stub_conn_prompt_result, {:ok, :end_turn})

      # Run StreamRunner in a task so signals dispatch to us
      agent_pid = self()

      Task.start(fn ->
        Jido.GHCopilot.StreamRunner.run(agent_pid, conn, session_id, "hello", 5_000)
      end)

      assert_receive {:signal, %{type: "ghcopilot.internal.message", data: %{update_type: :session_completed}}}, 2_000
    end

    @tag capture_log: true
    test "dispatches error signal on failure", %{conn: conn, session_id: session_id} do
      Application.put_env(:jido_ghcopilot, :stub_conn_events, [])
      Application.put_env(:jido_ghcopilot, :stub_conn_prompt_result, {:error, :timeout})

      agent_pid = self()

      Task.start(fn ->
        Jido.GHCopilot.StreamRunner.run(agent_pid, conn, session_id, "hello", 5_000)
      end)

      assert_receive {:signal, %{type: "ghcopilot.internal.message", data: %{update_type: :session_error}}}, 2_000
    end

    test "forwards message events to agent", %{conn: conn, session_id: session_id} do
      events = [
        Fixtures.agent_message_chunk(session_id: session_id, text: "Hello!")
      ]

      Application.put_env(:jido_ghcopilot, :stub_conn_events, events)
      Application.put_env(:jido_ghcopilot, :stub_conn_prompt_result, {:ok, :end_turn})

      agent_pid = self()

      Task.start(fn ->
        Jido.GHCopilot.StreamRunner.run_with_forwarding(agent_pid, conn, session_id, "hello", 5_000)
      end)

      # Should receive the forwarded update as a signal
      assert_receive {:signal, %{type: "ghcopilot.internal.message", data: %{update_type: :agent_message_chunk}}}, 2_000
    end

    test "forwards thinking events to agent", %{conn: conn, session_id: session_id} do
      events = [
        Fixtures.agent_thought_chunk(session_id: session_id, text: "Thinking...")
      ]

      Application.put_env(:jido_ghcopilot, :stub_conn_events, events)
      Application.put_env(:jido_ghcopilot, :stub_conn_prompt_result, {:ok, :end_turn})

      agent_pid = self()

      Task.start(fn ->
        Jido.GHCopilot.StreamRunner.run_with_forwarding(agent_pid, conn, session_id, "hello", 5_000)
      end)

      assert_receive {:signal, %{type: "ghcopilot.internal.message", data: %{update_type: :agent_thought_chunk}}}, 2_000
    end

    test "forwards tool call events", %{conn: conn, session_id: session_id} do
      events = [
        Fixtures.tool_call(session_id: session_id)
      ]

      Application.put_env(:jido_ghcopilot, :stub_conn_events, events)
      Application.put_env(:jido_ghcopilot, :stub_conn_prompt_result, {:ok, :end_turn})

      agent_pid = self()

      Task.start(fn ->
        Jido.GHCopilot.StreamRunner.run_with_forwarding(agent_pid, conn, session_id, "hello", 5_000)
      end)

      assert_receive {:signal, %{type: "ghcopilot.internal.message", data: %{update_type: :tool_call}}}, 2_000
    end
  end
end
