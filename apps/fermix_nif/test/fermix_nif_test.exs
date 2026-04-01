defmodule FermixNifTest do
  use ExUnit.Case
  doctest FermixNif

  test "greets the world" do
    assert FermixNif.hello() == :world
  end
end
