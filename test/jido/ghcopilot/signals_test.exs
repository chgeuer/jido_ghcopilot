defmodule Jido.GHCopilot.SignalsTest do
  use ExUnit.Case, async: true

  alias Jido.GHCopilot.Test.Fixtures
  alias Jido.GHCopilot.ACP.Types.ContentBlock
  alias Jido.GHCopilot.Actions.HandleMessage

  # HandleMessage.run/2 needs params and context
  # We test process_update indirectly through run/2

  defp run_handle_message(update_type, session_id, data, agent \\ nil) do
    params = %{
      update_type: update_type,
      session_id: session_id,
      data: data
    }

    context = if agent, do: [agent: agent], else: [agent: nil]
    HandleMessage.run(params, context)
  end

  describe "agent_message_chunk signal" do
    test "produces TurnText signal" do
      data = Fixtures.agent_message_chunk(text: "Hello!").data
      {:ok, state, directives} = run_handle_message(:agent_message_chunk, "s1", data)

      assert state.turns == 1
      assert [{:assistant, "Hello!"}] = state.transcript

      signal = find_signal(directives, "ghcopilot.turn.text")
      assert signal != nil
      assert signal.data.text == "Hello!"
      assert signal.data.session_id == "s1"
    end

    test "accumulates transcript across turns" do
      agent = mock_agent(transcript: [{:assistant, "prev"}], turns: 1)
      data = %ContentBlock{type: "text", text: "next"}
      {:ok, state, _} = run_handle_message(:agent_message_chunk, "s1", data, agent)

      assert state.turns == 2
      assert length(state.transcript) == 2
    end
  end

  describe "agent_thought_chunk signal" do
    test "produces TurnThought signal" do
      data = Fixtures.agent_thought_chunk(text: "Let me think...").data
      {:ok, state, directives} = run_handle_message(:agent_thought_chunk, "s1", data)

      assert ["Let me think..."] = state.thinking
      signal = find_signal(directives, "ghcopilot.turn.thought")
      assert signal.data.text == "Let me think..."
    end

    test "accumulates thinking" do
      agent = mock_agent(thinking: ["first thought"])
      data = %ContentBlock{type: "text", text: "second thought"}
      {:ok, state, _} = run_handle_message(:agent_thought_chunk, "s1", data, agent)

      assert length(state.thinking) == 2
    end
  end

  describe "tool_call signal" do
    test "produces TurnToolUse signal" do
      data = Fixtures.tool_call(tool_call_id: "tc-99", kind: "grep", title: "Searching").data
      {:ok, _state, directives} = run_handle_message(:tool_call, "s1", data)

      signal = find_signal(directives, "ghcopilot.turn.tool_use")
      assert signal.data.tool_call_id == "tc-99"
      assert signal.data.kind == "grep"
      assert signal.data.title == "Searching"
      assert signal.data.status == "pending"
    end
  end

  describe "tool_call_update signal" do
    test "produces TurnToolResult signal" do
      data =
        Fixtures.tool_call_update(
          tool_call_id: "tc-99",
          status: :completed,
          content: [%{"type" => "text", "text" => "file contents"}]
        ).data

      {:ok, _state, directives} = run_handle_message(:tool_call_update, "s1", data)

      signal = find_signal(directives, "ghcopilot.turn.tool_result")
      assert signal.data.tool_call_id == "tc-99"
      assert signal.data.status == "completed"
      assert length(signal.data.content) == 1
    end
  end

  describe "plan signal" do
    test "produces TurnPlan signal" do
      data = Fixtures.plan().data
      {:ok, _state, directives} = run_handle_message(:plan, "s1", data)

      signal = find_signal(directives, "ghcopilot.turn.plan")
      assert length(signal.data.entries) == 2
    end
  end

  describe "session_completed signal" do
    test "produces SessionSuccess signal and terminal directive" do
      data = %{stop_reason: :end_turn}
      {:ok, state, directives} = run_handle_message(:session_completed, "s1", data)

      assert state.status == :success
      assert state.stop_reason == :end_turn

      signal = find_signal(directives, "ghcopilot.session.success")
      assert signal.data.session_id == "s1"
      assert signal.data.stop_reason == "end_turn"

      assert has_stop_directive?(directives)
    end
  end

  describe "session_error signal" do
    test "produces SessionError signal and terminal directive" do
      data = %{error: "connection lost"}
      {:ok, state, directives} = run_handle_message(:session_error, "s1", data)

      assert state.status == :failure
      signal = find_signal(directives, "ghcopilot.session.error")
      assert signal.data.error_type == "acp_error"
      assert has_stop_directive?(directives)
    end
  end

  describe "user_message_chunk" do
    test "is a no-op" do
      data = Fixtures.user_message_chunk().data
      {:ok, state, directives} = run_handle_message(:user_message_chunk, "s1", data)

      assert state == %{}
      assert directives == []
    end
  end

  describe "unknown event type" do
    test "does not crash" do
      {:ok, state, directives} = run_handle_message(:some_future_type, "s1", %{})
      assert state == %{}
      assert directives == []
    end
  end

  # ── Helpers ──

  defp find_signal(directives, type) do
    Enum.find_value(directives, fn
      %Jido.Agent.Directive.Emit{signal: signal} ->
        if signal.type == type, do: signal

      _ ->
        nil
    end)
  end

  defp has_stop_directive?(directives) do
    Enum.any?(directives, &match?(%Jido.Agent.Directive.Stop{}, &1))
  end

  defp mock_agent(opts) do
    state =
      %{
        transcript: Keyword.get(opts, :transcript, []),
        turns: Keyword.get(opts, :turns, 0),
        thinking: Keyword.get(opts, :thinking, []),
        started_at: Keyword.get(opts, :started_at, System.monotonic_time(:millisecond))
      }

    %{state: state, id: "test-agent", parent: nil}
  end
end
