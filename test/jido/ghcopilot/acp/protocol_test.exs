defmodule Jido.GHCopilot.ACP.ProtocolTest do
  use ExUnit.Case, async: true

  alias Jido.GHCopilot.ACP.Protocol

  alias Jido.GHCopilot.ACP.Types.{
    ContentBlock,
    InitResult,
    PromptResult,
    Response,
    SessionResult,
    SessionUpdate,
    ToolCall
  }

  describe "request builders" do
    test "initialize_request" do
      json = Protocol.initialize_request(1)
      decoded = Jason.decode!(json)
      assert decoded["jsonrpc"] == "2.0"
      assert decoded["id"] == 1
      assert decoded["method"] == "initialize"
      assert decoded["params"]["protocolVersion"] == 1
      assert decoded["params"]["clientInfo"]["name"] == "jido_ghcopilot"
    end

    test "new_session_request" do
      json = Protocol.new_session_request(2, "/tmp/project")
      decoded = Jason.decode!(json)
      assert decoded["method"] == "session/new"
      assert decoded["params"]["cwd"] == "/tmp/project"
      assert decoded["params"]["mcpServers"] == []
    end

    test "prompt_request with string" do
      json = Protocol.prompt_request(3, "sess-1", "Hello")
      decoded = Jason.decode!(json)
      assert decoded["method"] == "session/prompt"
      assert decoded["params"]["sessionId"] == "sess-1"
      assert [%{"type" => "text", "text" => "Hello"}] = decoded["params"]["prompt"]
    end

    test "prompt_request with content blocks" do
      blocks = [%{type: "text", text: "Hello"}, %{type: "text", text: "World"}]
      json = Protocol.prompt_request(3, "sess-1", blocks)
      decoded = Jason.decode!(json)
      assert length(decoded["params"]["prompt"]) == 2
    end

    test "cancel_notification" do
      json = Protocol.cancel_notification("sess-1")
      decoded = Jason.decode!(json)
      assert decoded["method"] == "session/cancel"
      assert decoded["params"]["sessionId"] == "sess-1"
      refute Map.has_key?(decoded, "id")
    end

    test "permission_response" do
      json = Protocol.permission_response(5, :allow)
      decoded = Jason.decode!(json)
      assert decoded["id"] == 5
      assert decoded["result"]["outcome"]["outcome"] == "allow"
    end
  end

  describe "parse/1" do
    test "parses success response" do
      json = ~s({"jsonrpc":"2.0","id":1,"result":{"sessionId":"abc"}})
      assert {:response, %Response{id: 1, result: %{"sessionId" => "abc"}}} = Protocol.parse(json)
    end

    test "parses error response" do
      json = ~s({"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"Not found"}})
      assert {:response, %Response{id: 1, error: %{"code" => -32601}}} = Protocol.parse(json)
    end

    test "parses session/update notification with agent_message_chunk" do
      json =
        Jason.encode!(%{
          jsonrpc: "2.0",
          method: "session/update",
          params: %{
            sessionId: "sess-1",
            update: %{sessionUpdate: "agent_message_chunk", content: %{type: "text", text: "Hello"}}
          }
        })

      assert {:notification,
              %SessionUpdate{
                session_id: "sess-1",
                update_type: :agent_message_chunk,
                data: %ContentBlock{type: "text", text: "Hello"}
              }} = Protocol.parse(json)
    end

    test "parses agent_thought_chunk" do
      json =
        Jason.encode!(%{
          jsonrpc: "2.0",
          method: "session/update",
          params: %{
            sessionId: "sess-1",
            update: %{sessionUpdate: "agent_thought_chunk", content: %{type: "text", text: "Thinking..."}}
          }
        })

      assert {:notification,
              %SessionUpdate{
                update_type: :agent_thought_chunk,
                data: %ContentBlock{text: "Thinking..."}
              }} = Protocol.parse(json)
    end

    test "parses tool_call" do
      json =
        Jason.encode!(%{
          jsonrpc: "2.0",
          method: "session/update",
          params: %{
            sessionId: "sess-1",
            update: %{
              sessionUpdate: "tool_call",
              toolCallId: "call-1",
              title: "Reading file",
              kind: "read",
              status: "pending"
            }
          }
        })

      assert {:notification,
              %SessionUpdate{
                update_type: :tool_call,
                data: %ToolCall{tool_call_id: "call-1", title: "Reading file", status: :pending}
              }} = Protocol.parse(json)
    end

    test "parses plan" do
      json =
        Jason.encode!(%{
          jsonrpc: "2.0",
          method: "session/update",
          params: %{
            sessionId: "sess-1",
            update: %{
              sessionUpdate: "plan",
              entries: [%{content: "Step 1", priority: "high", status: "pending"}]
            }
          }
        })

      assert {:notification, %SessionUpdate{update_type: :plan, data: %{entries: [entry]}}} =
               Protocol.parse(json)

      assert entry.content == "Step 1"
      assert entry.priority == "high"
    end

    test "parses request from agent" do
      json =
        Jason.encode!(%{jsonrpc: "2.0", id: 10, method: "session/request_permission", params: %{sessionId: "sess-1"}})

      assert {:request, request} = Protocol.parse(json)
      assert request.id == 10
      assert request.method == "session/request_permission"
    end

    test "returns error for invalid JSON" do
      assert {:error, {:json_decode, _}} = Protocol.parse("not json")
    end
  end

  describe "decode helpers" do
    test "decode_init_result" do
      result =
        Protocol.decode_init_result(%{
          "protocolVersion" => 1,
          "agentInfo" => %{"name" => "Copilot", "title" => "Copilot", "version" => "0.0.412"},
          "agentCapabilities" => %{"loadSession" => true, "promptCapabilities" => %{"image" => true}}
        })

      assert %InitResult{protocol_version: 1} = result
      assert result.agent_info.name == "Copilot"
      assert result.agent_capabilities.load_session == true
    end

    test "decode_session_result" do
      assert %SessionResult{session_id: "abc"} =
               Protocol.decode_session_result(%{"sessionId" => "abc"})
    end

    test "decode_prompt_result" do
      assert %PromptResult{stop_reason: :end_turn} =
               Protocol.decode_prompt_result(%{"stopReason" => "end_turn"})

      assert %PromptResult{stop_reason: :cancelled} =
               Protocol.decode_prompt_result(%{"stopReason" => "cancelled"})
    end
  end
end
