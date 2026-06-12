# Copyright [2024] AshScylla Contributors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

defmodule AshScylla.DataLayer.Compression do
  @moduledoc """
  Compression support for large payloads in ScyllaDB.

  Provides:
  - Application-level compression/decompression for large text and binary fields
  - Table-level compression configuration CQL generation
  - Transparent compression for fields marked as compressible

  ## Compression Algorithms

  - `:lz4` — Fast compression/decompression, good for real-time workloads
  - `:snappy` — Google's Snappy, balanced speed/ratio
  - `:deflate` — zlib/gzip, better ratio but slower
  - `:zstd` — Zstandard, excellent ratio with good speed

  ## Usage

      # Compress a value before storing
      compressed = AshScylla.DataLayer.Compression.compress(large_text, :zstd)

      # Decompress after reading
      original = AshScylla.DataLayer.Compression.decompress(compressed, :zstd)

      # Generate table compression CQL
      AshScylla.DataLayer.Compression.table_compression_cql(:lz4)
  """

  @default_threshold 1024

  @algorithm_markers %{
    lz4: <<1>>,
    snappy: <<2>>,
    deflate: <<3>>,
    zstd: <<4>>
  }

  @algorithm_classes %{
    lz4: "LZ4Compressor",
    snappy: "SnappyCompressor",
    deflate: "DeflateCompressor",
    zstd: "ZstdCompressor"
  }

  @compression_ratios %{
    lz4: 0.5,
    snappy: 0.55,
    deflate: 0.35,
    zstd: 0.3
  }

  @doc """
  Compresses a binary value using the specified algorithm.

  The compressed output is prefixed with a 1-byte algorithm marker so that
  `decompress/2` can identify which algorithm was used.

  ## Examples

      iex> AshScylla.DataLayer.Compression.compress("hello world", :deflate)
      <<3, ...>>

      iex> AshScylla.DataLayer.Compression.compress("hello world", :lz4)
      <<1, ...>>
  """
  @spec compress(binary(), atom()) :: binary()
  def compress(value, algorithm) when is_binary(value) and is_atom(algorithm) do
    marker = Map.fetch!(@algorithm_markers, algorithm)
    compressed = do_compress(value, algorithm)
    <<marker::binary, compressed::binary>>
  end

  @doc """
  Decompresses a binary value using the algorithm indicated by the 1-byte marker prefix.

  ## Examples

      iex> data = AshScylla.DataLayer.Compression.compress("hello world", :deflate)
      iex> AshScylla.DataLayer.Compression.decompress(data, :deflate)
      "hello world"
  """
  @spec decompress(binary(), atom()) :: binary()
  def decompress(<<marker::binary-size(1), compressed::binary>>, algorithm) do
    expected_marker = Map.fetch!(@algorithm_markers, algorithm)

    if marker != expected_marker do
      raise ArgumentError,
            "Algorithm marker mismatch: expected #{inspect(expected_marker)}, got #{inspect(marker)}. " <>
              "Ensure the correct algorithm is used for decompression."
    end

    do_decompress(compressed, algorithm)
  end

  def decompress(data, _algorithm) when is_binary(data) do
    raise ArgumentError,
          "Cannot decompress: data is too short (missing algorithm marker). " <>
            "Got #{byte_size(data)} bytes."
  end

  @doc """
  Compresses a value only if it exceeds the given threshold size.

  Returns `{:compressed, compressed_binary}` if the value was compressed,
  or `{:ok, original_binary}` if the value was below the threshold.

  ## Examples

      iex> AshScylla.DataLayer.Compression.compress_if_large("small", :deflate, 1024)
      {:ok, "small"}

      iex> AshScylla.DataLayer.Compression.compress_if_large(String.duplicate("a", 2048), :deflate, 1024)
      {:compressed, <<3, ...>>}
  """
  @spec compress_if_large(binary(), atom(), non_neg_integer()) ::
          {:compressed, binary()} | {:ok, binary()}
  def compress_if_large(value, algorithm, threshold)
      when is_binary(value) and is_atom(algorithm) and is_integer(threshold) and threshold >= 0 do
    if should_compress?(value, threshold) do
      {:compressed, compress(value, algorithm)}
    else
      {:ok, value}
    end
  end

  @doc """
  Generates CQL for table-level compression configuration.

  Returns the `compression = {...}` clause value as a string.

  ## Examples

      iex> AshScylla.DataLayer.Compression.table_compression_cql(:lz4)
      "compression = {'class': 'LZ4Compressor'}"

      iex> AshScylla.DataLayer.Compression.table_compression_cql(:snappy, chunk_length_kb: 64)
      "compression = {'class': 'SnappyCompressor', 'chunk_length_kb': 64}"
  """
  @spec table_compression_cql(atom(), keyword()) :: String.t()
  def table_compression_cql(algorithm, opts \\ []) when is_atom(algorithm) and is_list(opts) do
    class = Map.fetch!(@algorithm_classes, algorithm)
    base = "'class': '#{class}'"

    extras =
      opts
      |> Enum.map(fn
        {:chunk_length_kb, val} when is_integer(val) and val > 0 ->
          "'chunk_length_kb': #{val}"

        {:crc_check_chance, val} when is_float(val) and val >= 0.0 and val <= 1.0 ->
          "'crc_check_chance': #{val}"

        {key, val} ->
          raise ArgumentError,
                "Unknown compression option: #{inspect(key)} with value #{inspect(val)}"
      end)
      |> Enum.join(", ")

    inner =
      if extras != "" do
        "#{base}, #{extras}"
      else
        base
      end

    "compression = {#{inner}}"
  end

  @doc """
  Generates CQL for the default compression class.

  Returns a `WITH compression = {'class': '...'}` clause.

  ## Examples

      iex> AshScylla.DataLayer.Compression.default_compression_cql(:lz4)
      "WITH compression = {'class': 'LZ4Compressor'}"
  """
  @spec default_compression_cql(atom()) :: String.t()
  def default_compression_cql(algorithm) when is_atom(algorithm) do
    "WITH #{table_compression_cql(algorithm)}"
  end

  @doc """
  Generates CQL for chunk length configuration.

  Returns a `chunk_length_kb = N` string suitable for inclusion in a compression clause.

  ## Examples

      iex> AshScylla.DataLayer.Compression.chunk_length_cql(64)
      "chunk_length_kb = 64"
  """
  @spec chunk_length_cql(non_neg_integer()) :: String.t()
  def chunk_length_cql(size_kb) when is_integer(size_kb) and size_kb > 0 do
    "chunk_length_kb = #{size_kb}"
  end

  @doc """
  Generates CQL for CRC check chance configuration.

  Returns a `crc_check_chance = N` string suitable for inclusion in a compression clause.

  ## Examples

      iex> AshScylla.DataLayer.Compression.crc_check_chance_cql(0.5)
      "crc_check_chance = 0.5"
  """
  @spec crc_check_chance_cql(float()) :: String.t()
  def crc_check_chance_cql(chance) when is_float(chance) and chance >= 0.0 and chance <= 1.0 do
    "crc_check_chance = #{chance}"
  end

  @doc """
  Generates the full compression clause for a CREATE TABLE statement.

  Combines algorithm class, chunk length, and CRC check chance into a single
  `WITH compression = {...}` clause.

  ## Options

  - `:chunk_length_kb` — Chunk size in kilobytes (positive integer)
  - `:crc_check_chance` — Probability of CRC check (float between 0.0 and 1.0)

  ## Examples

      iex> AshScylla.DataLayer.Compression.compression_clause(:lz4, chunk_length_kb: 64)
      "WITH compression = {'class': 'LZ4Compressor', 'chunk_length_kb': 64}"

      iex> AshScylla.DataLayer.Compression.compression_clause(:zstd, chunk_length_kb: 128, crc_check_chance: 0.75)
      "WITH compression = {'class': 'ZstdCompressor', 'chunk_length_kb': 128, 'crc_check_chance': 0.75}"
  """
  @spec compression_clause(atom(), keyword()) :: String.t()
  def compression_clause(algorithm, opts \\ []) when is_atom(algorithm) and is_list(opts) do
    "WITH #{table_compression_cql(algorithm, opts)}"
  end

  @doc """
  Estimates the compressed size without actually compressing.

  Uses a heuristic ratio based on the algorithm. This is useful for deciding
  whether compression is worthwhile before actually compressing.

  ## Examples

      iex> AshScylla.DataLayer.Compression.estimated_size(String.duplicate("a", 1000), :deflate)
      350
  """
  @spec estimated_size(binary(), atom()) :: non_neg_integer()
  def estimated_size(value, algorithm) when is_binary(value) and is_atom(algorithm) do
    ratio = Map.get(@compression_ratios, algorithm, 0.5)
    trunc(byte_size(value) * ratio)
  end

  @doc """
  Returns the default compression threshold in bytes.

  Values smaller than this threshold are not compressed by `compress_if_large/3`.

  ## Examples

      iex> AshScylla.DataLayer.Compression.default_threshold()
      1024
  """
  @spec default_threshold() :: non_neg_integer()
  def default_threshold, do: @default_threshold

  @doc """
  Checks if a value should be compressed based on size threshold.

  Returns `true` if the byte size of the value exceeds the threshold.

  ## Examples

      iex> AshScylla.DataLayer.Compression.should_compress?("small", 1024)
      false

      iex> AshScylla.DataLayer.Compression.should_compress?(String.duplicate("a", 2048), 1024)
      true
  """
  @spec should_compress?(binary(), non_neg_integer()) :: boolean()
  def should_compress?(value, threshold) when is_binary(value) and is_integer(threshold) do
    byte_size(value) > threshold
  end

  # ---------------------------------------------------------------------------
  # Private functions
  # ---------------------------------------------------------------------------

  @doc false
  defp do_compress(value, :deflate) do
    :zlib.compress(value)
  end

  defp do_compress(value, :lz4) do
    # NOTE: For production use with LZ4, add the `lz4` package and use
    # `:lz4.raw_compress/1` instead. This fallback uses zlib for portability.
    :zlib.compress(value)
  end

  defp do_compress(value, :snappy) do
    # NOTE: For production use with Snappy, add the `snappy` package and use
    # `:snappy.compress/1` instead. This fallback uses zlib for portability.
    :zlib.compress(value)
  end

  defp do_compress(value, :zstd) do
    # NOTE: For production use with Zstd, add the `ezstd` package and use
    # `:ezstd.compress/1` instead. This fallback uses zlib for portability.
    :zlib.compress(value)
  end

  @doc false
  defp do_decompress(value, :deflate) do
    :zlib.uncompress(value)
  end

  defp do_decompress(value, :lz4) do
    # NOTE: For production use with LZ4, add the `lz4` package and use
    # `:lz4.raw_uncompress/1` instead.
    :zlib.uncompress(value)
  end

  defp do_decompress(value, :snappy) do
    # NOTE: For production use with Snappy, add the `snappy` package and use
    # `:snappy.decompress/1` instead.
    :zlib.uncompress(value)
  end

  defp do_decompress(value, :zstd) do
    # NOTE: For production use with Zstd, add the `ezstd` package and use
    # `:ezstd.decompress/1` instead.
    :zlib.uncompress(value)
  end
end
