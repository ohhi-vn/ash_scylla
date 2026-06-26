defmodule AshScylla.PaginationDecodeErrorTest do
  @moduledoc """
  Tests for graceful error handling in Pagination.decode_page_token/1.
  """

  use ExUnit.Case, async: true

  alias AshScylla.DataLayer.Pagination

  describe "decode_page_token/1 error handling" do
    test "returns {:ok, binary} for valid base64" do
      original = <<1, 2, 3, 4, 5>>
      token = Base.encode64(original)
      assert {:ok, ^original} = Pagination.decode_page_token(token)
    end

    test "returns {:error, :invalid_token} for malformed base64" do
      assert {:error, :invalid_token} = Pagination.decode_page_token("not-valid!!!")
    end

    test "returns {:ok, empty binary} for empty string" do
      # Base.decode64("") returns {:ok, ""}, which is a valid binary
      assert {:ok, ""} = Pagination.decode_page_token("")
    end

    test "returns {:error, :invalid_token} for nil" do
      assert {:error, :invalid_token} = Pagination.decode_page_token(nil)
    end

    test "returns {:error, :invalid_token} for non-binary" do
      assert {:error, :invalid_token} = Pagination.decode_page_token(123)
      assert {:error, :invalid_token} = Pagination.decode_page_token(:atom)
    end

    test "roundtrip encode/decode preserves data" do
      original = <<255, 254, 253, 252, 251>>
      token = Pagination.encode_page_token(original)
      assert {:ok, decoded} = Pagination.decode_page_token(token)
      assert decoded == original
    end
  end

  describe "fetch_page/5 with invalid page token" do
    test "returns error for malformed page token" do
      defmodule ValidPageRepo do
        @moduledoc false
        def query(_q, _p, _opts \\ []), do: {:ok, %Xandra.Page{content: [], paging_state: nil}}
      end

      assert {:error, :invalid_page_token} =
               Pagination.fetch_page(ValidPageRepo, "users", [], "invalid-token!!!", 10)
    end
  end
end
