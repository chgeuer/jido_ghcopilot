defmodule Mix.Tasks.Ghcopilot.Models do
  @moduledoc """
  List available GitHub Copilot CLI models with fuzzy search.

      mix ghcopilot.models
      mix ghcopilot.models --search opus
      mix ghcopilot.models --resolve "Claude Opus 4.6"

  ## Options

    * `--search` / `-s` — filter models by substring match
    * `--resolve` / `-r` — resolve a name to its CLI model ID
    * `--ids` — show only CLI model IDs (useful for scripting)
  """

  @shortdoc "List available GitHub Copilot CLI models"

  use Mix.Task

  alias Jido.GHCopilot.Models

  @switches [search: :string, resolve: :string, ids: :boolean]
  @aliases [s: :search, r: :resolve]

  @impl true
  def run(args) do
    {opts, _positional, _invalid} = OptionParser.parse(args, strict: @switches, aliases: @aliases)

    cond do
      opts[:resolve] ->
        resolve_model(opts[:resolve])

      opts[:ids] ->
        list_ids(opts[:search])

      true ->
        list_models(opts[:search])
    end
  end

  defp resolve_model(input) do
    case Models.resolve(input) do
      {:ok, id} ->
        Mix.shell().info([:green, "✓ ", :reset, input, " → ", :bright, id, :reset])

      {:error, msg} ->
        Mix.shell().error(msg)
    end
  end

  defp list_ids(search) do
    models = filter_models(search)
    Enum.each(models, fn {_name, id, _} -> Mix.shell().info(id) end)
  end

  defp list_models(search) do
    models = filter_models(search)

    if models == [] do
      Mix.shell().info([:yellow, "No models match \"#{search}\"", :reset])
    else
      # Find max name length for alignment
      max_name = models |> Enum.map(fn {n, _, _} -> String.length(n) end) |> Enum.max()

      Mix.shell().info([:bright, "Available GitHub Copilot models:", :reset, "\n"])

      Enum.each(models, fn {name, id, multiplier} ->
        padding = String.duplicate(" ", max_name - String.length(name) + 2)
        cost_str = format_multiplier(multiplier)
        Mix.shell().info(["  ", name, padding, :faint, id, :reset, "  ", cost_str])
      end)

      Mix.shell().info(["\n", :faint, "#{length(models)} models", :reset])
    end
  end

  defp format_multiplier(0), do: [:green, "free", :reset]
  defp format_multiplier(0.33), do: [:cyan, "0.33x", :reset]
  defp format_multiplier(m) when m >= 3, do: [:yellow, "#{m}x", :reset]
  defp format_multiplier(m), do: [:faint, "#{m}x", :reset]

  defp filter_models(nil), do: Models.all()

  defp filter_models(search) do
    down = String.downcase(search)

    Enum.filter(Models.all(), fn {name, id, _} ->
      String.contains?(String.downcase(name), down) or String.contains?(id, down)
    end)
  end
end
