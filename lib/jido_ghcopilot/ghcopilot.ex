defmodule Jido.GHCopilot do
  @moduledoc """
  GitHub Copilot CLI adapter for Jido.Harness.

  This package provides two integration modes:

  ## Simple mode (backward-compatible)
  - `run/2` — single prompt, returns event stream
  - `cancel/1` — cancel active session

  ## Agent mode (ACP-based, on-par with jido_claude)
  - `start_session/1` — start a long-lived ACP session
  - `send_prompt/4` — send a prompt to an existing session
  - `cancel_session/2` — cancel a session
  - `resume_session/3` — resume a previous session by ID

  ## Options

  All public functions that accept options validate them with Zoi schemas.
  Pass an invalid key and you'll get a clear error message.
  """

  @version "0.1.0"

  alias Jido.GHCopilot.{Adapter, Compatibility}
  alias Jido.GHCopilot.ACP.Connection
  alias Jido.Harness.RunRequest

  # ── Option Schemas (Zoi) ──

  @run_schema Zoi.map(
                %{
                  cwd: Zoi.string() |> Zoi.nullable() |> Zoi.optional(),
                  model: Zoi.string() |> Zoi.nullable() |> Zoi.optional(),
                  max_turns: Zoi.integer() |> Zoi.nullable() |> Zoi.optional(),
                  timeout_ms: Zoi.integer() |> Zoi.optional(),
                  system_prompt: Zoi.string() |> Zoi.nullable() |> Zoi.optional(),
                  allowed_tools: Zoi.array(Zoi.string()) |> Zoi.optional(),
                  attachments: Zoi.array(Zoi.any()) |> Zoi.optional(),
                  metadata: Zoi.map(Zoi.string(), Zoi.any()) |> Zoi.optional()
                },
                coerce: true
              )

  @start_session_schema Zoi.map(
                          %{
                            cwd: Zoi.string() |> Zoi.nullable() |> Zoi.optional(),
                            model: Zoi.string() |> Zoi.nullable() |> Zoi.optional(),
                            mcp_servers: Zoi.array(Zoi.any()) |> Zoi.optional(),
                            cli_args: Zoi.array(Zoi.string()) |> Zoi.optional(),
                            allow_all_tools: Zoi.boolean() |> Zoi.optional(),
                            allow_all_paths: Zoi.boolean() |> Zoi.optional(),
                            allow_all_urls: Zoi.boolean() |> Zoi.optional(),
                            yolo: Zoi.boolean() |> Zoi.optional()
                          },
                          coerce: true
                        )

  @send_prompt_schema Zoi.map(
                        %{
                          timeout_ms: Zoi.integer() |> Zoi.optional()
                        },
                        coerce: true
                      )

  @resume_session_schema Zoi.map(
                           %{
                             cwd: Zoi.string() |> Zoi.nullable() |> Zoi.optional(),
                             mcp_servers: Zoi.array(Zoi.any()) |> Zoi.optional()
                           },
                           coerce: true
                         )

  @doc "Returns the package version."
  @spec version() :: String.t()
  def version, do: @version

  @doc "Returns all available models as `{display_name, cli_id, premium_multiplier}` tuples."
  @spec models() :: [{String.t(), String.t(), number()}]
  defdelegate models, to: Jido.GHCopilot.Models, as: :all

  @doc """
  Resolve a model name to its CLI ID. Accepts display names, CLI IDs, or partial matches.

  ## Examples

      iex> Jido.GHCopilot.resolve_model("Claude Opus 4.6")
      {:ok, "claude-opus-4.6"}

      iex> Jido.GHCopilot.resolve_model("gemini")
      {:ok, "gemini-3-pro-preview"}
  """
  @spec resolve_model(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  defdelegate resolve_model(input), to: Jido.GHCopilot.Models, as: :resolve

  @doc "Returns true if the GitHub Copilot CLI binary can be found."
  @spec cli_installed?() :: boolean()
  def cli_installed?, do: Compatibility.cli_installed?()

  @doc "Returns true if the local Copilot CLI supports prompt execution."
  @spec compatible?() :: boolean()
  def compatible?, do: Compatibility.compatible?()

  @doc "Raises `Jido.GHCopilot.Error.ConfigError` if compatibility checks fail."
  @spec assert_compatible!() :: :ok | no_return()
  def assert_compatible!, do: Compatibility.assert_compatible!()

  # ── Simple Mode (backward-compatible) ──

  @doc """
  Runs a prompt through the GitHub Copilot adapter.

  ## Options

    * `:cwd` — working directory for the Copilot CLI process
    * `:model` — LLM model name (e.g. `"claude-opus-4.6"`, `"gpt-5.3-codex"`)
    * `:max_turns` — maximum number of conversation turns
    * `:timeout_ms` — timeout in milliseconds (default: 10 minutes)
    * `:system_prompt` — system prompt prepended to the conversation
    * `:allowed_tools` — list of tool names the model may call
    * `:attachments` — file or context attachments
    * `:metadata` — arbitrary metadata; use `"ghcopilot"` key for adapter-specific overrides
  """
  @spec run(String.t(), keyword()) :: {:ok, Enumerable.t()} | {:error, term()}
  def run(prompt, opts \\ []) when is_binary(prompt) do
    with {:ok, validated} <- validate_opts(opts, @run_schema) do
      request_keys = [:cwd, :model, :max_turns, :timeout_ms, :system_prompt, :allowed_tools, :attachments, :metadata]
      request_opts = Map.take(validated, request_keys) |> Enum.to_list()
      adapter_opts = Map.drop(validated, request_keys) |> Enum.to_list()

      with {:ok, request} <- RunRequest.new(Map.put(Map.new(request_opts), :prompt, prompt)) do
        run_request(request, adapter_opts)
      end
    end
  end

  @doc "Runs an already-built `%Jido.Harness.RunRequest{}` through the adapter."
  @spec run_request(RunRequest.t(), keyword()) :: {:ok, Enumerable.t()} | {:error, term()}
  def run_request(%RunRequest{} = request, opts \\ []) when is_list(opts) do
    adapter_module().run(request, opts)
  end

  @doc "Cancels an active streamed run by session id."
  @spec cancel(String.t()) :: :ok | {:error, term()}
  def cancel(session_id), do: adapter_module().cancel(session_id)

  # ── Agent Mode (ACP-based) ──

  @doc """
  Start a new ACP connection and session.

  Returns `{:ok, conn, session_id}` where `conn` is the ACP Connection pid
  and `session_id` identifies the session for subsequent calls.

  ## Options

    * `:cwd` — working directory (default: current)
    * `:model` — LLM model name
    * `:mcp_servers` — list of MCP server configs (default: `[]`)
    * `:cli_args` — extra CLI arguments passed to the `copilot` process (default: `[]`)
    * `:allow_all_tools` — pass `--allow-all-tools` to the CLI (default: `false`)
    * `:allow_all_paths` — pass `--allow-all-paths`, disables file path verification (default: `false`)
    * `:allow_all_urls` — pass `--allow-all-urls`, allows all network URLs (default: `false`)
    * `:yolo` — shortcut: sets all three allow flags to `true` (default: `false`)
  """
  @spec start_session(keyword()) :: {:ok, pid(), String.t()} | {:error, term()}
  def start_session(opts \\ []) do
    with {:ok, validated} <- validate_opts(opts, @start_session_schema) do
      cwd = Map.get(validated, :cwd, File.cwd!())
      mcp_servers = Map.get(validated, :mcp_servers, [])
      cli_args = build_acp_cli_args(validated)

      with {:ok, conn} <- Connection.start_link(cli_args: cli_args),
           {:ok, session_id} <- Connection.new_session(conn, cwd, mcp_servers) do
        {:ok, conn, session_id}
      end
    end
  end

  @doc """
  Send a prompt to an existing ACP session.

  Subscribe to updates first with `subscribe/2`, then call this.
  Returns `{:ok, stop_reason}` when the turn completes.

  ## Options

    * `:timeout_ms` — timeout in milliseconds for the prompt turn (default: 10 minutes)
  """
  @spec send_prompt(pid(), String.t(), String.t(), keyword()) ::
          {:ok, atom()} | {:error, term()}
  def send_prompt(conn, session_id, prompt, opts \\ []) do
    with {:ok, validated} <- validate_opts(opts, @send_prompt_schema) do
      timeout = Map.get(validated, :timeout_ms, to_timeout(minute: 10))
      Connection.prompt(conn, session_id, prompt, timeout)
    end
  end

  @doc "Subscribe to ACP session updates. Updates arrive as `{:acp_update, update}` messages."
  @spec subscribe(pid(), String.t()) :: :ok
  def subscribe(conn, session_id) do
    Connection.subscribe(conn, session_id)
  end

  @doc "Cancel an ACP session."
  @spec cancel_session(pid(), String.t()) :: :ok
  def cancel_session(conn, session_id) do
    Connection.cancel(conn, session_id)
  end

  @doc """
  Resume a previous ACP session by ID.

  ## Options

    * `:cwd` — working directory for the resumed session
    * `:mcp_servers` — list of MCP server configs (default: `[]`)
  """
  @spec resume_session(pid(), String.t(), keyword()) :: :ok | {:error, term()}
  def resume_session(conn, session_id, opts \\ []) do
    with {:ok, validated} <- validate_opts(opts, @resume_session_schema) do
      cwd = Map.get(validated, :cwd, File.cwd!())
      mcp_servers = Map.get(validated, :mcp_servers, [])
      Connection.load_session(conn, session_id, cwd, mcp_servers)
    end
  end

  @doc "Stop an ACP connection and its subprocess."
  @spec stop_session(pid()) :: :ok
  def stop_session(conn) do
    Connection.stop(conn)
  end

  # ── Private ──

  defp validate_opts(opts, schema) when is_list(opts) do
    case Zoi.parse(schema, Map.new(opts)) do
      {:ok, validated} -> {:ok, validated}
      {:error, reason} -> {:error, {:invalid_options, reason}}
    end
  end

  defp adapter_module do
    Application.get_env(:jido_ghcopilot, :adapter_module, Adapter)
  end

  defp build_acp_cli_args(validated) do
    args = Map.get(validated, :cli_args, [])
    yolo = Map.get(validated, :yolo, false)

    args =
      if yolo || Map.get(validated, :allow_all_tools, false),
        do: args ++ ["--allow-all-tools"],
        else: args

    args =
      if yolo || Map.get(validated, :allow_all_paths, false),
        do: args ++ ["--allow-all-paths"],
        else: args

    args =
      if yolo || Map.get(validated, :allow_all_urls, false),
        do: args ++ ["--allow-all-urls"],
        else: args

    model = Map.get(validated, :model)
    if model, do: args ++ ["--model", model], else: args
  end
end
