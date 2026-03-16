defmodule Jido.GHCopilot.CLI do
  @moduledoc false

  @doc "Resolves the path to the `copilot` CLI binary."
  @spec resolve_path() :: String.t() | nil
  def resolve_path do
    env_path = System.get_env("COPILOT_CLI_PATH")

    cond do
      is_binary(env_path) and File.exists?(env_path) -> env_path
      true -> System.find_executable("copilot")
    end
  end
end
