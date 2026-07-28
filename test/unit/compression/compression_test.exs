defmodule AshScylla.DataLayer.CompressionTest do
  use ExUnit.Case, async: true

  alias AshScylla.DataLayer.Compression

  describe "compress/2 and decompress/2" do
    test "deflate roundtrip" do
      original = String.duplicate("hello world compression test ", 10)
      compressed = Compression.compress(original, :deflate)
      assert compressed != original
      assert byte_size(compressed) < byte_size(original)
      assert Compression.decompress(compressed, :deflate) == original
    end

    test "compressed output has algorithm marker prefix" do
      compressed = Compression.compress("test data", :deflate)
      assert byte_size(compressed) > 1
      marker = binary_part(compressed, 0, 1)
      assert marker == <<3>>
    end

    test "raises on marker mismatch" do
      compressed = Compression.compress("test", :deflate)
      assert_raise ArgumentError, ~r/marker mismatch/i, fn ->
        Compression.decompress(compressed, :lz4)
      end
    end

    test "raises on empty data" do
      assert_raise ArgumentError, ~r/too short/i, fn ->
        Compression.decompress(<<>>, :deflate)
      end
    end

    test "raises on single byte data (marker only, no algorithm match)" do
      assert_raise ArgumentError, ~r/marker mismatch/i, fn ->
        Compression.decompress(<<0>>, :deflate)
      end
    end

    test "raises on unknown algorithm" do
      assert_raise ArgumentError, ~r/Unknown compression algorithm/, fn ->
        Compression.compress("test", :unknown_algo)
      end
    end
  end

  describe "compress_if_large/3" do
    test "returns {:ok, original} for small values" do
      assert Compression.compress_if_large("small", :deflate, 1024) == {:ok, "small"}
    end

    test "returns {:compressed, ...} for large values" do
      large = String.duplicate("a", 2048)
      result = Compression.compress_if_large(large, :deflate, 1024)
      assert match?({:compressed, _}, result)
    end

    test "uses marker prefix for compressed large values" do
      large = String.duplicate("a", 2048)
      {:compressed, data} = Compression.compress_if_large(large, :deflate, 1024)
      assert byte_size(data) > 1
    end

    test "edge case: threshold equals size" do
      value = String.duplicate("x", 1024)
      assert Compression.compress_if_large(value, :deflate, 1024) == {:ok, value}
    end

    test "edge case: threshold 0 compresses everything" do
      result = Compression.compress_if_large("x", :deflate, 0)
      assert match?({:compressed, _}, result)
    end
  end

  describe "table_compression_cql/1" do
    test "generates CQL for lz4" do
      assert Compression.table_compression_cql(:lz4) ==
               "compression = {'class': 'LZ4Compressor'}"
    end

    test "generates CQL for snappy" do
      assert Compression.table_compression_cql(:snappy) ==
               "compression = {'class': 'SnappyCompressor'}"
    end

    test "generates CQL for deflate" do
      assert Compression.table_compression_cql(:deflate) ==
               "compression = {'class': 'DeflateCompressor'}"
    end

    test "generates CQL for zstd" do
      assert Compression.table_compression_cql(:zstd) ==
               "compression = {'class': 'ZstdCompressor'}"
    end
  end

  describe "table_compression_cql/2" do
    test "includes chunk_length_kb" do
      cql = Compression.table_compression_cql(:lz4, chunk_length_kb: 64)
      assert cql =~ "LZ4Compressor"
      assert cql =~ "'chunk_length_kb': 64"
    end

    test "includes crc_check_chance" do
      cql = Compression.table_compression_cql(:snappy, crc_check_chance: 0.5)
      assert cql =~ "SnappyCompressor"
      assert cql =~ "'crc_check_chance': 0.5"
    end

    test "includes multiple options" do
      cql = Compression.table_compression_cql(:zstd, chunk_length_kb: 128, crc_check_chance: 0.75)
      assert cql =~ "ZstdCompressor"
      assert cql =~ "'chunk_length_kb': 128"
      assert cql =~ "'crc_check_chance': 0.75"
    end

    test "raises on unknown option" do
      assert_raise ArgumentError, ~r/Unknown compression option/, fn ->
        Compression.table_compression_cql(:lz4, bogus: true)
      end
    end

    test "raises on invalid chunk_length_kb" do
      assert_raise ArgumentError, ~r/Unknown compression option/, fn ->
        Compression.table_compression_cql(:lz4, chunk_length_kb: 0)
      end
    end

    test "raises on invalid crc_check_chance" do
      assert_raise ArgumentError, ~r/Unknown compression option/, fn ->
        Compression.table_compression_cql(:lz4, crc_check_chance: 1.5)
      end
    end
  end

  describe "default_compression_cql/1" do
    test "prepends WITH" do
      assert Compression.default_compression_cql(:lz4) ==
               "WITH compression = {'class': 'LZ4Compressor'}"
    end
  end

  describe "chunk_length_cql/1" do
    test "generates CQL for positive integer" do
      assert Compression.chunk_length_cql(64) == "chunk_length_kb = 64"
    end
  end

  describe "crc_check_chance_cql/1" do
    test "generates CQL for valid float" do
      assert Compression.crc_check_chance_cql(0.5) == "crc_check_chance = 0.5"
    end
  end

  describe "compression_clause/2" do
    test "generates full clause with algorithm only" do
      assert Compression.compression_clause(:lz4) ==
               "WITH compression = {'class': 'LZ4Compressor'}"
    end

    test "generates full clause with options" do
      cql = Compression.compression_clause(:lz4, chunk_length_kb: 64)
      assert cql =~ "WITH compression ="
      assert cql =~ "LZ4Compressor"
      assert cql =~ "'chunk_length_kb': 64"
    end
  end

  describe "estimated_size/2" do
    test "estimates based on algorithm ratio" do
      value = String.duplicate("a", 1000)
      size = Compression.estimated_size(value, :deflate)
      assert is_integer(size)
      assert size < 1000
    end

    test "unknown algorithm defaults to 0.5 ratio" do
      size = Compression.estimated_size("test", :unknown)
      assert size == 2
    end
  end

  describe "default_threshold/0" do
    test "returns 1024" do
      assert Compression.default_threshold() == 1024
    end
  end

  describe "should_compress?/2" do
    test "returns false for value below threshold" do
      refute Compression.should_compress?("small", 1024)
    end

    test "returns true for value above threshold" do
      assert Compression.should_compress?(String.duplicate("a", 2048), 1024)
    end

    test "returns false for value equal to threshold" do
      refute Compression.should_compress?(String.duplicate("a", 1024), 1024)
    end
  end

  describe "external compression packages" do
    test "lz4 raises when package not available" do
      assert_raise ArgumentError, ~r/LZ4 compression/, fn ->
        Compression.compress("test", :lz4)
      end
    end

    test "snappy raises when package not available" do
      assert_raise ArgumentError, ~r/Snappy compression/, fn ->
        Compression.compress("test", :snappy)
      end
    end

    test "zstd raises when package not available" do
      assert_raise ArgumentError, ~r/Zstd compression/, fn ->
        Compression.compress("test", :zstd)
      end
    end
  end
end
