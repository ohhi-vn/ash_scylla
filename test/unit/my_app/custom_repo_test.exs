defmodule MyApp.CustomRepoTest do
  use ExUnit.Case, async: false

  @config [
    nodes: ["127.0.0.1:9051"],
    keyspace: "custom_repo_test_ks",
    connect_timeout: 5_000,
    disable_lwt?: true,
    disable_atomic_actions?: true,
    installed_extensions: [:lwt]
  ]

  setup do
    Application.put_env(:ash_scylla, MyApp.CustomRepo, @config)

    on_exit(fn ->
      Application.delete_env(:ash_scylla, MyApp.CustomRepo)
    end)

    :ok
  end

  describe "MyApp.CustomRepo" do
    test "compiles as a valid module" do
      assert is_atom(MyApp.CustomRepo)
      assert Code.ensure_loaded?(MyApp.CustomRepo)
    end

    test "uses AshScylla.Repo behaviour" do
      assert function_exported?(Code.ensure_loaded!(MyApp.CustomRepo), :__info__, 1)
    end
  end

  describe "config accessors" do
    test "config/0 returns the configured values" do
      assert MyApp.CustomRepo.config() == @config
    end

    test "keyspace/0 returns the configured keyspace" do
      assert MyApp.CustomRepo.keyspace() == "custom_repo_test_ks"
    end

    test "nodes/0 returns the configured nodes" do
      assert MyApp.CustomRepo.nodes() == ["127.0.0.1:9051"]
    end

    test "disable_lwt?/0 reads the config" do
      assert MyApp.CustomRepo.disable_lwt?() == true
    end

    test "disable_atomic_actions?/0 reads the config" do
      assert MyApp.CustomRepo.disable_atomic_actions?() == true
    end

    test "installed_extensions/0 reads the config" do
      assert MyApp.CustomRepo.installed_extensions() == [:lwt]
    end

    test "connection/0 returns nil when no connection is started" do
      assert MyApp.CustomRepo.connection() == nil
    end

    test "query/3 returns {:error, :not_connected} without a connection" do
      assert MyApp.CustomRepo.query("SELECT release_version FROM system.local", []) ==
               {:error, :not_connected}
    end
  end

  describe "keyspace management validation" do
    test "create_keyspace/2 rejects invalid keyspace names before connecting" do
      assert_raise ArgumentError, fn ->
        MyApp.CustomRepo.create_keyspace("123invalid")
      end
    end

    test "drop_keyspace/1 rejects invalid keyspace names before connecting" do
      assert_raise ArgumentError, fn ->
        MyApp.CustomRepo.drop_keyspace("123invalid")
      end
    end

    test "drop_keyspace/1 defaults to the configured keyspace and errors when offline" do
      assert {:error, :not_connected} = MyApp.CustomRepo.drop_keyspace()
    end
  end

  describe "child_spec/1" do
    test "returns a supervisor child spec named after the repo" do
      spec = MyApp.CustomRepo.child_spec([])

      assert spec[:id] == MyApp.CustomRepo
      assert {AshScylla.Connection, :start_link, [opts]} = spec[:start]
      assert Keyword.get(opts, :name) == MyApp.CustomRepo
      assert Keyword.get(opts, :keyspace) == "custom_repo_test_ks"
      assert Keyword.get(opts, :nodes) == ["127.0.0.1:9051"]
    end
  end
end
