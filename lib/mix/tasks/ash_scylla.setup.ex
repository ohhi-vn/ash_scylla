defmodule Mix.Tasks.AshScylla.Setup do
  @moduledoc """
  Sets up the ScyllaDB keyspace for AshScylla.

  ## Usage

      mix ash_scylla.setup
      mix ash_scylla.setup --repo MyApp.Repo
  """

  use Mix.Task

  @shortdoc "Creates the ScyllaDB keyspace"

  @impl Mix.Task
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [repo: :string])

    # Compile first so the repo module is available
    Mix.Task.run("compile", args)

    # Load application config without starting the supervision tree
    otp_app = Mix.Project.config()[:app]

    if otp_app do
      Application.load(otp_app)
    end

    repo = find_repo(opts)

    Mix.shell().info("Creating keyspace for #{inspect(repo)}...")

    case repo.create_keyspace() do
      {:ok, _} ->
        Mix.shell().info("Keyspace created successfully.")

      {:error, error} ->
        Mix.shell().error("Failed to create keyspace: #{inspect(error)}")
        Mix.raise("Keyspace creation failed")
    end
  end

  defp find_repo(opts) do
    case Keyword.get(opts, :repo) do
      nil ->
        find_default_repo()

      repo ->
        repo
        |> Macro.underscore()
        |> String.split("/")
        |> Enum.map(&Macro.camelize/1)
        |> Module.concat()
    end
  end

  defp find_default_repo do
    repos =
      case Mix.Project.apps_paths() do
        nil ->
          lib_path = Mix.Project.config()[:source_paths] || "lib"
          pattern = Path.join(lib_path, "**/repo.ex")
          find_repos_in_files(Path.wildcard(pattern))

        apps_paths ->
          for {_app, path} <- apps_paths,
              file <- Path.wildcard(Path.join(path, "lib/**/repo.ex")),
              module = file_to_module(file),
              module != nil,
              function_exported?(module, :__info__, 1),
              do: module
      end

    case repos do
      [repo | _] ->
        repo

      [] ->
        Mix.raise("""
        No repo found. Generate one first with:

            mix ash_scylla.gen.repo

        Or specify one explicitly:

            mix ash_scylla.setup --repo MyApp.Repo
        """)
    end
  end

  defp find_repos_in_files(files) do
    for file <- files,
        module = file_to_module(file),
        module != nil,
        function_exported?(module, :__info__, 1),
        do: module
  end

  defp file_to_module(file) do
    case file |> Path.rootname() |> Path.split() do
      ["lib" | parts] ->
        parts
        |> Enum.join(".")
        |> Macro.camelize()
        |> Module.concat()

      _ ->
        nil
    end
  rescue
    _ -> nil
  end
end
