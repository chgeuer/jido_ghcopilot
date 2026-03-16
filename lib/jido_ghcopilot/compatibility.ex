defmodule Jido.GHCopilot.Compatibility do
  @moduledoc """
  Runtime compatibility checks for the GitHub Copilot CLI.

  Verifies the `copilot` binary is available and supports non-interactive
  prompt execution (`-p`).
  """

  alias Jido.GHCopilot.Error
  alias Jido.GHCopilot.Error.ConfigError

  @command_timeout to_timeout(second: 5)
  @required_tokens ["-p", "--prompt"]

  @spec status() :: {:ok, map()} | {:error, ConfigError.t()}
  @doc "Returns compatibility metadata for the Copilot CLI."
  def status do
    with {:ok, cli_path} <- resolve_cli(),
         {:ok, help_output} <- read_help(cli_path),
         :ok <- ensure_prompt_support(help_output) do
      {:ok,
       %{
         program: cli_path,
         version: read_version(cli_path),
         required_tokens: @required_tokens
       }}
    end
  end

  @spec check() :: :ok | {:error, ConfigError.t()}
  @doc "Returns :ok when compatible, otherwise a structured config error."
  def check do
    case status() do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  @spec compatible?() :: boolean()
  @doc "Boolean predicate for compatibility checks."
  def compatible?, do: match?({:ok, _}, status())

  @spec assert_compatible!() :: :ok | no_return()
  @doc "Raises when the Copilot CLI is not compatible."
  def assert_compatible! do
    case check() do
      :ok -> :ok
      {:error, error} -> raise error
    end
  end

  @spec cli_installed?() :: boolean()
  @doc "Returns true when a Copilot CLI binary can be resolved."
  def cli_installed?, do: cli_module().resolve_path() != nil

  @doc false
  @spec cli_module() :: module()
  def cli_module do
    Application.get_env(:jido_ghcopilot, :cli_module, Jido.GHCopilot.CLI)
  end

  @doc false
  @spec command_module() :: module()
  def command_module do
    Application.get_env(:jido_ghcopilot, :command_module, Jido.GHCopilot.SystemCommand)
  end

  defp resolve_cli do
    case cli_module().resolve_path() do
      nil ->
        {:error,
         Error.config_error(
           "GitHub Copilot CLI is not available. Install it with `npm install -g @githubnext/github-copilot-cli` or via `gh copilot`.",
           %{key: :ghcopilot_cli}
         )}

      path ->
        {:ok, path}
    end
  end

  defp read_help(program) do
    case command_module().run(program, ["--help"], timeout: @command_timeout) do
      {:ok, output} ->
        {:ok, output}

      {:error, reason} ->
        {:error,
         Error.config_error("Unable to read Copilot CLI help output.", %{
           key: :ghcopilot_cli_help,
           details: %{reason: reason}
         })}
    end
  end

  defp ensure_prompt_support(help_output) do
    missing = Enum.reject(@required_tokens, &String.contains?(help_output, &1))

    case missing do
      [] ->
        :ok

      _ ->
        {:error,
         Error.config_error(
           "Installed Copilot CLI does not support non-interactive prompt execution.",
           %{key: :ghcopilot_cli_prompt_support, details: %{missing_tokens: missing}}
         )}
    end
  end

  defp read_version(program) do
    case command_module().run(program, ["--version"], timeout: @command_timeout) do
      {:ok, version} -> String.trim(version)
      {:error, _} -> "unknown"
    end
  end
end
