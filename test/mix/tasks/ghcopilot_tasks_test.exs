defmodule Mix.Tasks.GhcopilotTasksTest do
  use ExUnit.Case

  describe "mix ghcopilot.models" do
    test "lists all models" do
      output = capture_task(fn -> Mix.Tasks.Ghcopilot.Models.run([]) end)
      assert output =~ "Claude Opus 4.6"
      assert output =~ "claude-opus-4.6"
      assert output =~ "GPT-5"
      assert output =~ ~r/\d+ models/
    end

    test "filters with --search" do
      output = capture_task(fn -> Mix.Tasks.Ghcopilot.Models.run(["--search", "opus"]) end)
      assert output =~ "Opus"
      refute output =~ "Haiku"
    end

    test "resolves with --resolve" do
      output = capture_task(fn -> Mix.Tasks.Ghcopilot.Models.run(["--resolve", "gemini"]) end)
      assert output =~ "gemini-3-pro-preview"
    end

    test "resolve failure shows error" do
      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          _stdout = capture_task(fn -> Mix.Tasks.Ghcopilot.Models.run(["--resolve", "nonexistent-xyz"]) end)
        end)

      assert stderr =~ "Unknown model"
    end

    test "ids-only mode" do
      output = capture_task(fn -> Mix.Tasks.Ghcopilot.Models.run(["--ids"]) end)
      assert output =~ "claude-opus-4.6"
      refute output =~ "Claude Opus"
    end

    test "ids with search" do
      output = capture_task(fn -> Mix.Tasks.Ghcopilot.Models.run(["--ids", "-s", "gpt-5.1"]) end)
      lines = String.split(String.trim(output), "\n")
      assert length(lines) >= 3
      assert Enum.all?(lines, &String.starts_with?(&1, "gpt-5.1"))
    end

    test "no match shows message" do
      output = capture_task(fn -> Mix.Tasks.Ghcopilot.Models.run(["--search", "zzz-no-match"]) end)
      assert output =~ "No models match"
    end
  end

  describe "mix ghcopilot.compat" do
    test "reports CLI status" do
      output = capture_task(fn -> Mix.Tasks.Ghcopilot.Compat.run([]) end)
      # Should either find it or not — both are valid outcomes
      assert output =~ "Copilot CLI" or output =~ "copilot"
    end
  end

  defp capture_task(fun) do
    ExUnit.CaptureIO.capture_io(fun)
  end
end
