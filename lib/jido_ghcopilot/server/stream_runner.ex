defmodule Jido.GHCopilot.Server.StreamRunner do
  @moduledoc """
  Task that subscribes to CLI Server Connection events for a session and
  dispatches them as `ghcopilot.internal.message` signals to the SessionAgent.

  Similar to `Jido.GHCopilot.StreamRunner` but works with the CLI Server
  protocol, which delivers raw session events including `assistant.usage`.
  """

  require Logger

  alias Jido.GHCopilot.Server.Connection
  alias Jido.GHCopilot.Server.Types.SessionEvent

  @doc """
  Run the stream runner with event forwarding.

  Subscribes to CLI Server events, sends the prompt, and forwards events
  as signals to the agent process. Returns when the session goes idle
  or times out.
  """
  def run_with_forwarding(agent_pid, conn, session_id, prompt, timeout_ms \\ to_timeout(minute: 10)) do
    :ok = Connection.subscribe(conn, session_id)

    # Send the prompt — this returns immediately with a message_id
    case Connection.send_prompt(conn, session_id, prompt, %{}, timeout_ms) do
      {:ok, _message_id} ->
        # Forward events until session goes idle or we time out
        forward_loop(agent_pid, session_id, timeout_ms)
        dispatch_completion(agent_pid, session_id, :end_turn)

      {:error, reason} ->
        Logger.error("CLI Server send failed for session #{session_id}: #{inspect(reason)}")
        dispatch_error(agent_pid, session_id, reason)
    end
  after
    if Process.alive?(conn) do
      Connection.unsubscribe(conn, session_id)
    end
  rescue
    e ->
      Logger.error("Server.StreamRunner crash: #{Exception.message(e)}")
      dispatch_error(agent_pid, session_id, Exception.message(e))
  end

  defp forward_loop(agent_pid, session_id, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_forward_loop(agent_pid, session_id, deadline)
  end

  defp do_forward_loop(agent_pid, session_id, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      Logger.warning("Server.StreamRunner timeout for session #{session_id}")
      :timeout
    else
      wait_ms = min(remaining, 500)

      receive do
        {:server_event, %SessionEvent{session_id: ^session_id} = event} ->
          dispatch_event(agent_pid, session_id, event)

          # session.idle means the turn is complete
          if event.type == "session.idle" do
            :idle
          else
            do_forward_loop(agent_pid, session_id, deadline)
          end
      after
        wait_ms ->
          do_forward_loop(agent_pid, session_id, deadline)
      end
    end
  end

  defp dispatch_event(agent_pid, session_id, %SessionEvent{} = event) do
    update_type = map_event_type(event.type)

    signal =
      Jido.Signal.new!(%{
        type: "ghcopilot.internal.message",
        source: "/ghcopilot/server_stream_runner",
        data: %{
          update_type: update_type,
          session_id: session_id,
          data: build_update_data(update_type, event)
        }
      })

    Jido.Signal.Dispatch.dispatch(signal, {:pid, target: agent_pid})
  end

  defp dispatch_completion(agent_pid, session_id, stop_reason) do
    signal =
      Jido.Signal.new!(%{
        type: "ghcopilot.internal.message",
        source: "/ghcopilot/server_stream_runner",
        data: %{
          update_type: :session_completed,
          session_id: session_id,
          data: %{stop_reason: stop_reason}
        }
      })

    Jido.Signal.Dispatch.dispatch(signal, {:pid, target: agent_pid})
  end

  defp dispatch_error(agent_pid, session_id, reason) do
    signal =
      Jido.Signal.new!(%{
        type: "ghcopilot.internal.message",
        source: "/ghcopilot/server_stream_runner",
        data: %{
          update_type: :session_error,
          session_id: session_id,
          data: %{error: inspect(reason)}
        }
      })

    Jido.Signal.Dispatch.dispatch(signal, {:pid, target: agent_pid})
  end

  # Map raw session event types to the internal update types
  # that HandleMessage understands
  defp map_event_type("assistant.message"), do: :agent_message_chunk
  defp map_event_type("assistant.intent"), do: :agent_thought_chunk
  defp map_event_type("assistant.turn_start"), do: :turn_start
  defp map_event_type("assistant.turn_end"), do: :turn_end
  defp map_event_type("assistant.usage"), do: :usage
  defp map_event_type("tool.execution_start"), do: :tool_call
  defp map_event_type("tool.execution_complete"), do: :tool_call_update
  defp map_event_type("tool.execution_partial_result"), do: :tool_call_update
  defp map_event_type("tool.user_requested"), do: :tool_call
  defp map_event_type("session.start"), do: :session_start
  defp map_event_type("session.idle"), do: :session_idle
  defp map_event_type("session.error"), do: :session_error
  defp map_event_type("session.info"), do: :session_info
  defp map_event_type("session.truncation"), do: :session_info
  defp map_event_type("abort"), do: :session_error
  defp map_event_type(_other), do: :unknown

  defp build_update_data(:agent_message_chunk, event) do
    text = event.data["text"] || extract_text_content(event.data["content"])
    %Jido.GHCopilot.ACP.Types.ContentBlock{type: "text", text: text}
  end

  defp build_update_data(:agent_thought_chunk, event) do
    text = event.data["text"] || extract_text_content(event.data["content"])
    %Jido.GHCopilot.ACP.Types.ContentBlock{type: "text", text: text}
  end

  defp build_update_data(:tool_call, event) do
    %Jido.GHCopilot.ACP.Types.ToolCall{
      tool_call_id: event.data["toolCallId"],
      title: event.data["title"],
      kind: event.data["kind"],
      status: decode_tool_status(event.data["status"]),
      content: event.data["content"]
    }
  end

  defp build_update_data(:tool_call_update, event) do
    %Jido.GHCopilot.ACP.Types.ToolCall{
      tool_call_id: event.data["toolCallId"],
      title: event.data["title"],
      kind: event.data["kind"],
      status: decode_tool_status(event.data["status"]),
      content: event.data["content"]
    }
  end

  defp build_update_data(:usage, event) do
    input = event.data["inputTokens"] || 0
    output = event.data["outputTokens"] || 0

    %{
      model: event.data["model"],
      input_tokens: input,
      output_tokens: output,
      total_tokens: input + output,
      cached_input_tokens: (event.data["cacheReadTokens"] || 0) + (event.data["cacheWriteTokens"] || 0),
      cost_usd: event.data["cost"],
      duration_ms: event.data["duration"]
    }
  end

  defp build_update_data(_type, event), do: event.data

  defp extract_text_content(content) when is_list(content) do
    content
    |> Enum.filter(&(is_map(&1) and &1["type"] == "text"))
    |> Enum.map_join("", & &1["text"])
  end

  defp extract_text_content(_), do: nil

  defp decode_tool_status("pending"), do: :pending
  defp decode_tool_status("in_progress"), do: :in_progress
  defp decode_tool_status("completed"), do: :completed
  defp decode_tool_status("cancelled"), do: :cancelled
  defp decode_tool_status("failed"), do: :failed
  defp decode_tool_status(_), do: :pending
end
