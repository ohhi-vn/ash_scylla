defmodule AshScyllaTest do
  use ExUnit.Case, async: true

  describe "version/0" do
    test "returns a non-empty version string" do
      version = AshScylla.version()
      assert is_binary(version)
      assert version != ""
    end

    test "returns a valid version format" do
      version = AshScylla.version()
      assert String.match?(version, ~r/^\d+\.\d+\.\d+/)
    end
  end
end
