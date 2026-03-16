defmodule Jido.GHCopilot.Parent.SpawnSessionTest do
  use ExUnit.Case, async: true

  alias Jido.GHCopilot.Parent.SpawnSession
  alias Jido.GHCopilot.Parent.SessionRegistry

  describe "run/2" do
    test "registers session and returns spawn directive" do
      params = %{
        prompt: "Analyze this code",
        model: "claude-opus-4.6",
        cwd: nil,
        session_tag: "test-session-1",
        timeout_ms: to_timeout(minute: 5)
      }

      context = %{agent: %{state: %{sessions: SessionRegistry.init_sessions()}}}

      assert {:ok, state_update, directives} = SpawnSession.run(params, context)

      # State should contain updated sessions
      assert is_map(state_update.sessions)
      entry = SessionRegistry.get_session(state_update.sessions, "test-session-1")
      assert entry.status == :starting
      assert entry.prompt == "Analyze this code"
      assert entry.model == "claude-opus-4.6"

      # Should emit a spawn directive
      assert [directive] = directives
      assert directive.__struct__ == Jido.Agent.Directive.SpawnAgent
    end

    test "auto-generates session_tag when nil" do
      params = %{
        prompt: "hello",
        model: nil,
        cwd: nil,
        session_tag: nil,
        timeout_ms: to_timeout(minute: 10)
      }

      context = %{agent: nil}

      assert {:ok, state_update, [_directive]} = SpawnSession.run(params, context)
      assert map_size(state_update.sessions) == 1
      [{tag, _}] = Map.to_list(state_update.sessions)
      assert String.starts_with?(tag, "ghcopilot-")
    end
  end
end
