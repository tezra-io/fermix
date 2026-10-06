defmodule FermixCore.Auth.ChatGPT.HostIdTest do
  use ExUnit.Case, async: true

  alias FermixCore.Auth.ChatGPT.HostId
  alias FermixTestSupport.SafeRm

  setup do
    home = SafeRm.make_tmp_dir!("chatgpt-host-id")
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    %{auth_path: Path.join(home, "auth.json"), home: home}
  end

  test "lives beside auth.json", %{auth_path: auth_path, home: home} do
    assert HostId.path(auth_path) == Path.join(home, "chatgpt_host.json")
  end

  test "is created on first use as a private v4 urn, and stable after", %{auth_path: auth_path} do
    assert {:ok, id} = HostId.fetch_or_create(auth_path)

    assert id =~
             ~r/\Aurn:uuid:[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/

    file = HostId.path(auth_path)
    assert {:ok, %File.Stat{mode: mode}} = File.stat(file)
    assert Bitwise.band(mode, 0o777) == 0o600
    assert Jason.decode!(File.read!(file)) == %{"version" => 1, "id" => id}

    assert {:ok, ^id} = HostId.fetch_or_create(auth_path)

    assert File.ls!(Path.dirname(file)) |> Enum.filter(&(&1 =~ "chatgpt_host")) == [
             "chatgpt_host.json"
           ]
  end

  test "first attempts racing each other agree on one id", %{auth_path: auth_path} do
    ids =
      1..8
      |> Enum.map(fn _n -> Task.async(fn -> HostId.fetch_or_create(auth_path) end) end)
      |> Enum.map(&Task.await/1)
      |> Enum.uniq()

    assert [{:ok, _id}] = ids
  end

  test "a file others can read is refused, never repaired", %{auth_path: auth_path} do
    {:ok, _id} = HostId.fetch_or_create(auth_path)
    file = HostId.path(auth_path)
    File.chmod!(file, 0o644)
    before = File.read!(file)

    assert {:error, {:host_id_insecure_permissions, ^file, 0o644}} =
             HostId.fetch_or_create(auth_path)

    assert File.read!(file) == before
  end

  test "a symlink is refused", %{auth_path: auth_path, home: home} do
    target = Path.join(home, "elsewhere.json")
    File.write!(target, ~s({"version":1,"id":"urn:uuid:0b6f3b8e-4d0a-4c5e-9f1e-2a7d3c9b1e44"}))
    File.chmod!(target, 0o600)
    file = HostId.path(auth_path)
    :ok = File.ln_s(target, file)

    assert {:error, {:host_id_symlink, ^file}} = HostId.fetch_or_create(auth_path)
  end

  test "a stored value that is not a v4 urn is refused and left as it is", %{
    auth_path: auth_path
  } do
    file = HostId.path(auth_path)

    for bad <- [
          ~s({"version":1,"id":"urn:uuid:not-a-uuid"}),
          ~s({"version":1,"id":"urn:uuid:0b6f3b8e-4d0a-1c5e-9f1e-2a7d3c9b1e44"}),
          ~s({"version":2,"id":"urn:uuid:0b6f3b8e-4d0a-4c5e-9f1e-2a7d3c9b1e44"}),
          "not json"
        ] do
      File.write!(file, bad)
      File.chmod!(file, 0o600)

      assert {:error, {:host_id_invalid, ^file}} = HostId.fetch_or_create(auth_path)
      assert File.read!(file) == bad
    end
  end
end
