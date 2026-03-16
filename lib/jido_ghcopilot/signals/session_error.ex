defmodule Jido.GHCopilot.Signals.SessionError do
  @moduledoc "`ghcopilot.session.error` — session failed."
  use Jido.Signal,
    type: "ghcopilot.session.error",
    default_source: "/ghcopilot",
    schema: [
      session_id: [type: :string, required: false],
      error_type: [type: :string, required: false],
      details: [type: :string, required: false]
    ]
end
