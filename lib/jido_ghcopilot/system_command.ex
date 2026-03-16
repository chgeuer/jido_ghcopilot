defmodule Jido.GHCopilot.SystemCommand do
  @moduledoc false

  @doc false
  @spec run(String.t(), [String.t()], keyword()) :: {:ok, String.t()} | {:error, term()}
  def run(program, args, opts \\ []) when is_binary(program) and is_list(args) do
    timeout = Keyword.get(opts, :timeout, to_timeout(second: 5))
    env = Keyword.get(opts, :env, [])

    try do
      task =
        Task.async(fn ->
          try do
            {:ok, System.cmd(program, args, stderr_to_stdout: true, env: env)}
          rescue
            e -> {:error, e}
          end
        end)

      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, {:ok, {output, 0}}} -> {:ok, output}
        {:ok, {:ok, {output, status}}} -> {:error, %{status: status, output: output}}
        {:ok, {:error, reason}} -> {:error, reason}
        {:exit, reason} -> {:error, reason}
        nil -> {:error, %{status: :timeout, output: ""}}
      end
    rescue
      e -> {:error, e}
    end
  end
end
