defmodule AshScylla.DataLayer.TypePipelineTest do
  @moduledoc """
  Tests the full type pipeline: Ash attribute type → CQL type → Xandra params
  and Xandra row → Ash struct. Covers every Ash type usable with ScyllaDB.
  """

  use ExUnit.Case, async: false

  alias AshScylla.DataLayer

  # ---------------------------------------------------------------------------
  # Fake repo that records typed params and returns typed rows
  # ---------------------------------------------------------------------------

  defmodule FakeTypeRepo do
    @moduledoc false

    def query(query, params, opts \\ []) do
      send(self(), {:ash_scylla_query, query, params, opts})

      # Return the same values back as a row for round-trip testing
      {row_values, _row_types} = extract_values_and_types(params)

      case query do
        "INSERT INTO type_test" <> _ ->
          {:ok, %{content: []}}

        "SELECT * FROM type_test WHERE id = ? LIMIT 1" ->
          {:ok,
           %{
             content: [row_values],
             columns: type_test_columns()
           }}

        "UPDATE type_test SET" <> _ ->
          {:ok, %{content: []}}

        _ ->
          {:error, %{reason: :overloaded}}
      end
    end

    defp extract_values_and_types(params) do
      {values, types} =
        Enum.reduce(params, {[], []}, fn
          {type, value}, {vs, ts} when is_binary(type) ->
            {[value | vs], [type | ts]}

          value, {vs, ts} ->
            {[value | vs], [nil | ts]}
        end)

      {Enum.reverse(values), Enum.reverse(types)}
    end

    defp type_test_columns do
      [
        "id",
        "str_val",
        "int_val",
        "float_val",
        "bool_val",
        "dt_val",
        "date_val",
        "time_val",
        "decimal_val",
        "binary_val",
        "duration_val",
        "naive_dt_val"
      ]
    end
  end

  # ---------------------------------------------------------------------------
  # Test resource with all supported types
  # ---------------------------------------------------------------------------

  defmodule TypeTestResource do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: AshScylla.DataLayer

    import AshScylla.DataLayer.Dsl

    ash_scylla do
      repo(FakeTypeRepo)
      table("type_test")
    end

    attributes do
      uuid_primary_key(:id)

      # Basic types
      attribute(:str_val, :string)
      attribute(:int_val, :integer)
      attribute(:float_val, :float)
      attribute(:bool_val, :boolean)

      # DateTime types
      attribute(:dt_val, :utc_datetime)
      attribute(:naive_dt_val, :naive_datetime)
      attribute(:date_val, :date)
      attribute(:time_val, :time)

      # Decimal
      attribute(:decimal_val, :decimal)

      # Binary
      attribute(:binary_val, :binary)

      # Duration as integer (Ash doesn't have :duration as a DSL atom)
      attribute(:duration_val, :integer)
    end

    actions do
      defaults([:create, :read, :update, :destroy])
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  setup do
    flush_messages()
    :ok
  end

  defp flush_messages do
    receive do
      _ -> flush_messages()
    after
      0 -> :ok
    end
  end

  defp changeset(attrs), do: %Ash.Changeset{attributes: attrs}

  # ---------------------------------------------------------------------------
  # Tests: attr_cql_type_map resolves correctly for all types
  # ---------------------------------------------------------------------------

  describe "attr_cql_type_map type resolution" do
    test "resolves basic types" do
      map = DataLayer.attr_cql_type_map(TypeTestResource)
      assert map[:str_val] == "text"
      assert map[:int_val] == "bigint"
      assert map[:float_val] == "double"
      assert map[:bool_val] == "boolean"
    end

    test "resolves datetime types" do
      map = DataLayer.attr_cql_type_map(TypeTestResource)
      assert map[:dt_val] == "timestamp"
      assert map[:date_val] == "date"
      assert map[:time_val] == "time"
    end

    test "resolves complex types" do
      map = DataLayer.attr_cql_type_map(TypeTestResource)
      assert map[:binary_val] == "blob"
    end

    test "resolves decimal and duration" do
      map = DataLayer.attr_cql_type_map(TypeTestResource)
      assert map[:decimal_val] == "decimal"
      assert map[:duration_val] == "bigint"
    end

    test "integer primary key gets uuid type" do
      map = DataLayer.attr_cql_type_map(TypeTestResource)
      assert map[:id] == "uuid"
    end
  end

  # ---------------------------------------------------------------------------
  # Tests: create/2 sends correctly typed params
  # ---------------------------------------------------------------------------

  describe "create/2 typed params" do
    test "sends float as double (8 bytes) to match ScyllaDB DOUBLE columns" do
      cs = changeset(%{float_val: 1.5})
      assert {:ok, _} = DataLayer.create(TypeTestResource, cs)

      assert_receive {:ash_scylla_query, insert_query, insert_params, _opts}
      assert insert_query =~ "INSERT INTO type_test"

      # Find the float_val param — must be {"double", 1.5}, not {"float", 1.5}
      # ScyllaDB DOUBLE columns require 8-byte encoding; 4-byte float would be rejected.
      double_param = find_param_by_type(insert_params, "double")
      assert double_param == {"double", 1.5}
    end

    test "sends integer as raw value (typed_params handles it)" do
      cs = changeset(%{int_val: 42})
      assert {:ok, _} = DataLayer.create(TypeTestResource, cs)

      assert_receive {:ash_scylla_query, _insert_query, insert_params, _opts}
      # integer is NOT wrapped by wrap_typed — falls through
      assert 42 in get_raw_values(insert_params)
    end

    test "sends boolean as {type, value} tuple" do
      cs = changeset(%{bool_val: true})
      assert {:ok, _} = DataLayer.create(TypeTestResource, cs)

      assert_receive {:ash_scylla_query, _insert_query, insert_params, _opts}
      assert {"boolean", true} in insert_params
    end

    test "sends false boolean as {type, value} tuple" do
      cs = changeset(%{bool_val: false})
      assert {:ok, _} = DataLayer.create(TypeTestResource, cs)

      assert_receive {:ash_scylla_query, _insert_query, insert_params, _opts}
      assert {"boolean", false} in insert_params
    end

    test "boolean tuple prevents CaseClauseError from text encoding" do
      cs = changeset(%{bool_val: false})
      assert {:ok, _} = DataLayer.create(TypeTestResource, cs)

      assert_receive {:ash_scylla_query, _insert_query, insert_params, _opts}
      # The type tag must be "boolean", not "text" — otherwise Xandra would
      # encode the raw false as the string "false" and ScyllaDB raises CaseClauseError.
      refute {"text", "false"} in insert_params
      assert {"boolean", false} in insert_params
    end

    test "sends string as raw value" do
      cs = changeset(%{str_val: "hello"})
      assert {:ok, _} = DataLayer.create(TypeTestResource, cs)

      assert_receive {:ash_scylla_query, _insert_query, insert_params, _opts}
      assert "hello" in get_raw_values(insert_params)
    end

    test "sends DateTime as %DateTime{} struct" do
      dt = ~U[2025-01-15 10:30:00Z]
      cs = changeset(%{dt_val: dt})
      assert {:ok, _} = DataLayer.create(TypeTestResource, cs)

      assert_receive {:ash_scylla_query, _insert_query, insert_params, _opts}
      assert %DateTime{} = find_struct(insert_params, DateTime)
    end

    test "sends Date as %Date{} struct" do
      d = ~D[2025-01-15]
      cs = changeset(%{date_val: d})
      assert {:ok, _} = DataLayer.create(TypeTestResource, cs)

      assert_receive {:ash_scylla_query, _insert_query, insert_params, _opts}
      assert %Date{} = find_struct(insert_params, Date)
    end

    test "sends Time as %Time{} struct" do
      t = ~T[10:30:00]
      cs = changeset(%{time_val: t})
      assert {:ok, _} = DataLayer.create(TypeTestResource, cs)

      assert_receive {:ash_scylla_query, _insert_query, insert_params, _opts}
      assert %Time{} = find_struct(insert_params, Time)
    end

    test "sends Decimal as %Decimal{} struct" do
      d = Decimal.new("3.14")
      cs = changeset(%{decimal_val: d})
      assert {:ok, _} = DataLayer.create(TypeTestResource, cs)

      assert_receive {:ash_scylla_query, _insert_query, insert_params, _opts}
      assert %Decimal{} = find_struct(insert_params, Decimal)
    end

    test "sends nil as nil (not wrapped)" do
      cs = changeset(%{str_val: nil, int_val: nil, float_val: nil})
      assert {:ok, _} = DataLayer.create(TypeTestResource, cs)

      assert_receive {:ash_scylla_query, _insert_query, insert_params, _opts}
      # nil values should be raw nil, not wrapped
      raw_values = get_raw_values(insert_params)
      nil_count = Enum.count(raw_values, &is_nil/1)
      assert nil_count >= 3
    end

    test "uuid string is converted to 16-byte binary" do
      cs = changeset(%{id: "550e8400-e29b-41d4-a716-446655440000"})
      assert {:ok, _} = DataLayer.create(TypeTestResource, cs)

      assert_receive {:ash_scylla_query, _insert_query, insert_params, _opts}
      # UUID should be 16-byte binary (not wrapped in {type, value})
      uuid_param =
        Enum.find(get_raw_values(insert_params), fn v ->
          is_binary(v) and byte_size(v) == 16
        end)

      assert uuid_param, "Expected a 16-byte binary UUID param, got: #{inspect(insert_params)}"
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp find_param_by_type(params, expected_type) do
    Enum.find(params, fn
      {^expected_type, _value} -> true
      _ -> false
    end)
  end

  defp get_raw_values(params) do
    Enum.map(params, fn
      {_type, value} -> value
      value -> value
    end)
  end

  defp find_struct(params, _expected_struct) do
    Enum.find(params, fn
      %_{} -> true
      {%DateTime{}, _} -> false
      _ -> false
    end)
  end
end
