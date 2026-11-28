defmodule FermixChannels.Home.MoveBackComputersTest do
  # M102 D6: a home off a server holds no computer, so a move back and
  # Restore here (both settle through `Candidate.Return.settle/4`) drop every
  # computer's row from the staged device list, this computer's and every
  # other's, through the real rail, and keep the phones. A computer that
  # joined the server dials the home's identity, which comes back with the
  # home, so it reaches this computer next; with its row gone it is told it
  # is unknown (`4003`), the word its relay keeps as "removed"
  # (`Desktop.RelayTest`), whose screen offers Join again (`HomeSummaryTest`).
  use ExUnit.Case, async: true

  alias FermixChannels.Desktop.Supervisor, as: DesktopSupervisor
  alias FermixChannels.Mobile.DeviceRegistry
  alias FermixChannels.Mobile.DeviceStore
  alias FermixChannels.Mobile.Noise
  alias FermixChannels.Test.SessionDriver, as: Driver
  alias FermixCore.Home.Candidate.Return
  alias FermixCore.Home.ComputerKey
  alias FermixCore.Home.DesktopLink
  alias FermixTestSupport.SafeRm

  @created ~U[2031-05-01 10:00:00Z]

  setup do
    tmp = SafeRm.make_tmp_dir!("move_back_computers")
    on_exit(fn -> SafeRm.rm_rf!(tmp) end)
    mac = Path.join(tmp, "mac")
    staging = Path.join(tmp, "staging")
    File.mkdir!(mac)
    File.mkdir!(staging)

    # This computer, the one the home left: a linked desktop whose own key
    # names its row in the server's list.
    File.write!(Path.join(mac, "config.toml"), """
    [fermix_core]
    profile = "mbc-#{System.unique_integer([:positive])}"
    secret_store = "file"
    """)

    {:ok, keypair, :file} = ComputerKey.create(mac)
    :ok = DesktopLink.write(mac, desktop_link())

    joined = Noise.generate_keypair()
    this_row = row(:desktop, "orchard-mac", keypair.public)
    joined_row = row(:desktop, "loft-linux", joined.public)
    phone = row(:phone, "Pixel 9", :crypto.strong_rand_bytes(32))

    for attrs <- [this_row, joined_row, phone],
        do: {:ok, _device} = DeviceStore.add(attrs, root: staging)

    %{mac: mac, staging: staging, joined: joined}
  end

  test "a move back's settle leaves no computer's row, this one's or another's, and keeps phones",
       ctx do
    assert {:ok, _text} = Return.settle("", ctx.mac, ctx.staging, [])

    assert {:ok, [%{name: "Pixel 9", kind: :phone}]} = DeviceStore.list(root: ctx.staging)
  end

  test "a computer that joined the server, dialing the home back here, is told it is unknown",
       ctx do
    assert {:ok, _text} = Return.settle("", ctx.mac, ctx.staging, [])
    store = start_supervised!({DeviceStore, name: nil, root: ctx.staging})
    gateway = Noise.generate_keypair()
    driver = Driver.start!(session_opts(gateway, store))

    {:ok, client} =
      Noise.initialize(:initiator, :ik, static_keypair: ctx.joined, remote_static: gateway.public)

    assert {:ok, first, client} = Noise.write_handshake(client, <<>>)
    Driver.wire(driver, first)

    assert {:unknown_device, {4003, "device unknown"}, [], _client} =
             Driver.client_closed(driver, client)
  end

  # The primary's session as `desktop_session_test.exs` drives it, reading
  # the staged list through the store a primary would start on it.
  defp session_opts(gateway, store) do
    suffix = System.unique_integer([:positive])
    peers = Module.concat(__MODULE__, "Peers#{suffix}")
    peer_supervisor = Module.concat(__MODULE__, "PeerSupervisor#{suffix}")

    start_supervised!(
      {DesktopSupervisor, name: nil, registry: peers, peer_supervisor: peer_supervisor}
    )

    registry =
      start_supervised!(
        {DeviceRegistry,
         name: Module.concat(__MODULE__, "Registry#{suffix}"),
         authorize_device: fn _store, _id -> {:error, :unused} end,
         delete_device: fn _store, _id -> :ok end,
         revoke_requests: fn _id -> :ok end}
      )

    [
      peer: {127, 0, 0, 1},
      gateway_keypair: gateway,
      primary_epoch: 6,
      device_store: store,
      device_registry: registry,
      desktop_peers: peers,
      desktop_peer_supervisor: peer_supervisor,
      wall_clock: fn -> @created end,
      pending_approvals: fn "main" -> [] end
    ]
  end

  defp desktop_link do
    %{
      device_id: "6f1e2d3c-4b5a-4968-8778-695a4b3c2d1e",
      key: :file,
      primary: %{
        name: "hetzner-orchard",
        gateway_pk: :binary.copy(<<3>>, 32),
        node_id: String.duplicate("c4", 32),
        relays: [%{"url" => "https://eu1.relay.invalid/", "quic_port" => 7842}],
        relays_rev: String.duplicate("a1", 8)
      },
      epoch: 5
    }
  end

  defp row(:desktop, name, noise_pk),
    do: %{
      device_id: uuid(),
      name: name,
      model: "macos desktop",
      noise_pk: noise_pk,
      created_at: @created,
      kind: :desktop
    }

  defp row(:phone, name, noise_pk),
    do: %{
      device_id: uuid(),
      name: name,
      model: "Pixel 9",
      noise_pk: noise_pk,
      created_at: @created,
      push_token: nil,
      last_seen: nil,
      apns_key_salt: :crypto.strong_rand_bytes(32)
    }

  defp uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    [a, b, c, d, e]
    |> Enum.zip([8, 4, 4, 4, 12])
    |> Enum.map_join("-", fn {value, width} ->
      value |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(width, "0")
    end)
  end
end
