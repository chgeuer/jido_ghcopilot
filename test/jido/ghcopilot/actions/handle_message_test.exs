defmodule Jido.GHCopilot.Actions.HandleMessageTest do
  use ExUnit.Case, async: true

  alias Jido.GHCopilot.Test.Fixtures
  alias Jido.GHCopilot.Actions.HandleMessage
  alias Jido.GHCopilot.ACP.Types.{ContentBlock, ToolCall}

  defp run(update_type, session_id, data, agent \\ nil) do
    HandleMessage.run(
      %{update_type: update_type, session_id: session_id, data: data},
      agent: agent
    )
  end

  describe "agent_message_chunk" do
    test "increments turns and appends to transcript" do
      {:ok, state, _} = run(:agent_message_chunk, "s1", %ContentBlock{type: "text", text: "Hi"})
      assert state.turns == 1
      assert [{:assistant, "Hi"}] = state.transcript
    end

    test "handles nil text gracefully" do
      {:ok, state, _} = run(:agent_message_chunk, "s1", %ContentBlock{type: "text", text: nil})
      assert state.turns == 1
      assert [{:assistant, ""}] = state.transcript
    end

    test "handles plain map data" do
      {:ok, state, _} = run(:agent_message_chunk, "s1", %{text: "from map"})
      assert [{:assistant, "from map"}] = state.transcript
    end
  end

  describe "agent_thought_chunk" do
    test "appends to thinking list" do
      {:ok, state, _} = run(:agent_thought_chunk, "s1", %ContentBlock{type: "text", text: "hmm"})
      assert state.thinking == ["hmm"]
    end

    test "accumulates with existing thinking" do
      agent = %{state: %{thinking: ["first"], turns: 0, transcript: []}}
      {:ok, state, _} = run(:agent_thought_chunk, "s1", %ContentBlock{type: "text", text: "second"}, agent)
      assert length(state.thinking) == 2
    end
  end

  describe "tool_call" do
    test "emits TurnToolUse signal" do
      data = %ToolCall{tool_call_id: "tc-1", title: "Reading", kind: "read_file", status: :pending, content: []}
      {:ok, state, directives} = run(:tool_call, "s1", data)
      assert state == %{}
      assert length(directives) > 0
    end
  end

  describe "tool_call_update" do
    test "emits TurnToolResult signal" do
      data = %ToolCall{tool_call_id: "tc-1", title: "Reading", kind: "read_file", status: :completed, content: []}
      {:ok, state, directives} = run(:tool_call_update, "s1", data)
      assert state == %{}
      assert length(directives) > 0
    end
  end

  describe "plan" do
    test "emits TurnPlan signal with entries" do
      data = Fixtures.plan().data
      {:ok, state, directives} = run(:plan, "s1", data)
      assert state == %{}
      assert length(directives) > 0
    end
  end

  describe "session_completed" do
    test "sets success status and emits stop directive" do
      {:ok, state, directives} = run(:session_completed, "s1", %{stop_reason: :end_turn})
      assert state.status == :success
      assert state.stop_reason == :end_turn
      assert Enum.any?(directives, &match?(%Jido.Agent.Directive.Stop{}, &1))
    end

    test "handles max_tokens stop reason" do
      {:ok, state, _} = run(:session_completed, "s1", %{stop_reason: :max_tokens})
      assert state.stop_reason == :max_tokens
    end
  end

  describe "session_error" do
    test "sets failure status" do
      {:ok, state, directives} = run(:session_error, "s1", %{error: "timeout"})
      assert state.status == :failure
      assert state.error.type == "acp_error"
      assert Enum.any?(directives, &match?(%Jido.Agent.Directive.Stop{}, &1))
    end
  end

  describe "user_message_chunk" do
    test "is no-op" do
      {:ok, state, directives} = run(:user_message_chunk, "s1", %ContentBlock{type: "text", text: "hi"})
      assert state == %{}
      assert directives == []
    end
  end

  describe "unknown type" do
    test "does not crash and returns empty" do
      {:ok, state, directives} = run(:future_event_type, "s1", %{data: "whatever"})
      assert state == %{}
      assert directives == []
    end
  end
end
