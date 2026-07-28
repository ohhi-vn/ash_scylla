defmodule Mix.Tasks.AshScylla.MigrateTaskTest do
  use ExUnit.Case, async: true

  describe "Mix.Tasks.AshScylla.Migrate" do
    test "task module exists" do
      assert Code.ensure_loaded?(Mix.Tasks.AshScylla.Migrate)
    end

    test "run/1 is exported" do
      assert function_exported?(Mix.Tasks.AshScylla.Migrate, :run, 1)
    end
  end
end
