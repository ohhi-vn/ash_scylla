defmodule AshScylla.DataLayer.Batch do
  @moduledoc """
  Batch operations support for AshScylla using ScyllaDB's BATCH statements.

  ScyllaDB/Cassandra supports batch operations for executing multiple
  CQL statements in a single request.
  """

  @moduledoc since: "1.0.0"

  @doc """
  Executes a batch of INSERT statements.

  ## Examples:

      statements = [
        {"INSERT INTO users (id, name) VALUES (?, ?)", [id1, "Alice"]},
        {"INSERT INTO users (id, name) VALUES (?, ?)", [id2, "Bob"]}
      ]

      DataLayer.Batch.batch_insert(repo, statements)
  """
  def batch_insert(repo, statements, opts \\ []) do
    case statements do
      [] -> {:ok, []}
      _ ->
        # Build BATCH statement
        {batch_query, all_params} =
          statements
          |> Enum.with_index()
          |> Enum.reduce({"BATCH BEGIN\n", []}, fn {{query, params}, _i}, {acc_q, acc_p} ->
            {"#{acc_q}  #{query};\n", acc_p ++ params}
          end)

        batch_query = "#{batch_query}APPLY BATCH;"

        repo.query(batch_query, all_params, opts)
    end
  end

  @doc """
  Executes a batch of UPDATE statements.
  """
  def batch_update(repo, statements, opts \\ []) do
    case statements do
      [] -> {:ok, []}
      _ ->
        # Build BATCH statement
        {batch_query, all_params} =
          statements
          |> Enum.with_index()
          |> Enum.reduce({"BATCH BEGIN\n", []}, fn {{query, params}, _i}, {acc_q, acc_p} ->
            {"#{acc_q}  #{query};\n", acc_p ++ params}
          end)

        batch_query = "#{batch_query}APPLY BATCH;"

        repo.query(batch_query, all_params, opts)
    end
  end

  @doc """
  Executes a batch of DELETE statements.
  """
  def batch_delete(repo, statements, opts \\ []) do
    case statements do
      [] -> {:ok, []}
      _ ->
        # Build BATCH statement
        {batch_query, all_params} =
          statements
          |> Enum.with_index()
          |> Enum.reduce({"BATCH BEGIN\n", []}, fn {{query, params}, _i}, {acc_q, acc_p} ->
            {"#{acc_q}  #{query};\n", acc_p ++ params}
          end)

        batch_query = "#{batch_query}APPLY BATCH;"

        repo.query(batch_query, all_params, opts)
    end
  end
end
