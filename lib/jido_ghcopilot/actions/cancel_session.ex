defmodule Jido.GHCopilot.Actions.CancelSession do
  @moduledoc """
  Cancels a running GHCopilot ACP session.
  """

  use Jido.Action,
    name: "ghcopilot_cancel_session",
    description: "Cancel a running GitHub Copilot session",
    schema: []

  alias Jido.Agent.Directive

  require Logger

  @impl true
  def run(_params, context) do
    agent = context[:agent]

    if agent do
      state = agent.state

      # Cancel via executor if available, otherwise try ACP connection directly
      cond do
        state[:executor_module] && state[:runner_ref] ->
          state.executor_module.cancel(state.runner_ref)

        state[:acp_connection] && state[:session_id] ->
          Jido.GHCopilot.ACP.Connection.cancel(state.acp_connection, state.session_id)

        true ->
          :ok
      end

      session_id = state[:session_id]
      Logger.info("Cancelled session #{session_id}")

      signal =
        Jido.GHCopilot.Signals.SessionError.new!(%{
          session_id: agent.state.session_id,
          error_type: "cancelled",
          details: "Session cancelled by user"
        })

      directives =
        case Directive.emit_to_parent(agent, signal) do
          nil -> [Directive.stop(:normal)]
          d -> [d, Directive.stop(:normal)]
        end

      {:ok, %{status: :cancelled}, directives}
    else
      {:ok, %{status: :cancelled}}
    end
  end
end
