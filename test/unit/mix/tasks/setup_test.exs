defmodule Mix.Tasks.AshScylla.SetupTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  describe "Mix.Tasks.AshScylla.Setup" do
    test "task module exists" do
      assert Code.ensure_loaded?(Mix.Tasks.AshScylla.Setup)
    end

    test "run/1 is exported" do
      assert function_exported?(Code.ensure_loaded!(Mix.Tasks.AshScylla.Setup), :run, 1)
    end
  end
end
