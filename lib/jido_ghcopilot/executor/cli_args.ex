defmodule Jido.GHCopilot.Executor.CliArgs do
  @moduledoc false

  @doc """
  Builds CLI permission flags from an args map.

  Supports `:cli_args` (base list), `:yolo` (enables all permissions),
  individual `:allow_all_tools` / `:allow_all_paths` / `:allow_all_urls`,
  and `:model`.
  """
  @spec build(map()) :: [String.t()]
  def build(args) do
    cli_args = args[:cli_args] || []
    yolo = args[:yolo] || false

    cli_args =
      if yolo || Map.get(args, :allow_all_tools, false),
        do: cli_args ++ ["--allow-all-tools"],
        else: cli_args

    cli_args =
      if yolo || Map.get(args, :allow_all_paths, false),
        do: cli_args ++ ["--allow-all-paths"],
        else: cli_args

    cli_args =
      if yolo || Map.get(args, :allow_all_urls, false),
        do: cli_args ++ ["--allow-all-urls"],
        else: cli_args

    model = args[:model]
    if model, do: cli_args ++ ["--model", model], else: cli_args
  end
end
