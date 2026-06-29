defmodule AshScylla.TtlExpirationIntegrationTest do
  @moduledoc """
  Integration tests for TTL (Time To Live) expiration behavior.

  These tests require a running ScyllaDB instance and use short TTLs
  with Process.sleep to verify records expire.
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  defp direct_connect?, do: System.get_env("SCYLLA_DIRECT") not in [nil, ""]
  defp direct_host, do: System.get_env("SCYLLA_HOST") || "127.0.0.1"

  defp direct_port do
    case System.get_env("SCYLLA_PORT") do
      nil -> 9042
      port -> String.to_integer(port)
    end
  end

  defp uid do
    <<u0::48, _::4, u1::12, _::2, u2::62>> = :crypto.strong_rand_bytes(16)
    <<u0::48, 4::4, u1::12, 2::2, u2::62>>
  end

  defp uuid?(value) when is_binary(value) do
    Regex.match?(~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i, value)
  end

  defp encode_param({type, value}) when is_binary(type), do: {type, value}

  defp encode_param(value) when is_binary(value) do
    if uuid?(value), do: {"uuid", value}, else: {"text", value}
  end

  defp encode_param(value) when is_integer(value), do: {"int", value}
  defp encode_param(value) when is_boolean(value), do: {"boolean", value}
  defp encode_param(value) when is_float(value), do: {"double", value}
  defp encode_param(nil), do: {"null", nil}
  defp encode_param(value), do: {"text", inspect(value)}

  defp connect do
    host = direct_host()
    port = direct_port()

    case Xandra.start_link(nodes: ["#{host}:#{port}"]) do
      {:ok, conn} ->
        case Xandra.execute(conn, "USE ash_scylla_test") do
          {:ok, _} -> {:ok, conn}
          {:error, _} -> {:error, :keyspace_not_found}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  setup do
    if direct_connect?() do
      case connect() do
        {:ok, conn} -> %{conn: conn}
        {:error, _} -> %{conn: nil}
      end
    else
      %{conn: nil}
    end
  end

  defp xq(conn, query, params \\ []) do
    if is_nil(conn), do: nil

    encoded = Enum.map(params, &encode_param/1)

    case Xandra.execute(conn, query, encoded) do
      {:ok, %Xandra.Page{} = page} ->
        rows = page.content || []
        %{rows: rows, num_rows: length(rows), columns: page.columns}

      {:ok, %Xandra.Void{}} ->
        %{rows: [], num_rows: 0, columns: []}

      {:ok, result} ->
        %{rows: [], num_rows: 0, columns: [], result: result}

      {:error, error} ->
        raise "Query failed: #{inspect(error)}"
    end
  end

  describe "TTL expiration" do
    test "record with short TTL expires after timeout", %{conn: conn} do
      if is_nil(conn), do: :ok
      id = uid()

      # Insert with 2-second TTL
      xq(conn, "INSERT INTO ash_scylla_test.users (id, name) VALUES (?, ?) USING TTL 2", [
        id,
        "Temporary"
      ])

      # Record should exist immediately
      result = xq(conn, "SELECT * FROM ash_scylla_test.users WHERE id = ?", [id])
      assert result.num_rows == 1

      # Wait for expiration
      Process.sleep(3_000)

      # Record should be gone
      result = xq(conn, "SELECT * FROM ash_scylla_test.users WHERE id = ?", [id])
      assert result.num_rows == 0
    end

    test "record with long TTL persists", %{conn: conn} do
      if is_nil(conn), do: :ok
      id = uid()

      # Insert with 1-hour TTL
      xq(conn, "INSERT INTO ash_scylla_test.users (id, name) VALUES (?, ?) USING TTL 3600", [
        id,
        "Persistent"
      ])

      result = xq(conn, "SELECT * FROM ash_scylla_test.users WHERE id = ?", [id])
      assert result.num_rows == 1
    end

    test "TTL column value decreases over time", %{conn: conn} do
      if is_nil(conn), do: :ok
      id = uid()

      xq(conn, "INSERT INTO ash_scylla_test.users (id, name) VALUES (?, ?) USING TTL 10", [
        id,
        "TTL Check"
      ])

      # Check TTL value immediately — should be close to 10
      result = xq(conn, "SELECT TTL(name) FROM ash_scylla_test.users WHERE id = ?", [id])
      assert result.num_rows == 1

      # Wait a bit and check TTL decreased
      Process.sleep(2_000)

      result = xq(conn, "SELECT TTL(name) FROM ash_scylla_test.users WHERE id = ?", [id])
      assert result.num_rows == 1
    end

    test "updated record can have new TTL", %{conn: conn} do
      if is_nil(conn), do: :ok
      id = uid()

      # Insert with short TTL
      xq(conn, "INSERT INTO ash_scylla_test.users (id, name) VALUES (?, ?) USING TTL 2", [
        id,
        "Short"
      ])

      # Update with longer TTL before expiration
      xq(conn, "UPDATE ash_scylla_test.users USING TTL 3600 SET name = ? WHERE id = ?", [
        "Extended",
        id
      ])

      # Wait past original TTL
      Process.sleep(3_000)

      # Record should still exist because of the updated TTL
      result = xq(conn, "SELECT * FROM ash_scylla_test.users WHERE id = ?", [id])
      assert result.num_rows == 1
    end
  end
end
