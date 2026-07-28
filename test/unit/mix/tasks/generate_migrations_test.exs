defmodule Mix.Tasks.AshScylla.GenerateMigrationsTest do
  use ExUnit.Case, async: true

  describe "Mix.Tasks.AshScylla.GenerateMigrations" do
    test "task module exists" do
      assert Code.ensure_loaded?(Mix.Tasks.AshScylla.GenerateMigrations)
    end

    test "run/1 is exported" do
      assert function_exported?(Mix.Tasks.AshScylla.GenerateMigrations, :run, 1)
    end
  end
end
