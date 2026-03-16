defmodule Jido.GHCopilot.ErrorTest do
  use ExUnit.Case, async: true

  alias Jido.GHCopilot.Error
  alias Jido.GHCopilot.Error.{InvalidInputError, ExecutionFailureError, ConfigError, Internal.UnknownError}

  describe "InvalidInputError" do
    test "can be raised and rescued" do
      assert_raise InvalidInputError, fn ->
        raise InvalidInputError, message: "bad field", field: :model, value: 123
      end
    end

    test "message is accessible" do
      err = %InvalidInputError{message: "invalid model", field: :model, value: "xyz"}
      assert Exception.message(err) == "invalid model"
    end

    test "stores field and value" do
      err = %InvalidInputError{message: "bad", field: :timeout, value: -1, details: %{min: 0}}
      assert err.field == :timeout
      assert err.value == -1
      assert err.details == %{min: 0}
    end
  end

  describe "ExecutionFailureError" do
    test "can be raised" do
      assert_raise ExecutionFailureError, fn ->
        raise ExecutionFailureError, message: "CLI crashed"
      end
    end

    test "stores details" do
      err = %ExecutionFailureError{message: "timeout", details: %{elapsed_ms: 60_000}}
      assert Exception.message(err) == "timeout"
      assert err.details.elapsed_ms == 60_000
    end
  end

  describe "ConfigError" do
    test "can be raised" do
      assert_raise ConfigError, fn ->
        raise ConfigError, message: "missing API key", key: :api_key
      end
    end

    test "stores key" do
      err = %ConfigError{message: "not found", key: :copilot_path, details: nil}
      assert err.key == :copilot_path
    end
  end

  describe "UnknownError" do
    test "can be raised" do
      assert_raise UnknownError, fn ->
        raise UnknownError, message: "something unexpected"
      end
    end
  end

  describe "helper constructors" do
    test "validation_error/2" do
      err = Error.validation_error("bad input", %{field: :model})
      assert %InvalidInputError{} = err
      assert err.message == "bad input"
      assert err.field == :model
    end

    test "execution_error/2" do
      err = Error.execution_error("failed", %{reason: :timeout})
      assert %ExecutionFailureError{} = err
      assert err.message == "failed"
      assert err.details.reason == :timeout
    end

    test "config_error/2" do
      err = Error.config_error("missing key", %{key: :path})
      assert %ConfigError{} = err
      assert err.message == "missing key"
    end
  end
end
