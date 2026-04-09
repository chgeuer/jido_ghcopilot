defmodule Jido.GHCopilot.Test.StubConnection do
  @moduledoc """
  A stub ACP Connection that can be used in place of the real
  `Jido.GHCopilot.ACP.Connection` for unit tests.

  Configurable via Application env:

      Application.put_env(:jido_ghcopilot, :stub_conn_events, [
        Fixtures.agent_message_chunk(text: "Hi")
      ])
      Application.put_env(:jido_ghcopilot, :stub_conn_prompt_result, {:ok, :end_turn})

  ## Usage

      {:ok, conn} = StubConnection.start_link()
      {:ok, _init} = StubConnection.initialize(conn)
      :ok = StubConnection.subscribe(conn, "session-1")
      {:ok, :end_turn} = StubConnection.prompt(conn, "session-1", "hello", 5000)
      # caller receives {:connection_event, session_id, %SessionUpdate{...}} for each configured event
  """

  use GenServer

  # ── Public API (mirrors ACP.Connection) ──

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  def initialize(conn, timeout \\ 30_000) do
    GenServer.call(conn, :initialize, timeout)
  end

  def new_session(conn, _cwd, _mcp_servers \\ []) do
    GenServer.call(conn, :new_session)
  end

  def subscribe(conn, session_id) do
    GenServer.call(conn, {:subscribe, session_id, self()})
  end

  def unsubscribe(conn, session_id) do
    GenServer.call(conn, {:unsubscribe, session_id, self()})
  end

  def prompt(conn, session_id, prompt, timeout \\ 60_000) do
    GenServer.call(conn, {:prompt, session_id, prompt}, timeout)
  end

  def cancel(conn, session_id) do
    GenServer.call(conn, {:cancel, session_id})
  end

  def stop(conn) do
    GenServer.stop(conn, :normal)
  end

  def init_result(conn) do
    GenServer.call(conn, :init_result)
  end

  def load_session(conn, session_id, _cwd, _mcp_servers \\ []) do
    GenServer.call(conn, {:load_session, session_id})
  end

  # ── GenServer callbacks ──
  # Handles both direct calls AND BaseConnection protocol calls ({:rpc_call, ...})
  # so StubConnection works whether called via wrapper or via BaseConnection.call_rpc

  @impl true
  def init(_opts) do
    {:ok,
     %{
       subscribers: %{},
       session_counter: 0,
       prompts_received: []
     }}
  end

  # BaseConnection protocol: call_rpc dispatches
  def handle_call({:rpc_call, "initialize", _params, :initialize}, _from, state) do
    result =
      Application.get_env(
        :jido_ghcopilot,
        :stub_conn_init_result,
        {:ok, Jido.GHCopilot.Test.Fixtures.init_result()}
      )

    {:reply, result, state}
  end

  def handle_call({:rpc_call, "session/new", _params, :new_session}, _from, state) do
    session_id =
      Application.get_env(
        :jido_ghcopilot,
        :stub_conn_session_id,
        "stub-session-#{state.session_counter + 1}"
      )

    {:reply, {:ok, session_id}, %{state | session_counter: state.session_counter + 1}}
  end

  def handle_call({:rpc_call, "session/prompt", %{"sessionId" => session_id} = _params, {:prompt, _sid}}, _from, state) do
    prompt_text = "rpc_prompt"
    state = %{state | prompts_received: state.prompts_received ++ [{session_id, prompt_text}]}

    events = Application.get_env(:jido_ghcopilot, :stub_conn_events, [])
    pids = Map.get(state.subscribers, session_id, [])

    Enum.each(events, fn event ->
      Enum.each(pids, fn pid ->
        send(pid, {:connection_event, session_id, event})
      end)
    end)

    result =
      Application.get_env(:jido_ghcopilot, :stub_conn_prompt_result, {:ok, :end_turn})

    {:reply, result, state}
  end

  def handle_call({:rpc_call, "session/load", _params, {:load_session, session_id}}, _from, state) do
    result =
      Application.get_env(
        :jido_ghcopilot,
        :stub_conn_load_session,
        {:ok, session_id}
      )

    {:reply, result, state}
  end

  # Direct calls (backward-compat for tests calling StubConnection directly)
  def handle_call(:initialize, _from, state) do
    result =
      Application.get_env(
        :jido_ghcopilot,
        :stub_conn_init_result,
        {:ok, Jido.GHCopilot.Test.Fixtures.init_result()}
      )

    {:reply, result, state}
  end

  @impl true
  def handle_call(:new_session, _from, state) do
    session_id =
      Application.get_env(
        :jido_ghcopilot,
        :stub_conn_session_id,
        "stub-session-#{state.session_counter + 1}"
      )

    {:reply, {:ok, session_id}, %{state | session_counter: state.session_counter + 1}}
  end

  def handle_call({:subscribe, session_id, pid}, _from, state) do
    subs = Map.update(state.subscribers, session_id, [pid], &[pid | &1])
    {:reply, :ok, %{state | subscribers: subs}}
  end

  def handle_call({:unsubscribe, session_id, pid}, _from, state) do
    subs = Map.update(state.subscribers, session_id, [], &List.delete(&1, pid))
    {:reply, :ok, %{state | subscribers: subs}}
  end

  def handle_call({:prompt, session_id, prompt}, _from, state) do
    state = %{state | prompts_received: state.prompts_received ++ [{session_id, prompt}]}

    # Deliver configured events to subscribers
    events = Application.get_env(:jido_ghcopilot, :stub_conn_events, [])
    pids = Map.get(state.subscribers, session_id, [])

    Enum.each(events, fn event ->
      Enum.each(pids, fn pid ->
        send(pid, {:connection_event, session_id, event})
      end)
    end)

    result =
      Application.get_env(:jido_ghcopilot, :stub_conn_prompt_result, {:ok, :end_turn})

    {:reply, result, state}
  end

  def handle_call({:cancel, _session_id}, _from, state) do
    {:reply, :ok, state}
  end

  def handle_call(:init_result, _from, state) do
    # Legacy — prefer initialize/2
    result =
      Application.get_env(
        :jido_ghcopilot,
        :stub_conn_init_result,
        {:ok, Jido.GHCopilot.Test.Fixtures.init_result()}
      )

    {:reply, result, state}
  end

  def handle_call({:load_session, session_id}, _from, state) do
    result =
      Application.get_env(
        :jido_ghcopilot,
        :stub_conn_load_session,
        {:ok, session_id}
      )

    {:reply, result, state}
  end

  @impl true
  def handle_cast({:rpc_cast, _method, _params}, state) do
    {:noreply, state}
  end
end
