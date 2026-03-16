defmodule Jido.GHCopilot.Signals.TurnToolResult do
  @moduledoc "`ghcopilot.turn.tool_result` — tool call status update (completed, failed, etc.)."
  use Jido.Signal,
    type: "ghcopilot.turn.tool_result",
    default_source: "/ghcopilot",
    schema: [
      session_id: [type: :string, required: false],
      tool_call_id: [type: :string, required: false],
      status: [type: :string, required: false],
      content: [type: :any, required: false]
    ]
end
