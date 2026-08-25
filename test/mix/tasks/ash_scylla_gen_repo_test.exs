defmodule Mix.Tasks.AshScylla.Gen.RepoTest do
  # Non-async: the generator resolves output paths relative to the working
  # directory, which is node-global. Each test runs inside its own temp dir.
  use ExUnit.Case, async: false

  @moduletag tmp_dir: true

  alias Mix.Tasks.AshScylla.Gen

  import ExUnit.CaptureIO

  setup %{tmp_dir: tmp_dir} do
    original_cwd = File.cwd!()
    File.cd!(tmp_dir)
    on_exit(fn -> File.cd(original_cwd) end)
    :ok
  end

  describe "Mix.Tasks.AshScylla.Gen.Repo" do
    test "task module exists and is callable" do
      assert is_function(&Mix.Tasks.AshScylla.Gen.Repo.run/1)
    end

    test "generates repo file with default options" do
      output = capture_io(fn -> Gen.Repo.run([]) end)

      assert output =~ "Generated"
      assert File.exists?(Path.join("lib", "ash_scylla/repo.ex"))

      content = File.read!(Path.join("lib", "ash_scylla/repo.ex"))
      assert content =~ "defmodule AshScylla.Repo"
      assert content =~ "otp_app: :ash_scylla"
    end

    test "generates repo file with custom --repo name" do
      capture_io(fn -> Gen.Repo.run(["--repo", "MyApp.CustomRepo"]) end)

      assert File.exists?(Path.join("lib", "my_app/custom_repo.ex"))
      assert File.read!(Path.join("lib", "my_app/custom_repo.ex")) =~ "defmodule MyApp.CustomRepo"
    end

    test "generates repo with custom --otp-app" do
      capture_io(fn ->
        Gen.Repo.run(["--repo", "CustomApp.Repo", "--otp-app", "my_custom_app"])
      end)

      content = File.read!(Path.join("lib", "custom_app/repo.ex"))
      assert content =~ "otp_app: :my_custom_app"
      assert content =~ "config :my_custom_app, CustomApp.Repo"
    end

    test "generates repo with custom --keyspace" do
      capture_io(fn ->
        Gen.Repo.run(["--repo", "CustomApp.Repo", "--keyspace", "custom_keyspace"])
      end)

      assert File.read!(Path.join("lib", "custom_app/repo.ex")) =~ "custom_keyspace"
    end

    test "generates repo with custom --nodes" do
      capture_io(fn ->
        Gen.Repo.run(["--repo", "CustomApp.Repo", "--nodes", "10.0.0.1:9042,10.0.0.2:9042"])
      end)

      content = File.read!(Path.join("lib", "custom_app/repo.ex"))
      assert content =~ "10.0.0.1:9042"
      assert content =~ "10.0.0.2:9042"
    end

    test "generates repo with all custom options" do
      capture_io(fn ->
        Gen.Repo.run([
          "--repo",
          "MyApp.ProdRepo",
          "--otp-app",
          "my_app",
          "--keyspace",
          "prod_ks",
          "--nodes",
          "scylla-1:9042,scylla-2:9042"
        ])
      end)

      path = Path.join("lib", "my_app/prod_repo.ex")
      assert File.exists?(path)
      content = File.read!(path)
      assert content =~ "defmodule MyApp.ProdRepo"
      assert content =~ "prod_ks"
      assert content =~ "scylla-1:9042"
    end
  end
end
