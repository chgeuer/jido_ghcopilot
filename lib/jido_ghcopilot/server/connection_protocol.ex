defmodule Jido.GHCopilot.Server.ConnectionProtocol do
  @moduledoc """
  `Jido.Harness.Connection.Protocol` implementation for GitHub Copilot CLI Server.

  Uses LSP Content-Length framing and implements the Server JSON-RPC protocol
  (dot-separated method names like `session.create`, `session.send`, etc.).
  """

  @behaviour Jido.Harness.Connection.Protocol

  require Logger

  alias Jido.Harness.Connection.Framing.LSP
  alias Jido.GHCopilot.Server.Protocol

  # -- Wire framing (delegated to LSP) --

  @impl true
  def cli_command(opts) do
    use_wrapper = Keyword.get(opts, :use_wrapper, true)

    if use_wrapper do
      wrapper_path = wrapper_script_path()
      node_path = System.find_executable("node")

      if node_path && File.exists?(wrapper_path) do
        extra_args = Keyword.get(opts, :cli_args, [])
        {node_path, [wrapper_path | extra_args]}
      else
        fallback_cli(opts)
      end
    else
      fallback_cli(opts)
    end
  end

  defp fallback_cli(opts) do
    cli_path = Keyword.get(opts, :cli_path) || Jido.GHCopilot.CLI.resolve_path()
    extra_args = Keyword.get(opts, :cli_args, [])
    {cli_path, ["--server", "--stdio"] ++ extra_args}
  end

  defp wrapper_script_path do
    :jido_ghcopilot
    |> :code.priv_dir()
    |> to_string()
    |> Path.join("copilot_wrapper/index.js")
  end

  @impl true
  defdelegate encode(json), to: LSP

  @impl true
  defdelegate decode_buffer(buffer), to: LSP

  @impl true
  def port_opts, do: LSP.port_opts()

  # -- Initialization --

  @impl true
  def initialize_request(_opts), do: nil

  # -- Response handling --

  @impl true
  def handle_response(%{"result" => result}, :ping), do: {:reply, result}

  def handle_response(%{"result" => %{"sessionId" => _} = result}, :create_session) do
    {:reply, Protocol.decode_create_result(result).session_id}
  end

  def handle_response(%{"result" => %{"messageId" => _} = result}, {:send, _sid}) do
    {:reply, Protocol.decode_send_result(result).message_id}
  end

  def handle_response(%{"result" => _}, :destroy), do: {:reply, :ok}

  def handle_response(%{"result" => %{"sessionId" => sid}}, {:resume, _sid}), do: {:reply, sid}

  def handle_response(%{"result" => %{"sessions" => _} = result}, :list_sessions) do
    {:reply, Protocol.decode_list_result(result)}
  end

  def handle_response(%{"result" => result}, :set_model), do: {:reply, result}

  def handle_response(%{"result" => _}, :permission_resolve), do: :ignore

  def handle_response(%{"result" => _}, :respond_external_tool), do: {:reply, :ok}

  def handle_response(_, _), do: :ignore

  # -- Notification handling --

  @impl true
  def handle_notification(%{
        "method" => "session.event",
        "params" => %{"sessionId" => sid, "event" => event_data}
      }) do
    session_event = Protocol.decode_session_event(sid, event_data)

    if session_event.type == "permission.requested" do
      request_id = get_in(session_event.data, ["requestId"])

      if request_id do
        {:broadcast_and_fire, sid, session_event,
         %{
           method: "session.permissions.handlePendingPermissionRequest",
           params: %{
             "sessionId" => sid,
             "requestId" => request_id,
             "result" => %{"kind" => "approved"}
           },
           meta: :permission_resolve
         }}
      else
        {:broadcast, sid, session_event}
      end
    else
      {:broadcast, sid, session_event}
    end
  end

  def handle_notification(_), do: :ignore

  # -- Server request handling --

  @impl true
  def handle_server_request(
        %{"id" => id, "method" => "tool.call", "params" => params},
        _handler
      ) do
    session_id = params["sessionId"]

    tool_call = %{
      request_id: id,
      session_id: session_id,
      tool_call_id: params["toolCallId"],
      tool_name: params["toolName"],
      arguments: params["arguments"]
    }

    {:broadcast, session_id, {:tool_call, tool_call}}
  end

  def handle_server_request(
        %{"id" => id, "method" => "permission.request", "params" => params},
        handler
      ) do
    kind = get_in(params, ["permissionRequest", "kind"]) || "unknown"
    session_id = params["sessionId"]
    outcome = resolve_permission(handler, %{kind: kind, session_id: session_id, data: params})
    result_kind = if outcome == :approved, do: "approved", else: "denied"

    {:reply_json,
     %{
       "jsonrpc" => "2.0",
       "id" => id,
       "result" => %{"result" => %{"kind" => result_kind}}
     }}
  end

  def handle_server_request(%{"id" => id}, _handler) do
    {:reply_json, %{"jsonrpc" => "2.0", "id" => id, "result" => %{}}}
  end

  defp resolve_permission(:auto_approve, _info), do: :approved
  defp resolve_permission(:deny, _info), do: :denied

  defp resolve_permission({:callback, fun}, info) when is_function(fun, 1) do
    case fun.(info) do
      outcome when outcome in [:approved, :denied] -> outcome
      _ -> :denied
    end
  end

  defp resolve_permission(_, _info), do: :denied
end
