defmodule Jido.GHCopilot.Signals.SessionStarted do
  @moduledoc "`ghcopilot.session.started` — emitted when ACP session initializes."
  use Jido.Signal,
    type: "ghcopilot.session.started",
    default_source: "/ghcopilot",
    schema: [
      session_id: [type: :string, required: false],
      model: [type: :string, required: false]
    ]
end
