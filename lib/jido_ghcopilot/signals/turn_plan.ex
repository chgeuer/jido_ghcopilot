defmodule Jido.GHCopilot.Signals.TurnPlan do
  @moduledoc "`ghcopilot.turn.plan` — agent's structured plan (unique to Copilot)."
  use Jido.Signal,
    type: "ghcopilot.turn.plan",
    default_source: "/ghcopilot",
    schema: [
      session_id: [type: :string, required: false],
      entries: [type: :any, required: false]
    ]
end
