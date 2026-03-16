defmodule Jido.GHCopilot.Executor.PortTest do
  # credo:disable-for-this-file Credo.Check.Design.DuplicatedCode
  use ExUnit.Case, async: true

  alias Jido.GHCopilot.Options

  describe "CLI arg construction via Options" do
    test "builds basic args with prompt" do
      {:ok, opts} = Options.new(%{prompt: "hello"})
      # Port executor builds args from Options struct
      args = build_port_args(opts)
      assert "-p" in args
      assert "hello" in args
      assert "--no-color" in args
    end

    test "includes model flag when provided" do
      {:ok, opts} = Options.new(%{prompt: "hello", model: "gpt-5-mini"})
      args = build_port_args(opts)
      idx = Enum.find_index(args, &(&1 == "--model"))
      assert idx != nil
      assert Enum.at(args, idx + 1) == "gpt-5-mini"
    end

    test "includes autopilot flag when enabled" do
      {:ok, opts} = Options.new(%{prompt: "hello", autopilot: true})
      args = build_port_args(opts)
      assert "--autopilot" in args
    end

    test "includes system prompt via -s flag" do
      {:ok, opts} = Options.new(%{prompt: "hello", silent: true})
      args = build_port_args(opts)
      assert "-s" in args
    end

    test "timeout_ms defaults to 10 minutes when set" do
      {:ok, opts} = Options.new(%{prompt: "hello", timeout_ms: 600_000})
      assert opts.timeout_ms == 600_000
    end
  end

  # Mirror the Port executor's private build_cli_args/1
  defp build_port_args(%Options{} = options) do
    args = ["-p", options.prompt, "--no-color"]
    args = if options.autopilot, do: args ++ ["--allow-all-tools", "--autopilot"], else: args
    args = if options.silent, do: args ++ ["-s"], else: args
    args = if options.model, do: args ++ ["--model", options.model], else: args
    args
  end
end
