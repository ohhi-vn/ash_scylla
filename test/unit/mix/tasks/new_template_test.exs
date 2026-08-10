defmodule Mix.Tasks.AshScylla.NewTemplateTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  describe "Mix.Tasks.AshScylla.NewTemplate" do
    test "task module exists" do
      assert Code.ensure_loaded?(Mix.Tasks.AshScylla.NewTemplate)
    end

    test "run/1 is exported" do
      assert function_exported?(Code.ensure_loaded!(Mix.Tasks.AshScylla.NewTemplate), :run, 1)
    end

    test "raises on invalid resource name" do
      assert_raise Mix.Error, fn ->
        capture_io(fn ->
          Mix.Tasks.AshScylla.NewTemplate.run(["123invalid"])
        end)
      end
    end

    test "raises on missing attributes" do
      assert_raise Mix.Error, fn ->
        capture_io(fn ->
          Mix.Tasks.AshScylla.NewTemplate.run(["MyResource"])
        end)
      end
    end
  end
end
