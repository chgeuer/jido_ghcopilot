defmodule Jido.GHCopilot.SystemCommandTest do
  use ExUnit.Case, async: true

  alias Jido.GHCopilot.SystemCommand

  test "run/3 returns output on success" do
    assert {:ok, output} = SystemCommand.run("echo", ["hello"])
    assert output =~ "hello"
  end

  test "run/3 returns error on non-zero exit" do
    assert {:error, %{status: status}} = SystemCommand.run("sh", ["-c", "exit 3"])
    assert status == 3
  end

  test "run/3 returns error when command cannot execute" do
    assert {:error, _} = SystemCommand.run("/definitely/not/a/program", [])
  end

  test "run/3 returns timeout errors" do
    assert {:error, %{status: :timeout}} = SystemCommand.run("sh", ["-c", "sleep 1"], timeout: 1)
  end
end
