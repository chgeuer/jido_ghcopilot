defmodule Jido.GHCopilot.Options do
  @moduledoc """
  Runtime option normalization for GitHub Copilot adapter execution.

  Combines:
  - defaults derived from `%Jido.Harness.RunRequest{}`
  - `request.metadata["ghcopilot"]` overrides
  - runtime adapter opts overrides

  Precedence is runtime opts > metadata > defaults.
  """

  alias Jido.Harness.RunRequest

  @default_timeout_ms to_timeout(minute: 10)

  @schema Zoi.struct(
            __MODULE__,
            %{
              prompt: Zoi.string(),
              cwd: Zoi.string() |> Zoi.nullable() |> Zoi.optional(),
              model: Zoi.string() |> Zoi.nullable() |> Zoi.optional(),
              silent: Zoi.boolean() |> Zoi.optional(),
              continue: Zoi.boolean() |> Zoi.optional(),
              resume: Zoi.any() |> Zoi.nullable() |> Zoi.optional(),
              autopilot: Zoi.boolean() |> Zoi.optional(),
              max_autopilot_continues: Zoi.integer() |> Zoi.nullable() |> Zoi.optional(),
              share: Zoi.string() |> Zoi.nullable() |> Zoi.optional(),
              timeout_ms: Zoi.integer() |> Zoi.optional(),
              add_dirs: Zoi.array(Zoi.string()) |> Zoi.optional(),
              env: Zoi.map() |> Zoi.optional()
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for adapter options."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Validates normalized adapter option attributes."
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs), do: Zoi.parse(@schema, attrs)

  @doc "Like `new/1` but raises on validation errors."
  @spec new!(map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, value} -> value
      {:error, reason} -> raise ArgumentError, "Invalid #{inspect(__MODULE__)}: #{inspect(reason)}"
    end
  end

  @doc "Builds normalized adapter options from a run request and runtime options."
  @spec from_run_request(RunRequest.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def from_run_request(%RunRequest{} = request, runtime_opts \\ []) when is_list(runtime_opts) do
    metadata_ghcopilot = ghcopilot_metadata(request.metadata)
    runtime_map = Map.new(runtime_opts)

    defaults = request_defaults(request)

    attrs = %{
      prompt: request.prompt,
      cwd: resolve_scalar(runtime_map, metadata_ghcopilot, :cwd, defaults.cwd),
      model: resolve_scalar(runtime_map, metadata_ghcopilot, :model, defaults.model),
      silent: resolve_scalar(runtime_map, metadata_ghcopilot, :silent, defaults.silent),
      continue: resolve_scalar(runtime_map, metadata_ghcopilot, :continue, defaults.continue),
      resume: resolve_scalar(runtime_map, metadata_ghcopilot, :resume, defaults.resume),
      autopilot: resolve_scalar(runtime_map, metadata_ghcopilot, :autopilot, defaults.autopilot),
      max_autopilot_continues:
        resolve_scalar(runtime_map, metadata_ghcopilot, :max_autopilot_continues, defaults.max_autopilot_continues),
      share: resolve_scalar(runtime_map, metadata_ghcopilot, :share, defaults.share),
      timeout_ms: resolve_scalar(runtime_map, metadata_ghcopilot, :timeout_ms, defaults.timeout_ms),
      add_dirs: resolve_list(runtime_map, metadata_ghcopilot, :add_dirs, defaults.add_dirs),
      env: merge_maps(defaults.env, metadata_ghcopilot, runtime_map, :env)
    }

    new(attrs)
  end

  defp request_defaults(%RunRequest{} = request) do
    %{
      cwd: request.cwd,
      model: request.model,
      silent: true,
      continue: false,
      resume: nil,
      autopilot: false,
      max_autopilot_continues: nil,
      share: nil,
      timeout_ms: @default_timeout_ms,
      add_dirs: [],
      env: %{}
    }
  end

  defp ghcopilot_metadata(metadata) when is_map(metadata) do
    metadata
    |> fetch_value(:ghcopilot)
    |> sanitize_map()
  end

  defp ghcopilot_metadata(_), do: %{}

  defp resolve_scalar(runtime_map, metadata, key, default) do
    case fetch_value(runtime_map, key) do
      nil ->
        case fetch_value(metadata, key) do
          nil -> default
          value -> value
        end

      value ->
        value
    end
  end

  defp resolve_list(runtime_map, metadata, key, default) do
    runtime_list = fetch_value(runtime_map, key)
    metadata_list = fetch_value(metadata, key)

    cond do
      is_list(runtime_list) and runtime_list != [] -> runtime_list
      is_list(metadata_list) and metadata_list != [] -> metadata_list
      true -> default
    end
  end

  defp merge_maps(base, metadata, runtime_map, key) do
    base
    |> deep_merge(sanitize_map(fetch_value(metadata, key)))
    |> deep_merge(sanitize_map(fetch_value(runtime_map, key)))
  end

  defp fetch_value(map, key) do
    atom_value = Map.get(map, key)

    if is_nil(atom_value) do
      Map.get(map, Atom.to_string(key))
    else
      atom_value
    end
  end

  defp sanitize_map(value) when is_map(value), do: value
  defp sanitize_map(_), do: %{}

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, lhs, rhs ->
      if is_map(lhs) and is_map(rhs), do: deep_merge(lhs, rhs), else: rhs
    end)
  end

  defp deep_merge(_left, right), do: right
end
