defmodule AshScylla.DataLayerFakeRepoTest do
  @moduledoc """
  Exercises the write/read paths of `AshScylla.DataLayer` (create, update,
  destroy, upsert, bulk_create, attach_aggregates) against a scripted fake
  repo so every result branch is covered without a running ScyllaDB.
  """

  use ExUnit.Case, async: false

  alias AshScylla.DataLayer
  alias AshScylla.DataLayer.Types

  @uuid Ash.UUID.generate()

  defmodule FakeCoverageRepo do
    @moduledoc false

    def start do
      if Process.whereis(__MODULE__) do
        :ok
      else
        Agent.start_link(fn -> :queue.new() end, name: __MODULE__)
      end
    end

    def stop do
      case Process.whereis(__MODULE__) do
        nil ->
          :ok

        pid ->
          Agent.stop(pid)
          :ok
      end
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    def reset do
      Agent.update(__MODULE__, fn _q -> :queue.new() end)
    end

    def enqueue(responses) when is_list(responses) do
      Enum.each(responses, &enqueue/1)
    end

    def enqueue(response) do
      Agent.update(__MODULE__, fn q -> :queue.in(response, q) end)
    end

    def query(_query, _params, opts \\ []) do
      case Agent.get_and_update(__MODULE__, fn q ->
             case :queue.out(q) do
               # Function responses are sticky: they stay queued so a single
               # dispatcher can serve any number of concurrent queries.
               {{:value, fun}, _rest} when is_function(fun, 3) ->
                 {fun, :queue.in(fun, q)}

               {{:value, response}, rest} ->
                 {response, rest}

               {:empty, q} ->
                 {{:error, :no_scripted_response}, q}
             end
           end) do
        fun when is_function(fun, 3) -> fun.(_query, _params, opts)
        response -> response
      end
    end
  end

  defmodule CoverageCrudResource do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

    import AshScylla.DataLayer.Dsl, only: [scylla: 1]

    scylla do
      repo(FakeCoverageRepo)
      table("coverage_crud")
      keyspace("coverage_ks")
      lwt(true)
      ttl(100)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:status, :atom, public?: true)
      attribute(:name, :string, public?: true)
    end

    code_interface do
      define(:create, action: :create)
    end

    actions do
      defaults([:create, :read, :update, :destroy])
    end
  end

  defmodule CoverageCompositeResource do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

    import AshScylla.DataLayer.Dsl, only: [scylla: 1]

    scylla do
      repo(FakeCoverageRepo)
      table("coverage_composite")
      keyspace("coverage_ks")
    end

    attributes do
      attribute(:id, :uuid, public?: true, primary_key?: true, allow_nil?: false)
      attribute(:code, :string, public?: true, primary_key?: true, allow_nil?: false)
    end
  end

  defmodule CoverageParentResource do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

    import AshScylla.DataLayer.Dsl, only: [scylla: 1]

    scylla do
      repo(FakeCoverageRepo)
      table("coverage_parents")
      keyspace("coverage_ks")
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:score, :integer, public?: true)
    end
  end


  defmodule CoverageCompositeAsParentResource do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

    import AshScylla.DataLayer.Dsl, only: [scylla: 1]

    scylla do
      repo(FakeCoverageRepo)
      table("coverage_composite_parent")
      keyspace("coverage_ks")
    end

    attributes do
      attribute(:id, :uuid, public?: true, primary_key?: true, allow_nil?: false)
      attribute(:id2, :string, public?: true, primary_key?: true, allow_nil?: false)
    end

    relationships do
      belongs_to(:parent, CoverageCompositeResource) do
        source_attribute(:id)
        public?(true)
      end
    end
  end

  defmodule CoverageChildResource do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

    import AshScylla.DataLayer.Dsl, only: [scylla: 1]

    scylla do
      repo(FakeCoverageRepo)
      table("coverage_children")
      keyspace("coverage_ks")
    end

    attributes do
      uuid_primary_key(:id)
    end

    relationships do
      belongs_to(:parent, CoverageParentResource) do
        public?(true)
      end

      has_many(:children, CoverageChildResource) do
        destination_attribute(:parent_id)
        public?(true)
      end
    end
  end

  setup do
    FakeCoverageRepo.start()
    FakeCoverageRepo.reset()
    on_exit(fn -> FakeCoverageRepo.stop() end)

    %{changeset: %Ash.Changeset{attributes: %{}, filter: nil, atomics: [], casted_attributes: %{}}}
  end

  defp page(rows, columns \\ nil), do: {:ok, %Xandra.Page{content: rows, columns: columns}}

  # ---------------------------------------------------------------------------
  # create/2 — insert + fetch_by_primary_key branches
  # ---------------------------------------------------------------------------

  describe "create/2" do
    test "returns the fetched record when the row comes back with typed columns" do
      cols = [{"coverage_ks", "coverage_crud", "id", :uuid}, {"coverage_ks", "coverage_crud", "name", :text}]

      FakeCoverageRepo.enqueue([
        page([]),
        page([[@uuid, "n"]], cols)
      ])

      changeset = %Ash.Changeset{attributes: %{id: @uuid, name: "n"}, filter: nil}

      assert {:ok, record} = DataLayer.create(CoverageCrudResource, changeset)
      assert record.id == @uuid
      assert record.name == "n"
    end

    test "maps rows without column metadata through plain-map fakes" do
      FakeCoverageRepo.enqueue([
        {:ok, %{content: []}},
        {:ok, %{content: [[@uuid]], columns: ["id"]}}
      ])

      changeset = %Ash.Changeset{attributes: %{id: @uuid}, filter: nil}

      assert {:ok, record} = DataLayer.create(CoverageCrudResource, changeset)
      assert record.id == @uuid
    end

    test "returns not-found when the select returns no rows" do
      FakeCoverageRepo.enqueue([page([]), page([])])

      changeset = %Ash.Changeset{attributes: %{id: @uuid}, filter: nil}

      assert {:error, error} = DataLayer.create(CoverageCrudResource, changeset)
      assert error.message =~ "Record not found"
    end

    test "returns not-found when content is nil" do
      FakeCoverageRepo.enqueue([page([]), page(nil)])

      changeset = %Ash.Changeset{attributes: %{id: @uuid}, filter: nil}

      assert {:error, error} = DataLayer.create(CoverageCrudResource, changeset)
      assert error.message =~ "Record not found"
    end

    test "wraps query failures into AshScylla errors" do
      FakeCoverageRepo.enqueue([{:error, %Xandra.ConnectionError{action: "insert", reason: :closed}}])

      changeset = %Ash.Changeset{attributes: %{id: @uuid}, filter: nil}

      assert {:error, %AshScylla.Error.ScyllaError{}} = DataLayer.create(CoverageCrudResource, changeset)
    end

    test "tags invalid uuid strings as uuid params instead of crashing" do
      FakeCoverageRepo.enqueue([{:error, :stop_early}])

      changeset = %Ash.Changeset{attributes: %{id: "not-a-uuid"}, filter: nil}

      assert {:error, _} = DataLayer.create(CoverageCrudResource, changeset)
    end
  end

  # ---------------------------------------------------------------------------
  # update/2 — LWT and no-op branches
  # ---------------------------------------------------------------------------

  describe "update/2" do
    test "returns StaleRecord when LWT reports the row as missing" do
      FakeCoverageRepo.enqueue([page([[false]])])

      changeset = %Ash.Changeset{
        attributes: %{id: @uuid},
        filter: nil,
        atomics: [],
        casted_attributes: %{},
        data: %CoverageCrudResource{id: @uuid}
      }

      assert {:error, %Ash.Error.Changes.StaleRecord{} = error} =
               DataLayer.update(CoverageCrudResource, changeset)

      assert error.resource == CoverageCrudResource
    end

    test "fetches the updated record after a successful conditional update" do
      FakeCoverageRepo.enqueue([
        page([[true]]),
        page([[@uuid]], [{"coverage_ks", "coverage_crud", "id", :uuid}])
      ])

      changeset = %Ash.Changeset{
        attributes: %{name: "updated"},
        filter: nil,
        atomics: [],
        casted_attributes: %{},
        data: %CoverageCrudResource{id: @uuid}
      }

      assert {:ok, record} = DataLayer.update(CoverageCrudResource, changeset)
      assert record.id == @uuid
    end

    test "wraps update failures" do
      FakeCoverageRepo.enqueue([{:error, :update_failed}])

      changeset = %Ash.Changeset{
        attributes: %{name: "updated"},
        filter: nil,
        atomics: [],
        casted_attributes: %{},
        data: %CoverageCrudResource{id: @uuid}
      }

      assert {:error, %AshScylla.Error.ScyllaError{}} = DataLayer.update(CoverageCrudResource, changeset)
    end

    test "skips the UPDATE entirely when nothing changed and fetches instead" do
      FakeCoverageRepo.enqueue([
        page([[@uuid]], [{"ks", "t", "id", :uuid}])
      ])

      changeset = %Ash.Changeset{
        attributes: %{},
        filter: nil,
        atomics: [],
        casted_attributes: %{},
        data: %CoverageCrudResource{id: @uuid}
      }

      assert {:ok, record} = DataLayer.update(CoverageCrudResource, changeset)
      assert record.id == @uuid
    end

    test "uses simple atomic values when attributes are empty" do
      FakeCoverageRepo.enqueue([
        page([[true]]),
        page([[@uuid]], [{"coverage_ks", "coverage_crud", "id", :uuid}])
      ])

      changeset = %Ash.Changeset{
        attributes: %{},
        atomics: [{:name, "from_atomic"}, {:other_expr, {:if, []}}],
        casted_attributes: %{},
        data: %CoverageCrudResource{id: @uuid}
      }

      assert {:ok, record} = DataLayer.update(CoverageCrudResource, changeset)
      assert record.id == @uuid
    end
  end

  # ---------------------------------------------------------------------------
  # destroy/2 — LWT delete branches
  # ---------------------------------------------------------------------------

  describe "destroy/2" do
    test "returns :ok when LWT confirms deletion" do
      FakeCoverageRepo.enqueue([page([[true]])])

      changeset = %Ash.Changeset{
        attributes: %{id: @uuid},
        filter: nil,
        atomics: [],
        casted_attributes: %{}
      }

      assert :ok = DataLayer.destroy(CoverageCrudResource, changeset)
    end

    test "returns StaleRecord when the row was already gone" do
      FakeCoverageRepo.enqueue([page([[false]])])

      changeset = %Ash.Changeset{
        attributes: %{id: @uuid},
        filter: nil,
        atomics: [],
        casted_attributes: %{}
      }

      assert {:error, %Ash.Error.Changes.StaleRecord{}} =
               DataLayer.destroy(CoverageCrudResource, changeset)
    end

    test "returns :ok for non-LWT acknowledgements" do
      FakeCoverageRepo.enqueue([{:ok, %{content: []}}])

      changeset = %Ash.Changeset{
        attributes: %{id: @uuid},
        filter: nil,
        atomics: [],
        casted_attributes: %{}
      }

      assert :ok = DataLayer.destroy(CoverageCrudResource, changeset)
    end

    test "wraps delete failures" do
      FakeCoverageRepo.enqueue([{:error, :delete_failed}])

      changeset = %Ash.Changeset{
        attributes: %{id: @uuid},
        filter: nil,
        atomics: [],
        casted_attributes: %{}
      }

      assert {:error, %AshScylla.Error.ScyllaError{}} = DataLayer.destroy(CoverageCrudResource, changeset)
    end

    test "composite primary keys produce multi-clause where clauses" do
      changeset = %Ash.Changeset{
        attributes: %{id: @uuid, code: "C-1"},
        filter: nil,
        atomics: [],
        casted_attributes: %{}
      }

      FakeCoverageRepo.enqueue([
        fn q, p, _o ->
          send(self(), {:query, q, p})
          page([[true]])
        end
      ])

      assert :ok = DataLayer.destroy(CoverageCompositeResource, changeset)

      assert_receive {:query, query, params}, 5_000
      assert query =~ "DELETE FROM coverage_ks.coverage_composite WHERE"
      assert query =~ "id = ?"
      assert query =~ "code = ?"
      assert length(params) == 2
      assert {"text", "C-1"} in params

      uuid = @uuid

      assert Enum.any?(params, fn
               {"uuid", <<_::128>>} -> true
               ^uuid -> true
               _ -> false
             end)
    end
  end

  # ---------------------------------------------------------------------------
  # upsert — LWT conflict handling
  # ---------------------------------------------------------------------------

  describe "upsert/2,3,4" do
    defp upsert_changeset do
      %Ash.Changeset{
        attributes: %{id: @uuid, name: "v2"},
        filter: nil,
        atomics: [],
        casted_attributes: %{},
        data: %CoverageCrudResource{id: @uuid}
      }
    end

    test "returns the record when the insert applies" do
      FakeCoverageRepo.enqueue([page([[true]])])

      assert {:ok, record} = DataLayer.upsert(CoverageCrudResource, upsert_changeset())
      assert record.id == @uuid
    end

    test "falls back to an update when the LWT loses a race" do
      FakeCoverageRepo.enqueue([
        page([[false]]),
        page([[true]]),
        page([[@uuid]], [{"coverage_ks", "coverage_crud", "id", :uuid}])
      ])

      assert {:ok, record} = DataLayer.upsert(CoverageCrudResource, upsert_changeset(), [:name])
      assert record.id == @uuid
    end

    test "accepts non-boolean acknowledgements" do
      FakeCoverageRepo.enqueue([page([])])

      assert {:ok, record} = DataLayer.upsert(CoverageCrudResource, upsert_changeset(), [:name])
      assert record.id == @uuid
    end

    test "wraps upsert failures" do
      FakeCoverageRepo.enqueue([{:error, :upsert_failed}])

      assert {:error, %AshScylla.Error.ScyllaError{}} =
               DataLayer.upsert(CoverageCrudResource, upsert_changeset())
    end

    test "the identity clause delegates to upsert/3" do
      FakeCoverageRepo.enqueue([page([[true]])])

      assert {:ok, _} =
               DataLayer.upsert(CoverageCrudResource, upsert_changeset(), [:name], nil)
    end
  end

  # ---------------------------------------------------------------------------
  # bulk_create/3 — chunking and option normalization
  # ---------------------------------------------------------------------------

  describe "bulk_create/3" do
    test "returns a lazy record stream keyed off return_records?" do
      FakeCoverageRepo.enqueue([{:ok, []}])

      changesets = [%Ash.Changeset{attributes: %{id: @uuid}, filter: nil}]

      assert {:ok, stream} =
               DataLayer.bulk_create(CoverageCrudResource, changesets, %{
                 batch_size: :infinity
               })

      assert [%CoverageCrudResource{}] = Enum.to_list(stream)
    end

    test "returns an empty list when records are not requested" do
      FakeCoverageRepo.enqueue([{:ok, []}])

      assert {:ok, []} =
               DataLayer.bulk_create(
                 CoverageCrudResource,
                 [%Ash.Changeset{attributes: %{id: @uuid}, filter: nil}],
                 return_records?: false
               )
    end

    test "caps batch size and wraps batch failures" do
      FakeCoverageRepo.enqueue([{:error, :batch_failed}])

      assert {:error, %AshScylla.Error.ScyllaError{}} =
               DataLayer.bulk_create(
                 CoverageCrudResource,
                 [%Ash.Changeset{attributes: %{id: @uuid}, filter: nil}],
                 []
               )
    end
  end

  # ---------------------------------------------------------------------------
  # run_aggregate_query/3 and attach_aggregates/5
  # ---------------------------------------------------------------------------

  describe "aggregate support" do
    test "run_aggregate_query computes count values from the scripted repo" do
      FakeCoverageRepo.enqueue([page([[7]])])

      query = %AshScylla.Query{repo: FakeCoverageRepo, table: "coverage_crud"}

      aggregate = %{
        name: :total,
        kind: :count,
        field: nil,
        relationship_path: [],
        query: nil,
        default_value: 0
      }

      assert {:ok, %{total: 7}} = DataLayer.run_aggregate_query(query, [aggregate], CoverageCrudResource)
    end

    test "attach_aggregates ignores empty aggregate lists" do
      records = [%{id: @uuid, aggregates: %{}}]
      assert ^records = DataLayer.attach_aggregates(records, [], CoverageCrudResource, FakeCoverageRepo, [])
    end

    test "attach_aggregates skips computation without a repo" do
      records = [%{id: @uuid, aggregates: %{}}]

      aggregate = %{name: :c, kind: :count, field: nil, relationship_path: [], query: nil, default_value: 0}

      assert ^records =
               DataLayer.attach_aggregates(records, [aggregate], CoverageCrudResource, nil, [])
    end

    test "same-table aggregates read values and fall back to defaults on errors" do
      # attach_aggregates computes records concurrently, so responses are
      # dispatched per primary key rather than by queue order.
      second_uuid = Ash.UUID.generate()
      {:ok, first_bin} = Types.uuid_string_to_binary(@uuid)
      {:ok, second_bin} = Types.uuid_string_to_binary(second_uuid)

      FakeCoverageRepo.enqueue([
        fn _q, params, _o ->
          case params do
            [{"uuid", ^first_bin}] -> page([[3]])
            [{"uuid", ^second_bin}] -> {:error, :agg_failed}
          end
        end
      ])

      aggregate = %{name: :c, kind: :count, field: nil, relationship_path: [], query: nil, default_value: 0}
      records = [%{id: @uuid, aggregates: %{}}, %{id: second_uuid, aggregates: %{}}]

      [first, second] =
        DataLayer.attach_aggregates(records, [aggregate], CoverageCrudResource, FakeCoverageRepo, [])

      assert first.aggregates.c == 3
      assert second.aggregates.c == 0
    end

    test "belongs-to relationship aggregates resolve values from the related table" do
      parent_id = Ash.UUID.generate()
      FakeCoverageRepo.enqueue([page([[9]])])

      aggregate = %{name: :parent_score, kind: :max, field: :score, relationship_path: [:parent], query: nil, default_value: 0}
      records = [%{id: @uuid, parent_id: parent_id, aggregates: %{}}]

      [record] =
        DataLayer.attach_aggregates(records, [aggregate], CoverageChildResource, FakeCoverageRepo, [])

      assert record.aggregates.parent_score == 9
    end

    test "nil aggregate values fall back to the default" do
      FakeCoverageRepo.enqueue([page([[nil]])])

      aggregate = %{name: :parent_score, kind: :sum, field: :score, relationship_path: [:parent], query: nil, default_value: 0}
      records = [%{id: @uuid, parent_id: Ash.UUID.generate(), aggregates: %{}}]

      [record] =
        DataLayer.attach_aggregates(records, [aggregate], CoverageChildResource, FakeCoverageRepo, [])

      assert record.aggregates.parent_score == 0
    end

    test "composite destination keys are unsupported and yield defaults" do
      aggregate = %{name: :cnt, kind: :count, field: nil, relationship_path: [:parent], query: nil, default_value: -1}
      records = [%{id: @uuid, id2: "x", aggregates: %{}}]

      [record] =
        DataLayer.attach_aggregates(
          records,
          [aggregate],
          CoverageCompositeAsParentResource,
          FakeCoverageRepo,
          []
        )

      assert record.aggregates.cnt == -1
    end

    test "has-many relationship aggregates are not yet supported and yield defaults" do
      aggregate = %{name: :kids, kind: :count, field: nil, relationship_path: [:children], query: nil, default_value: 0}
      records = [%{id: @uuid, parent_id: Ash.UUID.generate(), aggregates: %{}}]

      [record] =
        DataLayer.attach_aggregates(records, [aggregate], CoverageChildResource, FakeCoverageRepo, [])

      assert record.aggregates.kids == 0
    end

    test "aggregate queries receive typed primary-key filters" do
      parent = self()

      FakeCoverageRepo.enqueue([
        fn q, _p, _o ->
          send(parent, {:agg_query, q})
          page([[4]])
        end
      ])

      aggregate = %{name: :c, kind: :count, field: nil, relationship_path: [], query: nil, default_value: 0}
      records = [%{id: @uuid, aggregates: %{}}]

      [record] =
        DataLayer.attach_aggregates(records, [aggregate], CoverageCrudResource, FakeCoverageRepo, [])

      assert record.aggregates.c == 4

      assert_receive {:agg_query, q}
      assert q =~ "SELECT COUNT(*) FROM coverage_ks.coverage_crud WHERE id = ?"
    end
  end
end
