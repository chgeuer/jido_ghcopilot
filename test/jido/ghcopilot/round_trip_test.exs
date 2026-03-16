defmodule Jido.GHCopilot.RoundTripTest do
  use ExUnit.Case

  alias Jido.GHCopilot.Test.{Fixtures, StubConnection}
  alias Jido.GHCopilot.ACP.Types.SessionUpdate

  setup do
    old_events = Application.get_env(:jido_ghcopilot, :stub_conn_events)
    old_result = Application.get_env(:jido_ghcopilot, :stub_conn_prompt_result)
    old_session = Application.get_env(:jido_ghcopilot, :stub_conn_session_id)

    on_exit(fn ->
      restore(:jido_ghcopilot, :stub_conn_events, old_events)
      restore(:jido_ghcopilot, :stub_conn_prompt_result, old_result)
      restore(:jido_ghcopilot, :stub_conn_session_id, old_session)
    end)

    :ok
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, val), do: Application.put_env(app, key, val)

  describe "subscribe → prompt → drain" do
    test "receives message text as SessionUpdate structs" do
      Application.put_env(:jido_ghcopilot, :stub_conn_session_id, "rt-sess-1")

      Application.put_env(:jido_ghcopilot, :stub_conn_events, [
        Fixtures.agent_message_chunk(session_id: "rt-sess-1", text: "ROUND_TRIP_OK")
      ])

      Application.put_env(:jido_ghcopilot, :stub_conn_prompt_result, {:ok, :end_turn})

      {:ok, conn} = StubConnection.start_link()
      {:ok, session_id} = StubConnection.new_session(conn, "/tmp")
      assert session_id == "rt-sess-1"

      :ok = StubConnection.subscribe(conn, session_id)
      {:ok, :end_turn} = StubConnection.prompt(conn, session_id, "test", 5_000)

      # Events should be in our mailbox as {:acp_update, %SessionUpdate{}}
      assert_receive {:acp_update, update}, 500
      assert %SessionUpdate{update_type: :agent_message_chunk} = update
      assert update.data.text == "ROUND_TRIP_OK"

      StubConnection.stop(conn)
    end

    test "receives thinking as SessionUpdate structs" do
      Application.put_env(:jido_ghcopilot, :stub_conn_events, [
        Fixtures.agent_thought_chunk(text: "Reasoning...")
      ])

      {:ok, conn} = StubConnection.start_link()
      {:ok, session_id} = StubConnection.new_session(conn, "/tmp")
      :ok = StubConnection.subscribe(conn, session_id)
      {:ok, _} = StubConnection.prompt(conn, session_id, "test", 5_000)

      assert_receive {:acp_update, %SessionUpdate{update_type: :agent_thought_chunk, data: data}}, 500
      assert data.text == "Reasoning..."

      StubConnection.stop(conn)
    end

    test "receives tool call events" do
      Application.put_env(:jido_ghcopilot, :stub_conn_events, Fixtures.tool_call_sequence("sess", "read_file"))

      {:ok, conn} = StubConnection.start_link()
      {:ok, session_id} = StubConnection.new_session(conn, "/tmp")
      :ok = StubConnection.subscribe(conn, session_id)
      {:ok, _} = StubConnection.prompt(conn, session_id, "test", 5_000)

      updates = drain_updates()
      assert length(updates) == 3
      types = Enum.map(updates, & &1.update_type)
      assert :tool_call in types
      assert :tool_call_update in types

      StubConnection.stop(conn)
    end

    test "multi-turn: events from separate prompts don't mix" do
      {:ok, conn} = StubConnection.start_link()
      {:ok, session_id} = StubConnection.new_session(conn, "/tmp")
      :ok = StubConnection.subscribe(conn, session_id)

      # Turn 1
      Application.put_env(:jido_ghcopilot, :stub_conn_events, [
        Fixtures.agent_message_chunk(text: "Turn 1 response")
      ])

      {:ok, _} = StubConnection.prompt(conn, session_id, "first", 5_000)
      turn1 = drain_updates()

      # Turn 2
      Application.put_env(:jido_ghcopilot, :stub_conn_events, [
        Fixtures.agent_message_chunk(text: "Turn 2 response")
      ])

      {:ok, _} = StubConnection.prompt(conn, session_id, "second", 5_000)
      turn2 = drain_updates()

      assert length(turn1) == 1
      assert length(turn2) == 1
      assert hd(turn1).data.text == "Turn 1 response"
      assert hd(turn2).data.text == "Turn 2 response"

      StubConnection.stop(conn)
    end

    test "concurrent sessions don't cross-contaminate" do
      {:ok, conn} = StubConnection.start_link()

      Application.put_env(:jido_ghcopilot, :stub_conn_session_id, "sess-A")
      {:ok, sess_a} = StubConnection.new_session(conn, "/tmp")

      Application.put_env(:jido_ghcopilot, :stub_conn_session_id, "sess-B")
      {:ok, sess_b} = StubConnection.new_session(conn, "/tmp")

      :ok = StubConnection.subscribe(conn, sess_a)
      :ok = StubConnection.subscribe(conn, sess_b)

      # Send events to session A only
      Application.put_env(:jido_ghcopilot, :stub_conn_events, [
        Fixtures.agent_message_chunk(session_id: sess_a, text: "For A only")
      ])

      {:ok, _} = StubConnection.prompt(conn, sess_a, "test", 5_000)

      updates = drain_updates()
      assert length(updates) == 1
      assert hd(updates).data.text == "For A only"

      StubConnection.stop(conn)
    end

    test "session lifecycle: start → prompt → cancel" do
      {:ok, conn} = StubConnection.start_link()
      {:ok, session_id} = StubConnection.new_session(conn, "/tmp")
      :ok = StubConnection.subscribe(conn, session_id)

      Application.put_env(:jido_ghcopilot, :stub_conn_events, [
        Fixtures.agent_message_chunk(text: "partial")
      ])

      {:ok, _} = StubConnection.prompt(conn, session_id, "test", 5_000)

      drain_updates()

      assert :ok = StubConnection.cancel(conn, session_id)
      StubConnection.stop(conn)
    end
  end

  defp drain_updates(acc \\ []) do
    receive do
      {:acp_update, update} -> drain_updates([update | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end
end
