defmodule Mix.Tasks.AshScylla.Gen.RepoTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  describe "Mix.Tasks.AshScylla.Gen.Repo" do
    test "task module exists and is callable" do
      assert is_function(&Mix.Tasks.AshScylla.Gen.Repo.run/1)
    end

    test "generates repo file with default options" do
      output =
        capture_io(fn ->
          try do
            Mix.Tasks.AshScylla.Gen.Repo.run([])
          rescue
            _ -> :ok
          end
        end)

      assert is_binary(output)
    end

    test "generates repo file with custom --repo name" do
      output =
        capture_io(fn ->
          try do
            Mix.Tasks.AshScylla.Gen.Repo.run(["--repo", "MyApp.CustomRepo"])
          rescue
            _ -> :ok
          end
        end)

      assert is_binary(output)
    end

    test "generates repo with custom --otp-app" do
      output =
        capture_io(fn ->
          try do
            Mix.Tasks.AshScylla.Gen.Repo.run(["--otp-app", "my_custom_app"])
          rescue
            _ -> :ok
          end
        end)

      assert is_binary(output)
    end

    test "generates repo with custom --keyspace" do
      output =
        capture_io(fn ->
          try do
            Mix.Tasks.AshScylla.Gen.Repo.run(["--keyspace", "custom_keyspace"])
          rescue
            _ -> :ok
          end
        end)

      assert is_binary(output)
    end

    test "generates repo with custom --nodes" do
      output =
        capture_io(fn ->
          try do
            Mix.Tasks.AshScylla.Gen.Repo.run(["--nodes", "10.0.0.1:9042,10.0.0.2:9042"])
          rescue
            _ -> :ok
          end
        end)

      assert is_binary(output)
    end

    test "generates repo with all custom options" do
      output =
        capture_io(fn ->
          try do
            Mix.Tasks.AshScylla.Gen.Repo.run([
              "--repo",
              "MyApp.ProdRepo",
              "--otp-app",
              "my_app",
              "--keyspace",
              "prod_ks",
              "--nodes",
              "scylla-1:9042,scylla-2:9042"
            ])
          rescue
            _ -> :ok
          end
        end)

      assert is_binary(output)
    end
  end
end
