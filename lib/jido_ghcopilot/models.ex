defmodule Jido.GHCopilot.Models do
  @moduledoc """
  Model registry for GitHub Copilot CLI.

  Maps human-friendly display names to CLI model IDs. Supports fuzzy matching
  so users can type partial names like `"opus"` or `"gemini"`.

  ## Examples

      iex> Jido.GHCopilot.Models.resolve("Claude Opus 4.6")
      {:ok, "claude-opus-4.6"}

      iex> Jido.GHCopilot.Models.resolve("gemini")
      {:ok, "gemini-3-pro-preview"}

      iex> Jido.GHCopilot.Models.resolve("opus")
      {:error, "Ambiguous model \\"opus\\", matches: Claude Opus 4.6, Claude Opus 4.6 (fast mode), Claude Opus 4.5"}
  """

  @static_models [
    {"Claude Sonnet 4.6", "claude-sonnet-4.6", 1},
    {"Claude Sonnet 4.5", "claude-sonnet-4.5", 1},
    {"Claude Haiku 4.5", "claude-haiku-4.5", 0.33},
    {"Claude Opus 4.6", "claude-opus-4.6", 3},
    {"Claude Opus 4.6 (fast mode)", "claude-opus-4.6-fast", 30},
    {"Claude Opus 4.6 (1M context)", "claude-opus-4.6-1m", 6},
    {"Claude Opus 4.5", "claude-opus-4.5", 3},
    {"Claude Sonnet 4", "claude-sonnet-4", 1},
    {"Gemini 3 Pro (Preview)", "gemini-3-pro-preview", 1},
    {"GPT-5.3-Codex", "gpt-5.3-codex", 1},
    {"GPT-5.2-Codex", "gpt-5.2-codex", 1},
    {"GPT-5.2", "gpt-5.2", 1},
    {"GPT-5.1-Codex-Max", "gpt-5.1-codex-max", 1},
    {"GPT-5.1-Codex", "gpt-5.1-codex", 1},
    {"GPT-5.1", "gpt-5.1", 1},
    {"GPT-5.1-Codex-Mini", "gpt-5.1-codex-mini", 0.33},
    {"GPT-5 mini", "gpt-5-mini", 0},
    {"GPT-5", "gpt-5", 1},
    {"GPT-4.1", "gpt-4.1", 0}
  ]

  # Known premium multipliers for models not in the static list
  @known_multipliers %{
    "claude-opus" => 3,
    "claude-opus-4.6-fast" => 30,
    "claude-opus-4.6-1m" => 6,
    "claude-haiku" => 0.33,
    "gpt-5-mini" => 0,
    "gpt-5.1-codex-mini" => 0.33,
    "gpt-4.1" => 0
  }

  @doc "Returns all known models as `{display_name, cli_id, premium_multiplier}` tuples."
  @spec all() :: [{String.t(), String.t(), number()}]
  def all do
    cli_models =
      case discover_from_cli() do
        {:ok, models} -> models
        {:error, _} -> @static_models
      end

    # Merge in models from static list that CLI doesn't offer (e.g. internal-only models)
    cli_ids = MapSet.new(cli_models, &elem(&1, 1))

    static_extras =
      @static_models
      |> Enum.reject(fn {_, id, _} -> MapSet.member?(cli_ids, id) end)

    # Merge in models from session history
    db_models = discover_from_sessions()
    all_ids = MapSet.union(cli_ids, MapSet.new(static_extras, &elem(&1, 1)))

    db_extras =
      db_models
      |> Enum.reject(fn {_, id, _} -> MapSet.member?(all_ids, id) end)

    cli_models ++ static_extras ++ db_extras
  end

  @doc "Returns the static model list (no CLI call)."
  @spec static() :: [{String.t(), String.t(), number()}]
  def static, do: @static_models

  @doc "Returns all CLI model IDs."
  @spec all_ids() :: [String.t()]
  def all_ids, do: Enum.map(all(), &elem(&1, 1))

  @doc "Returns all display names."
  @spec all_names() :: [String.t()]
  def all_names, do: Enum.map(all(), &elem(&1, 0))

  @doc """
  Returns the premium request multiplier for a model ID.

  The multiplier indicates relative cost: 0 = free, 0.33 = cheap, 1 = standard, 3 = premium, 30 = ultra-premium.
  Falls back to 1 for unknown models.
  """
  @spec multiplier(String.t()) :: number()
  def multiplier(model_id) when is_binary(model_id) do
    case Enum.find(all(), fn {_, id, _} -> id == model_id end) do
      {_, _, m} -> m
      nil -> infer_multiplier(model_id)
    end
  end

  @doc """
  Resolve a user-provided string to a CLI model ID.

  Accepts:
  - Exact CLI ID: `"claude-opus-4.6"` → `"claude-opus-4.6"`
  - Exact display name: `"Claude Opus 4.6"` → `"claude-opus-4.6"`
  - Case-insensitive substring: `"opus 4.6"` → `"claude-opus-4.6"`
  - Partial match: `"gemini"` → `"gemini-3-pro-preview"`

  Returns `{:ok, cli_id}` or `{:error, reason}`.
  """
  @spec resolve(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def resolve(input) when is_binary(input) do
    input_trimmed = String.trim(input)
    input_down = String.downcase(input_trimmed)
    models = all()

    # 1. Exact CLI ID match
    case Enum.find(models, fn {_, id, _} -> id == input_trimmed end) do
      {_, id, _} ->
        {:ok, id}

      nil ->
        # 2. Exact display name match (case-insensitive)
        case Enum.find(models, fn {name, _, _} -> String.downcase(name) == input_down end) do
          {_, id, _} ->
            {:ok, id}

          nil ->
            # 3. Substring match on display name or CLI ID
            matches =
              Enum.filter(models, fn {name, id, _} ->
                String.contains?(String.downcase(name), input_down) or
                  String.contains?(id, input_down)
              end)

            case matches do
              [{_, id, _}] ->
                {:ok, id}

              [] ->
                {:error,
                 "Unknown model: #{inspect(input_trimmed)}. Available: #{Enum.map_join(models, ", ", &elem(&1, 0))}"}

              multiple ->
                names = Enum.map_join(multiple, ", ", &elem(&1, 0))
                {:error, "Ambiguous model #{inspect(input_trimmed)}, matches: #{names}"}
            end
        end
    end
  end

  @doc "Like `resolve/1` but raises on failure."
  @spec resolve!(String.t()) :: String.t()
  def resolve!(input) do
    case resolve(input) do
      {:ok, id} -> id
      {:error, msg} -> raise ArgumentError, msg
    end
  end

  @doc """
  Resolve a list of user-provided model strings.
  Returns `{:ok, [cli_id]}` or `{:error, reason}` on first failure.
  """
  @spec resolve_all([String.t()]) :: {:ok, [String.t()]} | {:error, String.t()}
  def resolve_all(inputs) when is_list(inputs) do
    results = Enum.map(inputs, &resolve/1)

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil -> {:ok, Enum.map(results, fn {:ok, id} -> id end)}
      {:error, _} = err -> err
    end
  end

  # ── Dynamic CLI discovery ──

  @doc """
  Discovers models from an external source (e.g. session history).
  Call `register_session_models/1` to populate.
  """
  @spec discover_from_sessions() :: [{String.t(), String.t(), number()}]
  def discover_from_sessions do
    :persistent_term.get({__MODULE__, :session_models}, [])
  end

  @doc """
  Registers models discovered from session history.
  Call this at application startup with a list of model ID strings.
  """
  @spec register_session_models([String.t()]) :: :ok
  def register_session_models(model_ids) when is_list(model_ids) do
    models =
      model_ids
      |> Enum.reject(&is_nil/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.map(&build_model_entry/1)

    :persistent_term.put({__MODULE__, :session_models}, models)
    :ok
  end

  @doc """
  Discovers available models by parsing `copilot --help` output.
  Results are cached in a persistent_term for the lifetime of the VM.
  """
  @spec discover_from_cli() :: {:ok, [{String.t(), String.t(), number()}]} | {:error, term()}
  def discover_from_cli do
    case :persistent_term.get({__MODULE__, :discovered_models}, :not_cached) do
      :not_cached ->
        result = do_discover_from_cli()

        if match?({:ok, _}, result) do
          :persistent_term.put({__MODULE__, :discovered_models}, result)
        end

        result

      cached ->
        cached
    end
  end

  defp do_discover_from_cli do
    case System.find_executable("copilot") do
      nil ->
        {:error, :copilot_not_found}

      _path ->
        case System.cmd("copilot", ["--help"], stderr_to_stdout: true) do
          {output, 0} ->
            ids = parse_model_choices(output)

            if ids == [] do
              {:error, :no_models_found}
            else
              models = Enum.map(ids, &build_model_entry/1)
              {:ok, models}
            end

          {_, _} ->
            {:error, :cli_failed}
        end
    end
  rescue
    _ -> {:error, :cli_error}
  end

  defp parse_model_choices(help_output) do
    # Extract the choices list from: --model <model>  Set the AI model to use (choices: "model-a", "model-b", ...)
    case Regex.run(~r/--model.*?\(choices:\s*(.*?)\)/s, help_output) do
      [_, choices_str] ->
        Regex.scan(~r/"([^"]+)"/, choices_str)
        |> Enum.map(fn [_, id] -> id end)

      _ ->
        []
    end
  end

  defp build_model_entry(cli_id) do
    # Check if we have a static entry for this model
    case Enum.find(@static_models, fn {_, id, _} -> id == cli_id end) do
      {name, _, mult} -> {name, cli_id, mult}
      nil -> {humanize_model_id(cli_id), cli_id, infer_multiplier(cli_id)}
    end
  end

  defp humanize_model_id(cli_id) do
    cli_id
    |> String.split("-")
    |> Enum.map_join(" ", fn
      "gpt" -> "GPT"
      "mcp" -> "MCP"
      part -> String.capitalize(part)
    end)
  end

  defp infer_multiplier(model_id) do
    # Check known multipliers by exact match or prefix
    case Map.get(@known_multipliers, model_id) do
      nil ->
        cond do
          String.contains?(model_id, "opus") && String.contains?(model_id, "fast") -> 30
          String.contains?(model_id, "opus") && String.contains?(model_id, "1m") -> 6
          String.contains?(model_id, "opus") -> 3
          String.contains?(model_id, "haiku") -> 0.33
          String.contains?(model_id, "mini") -> 0.33
          true -> 1
        end

      mult ->
        mult
    end
  end
end
