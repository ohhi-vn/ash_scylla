defmodule Mix.Tasks.AshScylla.NewTemplateCoverageTest do
  @moduledoc """
  Line-coverage test for Mix.Tasks.AshScylla.NewTemplate's success path, which
  writes the generated resource through AshScylla.ResourceGenerator.write_resource.

  The generator has no output-directory option — it always writes under
  lib/<app>/resources/ — so each test generates a uniquely named template and
  removes it again (immediately and via on_exit as a safety net). Runs with
  async: false because the generated path is relative to the VM-wide cwd.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  defp resources_dir do
    Path.join(["lib", "ash_scylla", "resources"])
  end

  defp generated_relative_path(name) do
    Path.join([resources_dir(), "#{Macro.underscore(name)}.ex"])
  end

  defp register_cleanup(relative_path) do
    absolute_path = Path.expand(relative_path, File.cwd!())
    absolute_dir = Path.dirname(absolute_path)

    on_exit(fn ->
      File.rm(absolute_path)
      File.rmdir(absolute_dir)
    end)
  end

  defp cleanup_now(relative_path) do
    absolute_path = Path.expand(relative_path, File.cwd!())

    File.rm(absolute_path)
    File.rmdir(Path.dirname(absolute_path))
  end

  test "run/1 writes a generated resource template" do
    name = "QbmProbeUser#{System.unique_integer([:positive])}"
    relative_path = generated_relative_path(name)
    register_cleanup(relative_path)

    out =
      capture_io(fn ->
        Mix.Tasks.AshScylla.NewTemplate.run([name, "name:string", "age:int"])
      end)

    assert out =~ "Generated #{relative_path}"
    assert File.exists?(Path.expand(relative_path, File.cwd!()))

    content = File.read!(Path.expand(relative_path, File.cwd!()))
    assert content =~ "defmodule #{name} do"
    assert content =~ ~r/attribute :name, :string/
    assert content =~ ~r/attribute :age, :integer/

    cleanup_now(relative_path)
  end

  test "run/1 with --domain prefixes the resource module and sets the domain option" do
    name = "QbmProbePost#{System.unique_integer([:positive])}"
    domain = "QbmProbeDomain#{System.unique_integer([:positive])}"
    relative_path = generated_relative_path(name)
    register_cleanup(relative_path)

    out =
      capture_io(fn ->
        Mix.Tasks.AshScylla.NewTemplate.run([name, "title:string", "--domain", domain])
      end)

    assert out =~ "Generated #{relative_path}"
    assert out =~ "already configured with domain"

    content = File.read!(Path.expand(relative_path, File.cwd!()))
    assert content =~ "defmodule #{domain}.#{name} do"
    assert content =~ "domain: #{domain}"

    cleanup_now(relative_path)
  end
end
