defmodule AshScylla.ScyllaIntegrationTest do
  @moduledoc """
  Integration tests for AshScylla with a real ScyllaDB instance using testcontainers.

  These tests will:
  1. Start a ScyllaDB container using testcontainers
  2. Configure the repo to connect to the container
  3. Create test keyspace and tables
  4. Run actual CRUD tests
  5. Test TTL and consistency levels
  """

  use ExUnit.Case, async: false

  alias AshScylla.TestRepo

  @moduletag :integration

  setup_all do
    # Start testcontainers
    {:ok, _} = Testcontainers.start_link()

    # Configure ScyllaDB container
    config =
      Testcontainers.Container.new("scylladb/scylla:latest")
      |> Testcontainers.Container.with_name("ash-scylla-test")
      |> Testcontainers.Container.with_exposed_port(9042)
      |> Testcontainers.Container.with_cmd(["--smp", "1", "--memory", "1G"])
      |> Testcontainers.Container.with_waiting_strategy(
        Testcontainers.PortWaitStrategy.new("localhost", 9042, 120_000, 2000)
      )

    # Start the container
    {:ok, container} = Testcontainers.start_container(config)

    # Get the mapped port
    port = Testcontainers.Container.mapped_port(container, 9042)
    host = "localhost"

    IO.puts("ScyllaDB container started on #{host}:#{port}")

    # Wait for ScyllaDB to be fully ready
    Process.sleep(20_000)

    # Test TCP connection
    case :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false], 10_000) do
      {:ok, socket} ->
        IO.puts("TCP connection successful!")
        :gen_tcp.close(socket)

        # Connect WITHOUT specifying keyspace initially
        repo_config = [
          nodes: ["#{host}:#{port}"],
          pool_size: 5,
          sync_connect: 60_000
        ]

        {:ok, _} = TestRepo.start_link(repo_config)
        IO.puts("TestRepo started (without keyspace)!")

        # Now create the keyspace
        create_keyspace_query = """
        CREATE KEYSPACE IF NOT EXISTS ash_scylla_test
        WITH REPLICATION = {'class': 'SimpleStrategy', 'replication_factor': 1}
        """

        case TestRepo.query(create_keyspace_query, []) do
          {:ok, _} ->
            IO.puts("Keyspace created successfully!")

            # Create test table (use fully qualified name)
            create_table_query = """
            CREATE TABLE IF NOT EXISTS ash_scylla_test.test_table (
              id UUID PRIMARY KEY,
              name TEXT,
              email TEXT,
              age INT,
              created_at TIMESTAMP
            )
            """

            case TestRepo.query(create_table_query, []) do
              {:ok, _} ->
                IO.puts("Test table created successfully!")

                # Store connection info for tests
                connection_info = %{
                  host: host,
                  port: port,
                  container: container
                }

                on_exit(fn ->
                  TestRepo.query("DROP TABLE IF EXISTS ash_scylla_test.test_table", [])
                  TestRepo.stop()
                  Testcontainers.stop_container(container.container_id)
                end)

                {:ok, connection_info}

              {:error, table_error} ->
                IO.puts("Failed to create table: #{inspect(table_error)}")
                TestRepo.stop()
                Testcontainers.stop_container(container.container_id)
                raise "Failed to create table: #{inspect(table_error)}"
            end

          {:error, ks_error} ->
            IO.puts("Failed to create keyspace: #{inspect(ks_error)}")
            TestRepo.stop()
            Testcontainers.stop_container(container.container_id)
            raise "Failed to create keyspace: #{inspect(ks_error)}"
        end

      {:error, tcp_error} ->
        IO.puts("TCP connection failed: #{inspect(tcp_error)}")
        Testcontainers.stop_container(container.container_id)
        raise "TCP connection failed: #{inspect(tcp_error)}"
    end
  end

  describe "basic connectivity" do
    test "can execute simple query" do
      {:ok, result} = TestRepo.query("SELECT now() FROM system.local", [])
      assert result.num_rows == 1
    end
  end

  describe "CRUD operations" do
    test "insert and select data" do
      id = "550e8400-e29b-41d4-a716-446655440000"

      insert_query = """
      INSERT INTO ash_scylla_test.test_table (id, name, email, age)
      VALUES (?, ?, ?, ?)
      """

      {:ok, _} = TestRepo.query(insert_query, [id, "John Doe", "john@example.com", 30])

      select_query = "SELECT * FROM ash_scylla_test.test_table WHERE id = ?"
      {:ok, result} = TestRepo.query(select_query, [id])

      assert result.num_rows == 1
      [row] = result.rows

      # Xandra returns rows as lists - order is: id(0), age(1), created_at(2), email(3), name(4)
      # Based on the CREATE TABLE statement order
      assert Enum.at(row, 4) == "John Doe"
      assert Enum.at(row, 3) == "john@example.com"
      assert Enum.at(row, 1) == 30
    end

    test "update data" do
      id = "550e8400-e29b-41d4-a716-446655440001"

      # Insert
      {:ok, _} =
        TestRepo.query(
          "INSERT INTO ash_scylla_test.test_table (id, name, age) VALUES (?, ?, ?)",
          [id, "Jane Doe", 25]
        )

      # Update
      {:ok, _} =
        TestRepo.query(
          "UPDATE ash_scylla_test.test_table SET age = ? WHERE id = ?",
          [26, id]
        )

      # Verify
      {:ok, result} =
        TestRepo.query("SELECT * FROM ash_scylla_test.test_table WHERE id = ?", [id])

      [row] = result.rows
      assert Enum.at(row, 1) == 26
    end

    test "delete data" do
      id = "550e8400-e29b-41d4-a716-446655440002"

      # Insert
      {:ok, _} =
        TestRepo.query(
          "INSERT INTO ash_scylla_test.test_table (id, name) VALUES (?, ?)",
          [id, "Delete Me"]
        )

      # Delete
      {:ok, _} =
        TestRepo.query("DELETE FROM ash_scylla_test.test_table WHERE id = ?", [id])

      # Verify
      {:ok, result} =
        TestRepo.query("SELECT * FROM ash_scylla_test.test_table WHERE id = ?", [id])

      assert result.num_rows == 0
    end
  end

  describe "TTL support" do
    test "insert with TTL" do
      id = "550e8400-e29b-41d4-a716-446655440003"

      insert_query = """
      INSERT INTO ash_scylla_test.test_table (id, name)
      VALUES (?, ?)
      USING TTL 1
      """

      {:ok, _} = TestRepo.query(insert_query, [id, "Temporary Data"])

      # Verify data exists
      {:ok, result} =
        TestRepo.query("SELECT * FROM ash_scylla_test.test_table WHERE id = ?", [id])

      assert result.num_rows == 1

      # Wait for TTL to expire
      Process.sleep(2000)

      # Verify data is gone
      {:ok, result} =
        TestRepo.query("SELECT * FROM ash_scylla_test.test_table WHERE id = ?", [id])

      assert result.num_rows == 0
    end
  end

  describe "consistency levels" do
    test "query with consistency level" do
      id = "550e8400-e29b-41d4-a716-446655440004"

      {:ok, _} =
        TestRepo.query(
          "INSERT INTO ash_scylla_test.test_table (id, name) VALUES (?, ?)",
          [id, "Consistency Test"]
        )

      # Query with consistency level
      select_query = """
      SELECT * FROM ash_scylla_test.test_table WHERE id = ?
      """

      {:ok, result} = TestRepo.query(select_query, [id])

      assert result.num_rows == 1
      [row] = result.rows
      assert Enum.at(row, 4) == "Consistency Test"
    end
  end
end
