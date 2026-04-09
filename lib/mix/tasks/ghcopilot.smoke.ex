defmodule Mix.Tasks.Ghcopilot.Smoke do
  @moduledoc """
  Execute a minimal GitHub Copilot prompt for smoke validation.

      mix ghcopilot.smoke
      mix ghcopilot.smoke "What is 2+2?"
      mix ghcopilot.smoke --model claude-sonnet-4.6
      mix ghcopilot.smoke --server   # use CLI Server protocol (shows token usage)
      mix ghcopilot.smoke --model gpt-5-mini --timeout 30000

  Sends a trivial prompt through the full ACP pipeline and reports
  whether the round-trip succeeded. Useful for verifying auth tokens,
  CLI communication, and model access after setup.

  ## Options

    * `--model` / `-m` — model to test with (default: let CLI choose)
    * `--timeout` / `-t` — timeout in milliseconds (default: 60000)
    * `--server` / `-s` — use CLI Server protocol (enables usage/token reporting)
  """

  @shortdoc "Run a minimal Copilot smoke prompt"

  use Mix.Task

  @switches [model: :string, timeout: :integer, server: :boolean]
  @aliases [m: :model, t: :timeout, s: :server]

  @default_prompt "Respond with exactly: SMOKE_OK"
  @default_timeout 60_000

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, positional, _invalid} = OptionParser.parse(args, strict: @switches, aliases: @aliases)

    prompt = List.first(positional) || @default_prompt
    timeout = opts[:timeout] || @default_timeout
    use_server = opts[:server] || false

    # Build session opts
    session_opts =
      [yolo: true]
      |> maybe_put(:model, opts[:model])

    protocol = if use_server, do: "Server", else: "ACP"
    Mix.shell().info(["☁ ", :bright, "Starting Copilot smoke test (#{protocol})...", :reset])

    if opts[:model] do
      Mix.shell().info(["  Model: ", opts[:model]])
    end

    Mix.shell().info(["  Prompt: ", prompt, "\n"])

    start_time = System.monotonic_time(:millisecond)

    result =
      if use_server do
        run_smoke_server(session_opts, prompt, timeout)
      else
        run_smoke_acp(session_opts, prompt, timeout)
      end

    case result do
      {:ok, %{message: message, thinking: thinking, events: events, usage: usage}} ->
        elapsed = System.monotonic_time(:millisecond) - start_time
        response = if message != "", do: message, else: thinking
        label = if message != "", do: "Response", else: "Thinking"

        lines = [
          :green,
          "✓ ",
          :reset,
          "Smoke test passed in #{elapsed}ms\n",
          "  Events: #{Enum.map_join(events, ", ", fn {k, v} -> "#{k}=#{v}" end)}\n"
        ]

        lines = lines ++ format_usage(usage)

        lines = lines ++ ["  #{label}: ", String.slice(String.trim(response), 0, 300)]

        Mix.shell().info(lines)

      {:error, reason} ->
        elapsed = System.monotonic_time(:millisecond) - start_time

        Mix.shell().error("""
        ✗ Smoke test failed after #{elapsed}ms

          #{format_error(reason)}
        """)

        System.halt(1)
    end
  end

  # ── ACP mode (original) ──

  defp run_smoke_acp(session_opts, prompt, timeout) do
    alias Jido.GHCopilot.ACP.Connection

    with {:ok, conn, session_id} <- Jido.GHCopilot.start_session(session_opts) do
      :ok = Connection.subscribe(conn, session_id)

      case Connection.prompt(conn, session_id, prompt, timeout) do
        {:ok, _stop_reason} ->
          result = drain_acp_events()
          Connection.stop(conn)
          {:ok, result}

        {:error, reason} ->
          Connection.stop(conn)
          {:error, reason}
      end
    end
  end

  # ── Server mode (with usage data) ──

  defp run_smoke_server(session_opts, prompt, timeout) do
    alias Jido.GHCopilot.Server.Connection

    cli_args =
      ["--allow-all-tools"]
      |> maybe_append("--model", session_opts[:model])

    with {:ok, conn} <- Connection.start_link(cli_args: cli_args),
         {:ok, session_id} <- Connection.create_session(conn, %{model: session_opts[:model]}) do
      :ok = Connection.subscribe(conn, session_id)

      case Connection.send_prompt(conn, session_id, prompt, %{}, timeout) do
        {:ok, _message_id} ->
          result = drain_server_events(session_id, timeout)
          Connection.stop(conn)
          {:ok, result}

        {:error, reason} ->
          Connection.stop(conn)
          {:error, reason}
      end
    end
  end

  # ── Event draining ──

  defp drain_acp_events do
    drain_acp_events(%{message: "", thinking: "", events: %{}, usage: []})
  end

  defp drain_acp_events(acc) do
    receive do
      {:connection_event, _sid, %{update_type: type, data: data}} ->
        type_str = to_string(type)
        acc = update_in(acc.events, &Map.update(&1, type_str, 1, fn n -> n + 1 end))

        acc =
          case type do
            :agent_message_chunk ->
              chunk = extract_text(data)
              %{acc | message: acc.message <> chunk}

            :agent_thought_chunk ->
              chunk = extract_text(data)
              %{acc | thinking: acc.thinking <> chunk}

            _ ->
              acc
          end

        drain_acp_events(acc)
    after
      200 ->
        acc
    end
  end

  defp drain_server_events(session_id, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_drain_server(%{message: "", thinking: "", events: %{}, usage: []}, session_id, deadline)
  end

  defp do_drain_server(acc, session_id, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      acc
    else
      wait_ms = min(remaining, 500)

      receive do
        {:connection_event, _sid, %{session_id: ^session_id, type: type, data: data}} ->
          acc = update_in(acc.events, &Map.update(&1, type, 1, fn n -> n + 1 end))

          acc =
            case type do
              "assistant.message" ->
                chunk = data["chunkContent"] || data["content"] || ""
                %{acc | message: acc.message <> chunk}

              "assistant.reasoning" ->
                chunk = data["chunkContent"] || data["content"] || ""
                %{acc | thinking: acc.thinking <> chunk}

              "assistant.usage" ->
                usage_entry = %{
                  model: data["model"],
                  input_tokens: data["inputTokens"] || 0,
                  output_tokens: data["outputTokens"] || 0,
                  cache_read_tokens: data["cacheReadTokens"] || 0,
                  cache_write_tokens: data["cacheWriteTokens"] || 0,
                  cost: data["cost"],
                  duration_ms: data["duration"]
                }

                %{acc | usage: acc.usage ++ [usage_entry]}

              "session.idle" ->
                drain_remaining_server(acc, session_id)

              _ ->
                acc
            end

          if type == "session.idle" do
            acc
          else
            do_drain_server(acc, session_id, deadline)
          end
      after
        wait_ms ->
          do_drain_server(acc, session_id, deadline)
      end
    end
  end

  defp drain_remaining_server(acc, session_id) do
    receive do
      {:connection_event, _sid, %{session_id: ^session_id, type: "assistant.usage", data: data}} ->
        usage_entry = %{
          model: data["model"],
          input_tokens: data["inputTokens"] || 0,
          output_tokens: data["outputTokens"] || 0,
          cache_read_tokens: data["cacheReadTokens"] || 0,
          cache_write_tokens: data["cacheWriteTokens"] || 0,
          cost: data["cost"],
          duration_ms: data["duration"]
        }

        drain_remaining_server(%{acc | usage: acc.usage ++ [usage_entry]}, session_id)

      {:connection_event, _sid, %{session_id: ^session_id}} ->
        drain_remaining_server(acc, session_id)
    after
      300 ->
        acc
    end
  end

  # ── Formatting ──

  defp format_usage([]), do: []

  defp format_usage(usage_list) do
    total_in = Enum.sum(Enum.map(usage_list, & &1.input_tokens))
    total_out = Enum.sum(Enum.map(usage_list, & &1.output_tokens))
    total_cache = Enum.sum(Enum.map(usage_list, & &1.cache_read_tokens))
    models = usage_list |> Enum.map(& &1.model) |> Enum.uniq() |> Enum.reject(&is_nil/1)
    calls = length(usage_list)

    cost_parts =
      usage_list
      |> Enum.map(& &1.cost)
      |> Enum.reject(&is_nil/1)

    duration_parts =
      usage_list
      |> Enum.map(& &1.duration_ms)
      |> Enum.reject(&is_nil/1)

    lines = [
      "  Tokens: ",
      :cyan,
      "#{total_in}",
      :reset,
      " in → ",
      :cyan,
      "#{total_out}",
      :reset,
      " out"
    ]

    lines = if total_cache > 0, do: lines ++ [" (", :cyan, "#{total_cache}", :reset, " cached)"], else: lines

    lines = lines ++ [" across ", :cyan, "#{calls}", :reset, " model call#{if calls != 1, do: "s", else: ""}"]

    lines =
      if cost_parts != [] do
        total_cost = Enum.sum(cost_parts)
        lines ++ [", cost multiplier: ", :yellow, "#{total_cost}", :reset]
      else
        lines
      end

    lines =
      if duration_parts != [] do
        total_dur = Enum.sum(duration_parts)
        lines ++ [", duration: ", "#{round(total_dur)}ms"]
      else
        lines
      end

    lines = lines ++ ["\n"]

    if models != [] do
      lines ++ ["  Model: ", Enum.join(models, ", "), "\n"]
    else
      lines
    end
  end

  # ── Helpers ──

  defp extract_text(%{text: text}) when is_binary(text), do: text
  defp extract_text(%{content: content}) when is_binary(content), do: content
  defp extract_text(_), do: ""

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp maybe_append(args, _flag, nil), do: args
  defp maybe_append(args, flag, value), do: args ++ [flag, value]

  defp format_error(%{message: msg}) when is_binary(msg), do: msg
  defp format_error(reason), do: inspect(reason)
end
