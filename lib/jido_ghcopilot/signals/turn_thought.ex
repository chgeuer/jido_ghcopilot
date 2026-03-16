defmodule Jido.GHCopilot.Signals.TurnThought do
  @moduledoc "`ghcopilot.turn.thought` — agent thinking/reasoning chunk (unique to Copilot)."
  use Jido.Signal,
    type: "ghcopilot.turn.thought",
    default_source: "/ghcopilot",
    schema: [
      session_id: [type: :string, required: false],
      text: [type: :string, required: false]
    ]
end
