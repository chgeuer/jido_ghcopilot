defmodule Jido.GHCopilot.Mapper do
  @moduledoc """
  Maps GitHub Copilot CLI output lines into normalized `Jido.Harness.Event` structs.

  The Copilot CLI outputs plain text (no structured JSON stream), so we parse
  output lines and classify them into event types.
  """

  alias Jido.Harness.Event

  @doc """
  Maps a single output line from the Copilot CLI to normalized events.

  Returns `{:ok, [Event.t()]}` or `{:error, reason}`.
  """
  @spec map_line(String.t(), String.t()) :: {:ok, [Event.t()]} | {:error, term()}
  def map_line(line, session_id) when is_binary(line) and is_binary(session_id) do
    trimmed = String.trim(line)

    if trimmed == "" do
      {:ok, []}
    else
      {:ok, [build_event(classify_line(trimmed), session_id, trimmed)]}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  def map_line(_, _), do: {:error, :invalid_input}

  defp classify_line("Error:" <> _), do: :error_text
  defp classify_line("error:" <> _), do: :error_text
  defp classify_line("Warning:" <> _), do: :warning_text
  defp classify_line("warning:" <> _), do: :warning_text

  defp classify_line(line) do
    cond do
      String.starts_with?(line, "─") or String.starts_with?(line, "━") ->
        :separator

      String.starts_with?(line, "●") or String.starts_with?(line, "◐") ->
        :status_indicator

      String.match?(line, ~r/^\s*\d+\s+(file|insertion|deletion)/) ->
        :file_change_summary

      true ->
        :output_text
    end
  end

  defp build_event(:error_text, session_id, text) do
    Event.new!(%{
      type: :ghcopilot_error,
      provider: :ghcopilot,
      session_id: session_id,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      payload: %{"text" => text},
      raw: text
    })
  end

  defp build_event(:warning_text, session_id, text) do
    Event.new!(%{
      type: :ghcopilot_warning,
      provider: :ghcopilot,
      session_id: session_id,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      payload: %{"text" => text},
      raw: text
    })
  end

  defp build_event(:separator, session_id, text) do
    Event.new!(%{
      type: :ghcopilot_separator,
      provider: :ghcopilot,
      session_id: session_id,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      payload: %{"text" => text},
      raw: text
    })
  end

  defp build_event(:status_indicator, session_id, text) do
    Event.new!(%{
      type: :ghcopilot_status,
      provider: :ghcopilot,
      session_id: session_id,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      payload: %{"text" => text},
      raw: text
    })
  end

  defp build_event(:file_change_summary, session_id, text) do
    Event.new!(%{
      type: :ghcopilot_file_change_summary,
      provider: :ghcopilot,
      session_id: session_id,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      payload: %{"text" => text},
      raw: text
    })
  end

  defp build_event(:output_text, session_id, text) do
    Event.new!(%{
      type: :output_text_delta,
      provider: :ghcopilot,
      session_id: session_id,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      payload: %{"text" => text},
      raw: text
    })
  end
end
