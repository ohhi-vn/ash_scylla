defmodule Mix.Tasks.AshScylla.GenTest do
  use ExUnit.Case, async: true

  alias AshScylla.ResourceGenerator

  describe "parse_args/1" do
    test "parses resource name and attributes" do
      assert {:ok, :MyResource,
              [
                user_id: :uuid,
                name: :string,
                age: :integer
              ]} =
               ResourceGenerator.parse_args(["MyResource", "user_id:uuid, name:string, age:int"])
    end

    test "requires at least one attribute" do
      assert {:error, "At least one attribute is required"} =
               ResourceGenerator.parse_args(["MyResource"])
    end

    test "returns error on empty args" do
      assert {:error, "Usage: mix ash_scylla.gen MyResource user_id:uuid, name:string, age:int"} =
               ResourceGenerator.parse_args([])
    end
  end

  describe "render_resource/2" do
    test "renders an Ash resource template" do
      rendered =
        ResourceGenerator.render_resource(
          :MyResource,
          [user_id: :uuid, name: :string, age: :integer],
          repo_module: MyApp.Repo
        )

      assert rendered =~ "defmodule MyResource do"
      assert rendered =~ "data_layer: AshScylla.DataLayer"
      assert rendered =~ "repo: MyApp.Repo"
      assert rendered =~ "uuid_primary_key :id"
      assert rendered =~ "attribute :user_id, :uuid"
      assert rendered =~ "attribute :name, :string"
      assert rendered =~ "attribute :age, :integer"
      assert rendered =~ "defaults [:create, :read, :update, :destroy]"
    end

    test "skips :id attribute to avoid duplicate primary key" do
      rendered =
        ResourceGenerator.render_resource(
          :MyResource,
          [id: :uuid, name: :string],
          repo_module: MyApp.Repo
        )

      refute rendered =~ "attribute :id, :uuid"
      assert rendered =~ "uuid_primary_key :id"
    end
  end

  describe "resource_file_path/1" do
    test "builds path from resource name" do
      path = ResourceGenerator.resource_file_path(:MyResource)
      assert path =~ ~r/lib\/.*\/resources\/my_resource\.ex$/
    end
  end
end
