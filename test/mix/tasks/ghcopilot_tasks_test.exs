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
    setup do
      old_cli = Application.get_env(:jido_ghcopilot, :cli_module)
      old_cmd = Application.get_env(:jido_ghcopilot, :command_module)

      Application.put_env(:jido_ghcopilot, :cli_module, Jido.GHCopilot.Test.StubCLI)
      Application.put_env(:jido_ghcopilot, :command_module, Jido.GHCopilot.Test.StubCommand)

      on_exit(fn ->
        if old_cli,
          do: Application.put_env(:jido_ghcopilot, :cli_module, old_cli),
          else: Application.delete_env(:jido_ghcopilot, :cli_module)

        if old_cmd,
          do: Application.put_env(:jido_ghcopilot, :command_module, old_cmd),
          else: Application.delete_env(:jido_ghcopilot, :command_module)
      end)

      :ok
    end

    test "reports CLI found" do
      output = capture_task(fn -> Mix.Tasks.Ghcopilot.Compat.run([]) end)
      assert output =~ "Copilot CLI"
    end

    test "reports CLI not found" do
      Application.put_env(:jido_ghcopilot, :stub_cli_resolve_path, fn -> nil end)
      on_exit(fn -> Application.delete_env(:jido_ghcopilot, :stub_cli_resolve_path) end)

      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          Mix.Tasks.Ghcopilot.Compat.run([])
        end)

      assert stderr =~ "Copilot CLI not found"
    end
  end

  defp capture_task(fun) do
    ExUnit.CaptureIO.capture_io(fun)
  end
end
