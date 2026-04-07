defmodule Jido.GHCopilot.Transport.Vsock do
  @moduledoc """
  Vsock transport — connects to a Copilot process running inside a
  Firecracker VM via a pre-established gen_tcp socket.

  The socket is typically a UDS connection to the Firecracker vsock proxy.
  The caller (HarnessBridge) establishes the connection and passes it here.

  ## Usage

      {:ok, handle} = Vsock.start(socket: vsock_conn)
      conn_opts = Vsock.connection_opts(handle, permission_handler: :auto_approve)
      {:ok, conn} = Connection.start_link(conn_opts)
  """

  @behaviour Jido.GHCopilot.Transport

  @impl true
  def start(opts) do
    socket = Keyword.fetch!(opts, :socket)
    {:ok, socket}
  end

  @impl true
  def send(socket, data) do
    :gen_tcp.send(socket, data)
  end

  @impl true
  def close(socket) do
    :gen_tcp.close(socket)
    :ok
  end

  @impl true
  def connection_opts(socket, opts) do
    base = Keyword.take(opts, [:permission_handler, :timeout, :name])
    [{:io, socket} | base]
  end
end
