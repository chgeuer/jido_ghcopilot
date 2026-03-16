defmodule Jido.GHCopilotTest do
  use ExUnit.Case

  alias Jido.GHCopilot.Test.StubAdapter

  setup do
    old_adapter_module = Application.get_env(:jido_ghcopilot, :adapter_module)
    old_adapter_run = Application.get_env(:jido_ghcopilot, :stub_adapter_run)
    old_adapter_cancel = Application.get_env(:jido_ghcopilot, :stub_adapter_cancel)
    old_cli_module = Application.get_env(:jido_ghcopilot, :cli_module)
    old_command_module = Application.get_env(:jido_ghcopilot, :command_module)
    old_cli_resolve = Application.get_env(:jido_ghcopilot, :stub_cli_resolve_path)
    old_command_run = Application.get_env(:jido_ghcopilot, :stub_command_run)

    Application.put_env(:jido_ghcopilot, :adapter_module, StubAdapter)
    Application.put_env(:jido_ghcopilot, :cli_module, Jido.GHCopilot.Test.StubCLI)
    Application.put_env(:jido_ghcopilot, :command_module, Jido.GHCopilot.Test.StubCommand)

    on_exit(fn ->
      restore_env(:jido_ghcopilot, :adapter_module, old_adapter_module)
      restore_env(:jido_ghcopilot, :stub_adapter_run, old_adapter_run)
      restore_env(:jido_ghcopilot, :stub_adapter_cancel, old_adapter_cancel)
      restore_env(:jido_ghcopilot, :cli_module, old_cli_module)
      restore_env(:jido_ghcopilot, :command_module, old_command_module)
      restore_env(:jido_ghcopilot, :stub_cli_resolve_path, old_cli_resolve)
      restore_env(:jido_ghcopilot, :stub_command_run, old_command_run)
    end)

    :ok
  end

  test "version/0 returns semver string" do
    assert is_binary(Jido.GHCopilot.version())
    assert Jido.GHCopilot.version() =~ ~r/^\d+\.\d+\.\d+$/
  end

  test "run/2 builds run request and delegates to adapter" do
    Application.put_env(:jido_ghcopilot, :stub_adapter_run, fn request, opts ->
      send(self(), {:adapter_run, request, opts})
      {:ok, []}
    end)

    assert {:ok, []} = Jido.GHCopilot.run("hello", cwd: "/tmp")

    assert_receive {:adapter_run, request, opts}
    assert request.prompt == "hello"
    assert request.cwd == "/tmp"
    assert opts == []
  end

  test "run_request/2 delegates directly to adapter" do
    request = Jido.Harness.RunRequest.new!(%{prompt: "hello", metadata: %{}})

    Application.put_env(:jido_ghcopilot, :stub_adapter_run, fn ^request, opts ->
      send(self(), {:adapter_run_request, opts})
      {:ok, []}
    end)

    assert {:ok, []} = Jido.GHCopilot.run_request(request, foo: :bar)
    assert_receive {:adapter_run_request, [foo: :bar]}
  end

  test "cancel/1 delegates to adapter" do
    Application.put_env(:jido_ghcopilot, :stub_adapter_cancel, fn session_id ->
      send(self(), {:adapter_cancel, session_id})
      :ok
    end)

    assert :ok = Jido.GHCopilot.cancel("session-1")
    assert_receive {:adapter_cancel, "session-1"}
  end

  test "compatibility helpers delegate through compatibility module behavior" do
    Application.put_env(:jido_ghcopilot, :stub_cli_resolve_path, fn -> "/tmp/copilot" end)

    Application.put_env(:jido_ghcopilot, :stub_command_run, fn
      _program, ["--help"], _opts -> {:ok, "-p --prompt --allow-all-tools"}
      _program, ["--version"], _opts -> {:ok, "0.0.412-0"}
      _program, _args, _opts -> {:ok, "ok"}
    end)

    assert Jido.GHCopilot.cli_installed?() == true
    assert Jido.GHCopilot.compatible?() == true
    assert :ok = Jido.GHCopilot.assert_compatible!()
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
