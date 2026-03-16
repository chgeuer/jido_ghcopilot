defmodule Jido.GHCopilot.SessionRegistryTest do
  use ExUnit.Case, async: false

  alias Jido.GHCopilot.SessionRegistry

  setup do
    SessionRegistry.clear()
    :ok
  end

  test "registers and fetches entries" do
    assert :ok = SessionRegistry.register("s1", %{port: nil, port_pid: nil})
    assert {:ok, entry} = SessionRegistry.fetch("s1")
    assert entry.port == nil
  end

  test "returns not_found for unknown sessions" do
    assert {:error, :not_found} = SessionRegistry.fetch("missing")
  end

  test "deletes entries" do
    SessionRegistry.register("s1", %{port: nil, port_pid: nil})
    assert :ok = SessionRegistry.delete("s1")
    assert {:error, :not_found} = SessionRegistry.fetch("s1")
  end

  test "clear removes all entries" do
    SessionRegistry.register("a", %{port: nil, port_pid: nil})
    SessionRegistry.register("b", %{port: nil, port_pid: nil})
    assert length(SessionRegistry.list()) == 2
    SessionRegistry.clear()
    assert SessionRegistry.list() == []
  end
end
