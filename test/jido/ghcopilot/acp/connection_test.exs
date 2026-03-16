defmodule Jido.GHCopilot.ACP.ConnectionTest do
  use ExUnit.Case

  alias Jido.GHCopilot.ACP.Connection
  alias Jido.GHCopilot.ACP.Types.SessionUpdate

  describe "ACP Connection lifecycle" do
    @tag :integration
    @tag timeout: to_timeout(minute: 1)
    test "initialize → session/new → prompt → receive thinking + text" do
      {:ok, conn} = Connection.start_link()

      # 1. Check init result
      {:ok, init} = Connection.init_result(conn)
      assert init.protocol_version == 1
      assert init.agent_info.name == "Copilot"
      assert init.agent_capabilities.load_session == true

      # 2. Create session
      {:ok, session_id} = Connection.new_session(conn, System.tmp_dir!())
      assert is_binary(session_id)
      assert String.length(session_id) > 0

      # 3. Subscribe to updates
      :ok = Connection.subscribe(conn, session_id)

      # 4. Send prompt
      {:ok, stop_reason} = Connection.prompt(conn, session_id, "Say exactly: TEST_ACP_OK", to_timeout(second: 30))
      assert stop_reason == :end_turn

      # 5. Collect all updates we received
      updates = collect_updates(500)

      # Should have at least one message chunk
      message_chunks =
        Enum.filter(updates, fn
          %SessionUpdate{update_type: :agent_message_chunk} -> true
          _ -> false
        end)

      assert length(message_chunks) > 0

      # Concatenate all text
      full_text =
        message_chunks
        |> Enum.map(& &1.data.text)
        |> Enum.join("")

      assert full_text =~ "TEST_ACP_OK"

      # May or may not have thinking chunks — log what we got
      thought_chunks =
        Enum.filter(updates, fn
          %SessionUpdate{update_type: :agent_thought_chunk} -> true
          _ -> false
        end)

      IO.puts("  Got #{length(message_chunks)} message chunks, #{length(thought_chunks)} thought chunks")

      # 6. Cleanup
      Connection.stop(conn)
    end

    @tag :integration
    @tag timeout: to_timeout(minute: 1)
    test "multi-turn conversation on same session" do
      {:ok, conn} = Connection.start_link()
      {:ok, session_id} = Connection.new_session(conn, System.tmp_dir!())
      :ok = Connection.subscribe(conn, session_id)

      # Turn 1
      {:ok, :end_turn} =
        Connection.prompt(conn, session_id, "Remember the number 42. Reply with just: OK", to_timeout(second: 30))

      _turn1 = collect_updates(500)

      # Turn 2 — follow-up on same session
      {:ok, :end_turn} =
        Connection.prompt(
          conn,
          session_id,
          "What number did I ask you to remember? Reply with just the number.",
          to_timeout(second: 30)
        )

      turn2 = collect_updates(500)

      text =
        turn2
        |> Enum.filter(&match?(%SessionUpdate{update_type: :agent_message_chunk}, &1))
        |> Enum.map(& &1.data.text)
        |> Enum.join("")

      assert text =~ "42"

      Connection.stop(conn)
    end
  end

  defp collect_updates(timeout_ms) do
    collect_updates([], timeout_ms)
  end

  defp collect_updates(acc, timeout_ms) do
    receive do
      {:acp_update, update} ->
        collect_updates([update | acc], timeout_ms)
    after
      timeout_ms ->
        Enum.reverse(acc)
    end
  end
end
