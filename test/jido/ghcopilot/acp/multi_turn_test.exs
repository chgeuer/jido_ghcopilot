defmodule Jido.GHCopilot.ACP.MultiTurnTest do
  use ExUnit.Case

  alias Jido.GHCopilot.ACP.Connection
  alias Jido.GHCopilot.ACP.Types.SessionUpdate

  describe "multi-turn conversations" do
    @tag :integration
    @tag timeout: to_timeout(minute: 1, second: 30)
    test "session maintains context across multiple prompts" do
      {:ok, conn} = Connection.start_link()
      {:ok, session_id} = Connection.new_session(conn, System.tmp_dir!())
      :ok = Connection.subscribe(conn, session_id)

      # Turn 1: establish context
      {:ok, :end_turn} =
        Connection.prompt(
          conn,
          session_id,
          "My favorite color is purple. Reply with just: NOTED",
          to_timeout(second: 30)
        )

      _turn1 = collect_updates(500)

      # Turn 2: query context from previous turn
      {:ok, :end_turn} =
        Connection.prompt(
          conn,
          session_id,
          "What is my favorite color? Reply with just the color.",
          to_timeout(second: 30)
        )

      turn2 = collect_updates(500)

      text =
        turn2
        |> Enum.filter(&match?(%SessionUpdate{update_type: :agent_message_chunk}, &1))
        |> Enum.map(& &1.data.text)
        |> Enum.join("")
        |> String.downcase()

      assert text =~ "purple"
      IO.puts("  ✓ Session retained context: '#{String.trim(text)}'")

      Connection.stop(conn)
    end

    @tag :integration
    @tag timeout: to_timeout(minute: 1)
    test "public API start_session + send_prompt works" do
      {:ok, conn, session_id} = Jido.GHCopilot.start_session(cwd: System.tmp_dir!())

      :ok = Jido.GHCopilot.subscribe(conn, session_id)

      {:ok, :end_turn} =
        Jido.GHCopilot.send_prompt(conn, session_id, "Say exactly: API_TEST_OK")

      updates = collect_updates(500)

      text =
        updates
        |> Enum.filter(&match?(%SessionUpdate{update_type: :agent_message_chunk}, &1))
        |> Enum.map(& &1.data.text)
        |> Enum.join("")

      assert text =~ "API_TEST_OK"

      Jido.GHCopilot.stop_session(conn)
    end
  end

  defp collect_updates(timeout_ms), do: collect_updates([], timeout_ms)

  defp collect_updates(acc, timeout_ms) do
    receive do
      {:connection_event, _sid, update} -> collect_updates([update | acc], timeout_ms)
    after
      timeout_ms -> Enum.reverse(acc)
    end
  end
end
