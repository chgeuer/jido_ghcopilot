defmodule Jido.GHCopilot.Test.FixturesTest do
  use ExUnit.Case, async: true

  alias Jido.GHCopilot.Test.Fixtures

  alias Jido.GHCopilot.ACP.Types.{
    SessionUpdate,
    ContentBlock,
    ToolCall,
    PlanEntry,
    InitResult,
    AgentInfo,
    AgentCapabilities,
    SessionResult,
    PromptResult,
    PermissionRequest
  }

  describe "agent_message_chunk/1" do
    test "returns SessionUpdate with correct type" do
      update = Fixtures.agent_message_chunk()
      assert %SessionUpdate{update_type: :agent_message_chunk} = update
      assert %ContentBlock{type: "text", text: "Hello, world!"} = update.data
      assert update.session_id == "test-session-001"
    end

    test "accepts overrides" do
      update = Fixtures.agent_message_chunk(session_id: "custom", text: "Custom text")
      assert update.session_id == "custom"
      assert update.data.text == "Custom text"
    end
  end

  describe "agent_thought_chunk/1" do
    test "returns thinking update" do
      update = Fixtures.agent_thought_chunk()
      assert %SessionUpdate{update_type: :agent_thought_chunk} = update
      assert update.data.text =~ "think"
    end
  end

  describe "tool_call/1" do
    test "returns tool call with defaults" do
      update = Fixtures.tool_call()
      assert %SessionUpdate{update_type: :tool_call} = update
      assert %ToolCall{tool_call_id: "tc-001", status: :pending} = update.data
    end

    test "accepts status override" do
      update = Fixtures.tool_call(status: :in_progress, kind: "write_file")
      assert update.data.status == :in_progress
      assert update.data.kind == "write_file"
    end
  end

  describe "tool_call_update/1" do
    test "returns completed tool update" do
      update = Fixtures.tool_call_update()
      assert %SessionUpdate{update_type: :tool_call_update} = update
      assert update.data.status == :completed
      assert length(update.data.content) > 0
    end
  end

  describe "plan/1" do
    test "returns plan with entries" do
      update = Fixtures.plan()
      assert %SessionUpdate{update_type: :plan} = update
      assert [%PlanEntry{} | _] = update.data.entries
    end

    test "accepts custom entries" do
      entries = [%PlanEntry{content: "Custom step", priority: "low", status: "done"}]
      update = Fixtures.plan(entries: entries)
      assert length(update.data.entries) == 1
    end
  end

  describe "user_message_chunk/1" do
    test "returns user message" do
      update = Fixtures.user_message_chunk()
      assert %SessionUpdate{update_type: :user_message_chunk} = update
    end
  end

  describe "unknown_update/1" do
    test "returns unknown type" do
      update = Fixtures.unknown_update()
      assert update.update_type == :unknown
    end
  end

  describe "composite sequences" do
    test "thinking_sequence returns 3 events" do
      seq = Fixtures.thinking_sequence()
      assert length(seq) == 3
      assert Enum.at(seq, 0).update_type == :agent_thought_chunk
      assert Enum.at(seq, 1).update_type == :agent_thought_chunk
      assert Enum.at(seq, 2).update_type == :agent_message_chunk
    end

    test "tool_call_sequence returns 3 events with matching tc_id" do
      seq = Fixtures.tool_call_sequence("s1", "grep")
      assert length(seq) == 3
      tc_id = Enum.at(seq, 0).data.tool_call_id
      assert Enum.all?(seq, &(&1.data.tool_call_id == tc_id))
      assert Enum.at(seq, 0).data.status == :pending
      assert Enum.at(seq, 2).data.status == :completed
    end

    test "multi_turn_conversation alternates roles" do
      seq = Fixtures.multi_turn_conversation()
      assert length(seq) == 5
      types = Enum.map(seq, & &1.update_type)
      assert :user_message_chunk in types
      assert :agent_message_chunk in types
      assert :agent_thought_chunk in types
    end

    test "full_session_sequence covers all event types" do
      seq = Fixtures.full_session_sequence()
      types = Enum.map(seq, & &1.update_type) |> Enum.uniq()
      assert :agent_message_chunk in types
      assert :agent_thought_chunk in types
      assert :tool_call in types
      assert :tool_call_update in types
      assert :plan in types
    end
  end

  describe "initialization fixtures" do
    test "init_result with defaults" do
      result = Fixtures.init_result()
      assert %InitResult{protocol_version: 1} = result
      assert %AgentInfo{name: "copilot"} = result.agent_info
      assert %AgentCapabilities{load_session: true} = result.agent_capabilities
    end

    test "session_result" do
      assert %SessionResult{session_id: "test-session-001"} = Fixtures.session_result()
    end

    test "prompt_result" do
      assert %PromptResult{stop_reason: :end_turn} = Fixtures.prompt_result()
      assert %PromptResult{stop_reason: :cancelled} = Fixtures.prompt_result(stop_reason: :cancelled)
    end
  end

  describe "permission_request/1" do
    test "returns permission request" do
      req = Fixtures.permission_request()
      assert %PermissionRequest{tool_name: "write_file"} = req
    end
  end

  describe "error fixtures" do
    test "malformed_update with nil session_id" do
      update = Fixtures.malformed_update()
      assert update.session_id == nil
      assert update.data == nil
    end
  end

  describe "content_block/1" do
    test "text content block" do
      cb = Fixtures.content_block(text: "hello")
      assert %ContentBlock{type: "text", text: "hello"} = cb
    end

    test "resource content block" do
      cb = Fixtures.resource_content_block()
      assert cb.type == "resource"
      assert cb.resource["uri"] =~ "file://"
    end
  end
end
