defmodule Jido.GHCopilot.Transport.Local do
  @moduledoc """
  Local transport — tells Connection to spawn copilot via Port.open
  in CLI Server mode (`--server --stdio`).

  This is the default transport. Connection handles Port lifecycle.
  """

  @behaviour Jido.GHCopilot.Transport

  @impl true
  def start(opts) do
    {:ok, opts}
  end

  @impl true
  def send(_handle, _data), do: :ok

  @impl true
  def close(_handle), do: :ok

  @impl true
  def connection_opts(handle, opts) do
    cwd = Keyword.get(handle, :cwd) || Keyword.get(opts, :cwd)
    permission_handler = Keyword.get(opts, :permission_handler, :auto_approve)

    base = if cwd, do: [cwd: cwd], else: []
    [{:permission_handler, permission_handler} | base]
  end
end
