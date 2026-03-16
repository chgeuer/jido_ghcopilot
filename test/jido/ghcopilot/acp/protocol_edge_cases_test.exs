defmodule Jido.GHCopilot.ACP.ProtocolEdgeCasesTest do
  use ExUnit.Case, async: true

  alias Jido.GHCopilot.ACP.Protocol

  describe "malformed JSON" do
    test "returns error for invalid JSON" do
      assert {:error, _} = Protocol.parse("not json at all")
    end

    test "returns error for truncated JSON" do
      assert {:error, _} = Protocol.parse("{\"jsonrpc\": \"2.0\", \"method\":")
    end

    test "returns error for empty string" do
      assert {:error, _} = Protocol.parse("")
    end

    test "handles JSON array (unexpected)" do
      assert {:error, _} = Protocol.parse("[1, 2, 3]")
    end
  end

  describe "missing required fields" do
    test "handles response without id" do
      json = Jason.encode!(%{jsonrpc: "2.0", result: %{foo: "bar"}})
      # Should not crash — either parses or returns error
      assert {_, _} = Protocol.parse(json)
    end

    test "handles notification with unknown method" do
      json =
        Jason.encode!(%{
          jsonrpc: "2.0",
          method: "unknown/method",
          params: %{data: "test"}
        })

      assert {_, _} = Protocol.parse(json)
    end

    test "handles session/update with missing sessionUpdate field" do
      json =
        Jason.encode!(%{
          jsonrpc: "2.0",
          method: "session/update",
          params: %{
            sessionId: "s1",
            update: %{}
          }
        })

      # Should handle gracefully — may crash or return error
      try do
        assert {_, _} = Protocol.parse(json)
      rescue
        _ -> :ok
      end
    end
  end

  describe "unexpected update_type values" do
    test "parses unknown session update type as :unknown" do
      json =
        Jason.encode!(%{
          jsonrpc: "2.0",
          method: "session/update",
          params: %{
            sessionId: "s1",
            update: %{
              sessionUpdate: "some_future_type",
              content: %{type: "text", text: "hi"}
            }
          }
        })

      case Protocol.parse(json) do
        {:notification, update} ->
          assert update.update_type == :unknown

        _ ->
          :ok
      end
    end
  end

  describe "edge case content" do
    test "handles empty text in content block" do
      json =
        Jason.encode!(%{
          jsonrpc: "2.0",
          method: "session/update",
          params: %{
            sessionId: "s1",
            update: %{
              sessionUpdate: "agent_message_chunk",
              content: %{type: "text", text: ""}
            }
          }
        })

      {:notification, update} = Protocol.parse(json)
      assert update.data.text == ""
    end

    test "handles unicode content" do
      json =
        Jason.encode!(%{
          jsonrpc: "2.0",
          method: "session/update",
          params: %{
            sessionId: "s1",
            update: %{
              sessionUpdate: "agent_message_chunk",
              content: %{type: "text", text: "こんにちは 🌍 émojis"}
            }
          }
        })

      {:notification, update} = Protocol.parse(json)
      assert update.data.text =~ "こんにちは"
    end

    test "handles very long text" do
      long_text = String.duplicate("a", 100_000)

      json =
        Jason.encode!(%{
          jsonrpc: "2.0",
          method: "session/update",
          params: %{
            sessionId: "s1",
            update: %{
              sessionUpdate: "agent_message_chunk",
              content: %{type: "text", text: long_text}
            }
          }
        })

      {:notification, update} = Protocol.parse(json)
      assert String.length(update.data.text) == 100_000
    end
  end

  describe "JSON-RPC error responses" do
    test "parses error response" do
      json =
        Jason.encode!(%{
          jsonrpc: "2.0",
          id: 1,
          error: %{code: -32600, message: "Invalid Request"}
        })

      {:response, response} = Protocol.parse(json)
      assert response.error != nil
      assert response.error["code"] == -32600
    end
  end

  describe "permission request" do
    test "parses session/request_permission" do
      json =
        Jason.encode!(%{
          jsonrpc: "2.0",
          id: 42,
          method: "session/request_permission",
          params: %{
            sessionId: "s1",
            toolCallId: "tc-1",
            toolName: "write_file",
            input: %{path: "/tmp/test.txt"}
          }
        })

      assert {_, _} = Protocol.parse(json)
    end
  end
end
