defmodule Mix.Tasks.AshScylla.Gen.RepoEdgeTest do
  @moduledoc """
  Covers AshScylla.Gen.Repo argument-resolution edges: a missing OTP app and
  single-segment repo module names.
  """

  # Non-async: the task resolves output paths relative to the working
  # directory, which is node-global.
  use ExUnit.Case, async: false

  @moduletag tmp_dir: true

  alias Mix.Tasks.AshScylla.Gen

  import ExUnit.CaptureIO

  defmodule FvxNoAppProject do
    def project, do: [app: nil, version: "0.1.0"]
  end

  setup %{tmp_dir: tmp_dir} do
    original_cwd = File.cwd!()
    File.cd!(tmp_dir)
    on_exit(fn -> File.cd(original_cwd) end)
    :ok
  end

  test "raises when no OTP app can be determined" do
    Mix.Project.push(FvxNoAppProject, "mix.exs")

    try do
      assert_raise Mix.Error, ~r/Could not determine OTP app/, fn ->
        capture_io(fn -> Gen.Repo.run(["--repo", "Fvx.OrphanRepo"]) end)
      end
    after
      Mix.Project.pop()
    end
  end

  test "writes single-segment repos into lib/ directly" do
    output = capture_io(fn -> Gen.Repo.run(["--repo", "Solo"]) end)

    assert output =~ "Generated #{Path.join("lib", "solo.ex")}"
    content = File.read!(Path.join("lib", "solo.ex"))
    assert content =~ "defmodule Solo do"
  end
end
