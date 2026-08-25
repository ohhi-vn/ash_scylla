defmodule AshScylla.Search.Indexer.DeleterTest do
  use ExUnit.Case, async: true

  alias AshScylla.Search.Indexer.Deleter

  @uuid "550e8400-e29b-41d4-a716-446655440000"

  defmodule FailingRepo do
    def query(_cql, _params), do: {:error, :mock_error}
  end

  defmodule EmptyRepo do
    def query(_cql, _params), do: {:ok, %{rows: []}}
  end

  # Storage.fetch_field_maps shape: rows of [field, %{term => tf}]
  defmodule TwoFieldRepo do
    def query("SELECT field, terms" <> _, _params),
      do:
        {:ok,
         %{
           rows: [
             ["title", %{"hello" => 1}],
             ["body", %{"world" => 2, "shared" => 3}]
           ]
         }}

    def query(cql, params),
      do:
        (
          send(self(), {:cql, {cql, params}})
          {:ok, %{rows: []}}
        )
  end

  defmodule FieldsFailOnFieldRowDeleteRepo do
    def query("SELECT field, terms" <> _, _params), do: {:ok, %{rows: [["title", %{"t1" => 1}]]}}

    def query(cql, _params) do
      if String.contains?(cql, "search_post_fields") do
        {:error, :field_delete_error}
      else
        {:ok, %{rows: []}}
      end
    end
  end

  describe "delete/3" do
    test "rejects invalid post_id" do
      assert {:error, _} = Deleter.delete(FailingRepo, "ks", "post-1")
    end

    test "returns error when the fetch fails" do
      assert Deleter.delete(FailingRepo, "ks", @uuid) == {:error, :mock_error}
    end

    test "returns :ok when post has no fields" do
      assert Deleter.delete(EmptyRepo, "ks", @uuid) == :ok
    end

    test "deletes one posting row per unique term and clears all field rows" do
      assert Deleter.delete(TwoFieldRepo, "ks", @uuid) == :ok

      saw = collect_until_done([])
      deletes = for({"delete", t} <- saw, do: t)
      assert Enum.sort(deletes) == ["hello", "shared", "world"]
      assert {:fields_cleared, [@uuid]} in saw
    end

    test "returns error when deleting field rows fails" do
      assert Deleter.delete(FieldsFailOnFieldRowDeleteRepo, "ks", @uuid) ==
               {:error, :field_delete_error}
    end
  end

  describe "delete_field/4" do
    defmodule SharedTermRepo do
      # title has "shared"=2, body has "shared"=5 -> doc total 7.
      def query("SELECT field, terms" <> _, _params),
        do: {:ok, %{rows: [["title", %{"solo" => 1, "shared" => 2}], ["body", %{"shared" => 5}]]}}

      def query(cql, params),
        do:
          (
            send(self(), {:cql, {cql, params}})
            {:ok, %{rows: []}}
          )
    end

    test "rejects invalid post_id" do
      assert {:error, _} = Deleter.delete_field(FailingRepo, "ks", "nope", "title")
    end

    test "removes solo terms, lowers shared totals, clears the field row" do
      assert Deleter.delete_field(SharedTermRepo, "ks", @uuid, "title") == :ok

      saw = collect_until_done([])

      assert {"delete", "solo"} in saw
      assert {"upsert", {"shared", 5}} in saw
      refute {"delete", "shared"} in saw
      assert {:fields_cleared, [@uuid, "title"]} in saw
    end

    test "still clears an unknown fields row" do
      defmodule GhostCaptureRepo do
        def query("SELECT field, terms" <> _, _params), do: {:ok, %{rows: []}}

        def query(cql, params),
          do:
            (
              send(self(), {:cql, {cql, params}})
              {:ok, %{rows: []}}
            )
      end

      assert Deleter.delete_field(GhostCaptureRepo, "ks", @uuid, "ghost") == :ok
      assert_received {:cql, {fields_cql, [@uuid, "ghost"]}}
      assert fields_cql =~ ~r/DELETE FROM .*search_post_fields/
    end
  end

  defp collect_until_done(acc) do
    receive do
      {:cql, {cql, params}} = msg ->
        cond do
          cql =~ ~r/DELETE FROM .*search_post_terms/ ->
            [term, @uuid] = params
            collect_until_done([{"delete", term} | acc])

          String.contains?(cql, "BEGIN UNLOGGED BATCH") and cql =~ "search_post_terms" ->
            ups =
              Regex.scan(~r/'[^']+', \d+, #{@uuid}, (\d+)/, cql)
              |> Enum.map(fn [_all, tf] -> String.to_integer(tf) end)

            terms =
              Regex.scan(~r/'([^']+)', \d+, #{@uuid}, \d+/, cql)
              |> Enum.map(fn [_, t] -> t end)

            ups = Enum.zip(terms, ups) |> Enum.map(&{"upsert", &1})
            collect_until_done(ups ++ acc)

          Regex.match?(~r/DELETE FROM .*search_post_fields.*field = \?$/, cql) or
              Regex.match?(~r/DELETE FROM .*search_post_fields["\s]*WHERE post_id = \?$/, cql) ->
            collect_until_done([{:fields_cleared, params} | acc])

          true ->
            _ = msg
            collect_until_done(acc)
        end

      _ ->
        collect_until_done(acc)
    after
      50 ->
        acc
    end
  end
end
