defmodule Jido.GHCopilot.StreamRunner do
  @moduledoc """
  Task that subscribes to ACP Connection updates for a session and
  dispatches them as `ghcopilot.internal.message` signals to the
  SessionAgent.
  """

  require Logger

  @doc """
  Run the stream runner. Subscribes to ACP updates and dispatches
  them as signals to the agent process.

  Called via `Task.start/1` from StartSession action.
  """
  def run(agent_pid, acp_connection, session_id, prompt, timeout_ms \\ to_timeout(minute: 10)) do
    # Subscribe to ACP updates for this session
    :ok = Jido.GHCopilot.ACP.Connection.subscribe(acp_connection, session_id)

    # Send the prompt
    case Jido.GHCopilot.ACP.Connection.prompt(acp_connection, session_id, prompt, timeout_ms) do
      {:ok, stop_reason} ->
        # Prompt completed — dispatch completion signal
        dispatch_completion(agent_pid, session_id, stop_reason)

      {:error, reason} ->
        Logger.error("ACP prompt failed for session #{session_id}: #{inspect(reason)}")
        dispatch_error(agent_pid, session_id, reason)
    end
  after
    # Always unsubscribe
    if Process.alive?(acp_connection) do
      Jido.GHCopilot.ACP.Connection.unsubscribe(acp_connection, session_id)
    end
  rescue
    e ->
      Logger.error("StreamRunner crash: #{Exception.message(e)}")
      dispatch_error(agent_pid, session_id, Exception.message(e))
  end

  @doc """
  Called by the process receiving {:acp_update, update} messages.
  The StreamRunner process receives these because it called subscribe/2.
  We set up a receive loop to forward them as signals.
  """
  def run_with_forwarding(agent_pid, acp_connection, session_id, prompt, timeout_ms \\ to_timeout(minute: 10)) do
    # Subscribe — this process will receive {:acp_update, ...} messages
    :ok = Jido.GHCopilot.ACP.Connection.subscribe(acp_connection, session_id)

    # Start prompt in a separate task so we can receive updates concurrently
    prompt_task =
      Task.async(fn ->
        Jido.GHCopilot.ACP.Connection.prompt(acp_connection, session_id, prompt, timeout_ms)
      end)

    # Forward updates as signals while waiting for prompt to complete
    forward_loop(agent_pid, session_id)

    # Get prompt result
    case Task.await(prompt_task, timeout_ms + to_timeout(second: 5)) do
      {:ok, stop_reason} ->
        dispatch_completion(agent_pid, session_id, stop_reason)

      {:error, reason} ->
        dispatch_error(agent_pid, session_id, reason)
    end
  after
    if Process.alive?(acp_connection) do
      Jido.GHCopilot.ACP.Connection.unsubscribe(acp_connection, session_id)
    end
  rescue
    e ->
      Logger.error("StreamRunner crash: #{Exception.message(e)}")
      dispatch_error(agent_pid, session_id, Exception.message(e))
  end

  defp forward_loop(agent_pid, session_id) do
    receive do
      {:acp_update, update} ->
        dispatch_update(agent_pid, session_id, update)
        forward_loop(agent_pid, session_id)
    after
      100 ->
        # Check if prompt task is still running
        :ok
    end
  end

  defp dispatch_update(agent_pid, _session_id, update) do
    signal =
      Jido.Signal.new!(%{
        type: "ghcopilot.internal.message",
        source: "/ghcopilot/stream_runner",
        data: %{
          update_type: update.update_type,
          session_id: update.session_id,
          data: update.data
        }
      })

    Jido.Signal.Dispatch.dispatch(signal, {:pid, target: agent_pid})
  end

  defp dispatch_completion(agent_pid, session_id, stop_reason) do
    signal =
      Jido.Signal.new!(%{
        type: "ghcopilot.internal.message",
        source: "/ghcopilot/stream_runner",
        data: %{
          update_type: :session_completed,
          session_id: session_id,
          data: %{stop_reason: stop_reason}
        }
      })

    Jido.Signal.Dispatch.dispatch(signal, {:pid, target: agent_pid})
  end

  defp dispatch_error(agent_pid, session_id, reason) do
    signal =
      Jido.Signal.new!(%{
        type: "ghcopilot.internal.message",
        source: "/ghcopilot/stream_runner",
        data: %{
          update_type: :session_error,
          session_id: session_id,
          data: %{error: inspect(reason)}
        }
      })

    Jido.Signal.Dispatch.dispatch(signal, {:pid, target: agent_pid})
  end
end
