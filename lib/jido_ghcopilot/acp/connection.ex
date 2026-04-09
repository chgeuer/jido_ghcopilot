defmodule Jido.GHCopilot.ACP.Connection do
  @moduledoc """
  ACP connection wrapper using the shared `Jido.Harness.Connection` base.

  Provides the same public API as the previous inline GenServer but delegates
  all transport, framing, and JSON-RPC plumbing to the shared base.

  ## Message Format

  Subscribers receive `{:connection_event, session_id, event}` messages where
  `event` is a `Jido.GHCopilot.ACP.Types.SessionUpdate` struct.
  """

  alias Jido.Harness.Connection, as: BaseConnection
  alias Jido.GHCopilot.ACP.ConnectionProtocol

  @default_timeout to_timeout(second: 30)

  @doc "Start a new ACP connection. Does NOT auto-initialize — call `initialize/2` next."
  def start_link(opts \\ []) do
    conn_opts =
      opts
      |> Keyword.put(:protocol, ConnectionProtocol)
      |> Keyword.put_new(:permission_handler, :auto_approve)

    BaseConnection.start_link(conn_opts)
  end

  @doc "Perform the ACP initialize handshake. Returns `{:ok, init_result}` or `{:error, reason}`."
  def initialize(conn, timeout \\ @default_timeout) do
    BaseConnection.call_rpc(conn, "initialize", ConnectionProtocol.init_params(), :initialize, timeout)
  end

  @doc "Create a new session. Returns `{:ok, session_id}` or `{:error, reason}`."
  def new_session(conn, cwd, mcp_servers \\ [], timeout \\ @default_timeout) do
    BaseConnection.call_rpc(
      conn,
      "session/new",
      %{"cwd" => cwd, "mcpServers" => mcp_servers},
      :new_session,
      timeout
    )
  end

  @doc """
  Send a prompt to a session (blocking). Returns `{:ok, stop_reason}` when the turn completes.

  Session updates are delivered to subscribers as `{:connection_event, session_id, update}` messages.
  """
  def prompt(conn, session_id, prompt_text, timeout \\ to_timeout(minute: 10))
      when is_binary(prompt_text) do
    BaseConnection.call_rpc(
      conn,
      "session/prompt",
      %{"sessionId" => session_id, "prompt" => [%{"type" => "text", "text" => prompt_text}]},
      {:prompt, session_id},
      timeout
    )
  end

  @doc "Subscribe the calling process to session updates for `session_id`."
  def subscribe(conn, session_id), do: BaseConnection.subscribe(conn, session_id)

  @doc "Unsubscribe from session updates."
  def unsubscribe(conn, session_id), do: BaseConnection.unsubscribe(conn, session_id)

  @doc "Cancel an ongoing prompt turn."
  def cancel(conn, session_id) do
    BaseConnection.cast_rpc(conn, "session/cancel", %{"sessionId" => session_id})
  end

  @doc "Load a previous session. Returns `:ok` or `{:error, reason}`."
  def load_session(conn, session_id, cwd, mcp_servers \\ [], timeout \\ @default_timeout) do
    BaseConnection.call_rpc(
      conn,
      "session/load",
      %{"sessionId" => session_id, "cwd" => cwd, "mcpServers" => mcp_servers},
      {:load_session, session_id},
      timeout
    )
  end

  @doc "Stop the connection and terminate the subprocess."
  def stop(conn), do: BaseConnection.stop(conn)
end
