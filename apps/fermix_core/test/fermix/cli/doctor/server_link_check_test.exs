defmodule Fermix.CLI.Doctor.ServerLinkCheckTest do
  # M75 Always On step 7: `fermix doctor` says how this computer reaches its
  # server, direct or through Fermix's relay, from the running engine's own
  # `home.status`; a computer with no link to a server shows no row.
  use ExUnit.Case, async: true

  alias Fermix.CLI.Doctor.Checks
  alias FermixCore.Home.DesktopLink
  alias FermixCore.Management.Doctor.Descriptor
  alias FermixTestSupport.SafeRm

  setup do
    home = SafeRm.make_tmp_dir!("doctor-link")
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    %{home: home}
  end

  defp linked!(home) do
    :ok =
      DesktopLink.write(home, %{
        device_id: "6f1e2d3c-4b5a-4968-8778-695a4b3c2d1e",
        primary: %{
          name: "fermix-vm",
          gateway_pk: <<7::256>>,
          node_id: String.duplicate("ab", 32),
          relays: [%{"url" => "https://relay.invalid/", "quic_port" => 7842}],
          relays_rev: "0123456789abcdef"
        },
        epoch: 4
      })

    home
  end

  defp answering(primary),
    do: fn -> {:ok, %{"status" => "ok", "result" => %{"primary" => primary}}} end

  defp primary(fields) do
    Map.merge(
      %{
        "name" => "fermix-vm",
        "connected" => true,
        "status" => "connected",
        "since" => "2031-05-04T09:00:00Z",
        "epoch" => 5,
        "sentence" => "Fermix is connected to the server fermix-vm."
      },
      fields
    )
  end

  test "a connected link says whether it runs direct or through the relay", %{home: home} do
    home = linked!(home)

    assert %{name: "server link", status: :ok, detail: "connected to fermix-vm directly"} =
             Checks.server_link(home: home, client: answering(primary(%{"path" => "direct"})))

    assert %{status: :ok, detail: "connected to fermix-vm through Fermix's relay"} =
             Checks.server_link(home: home, client: answering(primary(%{"path" => "relay"})))

    # An engine that names no path yet.
    assert %{status: :ok, detail: "connected to fermix-vm"} =
             Checks.server_link(home: home, client: answering(primary(%{})))
  end

  test "a link that is down says why, in the link's own sentence", %{home: home} do
    home = linked!(home)
    down = "The server fermix-vm is unreachable: no route reached it. Fermix tries again in 4 s."

    assert %{status: :warn, detail: ^down} =
             Checks.server_link(
               home: home,
               client:
                 answering(
                   primary(%{"connected" => false, "status" => "unreachable", "sentence" => down})
                 )
             )

    revoked = "The server fermix-vm does not know this computer. Fermix stopped reaching it."

    assert %{status: :fail, detail: ^revoked} =
             Checks.server_link(
               home: home,
               client:
                 answering(
                   primary(%{"connected" => false, "status" => "revoked", "sentence" => revoked})
                 )
             )
  end

  test "an engine that does not answer is said, never taken for a link", %{home: home} do
    home = linked!(home)

    # A stopped engine in the daemon socket row's words, never a bare atom.
    assert %{
             status: :warn,
             detail: "not read: the engine is not running (start with `fermix start`)"
           } = Checks.server_link(home: home, client: fn -> {:error, :not_running} end)

    # An engine older than the row's request.
    older = fn -> {:ok, %{"status" => "error", "reason" => "unknown method"}} end

    assert %{status: :warn, detail: "not read: the running engine answered unknown method"} =
             Checks.server_link(home: home, client: older)
  end

  test "a computer with no link to a server has no row", %{home: home} do
    assert Checks.server_link(home: home, client: fn -> flunk("asked") end) == nil
  end

  test "the engine's doctor publishes the row in its local catalog" do
    assert "server_link" in Enum.map(Descriptor.catalog(:local), & &1.id)
  end
end
