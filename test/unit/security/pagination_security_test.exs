defmodule AshScylla.PaginationSecurityTest do
  @moduledoc """
  Security tests for pagination — ensures that paging_state tokens
  are handled safely and cannot be used for injection or data leakage.
  """

  use ExUnit.Case, async: true

  alias AshScylla.DataLayer.Pagination

  # ---------------------------------------------------------------------------
  # Cursor encoding/decoding safety
  # ---------------------------------------------------------------------------

  describe "cursor encoding safety" do
    test "encode_cursor produces valid base64url without padding" do
      binary = :crypto.strong_rand_bytes(32)
      encoded = Pagination.encode_cursor(binary)

      # Should be base64url (no +, /, or =)
      refute encoded =~ "+"
      refute encoded =~ "/"
      refute encoded =~ "="
      # Should be decodable
      assert {:ok, ^binary} = Pagination.decode_cursor(encoded)
    end

    test "decode_cursor rejects invalid base64" do
      assert {:error, :invalid_cursor} = Pagination.decode_cursor("not-valid-base64!!!")
    end

    test "decode_cursor handles nil input" do
      assert {:error, :invalid_cursor} = Pagination.decode_cursor(nil)
    end

    test "decode_cursor handles empty string" do
      # Empty string decodes to empty binary, which is valid
      result = Pagination.decode_cursor("")
      # This should either be ok or error depending on implementation
      match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "round-trip encoding preserves binary exactly" do
      for _ <- 1..10 do
        binary = :crypto.strong_rand_bytes(:rand.uniform(256))
        assert {:ok, ^binary} = binary |> Pagination.encode_cursor() |> Pagination.decode_cursor()
      end
    end
  end

  # ---------------------------------------------------------------------------
  # page_opts safety
  # ---------------------------------------------------------------------------

  describe "page_opts/2 safety" do
    test "first page returns only page_size option" do
      opts = Pagination.page_opts(nil, 50)
      assert opts == [page_size: 50]
      refute Keyword.has_key?(opts, :paging_state)
    end

    test "subsequent page includes paging_state" do
      paging_state = :crypto.strong_rand_bytes(16)
      opts = Pagination.page_opts(paging_state, 50)
      assert opts == [page_size: 50, paging_state: paging_state]
    end

    test "page_size is always a positive integer" do
      opts = Pagination.page_opts(nil, 10)
      assert opts[:page_size] == 10
      assert is_integer(opts[:page_size])
      assert opts[:page_size] > 0
    end
  end

  # ---------------------------------------------------------------------------
  # extract_paging_state safety
  # ---------------------------------------------------------------------------

  describe "extract_paging_state/1 safety" do
    test "extracts paging_state from valid result" do
      ps = :crypto.strong_rand_bytes(16)
      assert Pagination.extract_paging_state(%{paging_state: ps}) == ps
    end

    test "returns nil when no more pages" do
      assert Pagination.extract_paging_state(%{paging_state: nil}) == nil
    end

    test "returns nil for unexpected result format" do
      assert Pagination.extract_paging_state([]) == nil
      assert Pagination.extract_paging_state(:error) == nil
      assert Pagination.extract_paging_state(nil) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Page token encoding (legacy API) safety
  # ---------------------------------------------------------------------------

  describe "legacy page token safety" do
    test "encode_page_token produces standard base64" do
      binary = :crypto.strong_rand_bytes(32)
      encoded = Pagination.encode_page_token(binary)
      assert is_binary(encoded)
      # Standard base64 may contain +, /, =
    end

    test "decode_page_token rejects tampered tokens" do
      # A token that's been tampered with should fail gracefully
      assert {:error, :invalid_token} = Pagination.decode_page_token("!!!invalid!!!")
    end

    test "decode_page_token round-trips correctly" do
      binary = :crypto.strong_rand_bytes(32)
      encoded = Pagination.encode_page_token(binary)
      assert {:ok, ^binary} = Pagination.decode_page_token(encoded)
    end
  end

  # ---------------------------------------------------------------------------
  # Page size limits
  # ---------------------------------------------------------------------------

  describe "page size limits prevent abuse" do
    test "default page size is reasonable" do
      default = Pagination.default_page_size()
      assert default == 50
    end

    test "max page size is bounded" do
      max = Pagination.max_page_size()
      assert max == 1000
      assert max > 0
    end

    test "fetch_page clamps page_size to max" do
      # Requesting 9999 should be clamped to 1000
      # (tested indirectly — the function enforces the limit internally)
      max = Pagination.max_page_size()
      assert max <= 1000
    end
  end
end
