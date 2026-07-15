defmodule AshScylla.MigrationGeneratorTest do
  use ExUnit.Case, async: false

  # Two resources with the same short name in different domains must produce
  # distinct snapshot files so they do not collide, even when they map to the
  # same underlying table.
  defmodule DomainA do
    use Ash.Domain, otp_app: :ash_scylla, validate_config_inclusion?: false

    resources do
      resource(AshScylla.MigrationGeneratorTest.DomainA.User)
    end
  end

  defmodule DomainB do
    use Ash.Domain, otp_app: :ash_scylla, validate_config_inclusion?: false

    resources do
      resource(AshScylla.MigrationGeneratorTest.DomainB.User)
    end
  end

  defmodule DomainA.User do
    use Ash.Resource,
      domain: AshScylla.MigrationGeneratorTest.DomainA,
      data_layer: AshScylla.DataLayer

    import AshScylla.DataLayer.Dsl

    scylla do
      repo(AshScylla.TestRepo)
      table("users")
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string)
    end
  end

  defmodule DomainB.User do
    use Ash.Resource,
      domain: AshScylla.MigrationGeneratorTest.DomainB,
      data_layer: AshScylla.DataLayer

    import AshScylla.DataLayer.Dsl

    scylla do
      repo(AshScylla.TestRepo)
      table("users")
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string)
    end
  end

  describe "snapshot generation across domains" do
    test "same-named resources in different domains get distinct snapshot files" do
      tmp = briefly_make_snapshot_dir()

      AshScylla.MigrationGenerator.generate(
        domains: [DomainA, DomainB],
        snapshot_path: tmp,
        snapshots_only: true
      )

      repo_snapshot_dir = Path.join(tmp, "test_repo")
      files = repo_snapshot_dir |> File.ls!() |> Enum.filter(&String.ends_with?(&1, ".json"))

      # Both resources are captured without overwriting each other.
      assert length(files) == 2

      names = Enum.map(files, &Path.rootname/1)
      assert "ash_scylla.migration_generator_test.domain_a.user" in names
      assert "ash_scylla.migration_generator_test.domain_b.user" in names
    end

    test "snapshot generation is idempotent (no rewrite when unchanged)" do
      # Regression for the resource-keyed snapshot store: re-running generation
      # for the same resources must not create duplicate snapshot files.
      tmp = briefly_make_snapshot_dir()

      AshScylla.MigrationGenerator.generate(
        domains: [DomainA],
        snapshot_path: tmp,
        snapshots_only: true
      )

      repo_snapshot_dir = Path.join(tmp, "test_repo")
      first = repo_snapshot_dir |> File.ls!() |> Enum.filter(&String.ends_with?(&1, ".json"))
      assert length(first) == 1

      # Second run with no schema change should not add more snapshot files.
      AshScylla.MigrationGenerator.generate(
        domains: [DomainA],
        snapshot_path: tmp,
        snapshots_only: true
      )

      second = repo_snapshot_dir |> File.ls!() |> Enum.filter(&String.ends_with?(&1, ".json"))
      assert length(second) == 1
    end
  end

  describe "migration generation across domains" do
    test "same-named resources in different domains get distinct migration files" do
      tmp = briefly_make_dir()

      # Use the same temp dir for both snapshots and migrations, and ensure no
      # prior snapshots exist so operations are generated for both resources.
      AshScylla.MigrationGenerator.generate(
        domains: [DomainA, DomainB],
        migration_path: tmp,
        snapshot_path: tmp,
        dev: true
      )

      repo_migration_dir = tmp
      files = repo_migration_dir |> File.ls!() |> Enum.filter(&String.ends_with?(&1, ".exs"))

      # Both resources produce a migration file; neither overwrites the other.
      assert length(files) == 2

      # The domain is embedded in each migration filename (via the full module
      # path), so same-named resources in different domains stay distinct.
      a_file = Enum.find(files, &String.contains?(&1, "domain_a"))
      b_file = Enum.find(files, &String.contains?(&1, "domain_b"))
      assert a_file, "expected a migration file containing 'domain_a', got: #{inspect(files)}"
      assert b_file, "expected a migration file containing 'domain_b', got: #{inspect(files)}"
      refute a_file == b_file

      # The buggy short name (just the resource, no domain) must never appear.
      refute Enum.any?(files, &String.ends_with?(&1, "user_dev.exs"))
    end
  end

  describe "migration generation with a fixed --name" do
    test "fixed name still yields unique module names per resource (no collision)" do
      tmp = briefly_make_dir()

      # Passing a fixed `name` (as `mix ash_scylla.generate_migrations new` does)
      # must not make every file share the same module (AshScylla.Migrations.New),
      # which previously caused `redefining module` / load failures.
      AshScylla.MigrationGenerator.generate(
        domains: [DomainA, DomainB],
        migration_path: tmp,
        snapshot_path: tmp,
        name: "new",
        dev: true
      )

      files = tmp |> File.ls!() |> Enum.filter(&String.ends_with?(&1, ".exs"))
      assert length(files) == 2

      # Each file's module name embeds the resource key, so they differ.
      contents = Enum.map(files, &File.read!(Path.join(tmp, &1)))

      modules =
        Enum.map(contents, fn c ->
          Regex.run(~r/defmodule (\S+) do/, c) |> Enum.at(1)
        end)

      assert length(Enum.uniq(modules)) == 2
      assert Enum.all?(modules, &String.contains?(&1, "New"))
      refute Enum.any?(modules, &(&1 == "AshScylla.Migrations.New"))
    end

    test "fixed name yields distinct on-disk filenames (no overwrite)" do
      # The file NAME (not just the module) must be unique per resource when a
      # fixed --name is given, otherwise the second file overwrites the first.
      tmp = briefly_make_dir()

      AshScylla.MigrationGenerator.generate(
        domains: [DomainA, DomainB],
        migration_path: tmp,
        snapshot_path: tmp,
        name: "new",
        dev: true
      )

      files = tmp |> File.ls!() |> Enum.filter(&String.ends_with?(&1, ".exs"))
      assert length(files) == 2
      # Both filenames contain the resource key, so they cannot collide.
      assert Enum.any?(files, &String.contains?(&1, "domain_a"))
      assert Enum.any?(files, &String.contains?(&1, "domain_b"))
      refute Enum.any?(files, &(&1 == "#{timestamp_prefix()}_new_dev.exs"))
    end
  end

  describe "cross-domain same table" do
    test "warns when two resources map to the same table" do
      # DomainA.User and DomainB.User both use table "users". The generator
      # must warn about the genuine DDL conflict while still producing distinct
      # files for each resource.
      tmp = briefly_make_dir()

      assert ExUnit.CaptureIO.capture_io(fn ->
               AshScylla.MigrationGenerator.generate(
                 domains: [DomainA, DomainB],
                 migration_path: tmp,
                 snapshot_path: tmp,
                 dev: true
               )
             end) =~ "multiple resources map to table users"

      files = tmp |> File.ls!() |> Enum.filter(&String.ends_with?(&1, ".exs"))
      assert length(files) == 2
    end
  end

  defp timestamp_prefix do
    {{y, m, d}, {hh, mm, ss}} = :calendar.universal_time()
    "#{y}#{pad(m)}#{pad(d)}#{pad(hh)}#{pad(mm)}#{pad(ss)}"
  end

  defp pad(i) when i < 10, do: <<?0, ?0 + i>>
  defp pad(i), do: to_string(i)

  defp briefly_make_snapshot_dir do
    unique = "snap_test_#{System.unique_integer([:positive])}"
    dir = Path.join(System.tmp_dir!(), unique)
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    dir
  end

  defp briefly_make_dir do
    unique = "mig_test_#{System.unique_integer([:positive])}"
    dir = Path.join(System.tmp_dir!(), unique)
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    dir
  end
end
