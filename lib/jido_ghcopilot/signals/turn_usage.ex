defmodule Jido.GHCopilot.Signals.TurnUsage do
  @moduledoc "`ghcopilot.turn.usage` — token/cost usage metrics from a model call."
  use Jido.Signal,
    type: "ghcopilot.turn.usage",
    default_source: "/ghcopilot",
    schema: [
      session_id: [type: :string, required: false],
      model: [type: :string, required: false],
      input_tokens: [type: :integer, required: false, default: 0],
      output_tokens: [type: :integer, required: false, default: 0],
      total_tokens: [type: :integer, required: false, default: 0],
      cached_input_tokens: [type: :integer, required: false, default: 0],
      cost_usd: [type: :float, required: false],
      duration_ms: [type: :float, required: false]
    ]
end
