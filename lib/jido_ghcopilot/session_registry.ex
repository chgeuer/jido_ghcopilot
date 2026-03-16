defmodule Jido.GHCopilot.SessionRegistry do
  @moduledoc """
  In-memory registry of active streamed GitHub Copilot sessions used for cancellation.

  Write operations are routed through the owning GenServer to maintain
  `:protected` ETS access control. Read operations are direct ETS lookups.
  """

  @table __MODULE__

  @type session_entry :: %{
          required(:port) => port() | nil,
          optional(:port_pid) => non_neg_integer() | nil
        }

  @doc "Registers an active session entry by session id."
  @spec register(String.t(), session_entry()) :: :ok
  def register(session_id, entry) when is_binary(session_id) and is_map(entry) do
    GenServer.call(Jido.GHCopilot.SessionRegistry.Server, {:register, session_id, entry})
  end

  @doc "Fetches a session entry by session id."
  @spec fetch(String.t()) :: {:ok, session_entry()} | {:error, :not_found}
  def fetch(session_id) when is_binary(session_id) do
    case :ets.lookup(@table, session_id) do
      [{^session_id, entry}] -> {:ok, entry}
      [] -> {:error, :not_found}
    end
  end

  @doc "Deletes a session entry by session id."
  @spec delete(String.t()) :: :ok
  def delete(session_id) when is_binary(session_id) do
    GenServer.call(Jido.GHCopilot.SessionRegistry.Server, {:delete, session_id})
  end

  @doc "Clears all active session entries."
  @spec clear() :: :ok
  def clear do
    GenServer.call(Jido.GHCopilot.SessionRegistry.Server, :clear)
  end

  @doc "Lists all active session entries."
  @spec list() :: [{String.t(), session_entry()}]
  def list do
    :ets.tab2list(@table)
  end
end
