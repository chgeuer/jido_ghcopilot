defmodule Jido.GHCopilot.Parent.SessionRegistryTest do
  use ExUnit.Case, async: true

  alias Jido.GHCopilot.Parent.SessionRegistry

  describe "init_sessions/0" do
    test "returns empty map" do
      assert SessionRegistry.init_sessions() == %{}
    end
  end

  describe "register_session/3" do
    test "registers a session with defaults" do
      sessions = SessionRegistry.init_sessions()
      sessions = SessionRegistry.register_session(sessions, "sess-1", %{prompt: "hello"})

      entry = SessionRegistry.get_session(sessions, "sess-1")
      assert entry.session_id == "sess-1"
      assert entry.status == :starting
      assert entry.prompt == "hello"
      assert entry.turns == 0
    end
  end

  describe "update_session/3" do
    test "updates session fields" do
      sessions =
        SessionRegistry.init_sessions()
        |> SessionRegistry.register_session("sess-1")
        |> SessionRegistry.update_session("sess-1", %{status: :running, turns: 3})

      entry = SessionRegistry.get_session(sessions, "sess-1")
      assert entry.status == :running
      assert entry.turns == 3
    end

    test "sets completed_at on terminal status" do
      sessions =
        SessionRegistry.init_sessions()
        |> SessionRegistry.register_session("sess-1")
        |> SessionRegistry.update_session("sess-1", %{status: :success})

      entry = SessionRegistry.get_session(sessions, "sess-1")
      assert entry.completed_at != nil
    end
  end

  describe "active_sessions/1" do
    test "returns only non-terminal sessions" do
      sessions =
        SessionRegistry.init_sessions()
        |> SessionRegistry.register_session("s1")
        |> SessionRegistry.register_session("s2")
        |> SessionRegistry.update_session("s1", %{status: :running})
        |> SessionRegistry.update_session("s2", %{status: :success})

      active = SessionRegistry.active_sessions(sessions)
      assert length(active) == 1
      assert hd(active).session_id == "s1"
    end
  end

  describe "count_by_status/1" do
    test "groups and counts" do
      sessions =
        SessionRegistry.init_sessions()
        |> SessionRegistry.register_session("s1")
        |> SessionRegistry.register_session("s2")
        |> SessionRegistry.register_session("s3")
        |> SessionRegistry.update_session("s1", %{status: :running})
        |> SessionRegistry.update_session("s2", %{status: :success})

      counts = SessionRegistry.count_by_status(sessions)
      assert counts[:starting] == 1
      assert counts[:running] == 1
      assert counts[:success] == 1
    end
  end
end
