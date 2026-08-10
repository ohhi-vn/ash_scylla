defmodule MyApp.ProdRepoTest do
  use ExUnit.Case, async: true

  describe "MyApp.ProdRepo" do
    test "compiles as a valid module" do
      assert is_atom(MyApp.ProdRepo)
      assert Code.ensure_loaded?(MyApp.ProdRepo)
    end

    test "uses AshScylla.Repo behaviour" do
      assert function_exported?(Code.ensure_loaded!(MyApp.ProdRepo), :__info__, 1)
    end
  end
end
