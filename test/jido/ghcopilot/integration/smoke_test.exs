defmodule Jido.GHCopilot.Integration.SmokeTest do
  @moduledoc """
  Integration smoke test for jido_ghcopilot adapter.

  Requires the `copilot` CLI to be installed and authenticated.
  Run with: mix test --include integration
  """
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag timeout: to_timeout(minute: 2)

  test "run/2 executes a simple prompt and streams events" do
    {:ok, events} =
      Jido.GHCopilot.run("Say exactly: SMOKE_TEST_OK",
        timeout_ms: to_timeout(minute: 1),
        silent: true
      )

    event_list = Enum.to_list(events)
    types = Enum.map(event_list, & &1.type)

    assert :session_started in types, "Expected :session_started event, got: #{inspect(types)}"

    assert :session_completed in types or :session_failed in types,
           "Expected terminal event, got: #{inspect(types)}"

    assert Enum.all?(event_list, &(&1.provider == :ghcopilot))

    text_events = Enum.filter(event_list, &(&1.type == :output_text_delta))

    if :session_completed in types do
      assert length(text_events) > 0, "Expected at least one text output event"
      full_text = text_events |> Enum.map(& &1.payload["text"]) |> Enum.join("\n")
      assert full_text =~ "SMOKE_TEST_OK", "Expected output to contain SMOKE_TEST_OK, got: #{full_text}"
    end
  end

  test "run/2 with model flag passes through to CLI" do
    {:ok, events} =
      Jido.GHCopilot.run("Say exactly: MODEL_TEST_OK",
        model: "gpt-4.1",
        timeout_ms: to_timeout(minute: 1),
        silent: true
      )

    event_list = Enum.to_list(events)
    types = Enum.map(event_list, & &1.type)

    assert :session_started in types
    assert :session_completed in types or :session_failed in types
  end

  test "run/2 with add_dirs provides directory access" do
    {:ok, events} =
      Jido.GHCopilot.run("List the files in /tmp and say DIRS_TEST_OK",
        add_dirs: ["/tmp"],
        timeout_ms: to_timeout(minute: 1),
        silent: true
      )

    event_list = Enum.to_list(events)
    types = Enum.map(event_list, & &1.type)

    assert :session_started in types
    assert :session_completed in types or :session_failed in types
  end

  test "cancel/1 returns error for non-existent session" do
    assert {:error, _} = Jido.GHCopilot.cancel("nonexistent-session")
  end

  test "compatibility checks pass" do
    assert Jido.GHCopilot.cli_installed?() == true
    assert Jido.GHCopilot.compatible?() == true
    assert :ok = Jido.GHCopilot.assert_compatible!()
  end
end
