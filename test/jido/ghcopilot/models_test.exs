defmodule Jido.GHCopilot.ModelsTest do
  use ExUnit.Case, async: true

  alias Jido.GHCopilot.Models

  describe "all/0" do
    test "returns a non-empty list of tuples" do
      models = Models.all()
      assert is_list(models)
      assert length(models) > 0

      assert Enum.all?(models, fn {name, id, multiplier} ->
               is_binary(name) and is_binary(id) and is_number(multiplier)
             end)
    end
  end

  describe "all_ids/0" do
    test "returns CLI IDs" do
      ids = Models.all_ids()
      assert "claude-opus-4.6" in ids
      assert "gpt-5.3-codex" in ids
    end
  end

  describe "all_names/0" do
    test "returns display names" do
      names = Models.all_names()
      assert "Claude Opus 4.6" in names
      assert "GPT-5.3-Codex" in names
    end
  end

  describe "resolve/1" do
    test "exact CLI ID" do
      assert {:ok, "claude-opus-4.6"} = Models.resolve("claude-opus-4.6")
    end

    test "exact display name" do
      assert {:ok, "claude-opus-4.6"} = Models.resolve("Claude Opus 4.6")
    end

    test "case-insensitive display name" do
      assert {:ok, "claude-opus-4.6"} = Models.resolve("claude opus 4.6")
    end

    test "unique substring match" do
      assert {:ok, "gemini-3-pro-preview"} = Models.resolve("gemini")
    end

    test "ambiguous match returns error with candidates" do
      assert {:error, msg} = Models.resolve("opus")
      assert msg =~ "Ambiguous"
      assert msg =~ "Claude Opus 4.6"
    end

    test "unknown model returns error" do
      assert {:error, msg} = Models.resolve("nonexistent-model")
      assert msg =~ "Unknown model"
    end

    test "trims whitespace" do
      assert {:ok, "claude-opus-4.6"} = Models.resolve("  claude-opus-4.6  ")
    end
  end

  describe "resolve!/1" do
    test "returns ID on success" do
      assert "claude-opus-4.6" = Models.resolve!("Claude Opus 4.6")
    end

    test "raises on failure" do
      assert_raise ArgumentError, fn -> Models.resolve!("nonexistent") end
    end
  end

  describe "resolve_all/1" do
    test "resolves multiple models" do
      assert {:ok, ids} = Models.resolve_all(["Claude Opus 4.6", "gemini", "gpt-5.3-codex"])
      assert ids == ["claude-opus-4.6", "gemini-3-pro-preview", "gpt-5.3-codex"]
    end

    test "fails on first bad model" do
      assert {:error, _} = Models.resolve_all(["Claude Opus 4.6", "bad-model"])
    end
  end

  describe "multiplier/1" do
    test "returns correct multiplier for known models" do
      assert Models.multiplier("claude-opus-4.6") == 3
      assert Models.multiplier("claude-haiku-4.5") == 0.33
      assert Models.multiplier("gpt-5-mini") == 0
      assert Models.multiplier("claude-opus-4.6-fast") == 30
      assert Models.multiplier("claude-sonnet-4.6") == 1
    end

    test "returns 1 for unknown models" do
      assert Models.multiplier("unknown-model") == 1
    end
  end
end
