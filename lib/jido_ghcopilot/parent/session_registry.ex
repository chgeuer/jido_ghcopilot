defmodule Jido.GHCopilot.Parent.SessionRegistry do
  @moduledoc """
  Pure functions for managing multiple GHCopilot sessions from a parent agent.

  Stores session metadata in the parent agent's state under a `:sessions` key.
  Each session is tracked by its session_id with status, turns, result, etc.
  """

  @doc "Initialize empty sessions map."
  def init_sessions, do: %{}

  @doc "Register a new session."
  def register_session(sessions, session_id, meta \\ %{}) do
    entry = %{
      session_id: session_id,
      status: :starting,
      prompt: meta[:prompt],
      model: meta[:model],
      child_pid: nil,
      turns: 0,
      result: nil,
      error: nil,
      thinking: [],
      started_at: System.monotonic_time(:millisecond),
      last_activity: System.monotonic_time(:millisecond),
      completed_at: nil
    }

    Map.put(sessions, session_id, entry)
  end

  @doc "Update a session's fields."
  def update_session(sessions, session_id, updates) when is_map(updates) do
    Map.update(sessions, session_id, nil, fn entry ->
      if entry do
        updates = Map.put(updates, :last_activity, System.monotonic_time(:millisecond))

        updates =
          if updates[:status] in [:success, :failure, :cancelled] do
            Map.put(updates, :completed_at, System.monotonic_time(:millisecond))
          else
            updates
          end

        Map.merge(entry, updates)
      end
    end)
  end

  @doc "Get a session entry."
  def get_session(sessions, session_id), do: Map.get(sessions, session_id)

  @doc "List active (non-terminal) sessions."
  def active_sessions(sessions) do
    sessions
    |> Map.values()
    |> Enum.filter(&(&1.status in [:starting, :running]))
  end

  @doc "List completed sessions."
  def completed_sessions(sessions) do
    sessions
    |> Map.values()
    |> Enum.filter(&(&1.status in [:success, :failure, :cancelled]))
  end

  @doc "Count sessions by status."
  def count_by_status(sessions) do
    sessions
    |> Map.values()
    |> Enum.group_by(& &1.status)
    |> Map.new(fn {status, entries} -> {status, length(entries)} end)
  end

  @doc "Find sessions by metadata field."
  def find_by_meta(sessions, key, value) do
    sessions
    |> Map.values()
    |> Enum.filter(&(Map.get(&1, key) == value))
  end
end
