defmodule Jido.GHCopilot.Adapter do
  @moduledoc """
  `Jido.Harness.Adapter` implementation for GitHub Copilot CLI.

  Executes prompts via the `copilot` CLI in non-interactive mode (`-p`)
  and streams output lines as normalized `Jido.Harness.Event` structs.
  """

  @behaviour Jido.Harness.Adapter

  alias Jido.GHCopilot.{Error, Mapper, Options, SessionRegistry}
  alias Jido.Harness.Capabilities
  alias Jido.Harness.Event
  alias Jido.Harness.RunRequest
  alias Jido.Harness.RuntimeContract

  @impl true
  @spec id() :: atom()
  def id, do: :ghcopilot

  @impl true
  @spec capabilities() :: map()
  def capabilities do
    %Capabilities{
      streaming?: true,
      tool_calls?: true,
      tool_results?: true,
      thinking?: true,
      resume?: true,
      usage?: true,
      file_changes?: true,
      cancellation?: true
    }
  end

  @impl true
  @spec runtime_contract() :: RuntimeContract.t()
  def runtime_contract do
    RuntimeContract.new!(%{
      provider: :ghcopilot,
      host_env_required_any: ["GH_TOKEN", "GITHUB_TOKEN"],
      host_env_required_all: [],
      sprite_env_forward: ["GH_TOKEN", "GITHUB_TOKEN"],
      sprite_env_injected: %{},
      runtime_tools_required: ["copilot"],
      compatibility_probes: [],
      install_steps: [],
      auth_bootstrap_steps: [],
      triage_command_template: "copilot -p \"{{prompt}}\"",
      coding_command_template: "copilot -p \"{{prompt}}\"",
      success_markers: []
    })
  end

  @impl true
  @spec run(RunRequest.t(), keyword()) :: {:ok, Enumerable.t()} | {:error, term()}
  def run(%RunRequest{} = request, opts \\ []) when is_list(opts) do
    transport = Keyword.get(opts, :transport, {Jido.GHCopilot.Transport.Local, []})

    with {:ok, normalized} <- Options.from_run_request(request, opts),
         :ok <- compatibility_module().check() do
      {:ok, build_transport_stream(normalized, transport)}
    end
  rescue
    e in [ArgumentError] ->
      {:error, Error.validation_error("Invalid run request", %{details: Exception.message(e)})}
  end

  @impl true
  @spec cancel(String.t()) :: :ok | {:error, term()}
  def cancel(session_id) when is_binary(session_id) and session_id != "" do
    with {:ok, entry} <- SessionRegistry.fetch(session_id) do
      # Prefer closing the Erlang Port owned by the adapter worker when possible
      case entry do
        %{port: port} when is_port(port) ->
          try do
            Port.close(port)
          catch
            _, _ -> :ok
          end

        _ ->
          :ok
      end

      SessionRegistry.delete(session_id)
      :ok
    else
      {:error, :not_found} ->
        {:error,
         Error.execution_error("No active GitHub Copilot session found for cancellation", %{session_id: session_id})}
    end
  end

  def cancel(other) do
    {:error, Error.validation_error("session_id must be a non-empty string", %{value: other})}
  end

  defp build_event_stream(%Options{} = options) do
    session_id = "ghcopilot-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    args = build_cli_args(options)
    cli_path = cli_module().resolve_path()
    mapper = mapper_module()
    timeout_ms = options.timeout_ms || to_timeout(minute: 10)

    Stream.resource(
      fn -> start_process(cli_path, args, options, session_id, timeout_ms) end,
      fn state -> receive_output(state, session_id, mapper) end,
      fn state -> cleanup(state, session_id) end
    )
  end

  # Build an event stream using the CLI Server protocol over a pluggable transport.
  # Follows the same pattern as CopilotServerBridge in ex_paperclip and
  # SessionServer in copilot_lv: Connection → subscribe → send_prompt → event loop.
  #
  # Server events are emitted as Harness Events with the raw copilot format
  # (type: "assistant.message", "tool.execution_start", etc.) so that
  # HarnessEventNormalizer can process them uniformly.
  defp build_transport_stream(%Options{} = options, {transport_module, transport_opts}) do
    alias Jido.GHCopilot.Server.Connection

    session_id = "ghcopilot-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

    transport_opts = Keyword.put_new(transport_opts, :cwd, options.cwd)
    {:ok, handle} = transport_module.start(transport_opts)
    conn_opts = transport_module.connection_opts(handle, permission_handler: :auto_approve)

    tools = Keyword.get(transport_opts, :tools, [])
    prompt = options.prompt || ""
    timeout_ms = options.timeout_ms || to_timeout(minute: 10)

    Stream.resource(
      fn ->
        {:ok, conn} = Connection.start_link(conn_opts)
        Process.monitor(conn)

        session_opts = %{model: options.model, tools: tools, request_permission: true}
        {:ok, sid} = Connection.create_session(conn, session_opts)
        :ok = Connection.subscribe(conn, sid)
        {:ok, _msg_id} = Connection.send_prompt(conn, sid, prompt)

        started = Event.new!(%{
          type: :session_started,
          provider: :ghcopilot,
          session_id: session_id,
          timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
          payload: %{"session_id" => session_id, "server_session_id" => sid},
          raw: nil
        })

        %{conn: conn, session_id: session_id, server_session_id: sid,
          pending: [started], done: false}
      end,
      fn
        %{done: true} = state ->
          {:halt, state}

        %{pending: [e | rest]} = state ->
          {[e], %{state | pending: rest}}

        state ->
          receive do
            {:connection_event, _sid, %{type: "session.idle"}} ->
              {:halt, state}

            {:connection_event, _sid, %{type: type, data: data}} ->
              event = server_event_to_harness(type, data, state.session_id)
              {List.wrap(event), state}

            {:connection_event, _sid, %{type: type}} ->
              event = server_event_to_harness(type, %{}, state.session_id)
              {List.wrap(event), state}

            {:DOWN, _, :process, pid, _} when pid == state.conn ->
              {:halt, %{state | done: true}}
          after
            timeout_ms ->
              {:halt, %{state | done: true}}
          end
      end,
      fn state ->
        if state[:conn] && Process.alive?(state.conn) do
          Connection.stop(state.conn)
        end
      end
    )
  end

  # Map Copilot Server events directly to Harness Events, preserving the
  # copilot event format that HarnessEventNormalizer already understands.
  defp server_event_to_harness(type, data, session_id) do
    ts = DateTime.utc_now() |> DateTime.to_iso8601()

    harness_type =
      case type do
        "assistant.message" -> :output_text_delta
        "assistant.usage" -> :usage
        "assistant.reasoning" -> :thinking_delta
        "assistant.turn_start" -> :turn_start
        "assistant.turn_end" -> :turn_end
        "tool.execution_start" -> :tool_use_start
        "tool.execution_complete" -> :tool_use_end
        "session.error" -> :session_failed
        "session.start" -> :session_started
        _ -> :ghcopilot_event
      end

    Event.new!(%{
      type: harness_type,
      provider: :ghcopilot,
      session_id: session_id,
      timestamp: ts,
      payload: data || %{},
      raw: %{"type" => type, "data" => data}
    })
  end

  defp start_process(cli_path, args, options, session_id, timeout_ms) do
    env =
      options.env
      |> Enum.map(fn {k, v} -> {to_charlist(k), to_charlist(v)} end)

    port =
      Port.open({:spawn_executable, cli_path}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        {:args, args},
        {:env, env},
        {:cd, to_charlist(options.cwd || File.cwd!())}
      ])

    try do
      port_info = Port.info(port)
      port_pid = if port_info, do: Keyword.get(port_info, :os_pid)

      SessionRegistry.register(session_id, %{port: port, port_pid: port_pid})

      started_event =
        Event.new!(%{
          type: :session_started,
          provider: :ghcopilot,
          session_id: session_id,
          timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
          payload: %{"session_id" => session_id, "cwd" => options.cwd},
          raw: nil
        })

      %{port: port, buffer: "", emitted_start: true, pending: [started_event], timeout_ms: timeout_ms}
    rescue
      e ->
        Port.close(port)
        reraise e, __STACKTRACE__
    end
  end

  defp receive_output(%{pending: [event | rest]} = state, _session_id, _mapper) do
    {[event], %{state | pending: rest}}
  end

  defp receive_output(%{port: nil}, _session_id, _mapper) do
    {:halt, nil}
  end

  defp receive_output(%{port: port, buffer: buffer, timeout_ms: timeout_ms} = state, session_id, mapper) do
    receive do
      {^port, {:data, data}} ->
        new_buffer = buffer <> data
        {lines, remaining} = extract_lines(new_buffer)

        events =
          lines
          |> Enum.flat_map(fn line ->
            case mapper.map_line(line, session_id) do
              {:ok, mapped_events} -> mapped_events
              {:error, _reason} -> []
            end
          end)

        {events, %{state | buffer: remaining}}

      {^port, {:exit_status, 0}} ->
        final_events = flush_buffer(state.buffer, session_id, mapper)

        completed_event =
          Event.new!(%{
            type: :session_completed,
            provider: :ghcopilot,
            session_id: session_id,
            timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
            payload: %{"session_id" => session_id, "status" => "completed"},
            raw: nil
          })

        {final_events ++ [completed_event], %{state | buffer: "", port: nil}}

      {^port, {:exit_status, status}} ->
        final_events = flush_buffer(state.buffer, session_id, mapper)

        failed_event =
          Event.new!(%{
            type: :session_failed,
            provider: :ghcopilot,
            session_id: session_id,
            timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
            payload: %{"error" => "Process exited with status #{status}"},
            raw: %{exit_status: status}
          })

        {final_events ++ [failed_event], %{state | buffer: "", port: nil}}
    after
      timeout_ms ->
        timeout_event =
          Event.new!(%{
            type: :session_failed,
            provider: :ghcopilot,
            session_id: session_id,
            timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
            payload: %{"error" => "Timeout waiting for output after #{timeout_ms}ms"},
            raw: nil
          })

        {[timeout_event], %{state | port: nil}}
    end
  end

  defp extract_lines(data) do
    case String.split(data, "\n", parts: :infinity) do
      [] -> {[], ""}
      parts -> {Enum.slice(parts, 0..-2//1), List.last(parts)}
    end
  end

  defp flush_buffer("", _session_id, _mapper), do: []

  defp flush_buffer(buffer, session_id, mapper) do
    trimmed = String.trim(buffer)

    if trimmed == "" do
      []
    else
      case mapper.map_line(trimmed, session_id) do
        {:ok, events} -> events
        {:error, _} -> []
      end
    end
  end

  defp cleanup(nil, _session_id), do: :ok

  defp cleanup(%{port: nil}, session_id) do
    SessionRegistry.delete(session_id)
  end

  defp cleanup(%{port: port}, session_id) do
    try do
      Port.close(port)
    catch
      _, _ -> :ok
    end

    SessionRegistry.delete(session_id)
  end

  defp build_cli_args(%Options{} = options) do
    args = ["-p", options.prompt, "--no-color"]
    args = if options.autopilot, do: args ++ ["--allow-all-tools"], else: args

    args = if options.silent, do: args ++ ["-s"], else: args
    args = if options.model, do: args ++ ["--model", options.model], else: args
    args = if options.continue, do: args ++ ["--continue"], else: args
    args = if options.autopilot, do: args ++ ["--autopilot"], else: args

    args =
      if options.max_autopilot_continues,
        do: args ++ ["--max-autopilot-continues", to_string(options.max_autopilot_continues)],
        else: args

    args =
      case options.share do
        nil -> args
        path when is_binary(path) -> args ++ ["--share", path]
      end

    args =
      case options.resume do
        nil -> args
        true -> args ++ ["--resume"]
        session_id when is_binary(session_id) -> args ++ ["--resume", session_id]
        _ -> args
      end

    args =
      Enum.reduce(options.add_dirs, args, fn dir, acc ->
        acc ++ ["--add-dir", dir]
      end)

    args
  end

  defp mapper_module do
    Application.get_env(:jido_ghcopilot, :mapper_module, Mapper)
  end

  defp compatibility_module do
    Application.get_env(:jido_ghcopilot, :compatibility_module, Jido.GHCopilot.Compatibility)
  end

  defp cli_module do
    Application.get_env(:jido_ghcopilot, :cli_module, Jido.GHCopilot.CLI)
  end
end
