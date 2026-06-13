defmodule Mix.Tasks.AshScylla.Gen.Repo do
  @moduledoc """
  Generates an AshScylla Repo module for your application.

  The repo module wraps `AshScylla.Repo` and provides the Xandra connection
  configuration needed for ScyllaDB access.

  ## Usage

      mix ash_scylla.gen.repo
      mix ash_scylla.gen.repo --repo MyApp.Repo
      mix ash_scylla.gen.repo --otp-app :my_app --keyspace my_app_dev --nodes 127.0.0.1:9042

  ## Options

  - `--repo` - Repo module name (defaults to `<AppName>.Repo`)
  - `--otp-app` - OTP app name (defaults to the current application name)
  - `--keyspace` - ScyllaDB keyspace name (defaults to `<app>_dev`)
  - `--nodes` - Comma-separated ScyllaDB nodes (defaults to `127.0.0.1:9042`)

  ## Examples

  Generate with defaults (infers app name from mix.exs):

      mix ash_scylla.gen.repo

  Generate with a custom repo name:

      mix ash_scylla.gen.repo --repo StorageService.Repo

  Generate with full custom options:

      mix ash_scylla.gen.repo --repo MyApp.Repo --otp-app :my_app --keyspace my_app_prod --nodes 10.0.0.1:9042,10.0.0.2:9042
  """

  use Mix.Task

  @shortdoc "Generates an AshScylla Repo module"

  @impl Mix.Task
  def run(args) do
    {opts, _} =
      OptionParser.parse!(args,
        strict: [
          repo: :string,
          otp_app: :string,
          keyspace: :string,
          nodes: :string
        ]
      )

    otp_app = resolve_otp_app(opts)
    repo_module = resolve_repo_module(opts, otp_app)
    keyspace = resolve_keyspace(opts, otp_app)
    nodes = resolve_nodes(opts)

    file_path = repo_file_path(repo_module)
    content = render_repo(repo_module, otp_app, keyspace, nodes)

    File.mkdir_p!(Path.dirname(file_path))
    File.write!(file_path, content)

    Mix.shell().info("Generated #{file_path}")
    Mix.shell().info("")
    Mix.shell().info("Next steps:")
    Mix.shell().info("  1. Review and adjust the config in config/config.exs:")
    Mix.shell().info("")
    Mix.shell().info("     config :#{otp_app}, #{inspect(repo_module)},")
    Mix.shell().info("       nodes: #{inspect(nodes)},")
    Mix.shell().info("       keyspace: #{inspect(keyspace)}")
    Mix.shell().info("")
    Mix.shell().info("  2. Add #{inspect(repo_module)} to your supervision tree:")
    Mix.shell().info("")
    Mix.shell().info("     children = [")
    Mix.shell().info("       #{inspect(repo_module)},")
    Mix.shell().info("       # ...")
    Mix.shell().info("     ]")
    Mix.shell().info("")
    Mix.shell().info("  3. Run `mix ash_scylla.setup` to create the keyspace.")
  end

  defp resolve_otp_app(opts) do
    case Keyword.get(opts, :otp_app) do
      nil ->
        case Mix.Project.config()[:app] do
          nil -> Mix.raise("Could not determine OTP app. Pass --otp-app explicitly.")
          app -> app
        end

      app_str ->
        String.to_atom(app_str)
    end
  end

  defp resolve_repo_module(opts, otp_app) do
    case Keyword.get(opts, :repo) do
      nil ->
        otp_app
        |> Atom.to_string()
        |> Macro.camelize()
        |> Kernel.<>(".Repo")
        |> String.to_atom()

      repo_str ->
        repo_str
        |> Macro.underscore()
        |> String.split("/")
        |> Enum.map(&Macro.camelize/1)
        |> Module.concat()
    end
  end

  defp resolve_keyspace(opts, otp_app) do
    case Keyword.get(opts, :keyspace) do
      nil ->
        otp_app
        |> Atom.to_string()
        |> Macro.underscore()
        |> Kernel.<>("_dev")

      keyspace ->
        keyspace
    end
  end

  defp resolve_nodes(opts) do
    case Keyword.get(opts, :nodes) do
      nil ->
        ["127.0.0.1:9042"]

      nodes_str ->
        nodes_str
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
    end
  end

  defp repo_file_path(repo_module) do
    segments = Module.split(repo_module)
    file_name = segments |> List.last() |> Macro.underscore()
    app_dir = segments |> Enum.drop(-1) |> Enum.join("/") |> Macro.underscore()

    dir =
      case app_dir do
        "" -> "lib"
        _ -> Path.join("lib", app_dir)
      end

    Path.join(dir, file_name <> ".ex")
  end

  defp render_repo(repo_module, otp_app, _keyspace, _nodes) do
    module_name = repo_module |> Module.split() |> Enum.join()

    """
    defmodule #{module_name} do
      @moduledoc \"\"\"
      AshScylla Repo for #{otp_app}.

      Manages the Xandra connection to ScyllaDB.
      \"\"\"

      use AshScylla.Repo,
        otp_app: :#{otp_app}
    end
    """
  end
end
