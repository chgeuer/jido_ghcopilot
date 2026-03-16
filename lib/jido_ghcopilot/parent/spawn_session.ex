defmodule Jido.GHCopilot.Parent.SpawnSession do
  @moduledoc """
  Parent action that registers a session and spawns a GHCopilotSessionAgent child.
  """

  use Jido.Action,
    name: "ghcopilot_spawn_session",
    description: "Spawn a GHCopilot session as a child agent",
    schema: [
      prompt: [type: :string, required: true],
      model: [type: :string, default: nil],
      cwd: [type: :string, default: nil],
      session_tag: [type: :string, default: nil],
      timeout_ms: [type: :integer, default: to_timeout(minute: 10)]
    ]

  alias Jido.Agent.Directive
  alias Jido.GHCopilot.Parent.SessionRegistry

  @impl true
  def run(params, context) do
    agent = context[:agent]
    session_tag = params.session_tag || "ghcopilot-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    sessions = (agent && agent.state[:sessions]) || SessionRegistry.init_sessions()

    # Register session with a placeholder ID (real ID comes from ACP)
    sessions =
      SessionRegistry.register_session(sessions, session_tag, %{
        prompt: params.prompt,
        model: params.model
      })

    # Spawn child agent with StartSession action queued
    spawn_directive =
      Directive.spawn_agent(
        Jido.GHCopilot.SessionAgent,
        session_tag,
        initial_action:
          {Jido.GHCopilot.Actions.StartSession,
           %{
             prompt: params.prompt,
             model: params.model,
             cwd: params.cwd || File.cwd!(),
             timeout_ms: params.timeout_ms
           }}
      )

    {:ok, %{sessions: sessions}, [spawn_directive]}
  end
end
