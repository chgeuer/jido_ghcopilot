defmodule Jido.GHCopilot.Server.Protocol do
  @moduledoc """
  JSON-RPC 2.0 encode/decode for the CLI Server protocol.

  The CLI Server protocol uses dot-separated method names (e.g. `session.create`)
  unlike ACP's slash-separated names (e.g. `session/new`). It delivers raw
  session events via `session.event` notifications, including `assistant.usage`.
  """

  alias Jido.GHCopilot.Server.Types.{
    CreateResult,
    ListEntry,
    SendResult,
    SessionEvent,
    UsageEvent
  }

  # ── Request Builders ──

  @doc "Build a `ping` request."
  def ping_request(id, message \\ nil) do
    params = if message, do: %{message: message}, else: %{}
    encode_request(id, "ping", params)
  end

  @doc "Build a `session.create` request."
  def create_session_request(id, opts \\ %{}) do
    params =
      %{}
      |> maybe_put(:model, opts[:model])
      |> maybe_put(:sessionId, opts[:session_id])
      |> maybe_put(:systemMessage, opts[:system_message])
      |> maybe_put(:availableTools, opts[:available_tools])
      |> maybe_put(:excludedTools, opts[:excluded_tools])
      |> maybe_put(:tools, opts[:tools])
      |> maybe_put(:requestPermission, opts[:request_permission])

    encode_request(id, "session.create", params)
  end

  @doc "Build a `session.send` request."
  def send_request(id, session_id, prompt, opts \\ %{}) do
    attachments =
      case opts[:attachments] do
        nil -> nil
        [] -> nil
        list -> Enum.map(list, &encode_attachment/1)
      end

    params =
      %{sessionId: session_id, prompt: prompt}
      |> maybe_put(:attachments, attachments)
      |> maybe_put(:mode, opts[:mode])

    encode_request(id, "session.send", params)
  end

  defp encode_attachment(%Jido.GHCopilot.Server.Types.Attachment{} = a),
    do: Jido.GHCopilot.Server.Types.Attachment.to_json(a)

  defp encode_attachment(%{type: _, path: _} = map), do: map

  @doc "Build a `session.resume` request."
  def resume_session_request(id, session_id, opts \\ %{}) do
    params =
      %{sessionId: session_id}
      |> maybe_put(:tools, opts[:tools])
      |> maybe_put(:requestPermission, opts[:request_permission])

    encode_request(id, "session.resume", params)
  end

  @doc "Build a `session.destroy` request."
  def destroy_session_request(id, session_id) do
    encode_request(id, "session.destroy", %{sessionId: session_id})
  end

  @doc "Build a `session.list` request."
  def list_sessions_request(id) do
    encode_request(id, "session.list", %{})
  end

  @doc "Build a `session.getMessages` request."
  def get_messages_request(id, session_id) do
    encode_request(id, "session.getMessages", %{sessionId: session_id})
  end

  @doc "Build a `session.getLastId` request."
  def get_last_id_request(id) do
    encode_request(id, "session.getLastId", %{})
  end

  @doc "Build a `session.delete` request."
  def delete_session_request(id, session_id) do
    encode_request(id, "session.delete", %{sessionId: session_id})
  end

  @doc "Build a `session.setModel` request (handled by the wrapper)."
  def set_model_request(id, session_id, model) do
    encode_request(id, "session.setModel", %{sessionId: session_id, model: model})
  end

  # ── Parsing ──

  @doc "Parse a JSON line into a typed message."
  def parse(json_line) when is_binary(json_line) do
    case Jason.decode(json_line) do
      # Server request (has both id and method) — e.g. tool.call
      {:ok, %{"id" => id, "method" => method, "params" => params}} when not is_nil(id) ->
        {:request, %{id: id, method: method, params: params}}

      {:ok, %{"id" => id} = msg} when not is_nil(id) ->
        parse_response(msg)

      {:ok, %{"method" => method, "params" => params}} ->
        parse_notification(method, params)

      {:ok, _} ->
        {:error, :unknown_message}

      {:error, reason} ->
        {:error, {:json_decode, reason}}
    end
  end

  defp parse_response(%{"id" => id, "result" => result}) when not is_nil(result) do
    {:response, %{id: id, result: result, error: nil}}
  end

  defp parse_response(%{"id" => id, "error" => error}) when not is_nil(error) do
    {:response, %{id: id, result: nil, error: error}}
  end

  defp parse_response(%{"id" => id}) do
    {:response, %{id: id, result: nil, error: nil}}
  end

  defp parse_notification("session.event", %{"sessionId" => sid, "event" => event}) do
    {:notification, decode_session_event(sid, event)}
  end

  defp parse_notification(method, params) do
    {:notification, %{method: method, params: params}}
  end

  # ── Response Decoders ──

  @doc "Decode a `session.create` response."
  def decode_create_result(%{"sessionId" => sid}) do
    %CreateResult{session_id: sid}
  end

  @doc "Decode a `session.send` response."
  def decode_send_result(%{"messageId" => mid}) do
    %SendResult{message_id: mid}
  end

  @doc "Decode a `session.list` response."
  def decode_list_result(%{"sessions" => sessions}) when is_list(sessions) do
    Enum.map(sessions, fn s ->
      %ListEntry{
        session_id: s["sessionId"],
        start_time: s["startTime"],
        modified_time: s["modifiedTime"],
        summary: s["summary"],
        is_remote: s["isRemote"] == true
      }
    end)
  end

  # ── Session Event Decoding ──

  @doc "Decode a raw session event from `session.event` notification."
  def decode_session_event(session_id, event) when is_map(event) do
    %SessionEvent{
      id: event["id"],
      type: event["type"] || "unknown",
      data: event["data"] || %{},
      timestamp: event["timestamp"],
      parent_id: event["parentId"],
      session_id: session_id,
      ephemeral: event["ephemeral"] == true
    }
  end

  @doc "Extract usage data from an `assistant.usage` session event."
  def decode_usage_event(%SessionEvent{type: "assistant.usage", data: data}) do
    %UsageEvent{
      model: data["model"],
      input_tokens: data["inputTokens"] || 0,
      output_tokens: data["outputTokens"] || 0,
      cache_read_tokens: data["cacheReadTokens"] || 0,
      cache_write_tokens: data["cacheWriteTokens"] || 0,
      cost: data["cost"],
      duration_ms: data["duration"],
      initiator: data["initiator"],
      api_call_id: data["apiCallId"],
      provider_call_id: data["providerCallId"],
      quota_snapshots: data["quotaSnapshots"]
    }
  end

  # ── Internal ──

  @doc "Build a JSON-RPC response (for server→client requests like tool.call)."
  def encode_response(id, result) do
    %{jsonrpc: "2.0", id: id, result: result}
    |> Jason.encode!()
  end

  defp encode_request(id, method, params) do
    %{jsonrpc: "2.0", id: id, method: method, params: params}
    |> Jason.encode!()
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
