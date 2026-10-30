defmodule FermixCore.Management.DeviceGrantsTest do
  @moduledoc """
  M75 §11 (re-check R1): the owner sees and removes, on the desktop, every
  folder the server may read there, through the management family the apps
  and `fermix device grants` call (`device.grants.list`,
  `device.grants.remove`), answered by this computer's engine and never the
  server's.
  """

  use ExUnit.Case, async: true

  alias FermixCore.Home.ReadGrants
  alias FermixCore.Management.Placement
  alias FermixCore.Management.Router
  alias FermixCore.Sandbox.PathPolicy
  alias FermixTestSupport.SafeRm

  @at ~U[2026-10-27 09:30:00Z]
  @device %{role: :device, primary: "fermix-vm"}

  setup do
    home = SafeRm.make_tmp_dir!("device-grants")
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    %{home: home}
  end

  defp route(method, params, home) do
    Router.route(
      %{request_id: "req-1", protocol_version: 2, method: method, params: params},
      engine_role: @device,
      operation_opts: [device: [home: home]]
    )
  end

  test "an engine that holds no grant lists none", %{home: home} do
    assert route("device.grants.list", %{}, home) ==
             {:ok,
              %{
                "grants" => [],
                "sentence" =>
                  "The server may read nothing on this computer beyond what its sandbox allows."
              }}
  end

  test "the grants are listed oldest first, and one removed is gone for good", %{home: home} do
    :ok = ReadGrants.add(home, "/Users/ana/Downloads", @at)
    :ok = ReadGrants.add(home, "/Users/ana/Taxes", ~U[2026-10-27 10:00:00Z])

    assert {:ok, %{"grants" => grants, "sentence" => sentence}} =
             route("device.grants.list", %{}, home)

    assert grants == [
             %{"path" => "/Users/ana/Downloads", "granted_at" => "2026-10-27T09:30:00Z"},
             %{"path" => "/Users/ana/Taxes", "granted_at" => "2026-10-27T10:00:00Z"}
           ]

    assert sentence ==
             "The server may read 2 folders on this computer beyond what its sandbox allows."

    assert route("device.grants.remove", %{"path" => "/Users/ana/Downloads"}, home) ==
             {:ok,
              %{
                "removed" => "/Users/ana/Downloads",
                "grants" => [
                  %{"path" => "/Users/ana/Taxes", "granted_at" => "2026-10-27T10:00:00Z"}
                ],
                "sentence" => "The server can no longer read that folder on this computer."
              }}

    assert {:ok, ["/Users/ana/Taxes"]} = ReadGrants.folders(home)

    assert route("device.grants.remove", %{"path" => "/Users/ana/Downloads"}, home) ==
             {:error, :invalid_params,
              %{
                "field" => "path",
                "sentence" => "This computer has no read grant for that folder."
              }}
  end

  test "a folder named another way (a link to it) removes its grant", %{home: home} do
    real = Path.join(home, "Shared Projects")
    File.mkdir_p!(real)
    link = Path.join(home, "projects-link")
    :ok = File.ln_s(real, link)
    :ok = ReadGrants.add(home, PathPolicy.canonical_path(real), @at)

    assert {:ok, %{"removed" => ^link, "grants" => []}} =
             route("device.grants.remove", %{"path" => link}, home)
  end

  test "a path that is not absolute, missing, or beside other fields is refused", %{home: home} do
    for params <- [
          %{"path" => "Downloads"},
          %{"path" => ""},
          %{"path" => 7},
          %{},
          %{"path" => "/a", "also" => true},
          %{"path" => "/" <> String.duplicate("a", 4_096)}
        ] do
      assert {:error, :invalid_params, %{"field" => field}} =
               route("device.grants.remove", params, home)

      assert field in ["path", "also"]
    end

    assert {:error, :invalid_params, _details} = route("device.grants.list", %{"x" => 1}, home)
  end

  test "a grants file that is not one is unavailable by name, never read as no grant",
       %{home: home} do
    File.mkdir_p!(Path.dirname(ReadGrants.path(home)))
    File.write!(ReadGrants.path(home), "not json")

    for {method, params} <- [
          {"device.grants.list", %{}},
          {"device.grants.remove", %{"path" => "/Users/ana/Downloads"}}
        ] do
      assert {:error, :unavailable, %{"capability" => "device", "sentence" => sentence}} =
               route(method, params, home)

      assert sentence == "This computer's read grants could not be read. See the daemon log."
    end
  end

  test "the family is this computer's: answered here and never served for a desktop" do
    for method <- ~w(device.grants.list device.grants.remove) do
      assert Placement.place(method, %{"path" => "/a"}) == :device
      refute Placement.served_forwarded?(method, %{"path" => "/a"})
    end
  end
end
