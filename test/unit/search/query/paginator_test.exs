defmodule AshScylla.Search.Query.PaginatorTest do
  @moduledoc "Tests for the paginator."
  use ExUnit.Case, async: true

  alias AshScylla.Search.Query.Paginator

  describe "paginate/2" do
    test "returns first page" do
      results = Enum.map(1..30, fn i -> {"post#{i}", 10.0 - i * 0.1} end)

      {:ok, page} = Paginator.paginate(results, page: 1, page_size: 10)

      assert length(page.entries) == 10
      assert page.page_number == 1
      assert page.total_count == 30
      assert page.total_pages == 3
      assert page.has_next? == true
      assert page.has_prev? == false
    end

    test "returns last page" do
      results = Enum.map(1..25, fn i -> {"post#{i}", 10.0 - i * 0.1} end)

      {:ok, page} = Paginator.paginate(results, page: 3, page_size: 10)

      assert length(page.entries) == 5
      assert page.has_next? == false
      assert page.has_prev? == true
    end

    test "clamps page number to valid range" do
      results = Enum.map(1..5, fn i -> {"post#{i}", 10.0 - i} end)

      {:ok, page} = Paginator.paginate(results, page: 99, page_size: 10)

      assert page.page_number == 1
      assert length(page.entries) == 5
    end

    test "handles empty results" do
      {:ok, page} = Paginator.paginate([], page: 1, page_size: 10)

      assert page.entries == []
      assert page.total_count == 0
      assert page.total_pages == 1
      assert page.has_next? == false
    end

    test "returns error for invalid params" do
      assert {:error, :invalid_pagination_params} =
               Paginator.paginate([], page: 0, page_size: 10)

      assert {:error, :invalid_pagination_params} =
               Paginator.paginate([], page: 1, page_size: 0)
    end

    test "uses default page size" do
      results = Enum.map(1..50, fn i -> {"post#{i}", 10.0 - i} end)

      {:ok, page} = Paginator.paginate(results)

      assert length(page.entries) == 20
      assert page.page_size == 20
    end
  end
end
