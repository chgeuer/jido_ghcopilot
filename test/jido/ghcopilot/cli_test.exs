defmodule Jido.GHCopilot.CLITest do
  use ExUnit.Case, async: false

  alias Jido.GHCopilot.CLI

  test "resolve_path finds copilot in PATH" do
    result = CLI.resolve_path()
    assert is_nil(result) or is_binary(result)
  end

  test "resolve_path respects COPILOT_CLI_PATH env" do
    old = System.get_env("COPILOT_CLI_PATH")

    on_exit(fn ->
      if is_nil(old), do: System.delete_env("COPILOT_CLI_PATH"), else: System.put_env("COPILOT_CLI_PATH", old)
    end)

    System.put_env("COPILOT_CLI_PATH", "/usr/bin/true")
    assert CLI.resolve_path() == "/usr/bin/true"
  end

  test "resolve_path returns nil for nonexistent COPILOT_CLI_PATH" do
    old = System.get_env("COPILOT_CLI_PATH")

    on_exit(fn ->
      if is_nil(old), do: System.delete_env("COPILOT_CLI_PATH"), else: System.put_env("COPILOT_CLI_PATH", old)
    end)

    System.put_env("COPILOT_CLI_PATH", "/definitely/not/a/real/path")
    result = CLI.resolve_path()
    assert result != "/definitely/not/a/real/path"
  end
end
