defmodule Jido.GHCopilot.SessionAgent do
  @moduledoc """
  Manages a single GitHub Copilot ACP session lifecycle.

  Mirrors jido_claude's ClaudeSessionAgent pattern — an immutable agent struct
  with signal-driven state transitions. The StreamRunner dispatches ACP
  session/update notifications as `ghcopilot.internal.message` signals.
  """

  use Jido.Agent,
    name: "ghcopilot_session",
    description: "Manages a single GitHub Copilot ACP session",
    schema: [
      status: [type: :atom, default: :idle],
      prompt: [type: :string, default: nil],
      options: [type: :any, default: nil],
      session_id: [type: :string, default: nil],
      acp_connection: [type: :any, default: nil],
      runner_pid: [type: :any, default: nil],
      model: [type: :string, default: nil],
      turns: [type: :integer, default: 0],
      transcript: [type: {:list, :any}, default: []],
      thinking: [type: {:list, :string}, default: []],
      result: [type: :string, default: nil],
      stop_reason: [type: :atom, default: nil],
      error: [type: :any, default: nil],
      started_at: [type: :any, default: nil]
    ]

  def actions do
    [
      Jido.GHCopilot.Actions.StartSession,
      Jido.GHCopilot.Actions.HandleMessage,
      Jido.GHCopilot.Actions.CancelSession
    ]
  end

  def signal_routes do
    [
      {"ghcopilot.internal.message", {Jido.GHCopilot.Actions.HandleMessage, %{}}}
    ]
  end
end
