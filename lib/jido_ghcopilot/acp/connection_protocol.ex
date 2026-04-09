defmodule Jido.GHCopilot.ACP.ConnectionProtocol do
  @moduledoc """
  `Jido.Harness.Connection.Protocol` implementation for GitHub Copilot ACP.

  Delegates wire framing to NDJSON and uses the existing `Jido.GHCopilot.ACP.Protocol`
  module for typed response/notification parsing.
  """

  @behaviour Jido.Harness.Connection.Protocol

  alias Jido.Harness.Connection.Framing.NDJSON
  alias Jido.GHCopilot.ACP.Protocol

  # -- Wire framing (delegated to NDJSON) --

  @impl true
  def cli_command(opts) do
    path = Keyword.get(opts, :cli_path) || Jido.GHCopilot.CLI.resolve_path()
    extra_args = Keyword.get(opts, :cli_args, [])
    {path, ["--acp", "--stdio"] ++ extra_args}
  end

  @impl true
  defdelegate encode(json), to: NDJSON

  @impl true
  defdelegate decode_buffer(buffer), to: NDJSON

  @impl true
  def port_opts, do: NDJSON.port_opts()

  # -- Initialization --

  @impl true
  def initialize_request(_opts), do: nil

  @doc "Parameters for the ACP initialize handshake."
  def init_params(client_info \\ %{"name" => "jido_ghcopilot", "version" => "0.1.0"}) do
    %{
      "protocolVersion" => 1,
      "capabilities" => %{},
      "clientInfo" => client_info
    }
  end

  # -- Response handling --

  @impl true
  def handle_response(%{"result" => result}, :initialize) do
    {:reply, Protocol.decode_init_result(result)}
  end

  def handle_response(%{"result" => %{"sessionId" => _} = result}, :new_session) do
    session = Protocol.decode_session_result(result)
    {:reply, session.session_id}
  end

  def handle_response(%{"result" => %{"stopReason" => _} = result}, {:prompt, _sid}) do
    prompt_result = Protocol.decode_prompt_result(result)
    {:reply, prompt_result.stop_reason}
  end

  def handle_response(%{"result" => _}, {:load_session, _sid}), do: {:reply, :ok}

  def handle_response(_, _), do: :ignore

  # -- Notification handling --

  @impl true
  def handle_notification(%{
        "method" => "session/update",
        "params" => %{"sessionId" => sid, "update" => update_data}
      }) do
    parsed = Protocol.decode_session_update(sid, update_data)
    {:broadcast, sid, parsed}
  end

  def handle_notification(_), do: :ignore

  # -- Server request handling (permissions) --

  @impl true
  def handle_server_request(
        %{"method" => "session/request_permission", "id" => id, "params" => _params},
        handler
      ) do
    outcome = resolve_permission(handler)

    {:reply_json,
     %{
       "jsonrpc" => "2.0",
       "id" => id,
       "result" => %{"outcome" => %{"outcome" => to_string(outcome)}}
     }}
  end

  def handle_server_request(_, _), do: :ignore

  defp resolve_permission(:auto_approve), do: :allow
  defp resolve_permission(:deny), do: :deny

  defp resolve_permission({:callback, fun}) when is_function(fun, 1) do
    case fun.(:request) do
      outcome when outcome in [:allow, :deny, :cancelled] -> outcome
      _ -> :deny
    end
  end

  defp resolve_permission(_), do: :deny
end
