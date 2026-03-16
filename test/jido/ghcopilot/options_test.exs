defmodule Jido.GHCopilot.OptionsTest do
  use ExUnit.Case, async: true

  alias Jido.GHCopilot.Options

  test "from_run_request/2 maps request defaults" do
    request =
      Jido.Harness.RunRequest.new!(%{
        prompt: "hello",
        cwd: "/tmp/project",
        model: "gpt-5",
        metadata: %{}
      })

    assert {:ok, options} = Options.from_run_request(request)
    assert options.prompt == "hello"
    assert options.cwd == "/tmp/project"
    assert options.model == "gpt-5"
    assert options.silent == true
    assert options.continue == false
    assert options.resume == nil
    assert options.autopilot == false
    assert options.max_autopilot_continues == nil
    assert options.share == nil
    assert options.timeout_ms == to_timeout(minute: 10)
    assert options.add_dirs == []
  end

  test "supports autopilot, share, and timeout options" do
    request =
      Jido.Harness.RunRequest.new!(%{
        prompt: "hello",
        metadata: %{
          "ghcopilot" => %{
            "autopilot" => true,
            "max_autopilot_continues" => 10,
            "share" => "/tmp/transcript.md",
            "timeout_ms" => to_timeout(minute: 20)
          }
        }
      })

    assert {:ok, options} = Options.from_run_request(request)
    assert options.autopilot == true
    assert options.max_autopilot_continues == 10
    assert options.share == "/tmp/transcript.md"
    assert options.timeout_ms == to_timeout(minute: 20)
  end

  test "runtime opts override autopilot/share/timeout from metadata" do
    request =
      Jido.Harness.RunRequest.new!(%{
        prompt: "hello",
        metadata: %{
          "ghcopilot" => %{
            "autopilot" => false,
            "timeout_ms" => to_timeout(minute: 5)
          }
        }
      })

    assert {:ok, options} =
             Options.from_run_request(request,
               autopilot: true,
               timeout_ms: to_timeout(minute: 15),
               share: "/tmp/out.md"
             )

    assert options.autopilot == true
    assert options.timeout_ms == to_timeout(minute: 15)
    assert options.share == "/tmp/out.md"
  end

  test "runtime opts override metadata and defaults" do
    request =
      Jido.Harness.RunRequest.new!(%{
        prompt: "hello",
        metadata: %{
          "ghcopilot" => %{
            "model" => "metadata-model",
            "silent" => false,
            "add_dirs" => ["/tmp/extra"]
          }
        }
      })

    assert {:ok, options} =
             Options.from_run_request(request,
               model: "runtime-model",
               silent: true,
               add_dirs: ["/tmp/override"]
             )

    assert options.model == "runtime-model"
    assert options.silent == true
    assert options.add_dirs == ["/tmp/override"]
  end

  test "supports string metadata keys" do
    request =
      Jido.Harness.RunRequest.new!(%{
        prompt: "hello",
        metadata: %{
          "ghcopilot" => %{
            "continue" => true,
            "resume" => "session-123"
          }
        }
      })

    assert {:ok, options} = Options.from_run_request(request)
    assert options.continue == true
    assert options.resume == "session-123"
  end

  test "deep merges env maps" do
    request =
      Jido.Harness.RunRequest.new!(%{
        prompt: "hello",
        metadata: %{
          "ghcopilot" => %{
            "env" => %{"FOO" => "bar"}
          }
        }
      })

    assert {:ok, options} = Options.from_run_request(request, env: %{"BAZ" => "qux"})
    assert options.env["FOO"] == "bar"
    assert options.env["BAZ"] == "qux"
  end

  test "schema/new!/1 helpers validate attrs" do
    assert is_struct(Options.schema())

    assert %Options{} = Options.new!(%{prompt: "hello"})

    assert_raise ArgumentError, ~r/Invalid/, fn ->
      Options.new!(%{})
    end
  end

  test "handles non-map metadata gracefully" do
    request = %Jido.Harness.RunRequest{
      prompt: "hello",
      cwd: nil,
      model: nil,
      max_turns: nil,
      timeout_ms: nil,
      system_prompt: nil,
      allowed_tools: nil,
      attachments: [],
      metadata: :invalid
    }

    assert {:ok, options} = Options.from_run_request(request)
    assert options.prompt == "hello"
    assert options.silent == true
  end
end
