defmodule FermixCore.IMessage.HomeTest do
  use ExUnit.Case, async: false

  import Bitwise, only: [&&&: 2]

  alias FermixCore.IMessage.Home
  alias FermixTestSupport.SafeRm

  setup do
    previous = System.get_env("FERMIX_HOME")
    home = SafeRm.make_tmp_dir!("imessage-home")
    System.put_env("FERMIX_HOME", home)

    on_exit(fn ->
      restore_env(previous)
      SafeRm.rm_rf(home)
    end)

    %{home: home}
  end

  test "every path lives under the channel's own directory in the Fermix home", %{home: home} do
    root = Path.join(home, "imessage")

    assert Home.dir() == root
    assert Home.cursor_path() == Path.join(root, "cursor")
    assert Home.helper_dir() == Path.join(root, "helper")
    assert Home.inbox_dir() == Path.join(root, "inbox")
    assert Home.outbox_dir() == Path.join(root, "outbox")
  end

  test "ensure/0 creates all four directories readable by this account only" do
    assert Home.ensure() == :ok

    for dir <- [Home.dir(), Home.helper_dir(), Home.inbox_dir(), Home.outbox_dir()] do
      assert File.dir?(dir), "#{dir} was not created"
      assert {:ok, %File.Stat{mode: mode}} = File.stat(dir)
      assert (mode &&& 0o777) == 0o700, "#{dir} is #{Integer.to_string(mode &&& 0o777, 8)}"
    end
  end

  test "ensure/0 repairs a directory an earlier run left at a wider mode" do
    File.mkdir_p!(Home.inbox_dir())
    File.chmod!(Home.inbox_dir(), 0o755)

    assert Home.ensure() == :ok
    assert {:ok, %File.Stat{mode: mode}} = File.stat(Home.inbox_dir())
    assert (mode &&& 0o777) == 0o700
  end

  test "ensure/0 names the directory it could not create", %{home: home} do
    blocker = Path.join(home, "imessage")
    File.write!(blocker, "not a directory")

    assert {:error, {:imessage_home, ^blocker, _reason}} = Home.ensure()
  end

  defp restore_env(nil), do: System.delete_env("FERMIX_HOME")
  defp restore_env(value), do: System.put_env("FERMIX_HOME", value)
end
