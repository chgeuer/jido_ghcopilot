defmodule Jido.GHCopilot.ACP.Protocol do
  @moduledoc """
  JSON-RPC 2.0 encode/decode for the Agent Client Protocol.

  Handles building requests, parsing responses and notifications,
  and converting raw JSON maps into typed ACP structs.
  """

  alias Jido.GHCopilot.ACP.Types.{
    AgentCapabilities,
    AgentInfo,
    ContentBlock,
    InitResult,
    Notification,
    PlanEntry,
    PromptResult,
    Request,
    Response,
    SessionResult,
    SessionUpdate,
    ToolCall
  }

  @protocol_version 1

  # ── Request Builders ──

  @doc "Build an `initialize` request."
  def initialize_request(id, client_info \\ %{name: "jido_ghcopilot", version: "0.1.0"}) do
    encode_request(id, "initialize", %{
      protocolVersion: @protocol_version,
      capabilities: %{},
      clientInfo: client_info
    })
  end

  @doc "Build a `session/new` request."
  def new_session_request(id, cwd, mcp_servers \\ []) do
    encode_request(id, "session/new", %{
      cwd: cwd,
      mcpServers: mcp_servers
    })
  end

  @doc "Build a `session/prompt` request."
  def prompt_request(id, session_id, prompt) when is_binary(prompt) do
    prompt_request(id, session_id, [%{type: "text", text: prompt}])
  end

  def prompt_request(id, session_id, content_blocks) when is_list(content_blocks) do
    encode_request(id, "session/prompt", %{
      sessionId: session_id,
      prompt: content_blocks
    })
  end

  @doc "Build a `session/load` request."
  def load_session_request(id, session_id, cwd, mcp_servers \\ []) do
    encode_request(id, "session/load", %{
      sessionId: session_id,
      cwd: cwd,
      mcpServers: mcp_servers
    })
  end

  @doc "Build a `session/cancel` notification."
  def cancel_notification(session_id) do
    encode_notification("session/cancel", %{sessionId: session_id})
  end

  @doc "Build a `session/request_permission` response (client → agent)."
  def permission_response(id, outcome) when outcome in [:allow, :deny, :cancelled] do
    %{
      jsonrpc: "2.0",
      id: id,
      result: %{outcome: %{outcome: Atom.to_string(outcome)}}
    }
    |> Jason.encode!()
  end

  # ── Parsing ──

  @doc "Parse a JSON line into a typed message."
  def parse(json_line) when is_binary(json_line) do
    case Jason.decode(json_line) do
      {:ok, %{"id" => id} = msg} when not is_nil(id) ->
        parse_response_or_request(msg)

      {:ok, %{"method" => method, "params" => params}} ->
        parse_notification(method, params)

      {:ok, _} ->
        {:error, :unknown_message}

      {:error, reason} ->
        {:error, {:json_decode, reason}}
    end
  end

  defp parse_response_or_request(%{"id" => id, "result" => result}) when not is_nil(result) do
    {:response, %Response{id: id, result: result}}
  end

  defp parse_response_or_request(%{"id" => id, "error" => error}) when not is_nil(error) do
    {:response, %Response{id: id, error: error}}
  end

  defp parse_response_or_request(%{"id" => id, "method" => method, "params" => params}) do
    {:request, %Request{id: id, method: method, params: params}}
  end

  defp parse_response_or_request(%{"id" => id}) do
    {:response, %Response{id: id, result: nil}}
  end

  defp parse_notification("session/update", %{"sessionId" => sid, "update" => update}) do
    {:notification, parse_session_update(sid, update)}
  end

  defp parse_notification(method, params) do
    {:notification, %Notification{method: method, params: params}}
  end

  # ── Response Decoders ──

  @doc "Decode an initialize response result into `InitResult`."
  def decode_init_result(%{"protocolVersion" => pv} = result) do
    %InitResult{
      protocol_version: pv,
      agent_info: decode_agent_info(result["agentInfo"]),
      agent_capabilities: decode_capabilities(result["agentCapabilities"]),
      auth_methods: result["authMethods"]
    }
  end

  @doc "Decode a session/new response result into `SessionResult`."
  def decode_session_result(%{"sessionId" => sid}) do
    %SessionResult{session_id: sid}
  end

  @doc "Decode a session/prompt response result into `PromptResult`."
  def decode_prompt_result(%{"stopReason" => reason}) do
    %PromptResult{stop_reason: decode_stop_reason(reason)}
  end

  # ── Session Update Parsing ──

  @doc "Parse a raw session update map into a `SessionUpdate` struct."
  def decode_session_update(session_id, update) do
    parse_session_update(session_id, update)
  end

  defp parse_session_update(session_id, %{"sessionUpdate" => type} = update) do
    update_type = decode_update_type(type)

    data =
      case update_type do
        :agent_message_chunk -> decode_content(update["content"])
        :agent_thought_chunk -> decode_content(update["content"])
        :user_message_chunk -> decode_content(update["content"])
        :tool_call -> decode_tool_call(update)
        :tool_call_update -> decode_tool_call(update)
        :plan -> decode_plan(update)
        _ -> update
      end

    %SessionUpdate{
      session_id: session_id,
      update_type: update_type,
      data: data
    }
  end

  # ── Internal Decoders ──

  defp decode_agent_info(nil), do: nil

  defp decode_agent_info(info) do
    %AgentInfo{
      name: info["name"],
      title: info["title"],
      version: info["version"]
    }
  end

  defp decode_capabilities(nil), do: nil

  defp decode_capabilities(caps) do
    %AgentCapabilities{
      load_session: caps["loadSession"] == true,
      prompt_capabilities: caps["promptCapabilities"],
      session_capabilities: caps["sessionCapabilities"],
      mcp_capabilities: caps["mcpCapabilities"]
    }
  end

  defp decode_update_type("agent_message_chunk"), do: :agent_message_chunk
  defp decode_update_type("agent_thought_chunk"), do: :agent_thought_chunk
  defp decode_update_type("tool_call"), do: :tool_call
  defp decode_update_type("tool_call_update"), do: :tool_call_update
  defp decode_update_type("plan"), do: :plan
  defp decode_update_type("user_message_chunk"), do: :user_message_chunk
  defp decode_update_type(_), do: :unknown

  defp decode_stop_reason("end_turn"), do: :end_turn
  defp decode_stop_reason("max_tokens"), do: :max_tokens
  defp decode_stop_reason("max_turn_requests"), do: :max_turn_requests
  defp decode_stop_reason("refusal"), do: :refusal
  defp decode_stop_reason("cancelled"), do: :cancelled
  defp decode_stop_reason(_), do: :end_turn

  defp decode_content(%{"type" => type, "text" => text}) do
    %ContentBlock{type: type, text: text}
  end

  defp decode_content(other), do: %ContentBlock{type: "unknown", text: inspect(other)}

  defp decode_tool_call(update) do
    %ToolCall{
      tool_call_id: update["toolCallId"],
      title: update["title"],
      kind: update["kind"],
      status: decode_tool_status(update["status"]),
      content: update["content"]
    }
  end

  defp decode_tool_status("pending"), do: :pending
  defp decode_tool_status("in_progress"), do: :in_progress
  defp decode_tool_status("completed"), do: :completed
  defp decode_tool_status("cancelled"), do: :cancelled
  defp decode_tool_status("failed"), do: :failed
  defp decode_tool_status(_), do: :pending

  defp decode_plan(update) do
    entries =
      (update["entries"] || [])
      |> Enum.map(fn e ->
        %PlanEntry{
          content: e["content"],
          priority: e["priority"],
          status: e["status"]
        }
      end)

    %{entries: entries}
  end

  # ── Encoding Helpers ──

  defp encode_request(id, method, params) do
    %{jsonrpc: "2.0", id: id, method: method, params: params}
    |> Jason.encode!()
  end

  defp encode_notification(method, params) do
    %{jsonrpc: "2.0", method: method, params: params}
    |> Jason.encode!()
  end
end
