defmodule FermixCoreTest do
  use ExUnit.Case
  doctest FermixCore

  test "greets the world" do
    assert FermixCore.hello() == :world
  end
end
