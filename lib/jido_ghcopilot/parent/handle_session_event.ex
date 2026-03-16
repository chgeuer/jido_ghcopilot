defmodule Jido.GHCopilot.Parent.HandleSessionEvent do
  @moduledoc """
  Parent action that processes signals from child GHCopilotSessionAgents
  and updates the parent's session registry.
  """

  use Jido.Action,
    name: "ghcopilot_handle_session_event",
    description: "Handle a session event from a child agent",
    schema: [
      session_id: [type: :string, required: true],
      event_type: [type: :string, required: true],
      data: [type: :any, default: %{}]
    ]

  alias Jido.GHCopilot.Parent.SessionRegistry

  @impl true
  def run(params, context) do
    agent = context[:agent]
    sessions = (agent && agent.state[:sessions]) || SessionRegistry.init_sessions()

    updates = event_to_updates(params.event_type, params.data)
    sessions = SessionRegistry.update_session(sessions, params.session_id, updates)

    {:ok, %{sessions: sessions}}
  end

  defp event_to_updates("ghcopilot.session.started", data) do
    %{status: :running, model: data[:model]}
  end

  defp event_to_updates("ghcopilot.turn.text", data) do
    %{last_text: data[:text]}
  end

  defp event_to_updates("ghcopilot.turn.thought", _data) do
    %{}
  end

  defp event_to_updates("ghcopilot.turn.tool_use", data) do
    %{last_tool: data[:title]}
  end

  defp event_to_updates("ghcopilot.turn.tool_result", _data) do
    %{}
  end

  defp event_to_updates("ghcopilot.turn.plan", _data) do
    %{}
  end

  defp event_to_updates("ghcopilot.session.success", data) do
    %{
      status: :success,
      result: data[:result],
      turns: data[:turns],
      duration_ms: data[:duration_ms]
    }
  end

  defp event_to_updates("ghcopilot.session.error", data) do
    %{
      status: :failure,
      error: %{type: data[:error_type], details: data[:details]}
    }
  end

  defp event_to_updates("jido.agent.child.started", data) do
    %{child_pid: data[:pid]}
  end

  defp event_to_updates("jido.agent.child.exit", data) do
    if data[:reason] != :normal do
      %{status: :failure, error: %{type: "crash", details: inspect(data[:reason])}}
    else
      %{}
    end
  end

  defp event_to_updates(_, _data), do: %{}
end
