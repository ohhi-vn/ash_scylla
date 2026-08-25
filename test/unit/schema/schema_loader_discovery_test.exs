defmodule AshScylla.SchemaLoaderDiscoveryTest do
  @moduledoc """
  Covers AshScylla.SchemaLoader discovery across umbrella app paths and the
  edge cases of loading migration modules from files.
  """

  use ExUnit.Case, async: false

  alias AshScylla.SchemaLoader

  defmodule FvxUmbrellaProject do
    def project,
      do: [
        app: :fvx_umbrella_root,
        version: "0.1.0",
        apps_path: "apps",
        apps_paths: %{fvx_a: "apps/fvx_a"}
      ]
  end

  defmodule FvxSingleProject do
    def project,
      do: [
        app: :fvx_single,
        version: "0.1.0"
      ]
  end

  defp unique_tmp(prefix) do
    path = Path.expand(Path.join(["tmp", "#{prefix}_#{System.unique_integer([:positive])}"]))
    File.mkdir_p!(path)

    on_exit(fn ->
      File.rm_rf(path)
      File.cd(Path.expand("."))
    end)

    path
  end

  describe "discover/0" do
    test "finds migration files under umbrella child app paths" do
      root = unique_tmp("fvx_discover")
      app_dir = Path.join([root, "apps", "fvx_a"])
      mig_dir = Path.join([app_dir, "priv", "repo", "migrations"])
      File.mkdir_p!(mig_dir)

      # Mix only accepts umbrella children whose directory contains a mix.exs.
      File.write!(Path.join(app_dir, "mix.exs"), """
      defmodule Fvx.Child.MixProject do
        def project do
          [app: :fvx_a, version: "0.1.0"]
        end
      end
      """)

      mig_file = Path.join(mig_dir, "20260101000000_fvx.exs")

      File.write!(mig_file, """
      defmodule Fvx.DiscoveredMigration#{System.unique_integer([:positive])} do
        use AshScylla.Schema

        def change, do: []
      end
      """)

      original_cwd = File.cwd!()
      File.cd!(root)
      Mix.Project.push(FvxUmbrellaProject, "mix.exs")

      try do
        files = SchemaLoader.discover()

        assert Path.join([
                 "apps",
                 "fvx_a",
                 "priv",
                 "repo",
                 "migrations",
                 "20260101000000_fvx.exs"
               ]) in files
      after
        Mix.Project.pop()
        File.cd!(original_cwd)
      end
    end

    test "discovers migration files in a single (non-umbrella) project" do
      root = unique_tmp("fvx_discover_single")
      mig_dir = Path.join([root, "priv", "repo", "migrations"])
      File.mkdir_p!(mig_dir)

      File.write!(Path.join(mig_dir, "20260102000000_single.exs"), """
      defmodule Fvx.SingleMigration#{System.unique_integer([:positive])} do
        use AshScylla.Schema

        def change, do: []
      end
      """)

      original_cwd = File.cwd!()
      File.cd!(root)
      Mix.Project.push(FvxSingleProject, "mix.exs")

      try do
        files = SchemaLoader.discover()

        assert Path.join(["priv", "repo", "migrations", "20260102000000_single.exs"]) in files
      after
        Mix.Project.pop()
        File.cd!(original_cwd)
      end
    end
  end

  describe "load/1" do
    test "returns an error when the file was already required but the module is gone" do
      root = unique_tmp("fvx_load_once")
      path = Path.join(root, "once.exs")

      File.write!(path, """
      defmodule Fvx.LoadOnce#{System.unique_integer([:positive])} do
        use AshScylla.Schema

        def change, do: ["CREATE TABLE fvx_once (id uuid PRIMARY KEY)"]
      end
      """)

      # Extract the defined module from the source, require it, then purge it
      # so ensure_loaded fails and the re-require yields no fresh module.
      source = File.read!(path)
      [_, mod_name] = Regex.run(~r/defmodule\s+([\w.]+)\s+do/, source)
      module = Module.concat([mod_name])

      Code.require_file(path)
      :code.purge(module)
      :code.delete(module)

      assert {:error, nil} = SchemaLoader.load(path)
    end

    test "returns the raw require result when a file defines multiple modules" do
      root = unique_tmp("fvx_load_multi")
      path = Path.join(root, "multi.exs")

      File.write!(path, """
      defmodule Fvx.MultiFirst#{System.unique_integer([:positive])} do
        use AshScylla.Schema

        def change, do: []
      end

      defmodule Fvx.MultiSecond#{System.unique_integer([:positive])} do
        def other, do: :ok
      end
      """)

      assert {:error, [_first, _second]} = SchemaLoader.load(path)
    end
  end
end
