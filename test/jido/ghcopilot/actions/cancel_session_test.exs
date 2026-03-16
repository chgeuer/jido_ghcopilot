defmodule Jido.GHCopilot.Actions.CancelSessionTest do
  use ExUnit.Case

  alias Jido.GHCopilot.Test.StubExecutor
  alias Jido.GHCopilot.Actions.CancelSession

  describe "run/2 with executor" do
    test "calls executor cancel with runner_ref" do
      runner_ref = %{pid: self(), marker: :test}

      params = %{}

      context = [
        agent: %{
          state: %{
            executor_module: StubExecutor,
            runner_ref: runner_ref,
            session_id: "sess-1"
          }
        }
      ]

      {:ok, state, _directives} = CancelSession.run(params, context)

      assert state.status == :cancelled
      assert_receive {:stub_executor_cancelled, ^runner_ref}
    end
  end

  describe "run/2 without executor" do
    test "returns cancelled status" do
      params = %{}

      context = [
        agent: %{
          state: %{
            executor_module: nil,
            runner_ref: nil,
            session_id: "sess-1"
          }
        }
      ]

      {:ok, state, _directives} = CancelSession.run(params, context)
      assert state.status == :cancelled
    end
  end
end
