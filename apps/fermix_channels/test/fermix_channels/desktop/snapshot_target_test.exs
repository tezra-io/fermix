defmodule FermixChannels.Desktop.SnapshotTargetTest do
  # The desktop snapshot target end to end in one VM (M75 §8, D19): the
  # primary's target streams a real file to a desktop's `SnapshotStore`, whose
  # answer comes back through the primary's `snapshots` family, wired together
  # in place of the rail.
  use ExUnit.Case, async: true

  alias FermixChannels.Desktop.SnapshotCopies
  alias FermixChannels.Desktop.SnapshotStore
  alias FermixChannels.Desktop.SnapshotTarget
  alias FermixChannels.Test.DesktopFamilyHost
  alias FermixCore.Home.Snapshot.Scheduler
  alias FermixTestSupport.SafeRm

  @desktop "desk-1"
  @rows [%{device_id: @desktop, name: "Studio Mac"}]
  @plenty 100 * 1_024 * 1_024 * 1_024
  @wait 10_000

  setup do
    tmp = SafeRm.make_tmp_dir!("desktop_snapshots")
    on_exit(fn -> SafeRm.rm_rf!(tmp) end)
    primary = Path.join(tmp, "primary")
    desktop = Path.join(tmp, "desktop")
    File.mkdir_p!(primary)
    registry = :"snapshot_peers_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :unique, name: registry})
    %{me: self(), primary: primary, desktop: desktop, registry: registry}
  end

  # The desktop's store, whose answers reach the primary's family on `host`.
  defp start_desktop(ctx, free_bytes) do
    store_name = :"snapshot_store_#{System.unique_integer([:positive])}"
    me = ctx.me

    host =
      DesktopFamilyHost.start(
        SnapshotCopies,
        %{device_id: @desktop, session: me, max_media_bytes: 1},
        registry: ctx.registry
      )

    to_primary = fn %{"t" => type} = event, payload ->
      send(me, {:to_primary, type, event})
      GenServer.cast(host, {:event, type, Map.delete(event, "t"), payload})
      :ok
    end

    start_supervised!(
      {SnapshotStore,
       name: store_name,
       home: ctx.desktop,
       send: to_primary,
       free_bytes: fn _dir -> free_bytes end}
    )

    %{store: store_name, host: host}
  end

  defp target_opts(ctx, desktop, extra \\ []) do
    me = ctx.me

    send_event = fn @desktop, %{"t" => type} = event, payload, _opts ->
      :ok = SnapshotStore.handle(desktop.store, type, Map.delete(event, "t"), payload)
    end

    sync = fn session ->
      send(me, :synced)
      SnapshotTarget.sync_session(session)
    end

    [
      desktop_rows: fn -> @rows end,
      desktop_peers: ctx.registry,
      desktop_send: send_event,
      desktop_sync: sync,
      desktop_answer_timeout_ms: @wait
    ] ++ extra
  end

  # An encrypted snapshot as the scheduler hands it on: random bytes here.
  defp snapshot(ctx, name, bytes) do
    path = Path.join(ctx.primary, ".outgoing-#{System.unique_integer([:positive])}.fxsnap")
    data = :crypto.strong_rand_bytes(bytes)
    File.write!(path, data)

    %{
      path: path,
      name: name,
      size: bytes,
      sha256: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower),
      epoch: 4,
      created_at: ~U[2026-10-27 09:30:00Z]
    }
  end

  defp copies(ctx), do: ctx.desktop |> Path.join("snapshots") |> File.ls!() |> Enum.sort()

  test "streams the snapshot to the desktop, which keeps it verified and 0600", ctx do
    desktop = start_desktop(ctx, {:ok, @plenty})
    snapshot = snapshot(ctx, "20261027T093000Z-e4.fxsnap", 2 * 1_024 * 1_024 + 17)

    assert {:ok, %{location: "snapshots/ on Studio Mac"}} =
             SnapshotTarget.store(snapshot, %{names: ["Studio Mac"]}, target_opts(ctx, desktop))

    kept = Path.join([ctx.desktop, "snapshots", snapshot.name])
    assert File.read!(kept) == File.read!(snapshot.path)
    assert {:ok, %File.Stat{mode: mode}} = File.stat(kept)
    assert Bitwise.band(mode, 0o777) == 0o600
    assert copies(ctx) == [snapshot.name]

    # 35 chunks of 60 KiB: the stream waited on the session twice.
    assert_received :synced
    assert_received :synced
    refute_received :synced
    assert_received {:to_primary, "snapshot_stored", %{"sha256" => sha}}
    assert sha == snapshot.sha256
  end

  test "a copy that does not match is refused, and no partial is left", ctx do
    desktop = start_desktop(ctx, {:ok, @plenty})

    snapshot = %{
      snapshot(ctx, "20261027T093000Z-e4.fxsnap", 4_096)
      | sha256: String.duplicate("0", 64)
    }

    assert {:error, {:refused, "Studio Mac", "mismatch"} = reason} =
             SnapshotTarget.store(snapshot, %{names: ["Studio Mac"]}, target_opts(ctx, desktop))

    assert SnapshotTarget.sentence(reason) ==
             "Your Studio Mac received a copy that did not match the snapshot, so it kept none."

    assert copies(ctx) == []
  end

  test "a desktop answering another SHA-256 is not verified", ctx do
    me = ctx.me

    host =
      DesktopFamilyHost.start(
        SnapshotCopies,
        %{device_id: @desktop, session: me, max_media_bytes: 1},
        registry: ctx.registry
      )

    # A desktop that says it stored something else.
    lying = fn @desktop, %{"t" => type} = event, _payload, _opts ->
      if type == "snapshot_end" do
        fields = %{"snapshot_id" => event["snapshot_id"], "sha256" => String.duplicate("a", 64)}
        DesktopFamilyHost.event(host, "snapshot_stored", fields)
      end

      :ok
    end

    snapshot = snapshot(ctx, "20261027T093000Z-e4.fxsnap", 100)
    opts = Keyword.put(target_opts(ctx, %{store: nil}), :desktop_send, lying)

    assert {:error, {:sha_mismatch, "Studio Mac"}} =
             SnapshotTarget.store(snapshot, %{names: ["Studio Mac"]}, opts)
  end

  test "the desktop keeps the newest three", ctx do
    desktop = start_desktop(ctx, {:ok, @plenty})

    names =
      for hour <- 10..13 do
        snapshot = snapshot(ctx, "20261027T#{hour}0000Z-e4.fxsnap", 1_000)

        {:ok, _stored} =
          SnapshotTarget.store(snapshot, %{names: ["Studio Mac"]}, target_opts(ctx, desktop))

        snapshot.name
      end

    assert copies(ctx) == Enum.drop(names, 1)
    assert SnapshotStore.keep() == 3
  end

  test "a copy that would leave the disk under its floor is refused before a byte is written",
       ctx do
    snapshot_bytes = 1_000
    desktop = start_desktop(ctx, {:ok, SnapshotStore.floor_bytes() + snapshot_bytes - 1})
    snapshot = snapshot(ctx, "20261027T093000Z-e4.fxsnap", snapshot_bytes)

    assert {:error, {:refused, "Studio Mac", "disk_floor"} = reason} =
             SnapshotTarget.store(snapshot, %{names: ["Studio Mac"]}, target_opts(ctx, desktop))

    assert SnapshotTarget.sentence(reason) =~ "less than 2 GiB free"
    assert copies(ctx) == []
  end

  test "with no desktop connected the snapshot waits for the next run: waiting, not failed",
       ctx do
    snapshot = snapshot(ctx, "20261027T093000Z-e4.fxsnap", 10)
    opts = target_opts(ctx, %{store: nil})

    assert {:waiting, {:not_connected, "Studio Mac"} = reason} =
             SnapshotTarget.store(snapshot, %{names: ["Studio Mac"]}, opts)

    assert SnapshotTarget.sentence(reason) ==
             "Your Studio Mac is not connected; the snapshot waits for the next run."
  end

  describe "the desktop's store" do
    setup ctx do
      Map.put(ctx, :desktop_store, start_desktop(ctx, {:ok, @plenty}))
    end

    test "refuses a chunk out of order and drops the partial", ctx do
      store = ctx.desktop_store.store

      begin = %{
        "snapshot_id" => "s1",
        "name" => "20261027T093000Z-e4.fxsnap",
        "size_bytes" => 3,
        "sha256" => String.duplicate("0", 64)
      }

      :ok = SnapshotStore.handle(store, "snapshot_begin", begin, <<>>)

      :ok =
        SnapshotStore.handle(
          store,
          "snapshot_chunk",
          %{"snapshot_id" => "s1", "index" => 1},
          "abc"
        )

      assert_receive {:to_primary, "snapshot_refused", %{"reason" => "out_of_order"}}
      assert copies(ctx) == []
    end

    test "refuses a name that is not a snapshot's", ctx do
      begin = %{
        "snapshot_id" => "s1",
        "name" => "../evil.fxsnap",
        "size_bytes" => 3,
        "sha256" => String.duplicate("0", 64)
      }

      :ok = SnapshotStore.handle(ctx.desktop_store.store, "snapshot_begin", begin, <<>>)
      assert_receive {:to_primary, "snapshot_refused", %{"reason" => "invalid_name"}}
    end
  end

  test "the scheduler writes to S3 and then to the desktops" do
    assert Scheduler.targets() == [FermixCore.Home.Snapshot.S3, SnapshotTarget]
  end

  test "it is on only while the primary has a desktop row" do
    assert SnapshotTarget.configured(recipient: "x") == :not_configured
    assert SnapshotTarget.destination(%{names: ["Studio Mac"]}, []) == "snapshots/ on Studio Mac"
  end

  test "every sentence obeys the copy rules" do
    alias FermixCore.Management.Copy

    for reason <- [
          {:not_connected, "Studio Mac"},
          {:disconnected, "Studio Mac"},
          {:timeout, "Studio Mac"},
          {:sha_mismatch, "Studio Mac"},
          {:refused, "Studio Mac", "disk_floor"},
          {:refused, "Studio Mac", "space_unknown"},
          {:refused, "Studio Mac", "mismatch"},
          {:refused, "Studio Mac", "write_failed"}
        ] do
      sentence = SnapshotTarget.sentence(reason)
      assert Copy.violations(sentence, :prose, ["Studio Mac", "GiB"]) == [], sentence
    end
  end

  # The family on its own: an answer reaches the run that waits for it, once.
  test "an answer reaches the waiting run, and one nobody waits for is dropped" do
    {:ok, state} = SnapshotCopies.init(%{device_id: @desktop})
    {:ok, state} = SnapshotCopies.handle_info({:await, "s1", self()}, state)

    {:ok, state} =
      SnapshotCopies.handle_event(
        "snapshot_stored",
        %{"snapshot_id" => "s1", "sha256" => "AB"},
        <<>>,
        state
      )

    assert_received {:desktop_snapshot, "s1", {:stored, "ab"}}

    {:ok, _state} =
      SnapshotCopies.handle_event(
        "snapshot_refused",
        %{"snapshot_id" => "s1", "reason" => "mismatch"},
        <<>>,
        state
      )

    refute_received {:desktop_snapshot, "s1", _result}
  end
end
