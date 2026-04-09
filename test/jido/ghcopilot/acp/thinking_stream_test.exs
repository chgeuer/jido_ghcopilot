defmodule Jido.GHCopilot.ACP.ThinkingStreamTest do
  use ExUnit.Case

  alias Jido.GHCopilot.ACP.Connection
  alias Jido.GHCopilot.ACP.Types.SessionUpdate

  describe "thinking stream" do
    @tag :integration
    @tag timeout: to_timeout(minute: 1)
    test "agent_thought_chunk events are separate from agent_message_chunk" do
      {:ok, conn} = Connection.start_link()
      {:ok, _init} = Connection.initialize(conn)
      {:ok, session_id} = Connection.new_session(conn, System.tmp_dir!())
      :ok = Connection.subscribe(conn, session_id)

      # Use a prompt that should trigger thinking
      {:ok, :end_turn} =
        Connection.prompt(conn, session_id, "What is 2+2? Think step by step, then answer.", to_timeout(second: 30))

      updates = collect_updates(500)

      thoughts =
        Enum.filter(updates, &match?(%SessionUpdate{update_type: :agent_thought_chunk}, &1))

      messages =
        Enum.filter(updates, &match?(%SessionUpdate{update_type: :agent_message_chunk}, &1))

      IO.puts("  Thought chunks: #{length(thoughts)}")
      IO.puts("  Message chunks: #{length(messages)}")

      # Should have at least message chunks
      assert length(messages) > 0

      # Thinking and message should be separate events — never mixed
      if length(thoughts) > 0 do
        thought_text = Enum.map(thoughts, & &1.data.text) |> Enum.join("")
        message_text = Enum.map(messages, & &1.data.text) |> Enum.join("")

        # They should be different content
        assert thought_text != message_text
        IO.puts("  ✓ Thinking text is distinct from message text")
      end

      Connection.stop(conn)
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
