defmodule Jido.GHCopilot.Actions.HandleMessage do
  @moduledoc """
  Processes ACP session/update messages dispatched by the StreamRunner.
  Updates agent state and emits signals to parent.
  """

  use Jido.Action,
    name: "ghcopilot_handle_message",
    description: "Process an ACP session update message",
    schema: [
      update_type: [type: :atom, required: true],
      session_id: [type: :string, required: true],
      data: [type: :any, default: %{}]
    ]

  alias Jido.Agent.Directive

  alias Jido.GHCopilot.Signals.{
    SessionError,
    SessionSuccess,
    TurnPlan,
    TurnText,
    TurnThought,
    TurnToolResult,
    TurnToolUse,
    TurnUsage
  }

  @impl true
  def run(params, context) do
    agent = context[:agent]

    {state_update, parent_signals, terminal?} =
      process_update(params.update_type, params.session_id, params.data, agent)

    directives = build_directives(agent, parent_signals, terminal?)

    {:ok, state_update, directives}
  end

  defp process_update(:agent_message_chunk, session_id, data, agent) do
    text = get_text(data)
    current_transcript = get_transcript(agent)

    state = %{
      turns: get_turns(agent) + 1,
      transcript: current_transcript ++ [{:assistant, text}]
    }

    signal = TurnText.new!(%{session_id: session_id, text: text})

    {state, [signal], false}
  end

  defp process_update(:agent_thought_chunk, session_id, data, agent) do
    text = get_text(data)
    current_thinking = if agent, do: agent.state.thinking || [], else: []

    state = %{thinking: current_thinking ++ [text]}

    signal = TurnThought.new!(%{session_id: session_id, text: text})

    {state, [signal], false}
  end

  defp process_update(:tool_call, session_id, data, _agent) do
    signal =
      TurnToolUse.new!(%{
        session_id: session_id,
        tool_call_id: data.tool_call_id,
        title: data.title,
        kind: data.kind,
        status: to_string(data.status)
      })

    {%{}, [signal], false}
  end

  defp process_update(:tool_call_update, session_id, data, _agent) do
    signal =
      TurnToolResult.new!(%{
        session_id: session_id,
        tool_call_id: data.tool_call_id,
        status: to_string(data.status),
        content: data.content
      })

    {%{}, [signal], false}
  end

  defp process_update(:plan, session_id, data, _agent) do
    entries = data[:entries] || data.entries || []

    signal = TurnPlan.new!(%{session_id: session_id, entries: entries})

    {%{}, [signal], false}
  end

  defp process_update(:usage, session_id, data, _agent) do
    signal =
      TurnUsage.new!(%{
        session_id: session_id,
        model: data[:model],
        input_tokens: data[:input_tokens] || 0,
        output_tokens: data[:output_tokens] || 0,
        total_tokens: data[:total_tokens] || 0,
        cached_input_tokens: data[:cached_input_tokens] || 0,
        cost_usd: data[:cost_usd],
        duration_ms: data[:duration_ms]
      })

    {%{}, [signal], false}
  end

  defp process_update(:session_completed, session_id, data, agent) do
    stop_reason = data[:stop_reason] || data.stop_reason || :end_turn

    duration_ms =
      if agent && agent.state.started_at do
        System.monotonic_time(:millisecond) - agent.state.started_at
      end

    result_text =
      if agent do
        agent.state.transcript
        |> Enum.filter(fn {role, _} -> role == :assistant end)
        |> Enum.map_join("\n", fn {_, text} -> text end)
      else
        ""
      end

    state = %{
      status: :success,
      stop_reason: stop_reason,
      result: result_text
    }

    signal_params = %{
      session_id: session_id,
      result: String.slice(result_text, 0, 500),
      turns: get_turns(agent),
      stop_reason: to_string(stop_reason)
    }

    signal_params =
      if duration_ms, do: Map.put(signal_params, :duration_ms, duration_ms), else: signal_params

    signal = SessionSuccess.new!(signal_params)

    {state, [signal], true}
  end

  defp process_update(:session_error, session_id, data, _agent) do
    error_msg = data[:error] || inspect(data)

    state = %{
      status: :failure,
      error: %{type: "acp_error", details: error_msg}
    }

    signal =
      SessionError.new!(%{
        session_id: session_id,
        error_type: "acp_error",
        details: error_msg
      })

    {state, [signal], true}
  end

  defp process_update(:user_message_chunk, _session_id, _data, _agent) do
    # Session load replay — no state update needed
    {%{}, [], false}
  end

  defp process_update(_unknown, _session_id, _data, _agent) do
    {%{}, [], false}
  end

  # ── Helpers ──

  defp build_directives(agent, signals, terminal?) do
    signal_directives =
      Enum.flat_map(signals, fn signal ->
        if agent do
          case Directive.emit_to_parent(agent, signal) do
            nil -> []
            d -> [d]
          end
        else
          [Directive.emit(signal)]
        end
      end)

    if terminal? do
      signal_directives ++ [Directive.stop(:normal)]
    else
      signal_directives
    end
  end

  defp get_text(%{text: text}) when is_binary(text), do: text
  defp get_text(_), do: ""

  defp get_transcript(nil), do: []
  defp get_transcript(%{state: %{transcript: t}}) when is_list(t), do: t
  defp get_transcript(_), do: []

  defp get_turns(nil), do: 0
  defp get_turns(%{state: %{turns: t}}) when is_integer(t), do: t
  defp get_turns(_), do: 0
end
