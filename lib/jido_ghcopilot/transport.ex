defmodule Jido.GHCopilot.Transport do
  @moduledoc """
  Behaviour for Copilot CLI Server I/O transports.

  A transport provides a bidirectional byte stream to a Copilot CLI Server
  process. The Connection GenServer uses the transport for LSP-framed
  JSON-RPC communication.

  Two built-in implementations:
  - `Jido.GHCopilot.Transport.Local` — spawns copilot locally via Port
  - `Jido.GHCopilot.Transport.Vsock` — connects to copilot running in a
    Firecracker VM via a vsock UDS socket

  ## Usage in Adapter

      # Host mode (default — spawns local process)
      Jido.GHCopilot.Adapter.run(request, [])

      # Firecracker mode (connect to running VM)
      Jido.GHCopilot.Adapter.run(request,
        transport: {Jido.GHCopilot.Transport.Vsock, socket: vsock_conn}
      )
  """

  @type t :: pid() | port()

  @doc "Start the transport. Returns an I/O handle (socket or port)."
  @callback start(opts :: keyword()) :: {:ok, t()} | {:error, term()}

  @doc "Send raw bytes to the transport."
  @callback send(t(), iodata()) :: :ok | {:error, term()}

  @doc "Close the transport."
  @callback close(t()) :: :ok

  @doc """
  Returns Connection opts for this transport.

  Local transport returns `[cwd: ..., cli_path: ...]` (Connection spawns Port).
  Vsock transport returns `[io: socket]` (Connection uses pre-connected socket).
  """
  @callback connection_opts(t(), keyword()) :: keyword()
end
