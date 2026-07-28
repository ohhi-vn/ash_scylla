defmodule Mix.Tasks.AshScylla.ResetTaskTest do
  use ExUnit.Case, async: true

  describe "Mix.Tasks.AshScylla.Reset" do
    test "task module exists" do
      assert Code.ensure_loaded?(Mix.Tasks.AshScylla.Reset)
    end

    test "run/1 is exported" do
      assert function_exported?(Mix.Tasks.AshScylla.Reset, :run, 1)
    end
  end
end
