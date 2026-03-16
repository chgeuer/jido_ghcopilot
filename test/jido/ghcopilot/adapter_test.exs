defmodule Jido.GHCopilot.AdapterTest do
  use ExUnit.Case, async: false

  alias Jido.GHCopilot.{Adapter, SessionRegistry}
  alias Jido.GHCopilot.Test.StubCompatibility

  setup do
    old_compat_module = Application.get_env(:jido_ghcopilot, :compatibility_module)
    old_stub_compat_check = Application.get_env(:jido_ghcopilot, :stub_compat_check)

    Application.put_env(:jido_ghcopilot, :compatibility_module, StubCompatibility)
    Application.put_env(:jido_ghcopilot, :stub_compat_check, fn -> :ok end)

    SessionRegistry.clear()

    on_exit(fn ->
      restore_env(:jido_ghcopilot, :compatibility_module, old_compat_module)
      restore_env(:jido_ghcopilot, :stub_compat_check, old_stub_compat_check)
      SessionRegistry.clear()
    end)

    :ok
  end

  test "id/0 and capabilities/0" do
    assert Adapter.id() == :ghcopilot

    caps = Adapter.capabilities()
    assert caps.streaming? == true
    assert caps.tool_calls? == true
    assert caps.thinking? == true
    assert caps.cancellation? == true
    assert caps.resume? == true
  end

  test "run/2 returns error when compatibility fails" do
    Application.put_env(:jido_ghcopilot, :stub_compat_check, fn ->
      {:error, Jido.GHCopilot.Error.config_error("bad compat", %{key: :compat})}
    end)

    request = Jido.Harness.RunRequest.new!(%{prompt: "hello", metadata: %{}})
    assert {:error, %Jido.GHCopilot.Error.ConfigError{key: :compat}} = Adapter.run(request)
  end

  @tag timeout: to_timeout(second: 10)
  test "run/2 returns a stream on success" do
    # Use a script that ignores flags and just echoes output
    old_cli = Application.get_env(:jido_ghcopilot, :cli_module)

    Application.put_env(:jido_ghcopilot, :cli_module, Jido.GHCopilot.Test.StubScriptCLI)

    on_exit(fn -> restore_env(:jido_ghcopilot, :cli_module, old_cli) end)

    request = Jido.Harness.RunRequest.new!(%{prompt: "test output", metadata: %{}})
    assert {:ok, stream} = Adapter.run(request)

    events = Enum.to_list(stream)
    types = Enum.map(events, & &1.type)

    assert :session_started in types
    assert :session_completed in types or :session_failed in types
    assert Enum.all?(events, &(&1.provider == :ghcopilot))
  end

  test "cancel/1 returns error when unknown" do
    assert {:error, %Jido.GHCopilot.Error.ExecutionFailureError{}} = Adapter.cancel("missing")
  end

  test "cancel/1 validates non-string session ids" do
    assert {:error, %Jido.GHCopilot.Error.InvalidInputError{}} = Adapter.cancel(:bad)
  end

  test "cancel/1 validates empty string session ids" do
    assert {:error, %Jido.GHCopilot.Error.InvalidInputError{}} = Adapter.cancel("")
  end

  test "cancel/1 cancels registered session" do
    SessionRegistry.register("session-1", %{port: nil, port_pid: nil})
    assert :ok = Adapter.cancel("session-1")
    assert {:error, :not_found} = SessionRegistry.fetch("session-1")
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end

defmodule Jido.GHCopilot.Test.StubScriptCLI do
  @moduledoc false

  def resolve_path do
    script_path = Path.join(System.tmp_dir!(), "jido_ghcopilot_test_stub.sh")

    File.write!(script_path, """
    #!/bin/sh
    echo "Hello from stub"
    echo "Done"
    """)

    File.chmod!(script_path, 0o755)
    script_path
  end
end
