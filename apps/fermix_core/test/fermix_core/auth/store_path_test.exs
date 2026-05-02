defmodule FermixCore.Auth.StorePathTest do
  # async: false because we mutate the FERMIX_HOME env var.
  use ExUnit.Case, async: false

  alias FermixCore.Auth.Store

  setup do
    previous = System.get_env("FERMIX_HOME")

    on_exit(fn ->
      case previous do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end
    end)

    :ok
  end

  test "path/0 honors FERMIX_HOME" do
    home = Path.join(System.tmp_dir!(), "fermix-store-#{System.unique_integer([:positive])}")
    System.put_env("FERMIX_HOME", home)

    assert Store.path() == Path.join(home, "auth.json")
  end

  test "path/0 falls back to ~/.fermix when FERMIX_HOME is unset" do
    System.delete_env("FERMIX_HOME")

    assert Store.path() == Path.join(System.user_home!(), ".fermix/auth.json")
  end
end
