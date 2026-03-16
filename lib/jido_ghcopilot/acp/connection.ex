defmodule Jido.GHCopilot.ACP.Connection do
  @moduledoc """
  GenServer managing a long-lived ACP (Agent Client Protocol) connection
  to the Copilot CLI subprocess.

  Spawns `copilot --acp --stdio` as a Port, sends JSON-RPC requests over stdin,
  and receives NDJSON responses/notifications from stdout.

  Supports multiple concurrent sessions on the same connection. Subscribers
  register for notifications on a specific session ID.

  ## Permission Handling

  The `:permission_handler` option controls how `session/request_permission`
  requests from the CLI agent are handled:

    * `:auto_approve` — automatically approve all requests (default)
    * `:deny` — automatically deny all requests
    * `{:callback, fun}` — call `fun.(request)` which must return `:allow`, `:deny`, or `:cancelled`
  """
  use GenServer
  require Logger

  alias Jido.GHCopilot.ACP.Protocol
  alias Jido.GHCopilot.ACP.Types.Response

  @default_timeout to_timeout(second: 30)

  defstruct [
    :port,
    :port_pid,
    :init_result,
    buffer: "",
    next_id: 1,
    pending_requests: %{},
    subscribers: %{},
    cli_path: nil,
    cli_args: [],
    permission_handler: :auto_approve
  ]

  # ── Public API ──

  @doc "Start a new ACP connection."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  @doc "Get the initialization result (capabilities, agent info)."
  def init_result(conn, timeout \\ @default_timeout) do
    GenServer.call(conn, :init_result, timeout)
  end

  @doc "Create a new session. Returns `{:ok, session_id}` or `{:error, reason}`."
  def new_session(conn, cwd, mcp_servers \\ [], timeout \\ @default_timeout) do
    GenServer.call(conn, {:new_session, cwd, mcp_servers}, timeout)
  end

  @doc """
  Send a prompt to a session. Returns `{:ok, stop_reason}` when the turn completes.

  Session updates are delivered to subscribers as `{:acp_update, session_update}` messages.
  Permission requests are auto-approved with `:allow`.
  """
  def prompt(conn, session_id, prompt, timeout \\ to_timeout(minute: 10)) do
    GenServer.call(conn, {:prompt, session_id, prompt}, timeout)
  end

  @doc "Subscribe the calling process to session updates for `session_id`."
  def subscribe(conn, session_id) do
    GenServer.call(conn, {:subscribe, session_id, self()})
  end

  @doc "Unsubscribe from session updates."
  def unsubscribe(conn, session_id) do
    GenServer.call(conn, {:unsubscribe, session_id, self()})
  end

  @doc "Cancel an ongoing prompt turn."
  def cancel(conn, session_id) do
    GenServer.cast(conn, {:cancel, session_id})
  end

  @doc "Load a previous session. Returns `:ok` when replay is complete."
  def load_session(conn, session_id, cwd, mcp_servers \\ [], timeout \\ @default_timeout) do
    GenServer.call(conn, {:load_session, session_id, cwd, mcp_servers}, timeout)
  end

  @doc "Stop the connection and terminate the subprocess."
  def stop(conn) do
    GenServer.stop(conn, :normal)
  end

  # ── GenServer Callbacks ──

  @impl true
  def init(opts) do
    cli_path = Keyword.get(opts, :cli_path) || Jido.GHCopilot.CLI.resolve_path()

    if is_nil(cli_path) do
      {:stop, :copilot_cli_not_found}
    else
      extra_args = Keyword.get(opts, :cli_args, [])
      args = ["--acp", "--stdio"] ++ extra_args
      permission_handler = Keyword.get(opts, :permission_handler, :auto_approve)

      state = %__MODULE__{
        cli_path: cli_path,
        cli_args: args,
        permission_handler: permission_handler
      }

      {:ok, state, {:continue, :start_connection}}
    end
  end

  @impl true
  def handle_continue(:start_connection, state) do
    port =
      Port.open({:spawn_executable, state.cli_path}, [
        :binary,
        :exit_status,
        :use_stdio,
        {:args, state.cli_args},
        {:line, 1_048_576}
      ])

    port_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        _ -> nil
      end

    state = %{state | port: port, port_pid: port_pid}

    # Send initialize request
    {id, state} = next_id(state)
    request = Protocol.initialize_request(id)
    send_to_port(state, request)

    # Wait synchronously for init response
    receive do
      {^port, {:data, {:eol, line}}} ->
        state = handle_line(line, state)

        case Map.pop(state.pending_requests, id) do
          {nil, _} ->
            # Not yet resolved — store pending
            state = put_in(state.pending_requests[id], {:init, nil, nil})
            {:noreply, state}

          _ ->
            {:noreply, state}
        end
    after
      @default_timeout ->
        Logger.error("ACP initialize timeout")
        {:stop, :init_timeout, state}
    end
  end

  @impl true
  def handle_call(:init_result, _from, state) do
    {:reply, {:ok, state.init_result}, state}
  end

  def handle_call({:new_session, cwd, mcp_servers}, from, state) do
    {id, state} = next_id(state)
    request = Protocol.new_session_request(id, cwd, mcp_servers)
    send_to_port(state, request)
    state = put_in(state.pending_requests[id], {:new_session, from})
    {:noreply, state}
  end

  def handle_call({:prompt, session_id, prompt}, from, state) do
    {id, state} = next_id(state)
    request = Protocol.prompt_request(id, session_id, prompt)
    send_to_port(state, request)
    state = put_in(state.pending_requests[id], {:prompt, from, session_id})
    {:noreply, state}
  end

  def handle_call({:load_session, session_id, cwd, mcp_servers}, from, state) do
    {id, state} = next_id(state)
    request = Protocol.load_session_request(id, session_id, cwd, mcp_servers)
    send_to_port(state, request)
    state = put_in(state.pending_requests[id], {:load_session, from, session_id})
    {:noreply, state}
  end

  def handle_call({:subscribe, session_id, pid}, _from, state) do
    Process.monitor(pid)
    subs = Map.update(state.subscribers, session_id, [pid], &[pid | &1])
    {:reply, :ok, %{state | subscribers: subs}}
  end

  def handle_call({:unsubscribe, session_id, pid}, _from, state) do
    subs =
      Map.update(state.subscribers, session_id, [], fn pids ->
        List.delete(pids, pid)
      end)

    {:reply, :ok, %{state | subscribers: subs}}
  end

  @impl true
  def handle_cast({:cancel, session_id}, state) do
    notification = Protocol.cancel_notification(session_id)
    send_to_port(state, notification)
    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    state = handle_line(line, state)
    {:noreply, state}
  end

  def handle_info({port, {:data, {:noeol, chunk}}}, %{port: port} = state) do
    {:noreply, %{state | buffer: state.buffer <> chunk}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("ACP subprocess exited with status #{status}")

    # Reply to all pending requests with error
    Enum.each(state.pending_requests, fn
      {_id, {:prompt, from, _sid}} -> GenServer.reply(from, {:error, :connection_closed})
      {_id, {:new_session, from}} -> GenServer.reply(from, {:error, :connection_closed})
      {_id, {:load_session, from, _sid}} -> GenServer.reply(from, {:error, :connection_closed})
      _ -> :ok
    end)

    {:stop, {:subprocess_exit, status}, %{state | port: nil, pending_requests: %{}}}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # Remove dead subscriber
    subs =
      Map.new(state.subscribers, fn {sid, pids} ->
        {sid, List.delete(pids, pid)}
      end)

    {:noreply, %{state | subscribers: subs}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{port: port} = _state) when not is_nil(port) do
    Port.close(port)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # ── Internal ──

  defp handle_line(line, state) do
    # Prepend any buffered partial data
    full_line = state.buffer <> line
    state = %{state | buffer: ""}

    case Protocol.parse(full_line) do
      {:response, %Response{id: id} = response} ->
        handle_response(id, response, state)

      {:notification, notification} ->
        handle_notification(notification, state)

      {:request, request} ->
        handle_agent_request(request, state)

      {:error, reason} ->
        Logger.warning("ACP parse error: #{inspect(reason)} for line: #{String.slice(full_line, 0, 200)}")
        state
    end
  end

  defp handle_response(id, response, state) do
    case Map.pop(state.pending_requests, id) do
      {nil, _} ->
        # Init response (first response we receive)
        if is_nil(state.init_result) and response.result do
          init = Protocol.decode_init_result(response.result)

          Logger.info(
            "ACP initialized: #{init.agent_info && init.agent_info.name} v#{init.agent_info && init.agent_info.version}"
          )

          %{state | init_result: init}
        else
          state
        end

      {{:init, _, _}, pending} ->
        init = if response.result, do: Protocol.decode_init_result(response.result)
        %{state | pending_requests: pending, init_result: init}

      {{:new_session, from}, pending} ->
        reply =
          if response.error do
            {:error, response.error}
          else
            session = Protocol.decode_session_result(response.result)
            {:ok, session.session_id}
          end

        GenServer.reply(from, reply)
        %{state | pending_requests: pending}

      {{:prompt, from, _session_id}, pending} ->
        reply =
          if response.error do
            {:error, response.error}
          else
            result = Protocol.decode_prompt_result(response.result)
            {:ok, result.stop_reason}
          end

        GenServer.reply(from, reply)
        %{state | pending_requests: pending}

      {{:load_session, from, _session_id}, pending} ->
        reply = if response.error, do: {:error, response.error}, else: :ok
        GenServer.reply(from, reply)
        %{state | pending_requests: pending}
    end
  end

  defp handle_notification(notification, state) do
    session_id = notification.session_id

    case Map.get(state.subscribers, session_id, []) do
      [] -> :ok
      pids -> Enum.each(pids, &send(&1, {:acp_update, notification}))
    end

    state
  end

  defp handle_agent_request(request, state) do
    if request.method == "session/request_permission" do
      outcome = resolve_permission(state.permission_handler, request)
      Logger.debug("Permission request: #{inspect(request.params)}, outcome: #{outcome}")
      response = Protocol.permission_response(request.id, outcome)
      send_to_port(state, response)
    else
      Logger.warning("Unhandled ACP request: #{request.method}")
    end

    state
  end

  defp resolve_permission(:auto_approve, _request), do: :allow
  defp resolve_permission(:deny, _request), do: :deny

  defp resolve_permission({:callback, fun}, request) when is_function(fun, 1) do
    case fun.(request) do
      outcome when outcome in [:allow, :deny, :cancelled] -> outcome
      _ -> :deny
    end
  end

  defp resolve_permission(_other, _request), do: :deny

  defp send_to_port(%{port: port}, data) when not is_nil(port) do
    Port.command(port, [data, "\n"])
  end

  defp send_to_port(_, _data), do: :ok

  defp next_id(state) do
    {state.next_id, %{state | next_id: state.next_id + 1}}
  end
end
