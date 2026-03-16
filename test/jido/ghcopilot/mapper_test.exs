defmodule Jido.GHCopilot.MapperTest do
  use ExUnit.Case, async: true

  alias Jido.GHCopilot.Mapper

  test "maps regular output text" do
    assert {:ok, [event]} = Mapper.map_line("Hello world", "session-1")
    assert event.type == :output_text_delta
    assert event.provider == :ghcopilot
    assert event.session_id == "session-1"
    assert event.payload["text"] == "Hello world"
  end

  test "maps error lines" do
    assert {:ok, [event]} = Mapper.map_line("Error: something failed", "session-1")
    assert event.type == :ghcopilot_error
    assert event.payload["text"] == "Error: something failed"

    assert {:ok, [event2]} = Mapper.map_line("error: lowercase error", "session-1")
    assert event2.type == :ghcopilot_error
  end

  test "maps warning lines" do
    assert {:ok, [event]} = Mapper.map_line("Warning: deprecation notice", "session-1")
    assert event.type == :ghcopilot_warning

    assert {:ok, [event2]} = Mapper.map_line("warning: lowercase warning", "session-1")
    assert event2.type == :ghcopilot_warning
  end

  test "maps separator lines" do
    assert {:ok, [event]} = Mapper.map_line("─────────", "session-1")
    assert event.type == :ghcopilot_separator

    assert {:ok, [event2]} = Mapper.map_line("━━━━━━━━━", "session-1")
    assert event2.type == :ghcopilot_separator
  end

  test "maps status indicator lines" do
    assert {:ok, [event]} = Mapper.map_line("● Running tests", "session-1")
    assert event.type == :ghcopilot_status

    assert {:ok, [event2]} = Mapper.map_line("◐ Loading...", "session-1")
    assert event2.type == :ghcopilot_status
  end

  test "maps file change summary lines" do
    assert {:ok, [event]} = Mapper.map_line(" 3 files changed", "session-1")
    assert event.type == :ghcopilot_file_change_summary

    assert {:ok, [event2]} = Mapper.map_line(" 10 insertions(+)", "session-1")
    assert event2.type == :ghcopilot_file_change_summary
  end

  test "skips empty lines" do
    assert {:ok, []} = Mapper.map_line("", "session-1")
    assert {:ok, []} = Mapper.map_line("   ", "session-1")
  end

  test "returns error for invalid input" do
    assert {:error, :invalid_input} = Mapper.map_line(nil, "session-1")
    assert {:error, :invalid_input} = Mapper.map_line("hello", nil)
  end
end
