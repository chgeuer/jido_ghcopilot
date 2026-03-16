defmodule Jido.GHCopilot.Signals.TurnToolUse do
  @moduledoc "`ghcopilot.turn.tool_use` — agent requested a tool call."
  use Jido.Signal,
    type: "ghcopilot.turn.tool_use",
    default_source: "/ghcopilot",
    schema: [
      session_id: [type: :string, required: false],
      tool_call_id: [type: :string, required: false],
      title: [type: :string, required: false],
      kind: [type: :string, required: false],
      status: [type: :string, required: false]
    ]
end
