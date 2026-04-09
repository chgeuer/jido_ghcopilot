defmodule Jido.GHCopilot.Server.Connection do
  @moduledoc """
  CLI Server connection wrapper using the shared `Jido.Harness.Connection` base.

  Uses LSP Content-Length framing and provides the full Server protocol API:
  ping, session CRUD, prompt, model switching, tool call responses, etc.

  ## Message Format

  Subscribers receive:
  - `{:connection_event, session_id, %SessionEvent{}}` — session events
  - `{:connection_event, session_id, {:tool_call, tool_call}}` — tool call requests
  """

  alias Jido.Harness.Connection, as: BaseConnection
  alias Jido.GHCopilot.Server.ConnectionProtocol

  @default_timeout to_timeout(second: 30)
  @ping_delays [2_000, 5_000, 10_000, 15_000, 20_000, 30_000]

  @doc """
  Start a new CLI Server connection with ping-with-retry initialization.

  Returns `{:ok, pid}` when the server responds to a ping, or `{:error, reason}`.
  """
  def start_link(opts \\ []) do
    conn_opts =
      opts
      |> Keyword.put(:protocol, ConnectionProtocol)
      |> Keyword.put_new(:permission_handler, :auto_approve)

    with {:ok, conn} <- BaseConnection.start_link(conn_opts) do
      total_timeout = Keyword.get(opts, :timeout, to_timeout(minute: 2))

      case ping_with_retry(conn, total_timeout) do
        :ok -> {:ok, conn}
        {:error, reason} ->
          BaseConnection.stop(conn)
          {:error, reason}
      end
    end
  end

  @doc "Ping the server. Returns `{:ok, response}` or `{:error, reason}`."
  def ping(conn, timeout \\ @default_timeout) do
    BaseConnection.call_rpc(conn, "ping", %{"message" => "hello"}, :ping, timeout)
  end

  @doc "Create a new session. Returns `{:ok, session_id}` or `{:error, reason}`."
  def create_session(conn, opts \\ %{}, timeout \\ @default_timeout) do
    opts = Map.put_new(opts, :request_permission, true)

    params =
      %{}
      |> maybe_put("model", opts[:model])
      |> maybe_put("sessionId", opts[:session_id])
      |> maybe_put("systemMessage", opts[:system_message])
      |> maybe_put("availableTools", opts[:available_tools])
      |> maybe_put("excludedTools", opts[:excluded_tools])
      |> maybe_put("tools", opts[:tools])
      |> maybe_put("requestPermission", opts[:request_permission])

    BaseConnection.call_rpc(conn, "session.create", params, :create_session, timeout)
  end

  @doc """
  Send a prompt to a session. Returns `{:ok, message_id}` when accepted.

  Session events are delivered to subscribers as `{:connection_event, session_id, event}`.
  """
  def send_prompt(conn, session_id, prompt, opts \\ %{}, timeout \\ to_timeout(minute: 10)) do
    params =
      %{"sessionId" => session_id, "prompt" => prompt}
      |> maybe_put("attachments", opts[:attachments])
      |> maybe_put("mode", opts[:mode])

    BaseConnection.call_rpc(conn, "session.send", params, {:send, session_id}, timeout)
  end

  @doc "Subscribe the calling process to session events."
  def subscribe(conn, session_id), do: BaseConnection.subscribe(conn, session_id)

  @doc "Unsubscribe from session events."
  def unsubscribe(conn, session_id), do: BaseConnection.unsubscribe(conn, session_id)

  @doc "Destroy a session."
  def destroy_session(conn, session_id, timeout \\ @default_timeout) do
    BaseConnection.call_rpc(
      conn,
      "session.destroy",
      %{"sessionId" => session_id},
      :destroy,
      timeout
    )
  end

  @doc "Resume a previous session."
  def resume_session(conn, session_id, opts \\ %{}, timeout \\ @default_timeout) do
    opts = Map.put_new(opts, :request_permission, true)

    params =
      %{"sessionId" => session_id}
      |> maybe_put("tools", opts[:tools])
      |> maybe_put("requestPermission", opts[:request_permission])

    BaseConnection.call_rpc(conn, "session.resume", params, {:resume, session_id}, timeout)
  end

  @doc "List all sessions."
  def list_sessions(conn, timeout \\ @default_timeout) do
    BaseConnection.call_rpc(conn, "session.list", %{}, :list_sessions, timeout)
  end

  @doc "Change the model on an active session."
  def set_model(conn, session_id, model, timeout \\ @default_timeout) do
    BaseConnection.call_rpc(
      conn,
      "session.setModel",
      %{"sessionId" => session_id, "model" => model},
      :set_model,
      timeout
    )
  end

  @doc "Respond to a tool.call request from the server."
  def respond_to_tool_call(conn, request_id, result) do
    response = %{"jsonrpc" => "2.0", "id" => request_id, "result" => result}
    BaseConnection.send_raw(conn, response)
  end

  @doc "Respond to an external tool call."
  def respond_to_external_tool(conn, session_id, request_id, result) do
    BaseConnection.call_rpc(
      conn,
      "session.tools.handlePendingToolCall",
      %{"sessionId" => session_id, "requestId" => request_id, "result" => result},
      :respond_external_tool,
      to_timeout(minute: 5)
    )
  end

  @doc "Stop the connection."
  def stop(conn), do: BaseConnection.stop(conn)

  # -- Ping with retry --

  defp ping_with_retry(conn, total_timeout, attempt \\ 1) do
    delay = Enum.at(@ping_delays, min(attempt - 1, length(@ping_delays) - 1))
    Process.sleep(delay)

    case BaseConnection.call_rpc(conn, "ping", %{"message" => "init-#{attempt}"}, :ping, 15_000) do
      {:ok, _} ->
        :ok

      {:error, _} when attempt < length(@ping_delays) and total_timeout > 10_000 ->
        remaining = total_timeout - delay - 5_000
        ping_with_retry(conn, remaining, attempt + 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
