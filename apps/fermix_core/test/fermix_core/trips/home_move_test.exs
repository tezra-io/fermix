defmodule FermixCore.Trips.HomeMoveTest do
  # M89 §05: a trip lives in the home's memory.db, so it travels with the
  # home's backup and move with no registration. A snapshot written and
  # restored to an empty root reads the trip and its receipts back.
  use ExUnit.Case, async: true

  alias FermixCore.Home.Epoch
  alias FermixCore.Home.Snapshot
  alias FermixCore.Home.Snapshot.Recipient
  alias FermixCore.Memory.Repo
  alias FermixCore.Trips.Registry
  alias FermixTestSupport.SafeRm

  # Every title, id and passphrase here is invented.
  @passphrase "invented-harbour-lantern"
  @now ~U[2031-06-02 14:00:00Z]
  @now_ms 1_948_715_400_000
  @host "macos-aarch64"
  @inn %{"name" => "Marisco Inn", "location" => %{"latitude" => 41.2031, "longitude" => -8.4102}}

  # The derivation is the slow part, so the recovery pair is made once.
  setup_all do
    {:ok, pair} = Recipient.from_passphrase(@passphrase)
    %{pair: pair}
  end

  setup do
    tmp = SafeRm.make_tmp_dir!("trips_home_move")
    on_exit(fn -> SafeRm.rm_rf!(tmp) end)
    home = Path.join(tmp, "home")
    :ok = File.mkdir(home)
    %{home: home, out: Path.join(tmp, "out.fxsnap"), into: Path.join(tmp, "restored")}
  end

  defp opts(repo), do: [repo: repo, now: @now, notifier: fn _changes -> :ok end]

  defp device(repo, client_msg_id, op, trip_id \\ nil) do
    params = %{"client_msg_id" => client_msg_id, "op" => op}
    params = if trip_id, do: Map.put(params, "trip_id", trip_id), else: params
    Registry.device_edit(params, :independent, opts(repo))
  end

  defp start_repo(name, root) do
    database_path = Path.join(root, "memory.db")
    start_supervised!({Repo, name: name, enabled: true, database_path: database_path}, id: name)
  end

  test "reopen after a home move: a snapshot restored to an empty root reads the trip and its receipts back",
       %{pair: pair, home: home, out: out, into: into} do
    repo = :"trips_home_#{System.unique_integer([:positive])}"
    start_repo(repo, home)

    create = %{"op" => "create", "title" => "Varonne"}
    assert {:ok, %{trip_id: trip_id}} = device(repo, "mac-1", create)

    {:ok, %{rows: [%{id: day_id}]}} =
      Registry.device_trip(trip_id, false, :independent, repo: repo)

    add = %{"op" => "add", "text" => "Back to the inn", "day_id" => day_id, "place" => @inn}
    assert {:ok, %{made: stop_id}} = device(repo, "mac-2", add, trip_id)

    {:ok, before} = Registry.device_trip(trip_id, true, :independent, repo: repo)
    :ok = stop_supervised(repo)

    :ok = File.write(Path.join(home, "config.toml"), "")
    :ok = Epoch.write(home, 3)

    # The disk's free space is the test's own, never the host's.
    room = fn _dir -> {:ok, 1_000_000_000} end

    assert {:ok, %{epoch: 3}} =
             Snapshot.write(home, Recipient.public(pair), out,
               now: fn -> @now end,
               host: @host,
               free_bytes: room
             )

    assert {:ok, %{epoch: 4}} =
             Snapshot.restore(out, pair, into,
               host: @host,
               keyring_usable?: fn -> true end,
               now_ms: @now_ms
             )

    moved = :"#{repo}_moved"
    start_repo(moved, into)

    assert Registry.device_trip(trip_id, true, :independent, repo: moved) == {:ok, before}

    assert device(moved, "mac-2", add, trip_id) ==
             {:ok, %{trip_id: trip_id, made: stop_id, duplicate: true}}
  end
end
