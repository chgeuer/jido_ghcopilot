defmodule Jido.GHCopilot.Parent.CancelSession do
  @moduledoc """
  Parent action that cancels a child session and updates the registry.
  """

  use Jido.Action,
    name: "ghcopilot_parent_cancel_session",
    description: "Cancel a child GHCopilot session from the parent",
    schema: [
      session_tag: [type: :string, required: true]
    ]

  alias Jido.Agent.Directive
  alias Jido.GHCopilot.Parent.SessionRegistry

  @impl true
  def run(params, context) do
    agent = context[:agent]
    sessions = (agent && agent.state[:sessions]) || SessionRegistry.init_sessions()

    sessions =
      SessionRegistry.update_session(sessions, params.session_tag, %{
        status: :cancelled
      })

    directives = [Directive.stop_child(params.session_tag, :cancelled)]

    {:ok, %{sessions: sessions}, directives}
  end
end
