defmodule Jido.GHCopilot.Test.Fixtures do
  @moduledoc """
  Factory functions for ACP event structs used in tests.

  All fixtures return real typed structs — never raw maps.
  Every field is overridable via the `overrides` keyword argument.

  ## Examples

      # Default message chunk
      Fixtures.agent_message_chunk()

      # Custom content and session
      Fixtures.agent_message_chunk(session_id: "my-session", text: "Hello!")

      # Full tool call sequence
      Fixtures.tool_call_sequence("sess-1", "read_file")
  """

  alias Jido.GHCopilot.ACP.Types.{
    ContentBlock,
    InitResult,
    AgentInfo,
    AgentCapabilities,
    PlanEntry,
    PermissionRequest,
    PromptResult,
    SessionResult,
    SessionUpdate,
    ToolCall
  }

  @default_session_id "test-session-001"

  # ── Session Updates ──

  def agent_message_chunk(overrides \\ []) do
    %SessionUpdate{
      session_id: Keyword.get(overrides, :session_id, @default_session_id),
      update_type: :agent_message_chunk,
      data: %ContentBlock{
        type: "text",
        text: Keyword.get(overrides, :text, "Hello, world!"),
        resource: nil
      }
    }
  end

  def agent_thought_chunk(overrides \\ []) do
    %SessionUpdate{
      session_id: Keyword.get(overrides, :session_id, @default_session_id),
      update_type: :agent_thought_chunk,
      data: %ContentBlock{
        type: "text",
        text: Keyword.get(overrides, :text, "Let me think about this..."),
        resource: nil
      }
    }
  end

  def tool_call(overrides \\ []) do
    %SessionUpdate{
      session_id: Keyword.get(overrides, :session_id, @default_session_id),
      update_type: :tool_call,
      data: %ToolCall{
        tool_call_id: Keyword.get(overrides, :tool_call_id, "tc-001"),
        title: Keyword.get(overrides, :title, "Reading file"),
        kind: Keyword.get(overrides, :kind, "read_file"),
        status: Keyword.get(overrides, :status, :pending),
        content: Keyword.get(overrides, :content, [])
      }
    }
  end

  def tool_call_update(overrides \\ []) do
    %SessionUpdate{
      session_id: Keyword.get(overrides, :session_id, @default_session_id),
      update_type: :tool_call_update,
      data: %ToolCall{
        tool_call_id: Keyword.get(overrides, :tool_call_id, "tc-001"),
        title: Keyword.get(overrides, :title, "Reading file"),
        kind: Keyword.get(overrides, :kind, "read_file"),
        status: Keyword.get(overrides, :status, :completed),
        content: Keyword.get(overrides, :content, [%{"type" => "text", "text" => "file contents"}])
      }
    }
  end

  def plan(overrides \\ []) do
    entries =
      Keyword.get(overrides, :entries, [
        %PlanEntry{content: "Read the source files", priority: "high", status: "in_progress"},
        %PlanEntry{content: "Analyze the code", priority: "medium", status: "pending"}
      ])

    %SessionUpdate{
      session_id: Keyword.get(overrides, :session_id, @default_session_id),
      update_type: :plan,
      data: %{entries: entries}
    }
  end

  def user_message_chunk(overrides \\ []) do
    %SessionUpdate{
      session_id: Keyword.get(overrides, :session_id, @default_session_id),
      update_type: :user_message_chunk,
      data: %ContentBlock{
        type: "text",
        text: Keyword.get(overrides, :text, "User said something"),
        resource: nil
      }
    }
  end

  def unknown_update(overrides \\ []) do
    %SessionUpdate{
      session_id: Keyword.get(overrides, :session_id, @default_session_id),
      update_type: :unknown,
      data: Keyword.get(overrides, :data, %{raw: "something unexpected"})
    }
  end

  # ── Composite Sequences ──

  def thinking_sequence(session_id \\ @default_session_id) do
    [
      agent_thought_chunk(session_id: session_id, text: "Let me analyze this..."),
      agent_thought_chunk(session_id: session_id, text: "I see the pattern now."),
      agent_message_chunk(session_id: session_id, text: "Here is my analysis.")
    ]
  end

  def tool_call_sequence(session_id \\ @default_session_id, tool_name \\ "read_file") do
    tc_id = "tc-#{System.unique_integer([:positive])}"

    [
      tool_call(
        session_id: session_id,
        tool_call_id: tc_id,
        kind: tool_name,
        title: "Using #{tool_name}",
        status: :pending
      ),
      tool_call_update(
        session_id: session_id,
        tool_call_id: tc_id,
        kind: tool_name,
        title: "Using #{tool_name}",
        status: :in_progress
      ),
      tool_call_update(
        session_id: session_id,
        tool_call_id: tc_id,
        kind: tool_name,
        title: "Using #{tool_name}",
        status: :completed,
        content: [%{"type" => "text", "text" => "tool output here"}]
      )
    ]
  end

  def multi_turn_conversation(session_id \\ @default_session_id) do
    [
      agent_thought_chunk(session_id: session_id, text: "Processing first request..."),
      agent_message_chunk(session_id: session_id, text: "Here's my first response."),
      user_message_chunk(session_id: session_id, text: "Follow-up question"),
      agent_thought_chunk(session_id: session_id, text: "Considering the follow-up..."),
      agent_message_chunk(session_id: session_id, text: "Here's my second response.")
    ]
  end

  def full_session_sequence(session_id \\ @default_session_id) do
    thinking_sequence(session_id) ++
      tool_call_sequence(session_id) ++
      [plan(session_id: session_id)] ++
      [agent_message_chunk(session_id: session_id, text: "Final answer.")]
  end

  # ── Initialization ──

  def init_result(overrides \\ []) do
    %InitResult{
      protocol_version: Keyword.get(overrides, :protocol_version, 1),
      agent_info: Keyword.get(overrides, :agent_info, agent_info()),
      agent_capabilities: Keyword.get(overrides, :agent_capabilities, agent_capabilities()),
      auth_methods: Keyword.get(overrides, :auth_methods, [])
    }
  end

  def agent_info(overrides \\ []) do
    %AgentInfo{
      name: Keyword.get(overrides, :name, "copilot"),
      title: Keyword.get(overrides, :title, "GitHub Copilot"),
      version: Keyword.get(overrides, :version, "0.0.412-2")
    }
  end

  def agent_capabilities(overrides \\ []) do
    %AgentCapabilities{
      load_session: Keyword.get(overrides, :load_session, true),
      prompt_capabilities: Keyword.get(overrides, :prompt_capabilities, %{}),
      session_capabilities: Keyword.get(overrides, :session_capabilities, %{}),
      mcp_capabilities: Keyword.get(overrides, :mcp_capabilities, %{})
    }
  end

  # ── Session & Prompt Results ──

  def session_result(overrides \\ []) do
    %SessionResult{
      session_id: Keyword.get(overrides, :session_id, @default_session_id)
    }
  end

  def prompt_result(overrides \\ []) do
    %PromptResult{
      stop_reason: Keyword.get(overrides, :stop_reason, :end_turn)
    }
  end

  # ── Permission Requests ──

  def permission_request(overrides \\ []) do
    %PermissionRequest{
      session_id: Keyword.get(overrides, :session_id, @default_session_id),
      tool_call_id: Keyword.get(overrides, :tool_call_id, "tc-perm-001"),
      tool_name: Keyword.get(overrides, :tool_name, "write_file"),
      input: Keyword.get(overrides, :input, %{"path" => "/tmp/test.txt"})
    }
  end

  # ── Error Fixtures ──

  def malformed_update(overrides \\ []) do
    %SessionUpdate{
      session_id: Keyword.get(overrides, :session_id, nil),
      update_type: Keyword.get(overrides, :update_type, :unknown),
      data: Keyword.get(overrides, :data, nil)
    }
  end

  def content_block(overrides \\ []) do
    %ContentBlock{
      type: Keyword.get(overrides, :type, "text"),
      text: Keyword.get(overrides, :text, "content"),
      resource: Keyword.get(overrides, :resource, nil)
    }
  end

  def resource_content_block(overrides \\ []) do
    %ContentBlock{
      type: "resource",
      text: nil,
      resource:
        Keyword.get(overrides, :resource, %{
          "uri" => "file:///tmp/test.txt",
          "mimeType" => "text/plain",
          "text" => "file content"
        })
    }
  end
end
