defmodule AshScylla.PaginationTest do
  use ExUnit.Case, async: true

  alias AshScylla.DataLayer.Pagination

  describe "default_page_size/0" do
    test "returns 50" do
      assert Pagination.default_page_size() == 50
    end
  end

  describe "max_page_size/0" do
    test "returns 1000" do
      assert Pagination.max_page_size() == 1000
    end
  end

  describe "encode_page_token/1" do
    test "encodes binary to base64 string" do
      token = <<1, 2, 3, 4, 5>>
      encoded = Pagination.encode_page_token(token)
      assert is_binary(encoded)
      assert Base.decode64!(encoded) == token
    end
  end

  describe "decode_page_token/1" do
    test "decodes base64 string to binary" do
      original = <<1, 2, 3, 4, 5>>
      encoded = Base.encode64(original)
      assert {:ok, ^original} = Pagination.decode_page_token(encoded)
    end

    test "returns error for invalid base64" do
      assert {:error, :invalid_token} = Pagination.decode_page_token("not-valid-base64!!!")
    end

    test "returns error for non-binary input" do
      assert {:error, :invalid_token} = Pagination.decode_page_token(nil)
      assert {:error, :invalid_token} = Pagination.decode_page_token(123)
    end
  end

  describe "build_paginated_query/3" do
    test "builds query with LIMIT" do
      {query, params} = Pagination.build_paginated_query("users", [], 10)

      assert query =~ "SELECT * FROM users"
      assert query =~ "LIMIT ?"
      assert params == [10]
    end

    test "builds query with WHERE clause and LIMIT" do
      {query, params} =
        Pagination.build_paginated_query(
          "users",
          [%{operator: :eq, left: %{name: :status}, right: %{value: "active"}}],
          20
        )

      assert query =~ "SELECT * FROM users"
      assert query =~ "WHERE"
      assert query =~ "LIMIT ?"
      assert length(params) == 2
    end

    test "enforces max page size" do
      {_query, params} = Pagination.build_paginated_query("users", [], 5000)
      assert params == [1000]
    end
  end

  describe "build_paginated_query/4 with page token" do
    test "adds token clause when page_token is provided" do
      {query, params} = Pagination.build_paginated_query("users", [], "my_token", 10)

      assert query =~ "token() > ?"
      assert params == ["my_token", 10]
    end

    test "adds token clause with existing WHERE clause" do
      {query, params} =
        Pagination.build_paginated_query(
          "users",
          [%{operator: :eq, left: %{name: :status}, right: %{value: "active"}}],
          "my_token",
          10
        )

      assert query =~ "WHERE"
      assert query =~ "AND token() > ?"
      assert "my_token" in params
      assert 10 in params
    end
  end
end
