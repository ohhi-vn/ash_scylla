defmodule AshScylla.CompressionAlgorithmsTest do
  @moduledoc """
  Covers lz4/snappy/zstd compress/decompress dispatch in
  AshScylla.DataLayer.Compression. The optional NIF packages are not part of
  this project's deps, so every call surfaces the descriptive ArgumentError.
  """

  use ExUnit.Case, async: true

  alias AshScylla.DataLayer.Compression

  describe "lz4 algorithm dispatch" do
    test "compress reports the missing package" do
      assert_raise ArgumentError, ~r/LZ4 compression requires the :lz4 package/, fn ->
        Compression.compress("payload", :lz4)
      end
    end

    test "decompress reports the missing package" do
      assert_raise ArgumentError, ~r/LZ4 decompression requires the :lz4 package/, fn ->
        Compression.decompress(<<1, "payload">>, :lz4)
      end
    end
  end

  describe "snappy algorithm dispatch" do
    test "compress reports the missing package" do
      assert_raise ArgumentError, ~r/Snappy compression requires the :snappy package/, fn ->
        Compression.compress("payload", :snappy)
      end
    end

    test "decompress reports the missing package" do
      assert_raise ArgumentError, ~r/Snappy decompression requires the :snappy package/, fn ->
        Compression.decompress(<<2, "payload">>, :snappy)
      end
    end
  end

  describe "zstd algorithm dispatch" do
    test "compress reports the missing package" do
      assert_raise ArgumentError, ~r/Zstd compression requires the :ezstd package/, fn ->
        Compression.compress("payload", :zstd)
      end
    end

    test "decompress reports the missing package" do
      assert_raise ArgumentError, ~r/Zstd decompression requires the :ezstd package/, fn ->
        Compression.decompress(<<4, "payload">>, :zstd)
      end
    end
  end

  test "deflate round trips through zlib without optional packages" do
    data = String.duplicate("deflate", 64)

    compressed = Compression.compress(data, :deflate)
    assert <<3, _::binary>> = compressed
    assert Compression.decompress(compressed, :deflate) == data
  end

  test "unknown algorithms are rejected before compression" do
    assert_raise ArgumentError, ~r/Unknown compression algorithm/, fn ->
      Compression.compress("payload", :brotli)
    end
  end
end
