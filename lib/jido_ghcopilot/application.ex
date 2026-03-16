defmodule Jido.GHCopilot.Application do
  @moduledoc false

  use Application

  def start(_type, _args) do
    children = [
      # Supervise a process that owns the ETS table used by the session registry
      Jido.GHCopilot.SessionRegistry.Server,
      {Task.Supervisor, name: Jido.GHCopilot.TaskSupervisor}
    ]

    opts = [strategy: :one_for_one, name: Jido.GHCopilot.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
