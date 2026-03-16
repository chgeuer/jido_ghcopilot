defmodule Mix.Tasks.Ghcopilot.Compat do
  @moduledoc """
  Validate that the GitHub Copilot CLI is installed and compatible.

      mix ghcopilot.compat
  """

  @shortdoc "Validate GitHub Copilot CLI compatibility"

  use Mix.Task

  @impl true
  def run(_args) do
    alias Jido.GHCopilot.Compatibility

    if Jido.GHCopilot.cli_installed?() do
      cli_path = Compatibility.cli_module().resolve_path()

      case Compatibility.command_module().run(cli_path, ["--version"]) do
        {:ok, version} ->
          Mix.shell().info([
            :green,
            "✓ ",
            :reset,
            "GitHub Copilot CLI is installed and compatible.\n",
            "  Path:    ",
            cli_path,
            "\n",
            "  Version: ",
            String.trim(version)
          ])

        {:error, _} ->
          Mix.shell().info([
            :green,
            "✓ ",
            :reset,
            "GitHub Copilot CLI found at: ",
            cli_path,
            "\n",
            :yellow,
            "  (could not determine version)",
            :reset
          ])
      end
    else
      Mix.shell().error("""
      ✗ GitHub Copilot CLI not found.

        Install it from: https://github.com/github/copilot-cli
        Or ensure 'copilot' is on your PATH.
      """)
    end
  end
end
