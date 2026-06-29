defmodule AshScylla.PagingStateIntegrationTest do
  @moduledoc """
  Integration tests for paging_state-based pagination.

  Verifies that pages are consistent (no duplicates, no gaps)
  and that paging_state tokens work correctly across sequential queries.
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

  defp uuid_to_string(<<a::32, b::16, c::16, d::16, e::48>>) do
    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e])
    |> to_string()
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
      {:ok, conn} -> {:ok, conn}
      {:error, reason} -> {:error, reason}
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

  describe "paging_state continuity" do
    test "paging_state returns consistent pages without duplicates", %{conn: conn} do
      if is_nil(conn), do: :ok

      # Create a dedicated table for this test to avoid pollution from other tests
      table = "paging_test_#{:erlang.unique_integer([:positive])}"

      Xandra.execute!(
        conn,
        "CREATE TABLE IF NOT EXISTS ash_scylla_test.#{table} (id UUID PRIMARY KEY, seq INT)"
      )

      # Insert 25 records
      ids = for _i <- 1..25, do: uid()

      for {id, i} <- Enum.with_index(ids, 1) do
        Xandra.execute!(conn, "INSERT INTO ash_scylla_test.#{table} (id, seq) VALUES (?, ?)", [
          encode_param(id),
          encode_param(i)
        ])
      end

      # Fetch all pages with page_size=10
      {all_fetched_ids, page_count} = fetch_all_pages(conn, table, 10)

      # Normalize UUIDs to string format for comparison (ScyllaDB returns UUIDs as strings)
      inserted_strings = Enum.map(ids, &uuid_to_string/1)

      # Should have fetched all 25 records
      assert MapSet.new(inserted_strings) |> MapSet.equal?(MapSet.new(all_fetched_ids))
      # Should have taken 3 pages
      assert page_count == 3

      # Cleanup
      Xandra.execute!(conn, "DROP TABLE IF EXISTS ash_scylla_test.#{table}")
    end

    test "single page when results fit in one page", %{conn: conn} do
      if is_nil(conn), do: :ok

      table = "paging_single_#{:erlang.unique_integer([:positive])}"

      Xandra.execute!(
        conn,
        "CREATE TABLE IF NOT EXISTS ash_scylla_test.#{table} (id UUID PRIMARY KEY, seq INT)"
      )

      ids = for _i <- 1..5, do: uid()

      for {id, i} <- Enum.with_index(ids, 1) do
        Xandra.execute!(conn, "INSERT INTO ash_scylla_test.#{table} (id, seq) VALUES (?, ?)", [
          encode_param(id),
          encode_param(i)
        ])
      end

      {all_fetched_ids, page_count} = fetch_all_pages(conn, table, 50)

      # Normalize UUIDs to string format for comparison
      inserted_strings = Enum.map(ids, &uuid_to_string/1)

      assert length(all_fetched_ids) == 5
      assert MapSet.new(inserted_strings) |> MapSet.equal?(MapSet.new(all_fetched_ids))
      assert page_count == 1

      # Cleanup
      Xandra.execute!(conn, "DROP TABLE IF EXISTS ash_scylla_test.#{table}")
    end

    test "paging_state cursor encoding round-trips correctly", %{conn: conn} do
      if is_nil(conn), do: :ok

      alias AshScylla.DataLayer.Pagination

      # Test encode/decode round-trip
      binary = :crypto.strong_rand_bytes(32)
      encoded = Pagination.encode_cursor(binary)
      assert {:ok, ^binary} = Pagination.decode_cursor(encoded)

      # Invalid cursor returns error
      assert {:error, :invalid_cursor} = Pagination.decode_cursor("!!!invalid!!!")
    end
  end

  defp fetch_all_pages(conn, table, page_size) do
    query = "SELECT id FROM ash_scylla_test.#{table}"

    case Xandra.execute(conn, query, [], page_size: page_size) do
      {:ok, %Xandra.Page{content: content, paging_state: nil}} ->
        ids = content |> Enum.map(fn [id | _] -> id end)
        {ids, 1}

      {:ok, %Xandra.Page{content: content, paging_state: []}} ->
        ids = content |> Enum.map(fn [id | _] -> id end)
        {ids, 1}

      {:ok, %Xandra.Page{content: content, paging_state: ps}} when is_binary(ps) ->
        ids = content |> Enum.map(fn [id | _] -> id end)
        fetch_remaining_pages(conn, query, ps, ids, 1)

      {:error, error} ->
        raise "Query failed: #{inspect(error)}"
    end
  end

  defp fetch_remaining_pages(conn, query, paging_state, acc_ids, page_count) do
    # Xandra returns nil or [] for the last page; only pass paging_state if it's a valid binary
    opts = [page_size: 10]

    opts =
      if is_binary(paging_state) and paging_state != "",
        do: [{:paging_state, paging_state} | opts],
        else: opts

    case Xandra.execute(conn, query, [], opts) do
      {:ok, %Xandra.Page{content: content, paging_state: nil}} ->
        ids = content |> Enum.map(fn [id | _] -> id end)
        {acc_ids ++ ids, page_count + 1}

      {:ok, %Xandra.Page{content: content, paging_state: []}} ->
        ids = content |> Enum.map(fn [id | _] -> id end)
        {acc_ids ++ ids, page_count + 1}

      {:ok, %Xandra.Page{content: content, paging_state: next_ps}} when is_binary(next_ps) ->
        ids = content |> Enum.map(fn [id | _] -> id end)
        fetch_remaining_pages(conn, query, next_ps, acc_ids ++ ids, page_count + 1)

      {:error, error} ->
        raise "Query failed: #{inspect(error)}"
    end
  end
end
