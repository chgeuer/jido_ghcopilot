defmodule Jido.GHCopilot.SessionRegistry.Server do
  @moduledoc false
  use GenServer

  @table Jido.GHCopilot.SessionRegistry

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(state) do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
        :ok

      _ ->
        :ok
    end

    {:ok, state}
  rescue
    ArgumentError ->
      {:ok, state}
  end

  @impl true
  def handle_call({:register, session_id, entry}, _from, state) do
    :ets.insert(@table, {session_id, entry})

    if Code.ensure_loaded?(:telemetry) and function_exported?(:telemetry, :execute, 3) do
      :telemetry.execute([:jido, :ghcopilot, :session, :registered], %{}, %{session_id: session_id})
    end

    {:reply, :ok, state}
  end

  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:delete, session_id}, _from, state) do
    :ets.delete(@table, session_id)
    {:reply, :ok, state}
  end
end
