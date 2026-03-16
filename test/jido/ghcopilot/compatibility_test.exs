defmodule Jido.GHCopilot.CompatibilityTest do
  use ExUnit.Case, async: false

  alias Jido.GHCopilot.Compatibility
  alias Jido.GHCopilot.Error.ConfigError
  alias Jido.GHCopilot.Test.{StubCLI, StubCommand}

  setup do
    old_cli_module = Application.get_env(:jido_ghcopilot, :cli_module)
    old_command_module = Application.get_env(:jido_ghcopilot, :command_module)
    old_cli_resolve = Application.get_env(:jido_ghcopilot, :stub_cli_resolve_path)
    old_command_run = Application.get_env(:jido_ghcopilot, :stub_command_run)

    Application.put_env(:jido_ghcopilot, :cli_module, StubCLI)
    Application.put_env(:jido_ghcopilot, :command_module, StubCommand)

    on_exit(fn ->
      restore_env(:jido_ghcopilot, :cli_module, old_cli_module)
      restore_env(:jido_ghcopilot, :command_module, old_command_module)
      restore_env(:jido_ghcopilot, :stub_cli_resolve_path, old_cli_resolve)
      restore_env(:jido_ghcopilot, :stub_command_run, old_command_run)
    end)

    :ok
  end

  test "returns error when CLI is missing" do
    Application.put_env(:jido_ghcopilot, :stub_cli_resolve_path, fn -> nil end)

    assert {:error, %ConfigError{key: :ghcopilot_cli}} = Compatibility.status()
    assert Compatibility.compatible?() == false
    assert {:error, %ConfigError{key: :ghcopilot_cli}} = Compatibility.check()
  end

  test "checks prompt compatibility tokens" do
    Application.put_env(:jido_ghcopilot, :stub_cli_resolve_path, fn -> "/tmp/copilot" end)

    Application.put_env(:jido_ghcopilot, :stub_command_run, fn
      _program, ["--help"], _opts -> {:ok, "copilot -p --prompt --allow-all-tools --model"}
      _program, ["--version"], _opts -> {:ok, "GitHub Copilot CLI 0.0.412-0"}
      _program, _args, _opts -> {:ok, "ok"}
    end)

    assert {:ok, status} = Compatibility.status()
    assert status.version =~ "0.0.412-0"
    assert Compatibility.check() == :ok
    assert Compatibility.assert_compatible!() == :ok
  end

  test "returns compatibility error when required tokens are missing" do
    Application.put_env(:jido_ghcopilot, :stub_cli_resolve_path, fn -> "/tmp/copilot" end)

    Application.put_env(:jido_ghcopilot, :stub_command_run, fn
      _program, ["--help"], _opts -> {:ok, "copilot --version"}
      _program, _args, _opts -> {:ok, "ok"}
    end)

    assert {:error, %ConfigError{key: :ghcopilot_cli_prompt_support}} = Compatibility.status()
  end

  test "returns error when help output cannot be read" do
    Application.put_env(:jido_ghcopilot, :stub_cli_resolve_path, fn -> "/tmp/copilot" end)

    Application.put_env(:jido_ghcopilot, :stub_command_run, fn
      _program, ["--help"], _opts -> {:error, :boom}
      _program, _args, _opts -> {:ok, "ok"}
    end)

    assert {:error, %ConfigError{key: :ghcopilot_cli_help}} = Compatibility.status()
  end

  test "returns unknown version when version command fails" do
    Application.put_env(:jido_ghcopilot, :stub_cli_resolve_path, fn -> "/tmp/copilot" end)

    Application.put_env(:jido_ghcopilot, :stub_command_run, fn
      _program, ["--help"], _opts -> {:ok, "copilot -p --prompt"}
      _program, ["--version"], _opts -> {:error, :boom}
      _program, _args, _opts -> {:ok, "ok"}
    end)

    assert {:ok, status} = Compatibility.status()
    assert status.version == "unknown"
  end

  test "assert_compatible!/0 raises on missing CLI" do
    Application.put_env(:jido_ghcopilot, :stub_cli_resolve_path, fn -> nil end)

    assert_raise ConfigError, fn ->
      Compatibility.assert_compatible!()
    end
  end

  test "cli_installed?/0 returns true when CLI found" do
    Application.put_env(:jido_ghcopilot, :stub_cli_resolve_path, fn -> "/tmp/copilot" end)
    assert Compatibility.cli_installed?() == true
  end

  test "cli_installed?/0 returns false when CLI missing" do
    Application.put_env(:jido_ghcopilot, :stub_cli_resolve_path, fn -> nil end)
    assert Compatibility.cli_installed?() == false
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
