defmodule AshScylla.PaginationEdgePathsTest do
  @moduledoc """
  Covers AshScylla.DataLayer.Pagination error and normalization paths that
  need only a fake repo: unknown filters, odd paging states, and unexpected
  record shapes.
  """

  use ExUnit.Case, async: true

  alias AshScylla.DataLayer.Pagination

  defmodule FvxEmptyPageRepo do
    def query(_q, _p, _o), do: {:ok, %Xandra.Page{content: [], paging_state: nil}}
  end

  defmodule FvxKeywordRowsRepo do
    def query(_q, _p, _o),
      do: {:ok, %Xandra.Page{content: [[id: "a"], [id: "b"]], paging_state: nil}}
  end

  defmodule FvxWeirdPagingStateRepo do
    def query(_q, _p, _o),
      do: {:ok, %Xandra.Page{content: [[id: "a"]], paging_state: :unexpected}}
  end

  defmodule FvxGarbageRowsRepo do
    def query(_q, _p, _o),
      do: {:ok, %Xandra.Page{content: [:garbage_row, [id: "kept"]], paging_state: nil}}
  end

  describe "fetch_page/5" do
    test "returns a descriptive error for untranslatable filters" do
      filter = %{operator: :eq, left: fn x -> x end, right: %{value: 1}}

      assert {:error, message} =
               Pagination.fetch_page(FvxEmptyPageRepo, "fvx_t", [filter], nil, 10)

      assert message =~ "Unable to translate filter expression to CQL"
      assert message =~ "The query was not executed"
    end

    test "normalizes keyword-list rows to maps on the final page" do
      assert {:ok, records, nil} = Pagination.fetch_page(FvxKeywordRowsRepo, "fvx_t", [], nil, 10)
      assert records == [%{id: "a"}, %{id: "b"}]
    end

    test "handles non-binary paging states via the catch-all page clause" do
      assert {:ok, [%{id: "a"}], nil} =
               Pagination.fetch_page(FvxWeirdPagingStateRepo, "fvx_t", [], nil, 10)
    end

    test "warns and maps unexpected record formats to empty maps" do
      assert {:ok, [%{}, %{id: "kept"}], nil} =
               Pagination.fetch_page(FvxGarbageRowsRepo, "fvx_t", [], nil, 10)
    end

    test "normalizes %{name, value} filter maps into equality predicates" do
      assert {:ok, _, nil} =
               Pagination.fetch_page(
                 FvxEmptyPageRepo,
                 "fvx_t",
                 [%{name: :id, value: "abc"}],
                 nil,
                 10
               )
    end

    test "rejects undecodable page tokens" do
      assert {:error, :invalid_page_token} =
               Pagination.fetch_page(FvxEmptyPageRepo, "fvx_t", [], "not%valid%base64!", 10)
    end

    test "caps page size at the configured maximum" do
      assert {:ok, _, nil} = Pagination.fetch_page(FvxEmptyPageRepo, "fvx_t", [], nil, 99_999)
    end
  end

  describe "build_paginated_query/6" do
    test "propagates unknown-filter errors" do
      filter = %{operator: :eq, left: self(), right: %{value: 1}}

      assert {:error, {:unknown_filter, _}} =
               Pagination.build_paginated_query("fvx_t", [filter], nil, 10, %MapSet{}, %{})
    end

    test "appends token clause when a page token is given" do
      assert {:ok, {query, params}} =
               Pagination.build_paginated_query("fvx_t", [], "tok", 10, %MapSet{}, %{})

      assert query == "SELECT * FROM fvx_t WHERE token() > ? LIMIT ?"
      assert params == ["tok", 10]
    end
  end

  describe "cursor helpers" do
    test "decode_cursor round trips encode_cursor output" do
      state = <<1, 2, 3, 4>>
      cursor = Pagination.encode_cursor(state)

      assert Pagination.decode_cursor(cursor) == {:ok, state}
      assert Pagination.decode_cursor(42) == {:error, :invalid_cursor}
    end

    test "decode_page_token rejects invalid input" do
      assert Pagination.decode_page_token("**bad**") == {:error, :invalid_token}
      assert Pagination.decode_page_token(:atom) == {:error, :invalid_token}
    end

    test "page_opts and extract_paging_state handle both shapes" do
      assert Pagination.page_opts(nil, 25) == [page_size: 25]
      assert Pagination.page_opts("state-bin", 25) == [page_size: 25, paging_state: "state-bin"]
      assert Pagination.extract_paging_state(%{paging_state: "ps"}) == "ps"
      assert Pagination.extract_paging_state(%{}) == nil
    end
  end

  describe "size accessors" do
    test "exposes default and max page sizes" do
      assert Pagination.default_page_size() == 50
      assert Pagination.max_page_size() == 1000
    end
  end
end
