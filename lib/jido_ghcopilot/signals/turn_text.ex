defmodule Jido.GHCopilot.Signals.TurnText do
  @moduledoc "`ghcopilot.turn.text` — agent response text chunk."
  use Jido.Signal,
    type: "ghcopilot.turn.text",
    default_source: "/ghcopilot",
    schema: [
      session_id: [type: :string, required: false],
      text: [type: :string, required: false]
    ]
end
