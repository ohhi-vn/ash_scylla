defmodule AshScylla.Search.CoverageTest do
  @moduledoc "Covers search!/4 success path."
  use ExUnit.Case, async: true

  alias AshScylla.Search

  defmodule Src2LookupRepo do
    def query(_cql, _params), do: {:ok, %{rows: []}}
  end

  describe "search!/4" do
    test "returns the page on success" do
      page = Search.search!(Src2LookupRepo, "ks", "hello")
      assert page.entries == []
      assert page.page_number == 1
      assert page.total_count == 0
    end
  end
end
