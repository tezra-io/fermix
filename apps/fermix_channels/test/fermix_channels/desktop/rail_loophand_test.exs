defmodule FermixChannels.Desktop.RailLoophandTest do
  # The sign-in forward and the snapshot copy over a real desktop session (M75
  # D17, D19): the primary's own `Mobile.Session` and peer with Noise behind the
  # iroh bridge, the desktop's own relay, and the desktop's two servers under
  # the names the relay's `@inbound` reaches.
  #
  # Sync: those servers are registered under their own (global) names.
  use ExUnit.Case, async: false

  alias FermixChannels.Desktop.Loopback
  alias FermixChannels.Desktop.LoopbackForward
  alias FermixChannels.Desktop.Relay
  alias FermixChannels.Desktop.SnapshotCopies
  alias FermixChannels.Desktop.SnapshotStore
  alias FermixChannels.Desktop.SnapshotTarget
  alias FermixChannels.Test.DesktopRail
  alias FermixCore.Auth.OAuthFlow
  alias FermixCore.Auth.OAuthProvider

  @wait 10_000
  @plenty 100 * 1_024 * 1_024 * 1_024

  defp connect(families) do
    primary = DesktopRail.primary!(families: families)
    root = DesktopRail.desktop_home!(primary)
    relay = DesktopRail.start_relay!(root, primary)
    %{primary: primary, root: root, relay: relay, send: &Relay.send_event(relay, &1, &2)}
  end

  test "a snapshot streams to the desktop over the session and is verified" do
    ctx = connect(%{snapshots: SnapshotCopies})

    start_supervised!(
      {SnapshotStore, home: ctx.root, send: ctx.send, free_bytes: fn _dir -> {:ok, @plenty} end}
    )

    DesktopRail.await_connected(ctx.relay)

    # Twenty 60 KiB chunks: the stream waits on the session once.
    data = :crypto.strong_rand_bytes(20 * 61_440 - 7)
    dir = DesktopRail.root!("fx-snap")
    path = Path.join(dir, "outgoing.fxsnap")
    File.write!(path, data)
    name = "20261027T093000Z-e3.fxsnap"

    snapshot = %{
      path: path,
      name: name,
      size: byte_size(data),
      sha256: :sha256 |> :crypto.hash(data) |> Base.encode16(case: :lower),
      epoch: 3,
      created_at: ~U[2026-10-27 09:30:00Z]
    }

    opts = [
      desktop_rows: fn -> [%{device_id: DesktopRail.device_id(), name: "Studio Mac"}] end,
      desktop_peers: ctx.primary.peers
    ]

    assert {:ok, %{location: "snapshots/ on Studio Mac"}} =
             SnapshotTarget.store(snapshot, %{names: ["Studio Mac"]}, opts)

    assert File.read!(Path.join([ctx.root, "snapshots", name])) == data
  end

  test "a sign-in's reply on the desktop reaches the primary's listener over the session" do
    ctx = connect(%{loopback: LoopbackForward})
    test = self()

    bind_port = fn port ->
      {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
      {:ok, free} = :inet.port(socket)
      :ok = :gen_tcp.close(socket)
      send(test, {:bound, port, free})
      free
    end

    start_supervised!({Loopback, send: ctx.send, bind_port: bind_port})
    DesktopRail.await_connected(ctx.relay)

    flow =
      Task.async(fn ->
        OAuthFlow.await_authorization(provider(),
          opener: fn url -> send(test, {:authorize, url}) && :ok end,
          puts: fn _line -> :ok end,
          timeout_ms: @wait,
          loopback_owner: {:desktop, DesktopRail.device_id()}
        )
      end)

    assert_receive {:authorize, url}
    params = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    port = params["redirect_uri"] |> URI.parse() |> Map.fetch!(:port)
    assert_receive {:bound, ^port, desktop_port}, @wait

    {:ok, conn} = :gen_tcp.connect(~c"127.0.0.1", desktop_port, [:binary, active: false])

    :ok =
      :gen_tcp.send(
        conn,
        "GET /callback?code=c1&state=#{params["state"]} HTTP/1.1\r\n" <>
          "Host: 127.0.0.1:#{port}\r\n\r\n"
      )

    response = read_all(conn, "")
    :gen_tcp.close(conn)

    assert "HTTP/1.1 200 OK" <> _rest = response
    assert {:ok, %{code: "c1"}} = Task.await(flow, @wait)
  end

  defp provider do
    %OAuthProvider{
      id: :mcp,
      authorize_url: "https://auth.example/authorize",
      token_url: "https://auth.example/token",
      client_id: "client",
      redirect_host: "127.0.0.1",
      redirect_port: 0,
      redirect_path: "/callback",
      scopes: ["read"],
      hardened_callback?: true
    }
  end

  defp read_all(conn, acc) do
    case :gen_tcp.recv(conn, 0, @wait) do
      {:ok, bytes} -> read_all(conn, acc <> bytes)
      {:error, :closed} -> acc
    end
  end
end
