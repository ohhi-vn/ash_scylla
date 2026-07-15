defmodule AshScylla.SchemaTest do
  use ExUnit.Case, async: true

  alias AshScylla.SchemaFixtures.{EmptySchema, SampleSchema}

  describe "behaviour" do
    test "defines change/0 callback" do
      assert function_exported?(SampleSchema, :change, 0)
    end

    test "schema module returns list of CQL strings" do
      statements = SampleSchema.change()
      assert is_list(statements)
      assert Enum.all?(statements, &is_binary/1)
    end

    test "schema module returns expected CQL" do
      [create_table] = SampleSchema.change()
      assert create_table =~ "CREATE TABLE IF NOT EXISTS"
      assert create_table =~ "id UUID PRIMARY KEY"
    end
  end

  describe "default change/0" do
    test "returns empty list when not implemented" do
      assert EmptySchema.change() == []
    end
  end

  test "behaviour info lists change/0" do
    callbacks = AshScylla.Schema.behaviour_info(:callbacks)
    assert {:change, 0} in callbacks
  end

  describe "struct" do
    test "defines domain and resources fields" do
      schema = %AshScylla.Schema{
        domain: MyApp.Domain,
        resources: [
          %AshScylla.Schema.Resource{
            name: :users,
            statements: ["CREATE TABLE IF NOT EXISTS users (id UUID PRIMARY KEY)"]
          }
        ]
      }

      assert schema.domain == MyApp.Domain
      assert length(schema.resources) == 1
      [resource] = schema.resources
      assert resource.name == :users
      assert hd(resource.statements) =~ "CREATE TABLE"
    end

    test "defaults resources to empty list" do
      schema = %AshScylla.Schema{domain: MyApp.Domain}
      assert schema.resources == []
    end
  end

  describe "flatten/1" do
    test "passes through flat CQL strings" do
      input = ["CREATE TABLE IF NOT EXISTS t (id UUID PRIMARY KEY)"]
      assert AshScylla.Schema.flatten(input) == input
    end

    test "flattens struct-based schema to CQL strings" do
      input = [
        %AshScylla.Schema{
          domain: MyApp.Domain,
          resources: [
            %AshScylla.Schema.Resource{
              name: :users,
              statements: [
                "CREATE TABLE IF NOT EXISTS users (id UUID PRIMARY KEY, name TEXT)",
                "CREATE INDEX IF NOT EXISTS idx_users_name ON users (name)"
              ]
            },
            %AshScylla.Schema.Resource{
              name: :posts,
              statements: [
                "CREATE TABLE IF NOT EXISTS posts (id UUID PRIMARY KEY, title TEXT)"
              ]
            }
          ]
        }
      ]

      result = AshScylla.Schema.flatten(input)
      assert length(result) == 3
      assert Enum.at(result, 0) =~ "CREATE TABLE IF NOT EXISTS users"
      assert Enum.at(result, 1) =~ "CREATE INDEX IF NOT EXISTS idx_users_name"
      assert Enum.at(result, 2) =~ "CREATE TABLE IF NOT EXISTS posts"
    end

    test "flattens mixed strings and structs" do
      input = [
        "CREATE TABLE IF NOT EXISTS legacy (id UUID PRIMARY KEY)",
        %AshScylla.Schema{
          domain: MyApp.Domain,
          resources: [
            %AshScylla.Schema.Resource{
              name: :users,
              statements: ["CREATE TABLE IF NOT EXISTS users (id UUID PRIMARY KEY)"]
            }
          ]
        }
      ]

      result = AshScylla.Schema.flatten(input)
      assert length(result) == 2
      assert hd(result) =~ "legacy"
      assert Enum.at(result, 1) =~ "users"
    end

    test "handles multiple domain schemas" do
      input = [
        %AshScylla.Schema{
          domain: MyApp.DomainA,
          resources: [
            %AshScylla.Schema.Resource{
              name: :users,
              statements: ["CREATE TABLE IF NOT EXISTS users (id UUID PRIMARY KEY)"]
            }
          ]
        },
        %AshScylla.Schema{
          domain: MyApp.DomainB,
          resources: [
            %AshScylla.Schema.Resource{
              name: :posts,
              statements: ["CREATE TABLE IF NOT EXISTS posts (id UUID PRIMARY KEY)"]
            }
          ]
        }
      ]

      result = AshScylla.Schema.flatten(input)
      assert length(result) == 2
    end

    test "handles empty list" do
      assert AshScylla.Schema.flatten([]) == []
    end

    test "handles schema with empty resources" do
      input = [%AshScylla.Schema{domain: MyApp.Domain, resources: []}]
      assert AshScylla.Schema.flatten(input) == []
    end
  end
end
