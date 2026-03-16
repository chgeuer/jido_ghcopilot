defmodule Jido.GHCopilot.Signals.SessionSuccess do
  @moduledoc "`ghcopilot.session.success` — session completed successfully."
  use Jido.Signal,
    type: "ghcopilot.session.success",
    default_source: "/ghcopilot",
    schema: [
      session_id: [type: :string, required: false],
      result: [type: :string, required: false],
      turns: [type: :integer, required: false],
      stop_reason: [type: :string, required: false],
      duration_ms: [type: :integer, required: false]
    ]
end
