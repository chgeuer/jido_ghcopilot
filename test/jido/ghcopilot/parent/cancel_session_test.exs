defmodule Jido.GHCopilot.Parent.CancelSessionTest do
  use ExUnit.Case, async: true

  alias Jido.GHCopilot.Parent.CancelSession
  alias Jido.GHCopilot.Parent.SessionRegistry

  describe "run/2" do
    test "cancels session and emits stop_child directive" do
      sessions =
        SessionRegistry.init_sessions()
        |> SessionRegistry.register_session("sess-1", %{prompt: "hello"})
        |> SessionRegistry.update_session("sess-1", %{status: :running})

      params = %{session_tag: "sess-1"}
      context = %{agent: %{state: %{sessions: sessions}}}

      assert {:ok, state_update, directives} = CancelSession.run(params, context)

      entry = SessionRegistry.get_session(state_update.sessions, "sess-1")
      assert entry.status == :cancelled

      assert [directive] = directives
      assert directive.__struct__ == Jido.Agent.Directive.StopChild
    end
  end
end
