defmodule AshScylla.MixHelpers do
  @moduledoc """
  Shared helper functions for AshScylla Mix tasks.

  Provides resource/repo discovery, CLI option handling, and file scanning
  used by `ash_scylla.gen`, `ash_scylla.migrate`, and other tasks.
  """

  @doc """
  Converts a string CLI option value to a module atom, if present.

  Uses `Module.concat/1` to produce a proper module reference (e.g.
  `"MyApp.User"` becomes `MyApp.User`, not `:"MyApp.User"`).
  """
  @spec maybe_atomize(keyword(), atom()) :: keyword()
  def maybe_atomize(opts, key) do
    case Keyword.get(opts, key) do
      nil -> opts
      value -> Keyword.put(opts, key, Module.concat([value]))
    end
  end

  @doc """
  Returns the list of app atoms to scan: the current app + umbrella children.
  """
  @spec project_apps() :: [atom()]
  def project_apps do
    current =
      case Mix.Project.config()[:app] do
        nil -> []
        app -> [app]
      end

    children =
      case Mix.Project.apps_paths() do
        nil -> []
        apps -> Map.keys(apps)
      end

    (current ++ children) |> Enum.uniq()
  end

  @doc """
  Discovers Ash domains from the project's app configuration.

  Checks each app for `:ash_domains` config, ensures modules are compiled,
  and validates they are actual Ash domains (Spark DSL modules).
  """
  @spec project_domains() :: [module()]
  def project_domains do
    apps = project_apps()

    domains =
      Enum.flat_map(apps, fn app ->
        Application.get_env(app, :ash_domains, [])
      end)

    domains
    |> Enum.filter(fn domain ->
      try do
        Code.ensure_compiled(domain)

        if ash_domain?(domain) do
          true
        else
          Mix.shell().info("  Skipping #{inspect(domain)}: not an Ash domain")
          false
        end
      rescue
        _ ->
          Mix.shell().info("  Skipping #{inspect(domain)}: could not compile module")
          false
      end
    end)
  end

  @doc """
  Checks if a module is a valid Ash domain.

  Verifies the module is compiled and exports `domain?/0` (added by
  `use Ash.Domain`), which distinguishes domains from plain modules.
  """
  @spec ash_domain?(module()) :: boolean()
  def ash_domain?(module) do
    Code.ensure_compiled(module)
    function_exported?(module, :domain?, 0)
  rescue
    _ -> false
  end

  @doc """
  Checks if a resource module uses `AshScylla.DataLayer`.
  """
  @spec ash_scylla_resource?(module()) :: boolean()
  def ash_scylla_resource?(resource) do
    Code.ensure_compiled(resource)

    case Ash.Resource.Info.data_layer(resource) do
      AshScylla.DataLayer -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  @doc """
  Finds all AshScylla resources via domain config, with file-scan fallback.

  1. Reads configured domains from app env
  2. Gets each domain's resources via `Ash.Domain.Info.resources/1`
  3. Filters to AshScylla resources
  4. Falls back to scanning `lib/**/*.ex` files if no domains configured
  """
  @spec find_all_resources() :: [module()]
  def find_all_resources do
    domains = project_domains()

    resources =
      Enum.flat_map(domains, fn domain ->
        try do
          domain
          |> Ash.Domain.Info.resources()
          |> Enum.filter(&ash_scylla_resource?/1)
        rescue
          error in [ArgumentError] ->
            Mix.shell().info("  Skipping domain #{inspect(domain)}: #{Exception.message(error)}")
            []
        end
      end)

    if resources != [] do
      resources
    else
      scan_files_for_resources()
    end
  end

  @doc """
  Finds and returns the default repo module from AshScylla resources.

  Extracts the repo from each resource's DSL config and returns the first one.
  """
  @spec find_default_repo() :: module()
  def find_default_repo do
    resources = find_all_resources()

    repos =
      resources
      |> Enum.map(&AshScylla.DataLayer.Dsl.repo/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case repos do
      [repo | _] ->
        repo

      [] ->
        raise_no_repo_found()
    end
  end

  defp raise_no_repo_found do
    Mix.raise("""
    No repo found.

    To fix this, either:
    1. Specify a repo explicitly: mix ash_scylla.migrate --repo MyApp.Repo
    2. Configure a repo on your resources in the ash_scylla DSL:
         ash_scylla do
           repo MyApp.Repo
           table "my_table"
         end
    3. Configure ash_domains in your app config:
         config :my_app, ash_domains: [MyApp.MyDomain]
    """)
  end

  @doc """
  Returns the list of lib/ directories to scan (current app + umbrella children).
  """
  @spec project_lib_paths() :: [String.t()]
  def project_lib_paths do
    current =
      case Mix.Project.config()[:app] do
        nil -> []
        _app -> ["lib"]
      end

    children =
      case Mix.Project.apps_paths() do
        nil -> []
        apps -> Enum.map(apps, fn {_app, path} -> Path.join(path, "lib") end)
      end

    current ++ children
  end

  @doc """
  Converts a file path to a module name.

  ## Examples

      iex> AshScylla.MixHelpers.file_to_module("lib/my_app/resources/user.ex")
      :"Elixir.MyApp.Resources.User"

  """
  @spec file_to_module(String.t()) :: atom() | nil
  def file_to_module(file) do
    case file |> Path.rootname() |> Path.split() do
      ["lib" | parts] ->
        parts
        |> Enum.map(&Macro.camelize/1)
        |> Enum.map(&String.to_atom/1)
        |> Module.concat()

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  @doc """
  Scans all .ex files in project lib/ directories for AshScylla resources.
  """
  @spec scan_files_for_resources() :: [module()]
  def scan_files_for_resources do
    paths = project_lib_paths()

    paths
    |> Enum.flat_map(fn path ->
      path
      |> Path.join("**/*.ex")
      |> Path.wildcard()
    end)
    |> Enum.map(&file_to_module/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(fn module ->
      Code.ensure_compiled(module)
      function_exported?(module, :__info__, 1) and ash_scylla_resource?(module)
    end)
    |> Enum.uniq()
  end

  @doc """
  Returns the application name from Mix config.
  """
  @spec app_name() :: atom()
  def app_name do
    case Mix.Project.config()[:app] do
      nil ->
        Mix.raise("Could not determine application name")

      app ->
        app
    end
  end
end
