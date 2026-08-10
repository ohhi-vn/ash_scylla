defmodule Mix.Tasks.AshScylla.ResetTaskTest do
  use ExUnit.Case, async: true

  defmodule RepoWithoutFunctions do
  end

  describe "Mix.Tasks.AshScylla.Reset" do
    test "task module exists" do
      assert Code.ensure_loaded?(Mix.Tasks.AshScylla.Reset)
    end

    test "run/1 is exported" do
      assert function_exported?(Code.ensure_loaded!(Mix.Tasks.AshScylla.Reset), :run, 1)
    end

    test "raises when an explicit repo lacks required functions" do
      assert_raise Mix.Error, ~r/missing required functions/, fn ->
        Mix.Tasks.AshScylla.Reset.run([
          "--repo",
          "Mix.Tasks.AshScylla.ResetTaskTest.RepoWithoutFunctions",
          "--dry-run"
        ])
      end
    end

    test "rejects unknown command-line options" do
      assert_raise OptionParser.ParseError, fn ->
        Mix.Tasks.AshScylla.Reset.run(["--not-a-reset-option"])
      end
    end
  end
end
