defmodule FermixCore.Setup.ConfigStoreTest do
  use ExUnit.Case, async: false

  alias FermixCore.Setup.ConfigStore

  setup do
    fermix_home = System.get_env("FERMIX_HOME")

    on_exit(fn ->
      case fermix_home do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end
    end)

    :ok
  end

  test "workspace_paths follow FERMIX_HOME and match the persisted runtime layout" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    System.put_env("FERMIX_HOME", tmp_home)

    assert ConfigStore.workspace_paths() == %{
             skills: Path.join(tmp_home, "skills"),
             journals: Path.join(tmp_home, "journals"),
             traces: Path.join(tmp_home, "traces"),
             logs: Path.join(tmp_home, "logs")
           }
  end
end
