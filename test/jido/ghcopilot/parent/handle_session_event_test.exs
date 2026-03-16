defmodule Jido.GHCopilot.Parent.HandleSessionEventTest do
  use ExUnit.Case, async: true

  alias Jido.GHCopilot.Parent.HandleSessionEvent
  alias Jido.GHCopilot.Parent.SessionRegistry

  setup do
    sessions =
      SessionRegistry.init_sessions()
      |> SessionRegistry.register_session("sess-1", %{prompt: "hello"})

    %{sessions: sessions}
  end

  describe "run/2 with session.started" do
    test "updates status to running", %{sessions: sessions} do
      params = %{session_id: "sess-1", event_type: "ghcopilot.session.started", data: %{model: "opus"}}
      context = %{agent: %{state: %{sessions: sessions}}}

      assert {:ok, state_update} = HandleSessionEvent.run(params, context)
      entry = SessionRegistry.get_session(state_update.sessions, "sess-1")
      assert entry.status == :running
      assert entry.model == "opus"
    end
  end

  describe "run/2 with session.success" do
    test "updates status and records result", %{sessions: sessions} do
      params = %{
        session_id: "sess-1",
        event_type: "ghcopilot.session.success",
        data: %{result: "done", turns: 5, duration_ms: 1000}
      }

      context = %{agent: %{state: %{sessions: sessions}}}

      assert {:ok, state_update} = HandleSessionEvent.run(params, context)
      entry = SessionRegistry.get_session(state_update.sessions, "sess-1")
      assert entry.status == :success
      assert entry.result == "done"
      assert entry.turns == 5
    end
  end

  describe "run/2 with session.error" do
    test "updates status to failure", %{sessions: sessions} do
      params = %{
        session_id: "sess-1",
        event_type: "ghcopilot.session.error",
        data: %{error_type: "timeout", details: "took too long"}
      }

      context = %{agent: %{state: %{sessions: sessions}}}

      assert {:ok, state_update} = HandleSessionEvent.run(params, context)
      entry = SessionRegistry.get_session(state_update.sessions, "sess-1")
      assert entry.status == :failure
      assert entry.error.type == "timeout"
    end
  end

  describe "run/2 with child lifecycle" do
    test "records child_pid on child.started", %{sessions: sessions} do
      params = %{
        session_id: "sess-1",
        event_type: "jido.agent.child.started",
        data: %{pid: self()}
      }

      context = %{agent: %{state: %{sessions: sessions}}}

      assert {:ok, state_update} = HandleSessionEvent.run(params, context)
      entry = SessionRegistry.get_session(state_update.sessions, "sess-1")
      assert entry.child_pid == self()
    end

    test "marks failure on abnormal child exit", %{sessions: sessions} do
      params = %{
        session_id: "sess-1",
        event_type: "jido.agent.child.exit",
        data: %{reason: :killed}
      }

      context = %{agent: %{state: %{sessions: sessions}}}

      assert {:ok, state_update} = HandleSessionEvent.run(params, context)
      entry = SessionRegistry.get_session(state_update.sessions, "sess-1")
      assert entry.status == :failure
    end

    test "no-op on normal child exit", %{sessions: sessions} do
      params = %{
        session_id: "sess-1",
        event_type: "jido.agent.child.exit",
        data: %{reason: :normal}
      }

      context = %{agent: %{state: %{sessions: sessions}}}

      assert {:ok, state_update} = HandleSessionEvent.run(params, context)
      entry = SessionRegistry.get_session(state_update.sessions, "sess-1")
      assert entry.status == :starting
    end
  end

  describe "run/2 with unknown event" do
    test "no-op for unknown events", %{sessions: sessions} do
      params = %{session_id: "sess-1", event_type: "unknown.event", data: %{}}
      context = %{agent: %{state: %{sessions: sessions}}}

      assert {:ok, state_update} = HandleSessionEvent.run(params, context)
      entry = SessionRegistry.get_session(state_update.sessions, "sess-1")
      assert entry.status == :starting
    end
  end
end
