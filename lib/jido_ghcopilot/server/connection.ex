defmodule Jido.GHCopilot.Server.Connection do
  @moduledoc """
  GenServer managing a long-lived CLI Server protocol connection
  to the Copilot CLI subprocess.

  Spawns `copilot --server --stdio` as a Port, sends JSON-RPC requests over
  stdin, and receives responses/notifications from stdout using LSP-style
  Content-Length framing (the vscode-jsonrpc transport format).

  Unlike the ACP connection (which uses newline-delimited JSON), the CLI Server
  protocol uses `Content-Length: <n>\\r\\n\\r\\n<json>` framing. It delivers raw
  session events via `session.event` notifications — including `assistant.usage`
  with token counts, cost, and quota data.

  ## Permission Handling

  The `:permission_handler` option controls how `permission.request` messages
  from the CLI are handled:

    * `:auto_approve` — automatically approve all requests (default)
    * `:deny` — automatically deny all requests
    * `{:callback, fun}` — call `fun.(info)` which must return `:approved` or `:denied`
  """
  use GenServer
  require Logger

  alias Jido.GHCopilot.Server.Protocol

  @default_timeout to_timeout(second: 30)

  defstruct [
    :port,
    :port_pid,
    :io_socket,
    :io_reader,
    :init_timeout,
    buffer: <<>>,
    next_id: 1,
    pending_requests: %{},
    subscribers: %{},
    cli_path: nil,
    cli_args: [],
    cwd: nil,
    permission_handler: :auto_approve
  ]

  # ── Public API ──

  @doc "Start a new CLI Server connection."
  def start_link(opts \\ []) do
    socket = Keyword.get(opts, :io)

    case GenServer.start_link(__MODULE__, opts, name: opts[:name]) do
      {:ok, pid} = ok ->
        if socket do
          :gen_tcp.controlling_process(socket, pid)
          GenServer.cast(pid, :start_io_reader_and_init)
        end
        ok

      error ->
        error
    end
  end

  @doc "Ping the server. Returns `{:ok, response}` or `{:error, reason}`."
  def ping(conn, timeout \\ @default_timeout) do
    GenServer.call(conn, {:ping, "hello"}, timeout)
  end

  @doc "Create a new session. Returns `{:ok, session_id}` or `{:error, reason}`."
  def create_session(conn, opts \\ %{}, timeout \\ @default_timeout) do
    GenServer.call(conn, {:create_session, opts}, timeout)
  end

  @doc """
  Send a prompt to a session. Returns `{:ok, message_id}` when the message is accepted.

  Session events are delivered to subscribers as `{:server_event, session_event}` messages.
  The session.send response returns immediately after the message is accepted;
  actual completion is signaled by session events (session.idle).
  """
  def send_prompt(conn, session_id, prompt, opts \\ %{}, timeout \\ to_timeout(minute: 10)) do
    GenServer.call(conn, {:send, session_id, prompt, opts}, timeout)
  end

  @doc "Subscribe the calling process to session events for `session_id`."
  def subscribe(conn, session_id) do
    GenServer.call(conn, {:subscribe, session_id, self()})
  end

  @doc "Unsubscribe from session events."
  def unsubscribe(conn, session_id) do
    GenServer.call(conn, {:unsubscribe, session_id, self()})
  end

  @doc "Destroy a session."
  def destroy_session(conn, session_id, timeout \\ @default_timeout) do
    GenServer.call(conn, {:destroy, session_id}, timeout)
  end

  @doc "Resume a previous session."
  def resume_session(conn, session_id, opts \\ %{}, timeout \\ @default_timeout) do
    GenServer.call(conn, {:resume, session_id, opts}, timeout)
  end

  @doc "List all sessions."
  def list_sessions(conn, timeout \\ @default_timeout) do
    GenServer.call(conn, :list_sessions, timeout)
  end

  @doc """
  Change the model on an active session without losing conversation context.

  Uses the wrapper's `session.setModel` RPC which manipulates the session's
  events.jsonl and does a destroy+resume cycle to reload with the new model.
  """
  def set_model(conn, session_id, model, timeout \\ @default_timeout) do
    GenServer.call(conn, {:set_model, session_id, model}, timeout)
  end

  @doc "Respond to a tool.call request from the server."
  def respond_to_tool_call(conn, request_id, result) do
    GenServer.cast(conn, {:tool_call_response, request_id, result})
  end

  @doc "Respond to an external tool call via session.tools.handlePendingToolCall."
  def respond_to_external_tool(conn, session_id, request_id, result) do
    GenServer.call(conn, {:respond_external_tool, session_id, request_id, result}, to_timeout(minute: 5))
  end

  @doc "Stop the connection and terminate the subprocess."
  def stop(conn) do
    GenServer.stop(conn, :normal)
  end

  # ── GenServer Callbacks ──

  @impl true
  def init(opts) do
    case Keyword.get(opts, :io) do
      nil -> init_spawn_local(opts)
      socket -> init_with_io(socket, opts)
    end
  end

  # Connect to an already-running agent via a pre-connected bidirectional
  # byte stream (e.g. a Unix Domain Socket from Firecracker vsock).
  # The caller is responsible for starting the agent process — this just
  # attaches to its stdio via the given socket.
  defp init_with_io(socket, opts) do
    permission_handler = Keyword.get(opts, :permission_handler, :auto_approve)
    init_timeout = Keyword.get(opts, :timeout, to_timeout(minute: 2))

    state = %__MODULE__{
      io_socket: socket,
      permission_handler: permission_handler,
      init_timeout: init_timeout
    }

    # Reader and init ping are deferred to :start_io_reader_and_init cast
    # (sent from start_link after socket ownership is transferred)
    {:ok, state}
  end

  defp ping_with_retry(state, total_timeout, attempt \\ 1) do
    delays = [2_000, 5_000, 10_000, 15_000, 20_000, 30_000]
    delay = Enum.at(delays, min(attempt - 1, length(delays) - 1))

    # Wait before sending ping (let server initialize)
    Process.sleep(delay)

    {id, state} = next_id(state)
    request = Protocol.ping_request(id, "init-#{attempt}")
    send_to_io(state, request)
    state = put_in(state.pending_requests[id], {:ping, nil})

    remaining = max(total_timeout - (delay + 5_000), 5_000)

    case wait_for_init_io(state, min(remaining, 15_000)) do
      {:ok, state} ->
        {:ok, state}

      {:error, :timeout} when remaining > 10_000 ->
        # Drain the failed pending request and retry
        state = %{state | pending_requests: %{}}
        Logger.info("CLI Server ping attempt #{attempt} timed out, retrying...")
        ping_with_retry(state, remaining, attempt + 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Spawn the copilot process locally and connect via Port.
  defp init_spawn_local(opts) do
    use_wrapper = Keyword.get(opts, :use_wrapper, true)

    {executable, args} =
      if use_wrapper do
        wrapper_path = wrapper_script_path()
        node_path = System.find_executable("node")

        if node_path && File.exists?(wrapper_path) do
          extra_args = Keyword.get(opts, :cli_args, [])
          {node_path, [wrapper_path | extra_args]}
        else
          Logger.warning(
            "Copilot wrapper not available (node: #{inspect(node_path)}, wrapper: #{wrapper_path}), falling back to direct CLI"
          )

          cli_path = Keyword.get(opts, :cli_path) || Jido.GHCopilot.CLI.resolve_path()
          extra_args = Keyword.get(opts, :cli_args, [])
          {cli_path, ["--server", "--stdio"] ++ extra_args}
        end
      else
        cli_path = Keyword.get(opts, :cli_path) || Jido.GHCopilot.CLI.resolve_path()
        extra_args = Keyword.get(opts, :cli_args, [])
        {cli_path, ["--server", "--stdio"] ++ extra_args}
      end

    if is_nil(executable) do
      {:stop, :copilot_cli_not_found}
    else
      cwd = Keyword.get(opts, :cwd)
      permission_handler = Keyword.get(opts, :permission_handler, :auto_approve)

      state = %__MODULE__{
        cli_path: executable,
        cli_args: args,
        cwd: cwd,
        permission_handler: permission_handler
      }

      {:ok, state, {:continue, :start_connection}}
    end
  end

  defp wrapper_script_path do
    :jido_ghcopilot
    |> :code.priv_dir()
    |> to_string()
    |> Path.join("copilot_wrapper/index.js")
  end

  @impl true
  def handle_continue(:start_connection, state) do
    port_opts =
      [
        :binary,
        :exit_status,
        :use_stdio,
        {:args, state.cli_args},
        :stream
      ] ++ if(state.cwd, do: [{:cd, state.cwd}], else: [])

    port =
      Port.open({:spawn_executable, state.cli_path}, port_opts)

    port_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        _ -> nil
      end

    state = %{state | port: port, port_pid: port_pid}

    # Send a ping to verify the server is ready
    {id, state} = next_id(state)
    request = Protocol.ping_request(id, "init")
    send_to_port(state, request)
    state = put_in(state.pending_requests[id], {:ping, nil})

    # Wait for ping response (blocking read of LSP frames during init)
    case wait_for_init_response(port, state, @default_timeout) do
      {:ok, state} ->
        Logger.info("CLI Server connection established (PID #{port_pid})")
        {:noreply, state}

      {:error, reason} ->
        Logger.error("CLI Server init failed: #{inspect(reason)}")
        {:stop, :init_timeout, state}
    end
  end

  @impl true
  def handle_cast(:start_io_reader_and_init, %{io_socket: socket} = state) when not is_nil(socket) do
    parent = self()

    reader =
      spawn_link(fn ->
        receive do
          :socket_ready -> io_reader_loop(socket, parent)
        after
          10_000 -> :ok
        end
      end)

    :gen_tcp.controlling_process(socket, reader)
    Kernel.send(reader, :socket_ready)

    Logger.info("CLI Server connection established (external I/O, reader started)")
    {:noreply, %{state | io_reader: reader}}
  end

  def handle_cast(:start_io_reader_and_init, state), do: {:noreply, state}

  @impl true
  def handle_call({:ping, message}, from, state) do
    {id, state} = next_id(state)
    request = Protocol.ping_request(id, message)
    send_to_port(state, request)
    state = put_in(state.pending_requests[id], {:ping, from})
    {:noreply, state}
  end

  def handle_call({:create_session, opts}, from, state) do
    {id, state} = next_id(state)
    opts = Map.put_new(opts, :request_permission, true)
    request = Protocol.create_session_request(id, opts)
    send_to_port(state, request)
    state = put_in(state.pending_requests[id], {:create_session, from})
    {:noreply, state}
  end

  def handle_call({:send, session_id, prompt, opts}, from, state) do
    {id, state} = next_id(state)
    request = Protocol.send_request(id, session_id, prompt, opts)
    send_to_port(state, request)
    state = put_in(state.pending_requests[id], {:send, from, session_id})
    {:noreply, state}
  end

  def handle_call({:destroy, session_id}, from, state) do
    {id, state} = next_id(state)
    request = Protocol.destroy_session_request(id, session_id)
    send_to_port(state, request)
    state = put_in(state.pending_requests[id], {:destroy, from})
    {:noreply, state}
  end

  def handle_call({:resume, session_id, opts}, from, state) do
    {id, state} = next_id(state)
    opts = Map.put_new(opts, :request_permission, true)
    request = Protocol.resume_session_request(id, session_id, opts)
    send_to_port(state, request)
    state = put_in(state.pending_requests[id], {:resume, from, session_id})
    {:noreply, state}
  end

  def handle_call(:list_sessions, from, state) do
    {id, state} = next_id(state)
    request = Protocol.list_sessions_request(id)
    send_to_port(state, request)
    state = put_in(state.pending_requests[id], {:list_sessions, from})
    {:noreply, state}
  end

  def handle_call({:set_model, session_id, model}, from, state) do
    {id, state} = next_id(state)
    request = Protocol.set_model_request(id, session_id, model)
    send_to_port(state, request)
    state = put_in(state.pending_requests[id], {:set_model, from})
    {:noreply, state}
  end

  def handle_call({:respond_external_tool, session_id, request_id, result}, from, state) do
    {id, state} = next_id(state)

    request =
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: id,
        method: "session.tools.handlePendingToolCall",
        params: %{sessionId: session_id, requestId: request_id, result: result}
      })

    send_to_port(state, request)
    state = put_in(state.pending_requests[id], {:respond_external_tool, from})
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
  def handle_cast({:tool_call_response, request_id, result}, state) do
    response = Protocol.encode_response(request_id, result)
    send_to_port(state, response)
    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    state = %{state | buffer: state.buffer <> data}
    state = process_lsp_buffer(state)
    {:noreply, state}
  end

  # Data from external I/O socket (reader process forwards it)
  def handle_info({:io_data, data}, %{io_socket: sock} = state) when not is_nil(sock) do
    state = %{state | buffer: state.buffer <> data}
    state = process_lsp_buffer(state)
    {:noreply, state}
  end

  def handle_info(:io_closed, %{io_socket: _} = state) do
    Logger.warning("CLI Server I/O connection closed")
    fail_pending_requests(state)
    {:stop, :normal, %{state | io_socket: nil, pending_requests: %{}}}
  end

  def handle_info({:io_error, reason}, %{io_socket: _} = state) do
    Logger.error("CLI Server I/O error: #{inspect(reason)}")
    fail_pending_requests(state)
    {:stop, {:io_error, reason}, %{state | pending_requests: %{}}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("CLI Server subprocess exited with status #{status}")
    fail_pending_requests(state)
    {:stop, {:subprocess_exit, status}, %{state | port: nil, pending_requests: %{}}}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
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

  def terminate(_reason, %{io_socket: sock, io_reader: reader}) when not is_nil(sock) do
    if reader && Process.alive?(reader), do: Process.exit(reader, :kill)
    :gen_tcp.close(sock)
  catch
    _, _ -> :ok
  end

  def terminate(_reason, _state), do: :ok

  # ── LSP Content-Length Framing ──

  # Parse LSP frames from the buffer: "Content-Length: <n>\r\n\r\n<json>"
  defp process_lsp_buffer(state) do
    case extract_lsp_message(state.buffer) do
      {:ok, json, rest} ->
        state = %{state | buffer: rest}
        state = handle_json_message(json, state)
        # Recurse to handle multiple messages in one chunk
        process_lsp_buffer(state)

      :incomplete ->
        state
    end
  end

  # Extract a single LSP message from the buffer.
  # Format: "Content-Length: <n>\r\n\r\n<json-body>"
  # Also handles optional additional headers (e.g. Content-Type).
  defp extract_lsp_message(buffer) do
    case :binary.match(buffer, "\r\n\r\n") do
      {header_end, 4} ->
        headers = :binary.part(buffer, 0, header_end)

        case parse_content_length(headers) do
          {:ok, content_length} ->
            body_start = header_end + 4
            total_needed = body_start + content_length

            if byte_size(buffer) >= total_needed do
              json = :binary.part(buffer, body_start, content_length)
              rest = :binary.part(buffer, total_needed, byte_size(buffer) - total_needed)
              {:ok, json, rest}
            else
              :incomplete
            end

          :error ->
            :incomplete
        end

      :nomatch ->
        :incomplete
    end
  end

  defp parse_content_length(headers) do
    headers
    |> String.split("\r\n")
    |> Enum.find_value(:error, fn line ->
      case String.split(line, ":", parts: 2) do
        ["Content-Length", value] ->
          case Integer.parse(String.trim(value)) do
            {n, _} -> {:ok, n}
            :error -> nil
          end

        _ ->
          nil
      end
    end)
  end

  # Encode a JSON-RPC message with LSP Content-Length framing
  defp encode_lsp_message(json) when is_binary(json) do
    "Content-Length: #{byte_size(json)}\r\n\r\n#{json}"
  end

  # ── Init Helpers ──

  # Blocking wait for the init ping response during handle_continue
  defp wait_for_init_response(port, state, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_init(port, state, deadline)
  end

  defp do_wait_for_init(port, state, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :timeout}
    else
      receive do
        {^port, {:data, data}} ->
          state = %{state | buffer: state.buffer <> data}

          case extract_lsp_message(state.buffer) do
            {:ok, json, rest} ->
              state = %{state | buffer: rest}
              state = handle_json_message(json, state)

              # Check if ping was resolved (pending_requests no longer has our init ping)
              if map_size(state.pending_requests) == 0 do
                {:ok, state}
              else
                do_wait_for_init(port, state, deadline)
              end

            :incomplete ->
              do_wait_for_init(port, state, deadline)
          end

        {^port, {:exit_status, status}} ->
          {:error, {:subprocess_exit, status}}
      after
        min(remaining, 1000) ->
          do_wait_for_init(port, state, deadline)
      end
    end
  end

  # ── Message Processing ──

  defp handle_json_message(json, state) do
    case Protocol.parse(json) do
      {:response, response} ->
        handle_response(response, state)

      {:request, request} ->
        handle_server_request(request, state)

      {:notification, %Jido.GHCopilot.Server.Types.SessionEvent{} = event} ->
        handle_session_event(event, state)

      {:notification, _other} ->
        state

      {:error, reason} ->
        Logger.warning("CLI Server parse error: #{inspect(reason)} for data: #{String.slice(json, 0, 200)}")

        state
    end
  end

  defp handle_response(%{id: id} = response, state) do
    case Map.pop(state.pending_requests, id) do
      {nil, _} ->
        Logger.warning("Received response for unknown request #{id}")
        state

      {{:ping, nil}, pending} ->
        # Init ping — no caller to reply to
        %{state | pending_requests: pending}

      {{:ping, from}, pending} ->
        reply = if response.error, do: {:error, response.error}, else: {:ok, response.result}
        GenServer.reply(from, reply)
        %{state | pending_requests: pending}

      {{:create_session, from}, pending} ->
        reply =
          if response.error do
            {:error, response.error}
          else
            result = Protocol.decode_create_result(response.result)
            {:ok, result.session_id}
          end

        GenServer.reply(from, reply)
        %{state | pending_requests: pending}

      {{:send, from, _session_id}, pending} ->
        reply =
          if response.error do
            {:error, response.error}
          else
            result = Protocol.decode_send_result(response.result)
            {:ok, result.message_id}
          end

        GenServer.reply(from, reply)
        %{state | pending_requests: pending}

      {{:destroy, from}, pending} ->
        reply = if response.error, do: {:error, response.error}, else: :ok
        GenServer.reply(from, reply)
        %{state | pending_requests: pending}

      {{:resume, from, _session_id}, pending} ->
        reply =
          if response.error do
            {:error, response.error}
          else
            {:ok, response.result["sessionId"]}
          end

        GenServer.reply(from, reply)
        %{state | pending_requests: pending}

      {{:list_sessions, from}, pending} ->
        reply =
          if response.error do
            {:error, response.error}
          else
            {:ok, Protocol.decode_list_result(response.result)}
          end

        GenServer.reply(from, reply)
        %{state | pending_requests: pending}

      {{:set_model, from}, pending} ->
        reply =
          if response.error do
            {:error, response.error}
          else
            {:ok, response.result}
          end

        GenServer.reply(from, reply)
        %{state | pending_requests: pending}

      {{:permission_resolve, _from}, pending} ->
        if response.error do
          Logger.warning("Permission resolve failed: #{inspect(response.error)}")
        end

        %{state | pending_requests: pending}

      {{:respond_external_tool, from}, pending} ->
        reply = if response.error, do: {:error, response.error}, else: :ok
        GenServer.reply(from, reply)
        %{state | pending_requests: pending}
    end
  end

  defp handle_session_event(%{type: "permission.requested", data: data} = event, state) do
    request_id = data["requestId"]
    kind = get_in(data, ["permissionRequest", "kind"]) || "unknown"
    session_id = event.session_id

    outcome = resolve_permission(state.permission_handler, %{kind: kind, session_id: session_id, data: data})
    Logger.debug("Permission event: #{kind} for session #{session_id}, requestId: #{request_id}, outcome: #{outcome}")

    state =
      if request_id && outcome == :approved do
        {id, state} = next_id(state)

        request =
          Jason.encode!(%{
            jsonrpc: "2.0",
            id: id,
            method: "session.permissions.handlePendingPermissionRequest",
            params: %{sessionId: session_id, requestId: request_id, result: %{kind: "approved"}}
          })

        send_to_port(state, request)
        put_in(state.pending_requests[id], {:permission_resolve, nil})
      else
        state
      end

    # Forward to subscribers so the UI can show the event
    case Map.get(state.subscribers, session_id, []) do
      [] -> :ok
      pids -> Enum.each(pids, &send(&1, {:server_event, event}))
    end

    state
  end

  defp handle_session_event(event, state) do
    session_id = event.session_id

    case Map.get(state.subscribers, session_id, []) do
      [] -> :ok
      pids -> Enum.each(pids, &send(&1, {:server_event, event}))
    end

    state
  end

  defp handle_server_request(%{id: id, method: "tool.call", params: params}, state) do
    session_id = params["sessionId"]
    Logger.info("Received tool.call request: tool=#{params["toolName"]} session=#{session_id}")

    case Map.get(state.subscribers, session_id, []) do
      [] ->
        Logger.warning("tool.call for session #{session_id} but no subscribers")
        # Respond with error so copilot doesn't hang
        response = Protocol.encode_response(id, %{"error" => "No handler registered"})
        send_to_port(state, response)

      pids ->
        tool_call = %{
          request_id: id,
          session_id: session_id,
          tool_call_id: params["toolCallId"],
          tool_name: params["toolName"],
          arguments: params["arguments"]
        }

        Enum.each(pids, &send(&1, {:server_tool_call, tool_call}))
    end

    state
  end

  # Handle permission requests from the CLI (v0.0.421+).
  # The CLI sends these when requestPermission: true is set on session.create/resume.
  # Response must nest the outcome inside a "result" key because the CLI's
  # dispatchPermissionRequest does `(await sendRequest(...)).result`.
  defp handle_server_request(%{id: id, method: "permission.request", params: params}, state) do
    kind = get_in(params, ["permissionRequest", "kind"]) || "unknown"
    session_id = params["sessionId"]

    outcome = resolve_permission(state.permission_handler, %{kind: kind, session_id: session_id, data: params})
    Logger.debug("Permission request: #{kind} for session #{session_id}, outcome: #{outcome}")

    if outcome == :approved do
      response = Protocol.encode_response(id, %{"result" => %{"kind" => "approved"}})
      send_to_port(state, response)
    else
      response = Protocol.encode_response(id, %{"result" => %{"kind" => "denied"}})
      send_to_port(state, response)
    end

    state
  end

  defp handle_server_request(%{id: id, method: method}, state) do
    Logger.warning("Unhandled server request: #{method}")
    response = Protocol.encode_response(id, %{})
    send_to_port(state, response)
    state
  end

  defp send_to_port(%{port: port}, json) when not is_nil(port) do
    Port.command(port, encode_lsp_message(json))
  end

  defp send_to_port(%{io_socket: sock}, json) when not is_nil(sock) do
    :gen_tcp.send(sock, encode_lsp_message(json))
  end

  defp send_to_port(_, _data), do: :ok

  # Alias for clearer semantics when called from init_with_io
  defp send_to_io(state, json), do: send_to_port(state, json)

  defp next_id(state) do
    {state.next_id, %{state | next_id: state.next_id + 1}}
  end

  defp resolve_permission(:auto_approve, _info), do: :approved
  defp resolve_permission(:deny, _info), do: :denied

  defp resolve_permission({:callback, fun}, info) when is_function(fun, 1) do
    case fun.(info) do
      outcome when outcome in [:approved, :denied] -> outcome
      _ -> :denied
    end
  end

  defp resolve_permission(_other, _info), do: :denied

  # ── External I/O helpers ──

  defp io_reader_loop(socket, parent) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} ->
        send(parent, {:io_data, data})
        io_reader_loop(socket, parent)

      {:error, :timeout} ->
        io_reader_loop(socket, parent)

      {:error, :closed} ->
        send(parent, :io_closed)

      {:error, reason} ->
        send(parent, {:io_error, reason})
    end
  end

  defp wait_for_init_io(state, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    do_wait_for_init_io(state, deadline)
  end

  defp do_wait_for_init_io(state, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :timeout}
    else
      receive do
        {:io_data, data} ->
          state = %{state | buffer: state.buffer <> data}

          case extract_lsp_message(state.buffer) do
            {:ok, json, rest} ->
              state = %{state | buffer: rest}
              state = handle_json_message(json, state)

              if map_size(state.pending_requests) == 0 do
                {:ok, state}
              else
                do_wait_for_init_io(state, deadline)
              end

            :incomplete ->
              do_wait_for_init_io(state, deadline)
          end

        :io_closed ->
          {:error, :connection_closed}

        {:io_error, reason} ->
          {:error, reason}
      after
        min(remaining, 1000) ->
          do_wait_for_init_io(state, deadline)
      end
    end
  end

  defp fail_pending_requests(state) do
    Enum.each(state.pending_requests, fn
      {_id, {:send, from, _sid}} -> GenServer.reply(from, {:error, :connection_closed})
      {_id, {:create_session, from}} -> GenServer.reply(from, {:error, :connection_closed})
      {_id, {:destroy, from}} -> GenServer.reply(from, {:error, :connection_closed})
      {_id, {:resume, from, _sid}} -> GenServer.reply(from, {:error, :connection_closed})
      {_id, {:list_sessions, from}} -> GenServer.reply(from, {:error, :connection_closed})
      {_id, {:set_model, from}} -> GenServer.reply(from, {:error, :connection_closed})
      {_id, {:ping, from}} when not is_nil(from) -> GenServer.reply(from, {:error, :connection_closed})
      _ -> :ok
    end)
  end
end
