defmodule FermixChannels.Home.CandidateReturnTest do
  # Always On's move back, the receiving computer's side (design §3.1, §14):
  # the candidate process of a `return` kind stages the server's home as a
  # return and, on `move_commit`, puts it in place of this computer's retired
  # copy and restarts; it keeps the computer awake from `receiving` until that
  # restart; a stop part-way is finished by its next start. One of kind
  # `local` (restored from a copy this computer holds) waits for no commit.
  # Real: both homes on disk, the snapshot and the restore, the staging's
  # settling and the activation's renames. Stood in for: the rail (the test
  # calls the process as its move responder does), the timers and the
  # restart (messages to the test), the hold on sleep.
  use ExUnit.Case, async: true

  alias FermixChannels.Home.Candidate, as: CandidateProcess
  alias FermixChannels.Mobile.DeviceStore
  alias FermixChannels.Mobile.Noise
  alias FermixChannels.Test.HomeMove
  alias FermixCore.Home.Candidate
  alias FermixCore.Home.Candidate.Activation
  alias FermixCore.Home.DesktopLink
  alias FermixCore.Home.EnrollmentCode
  alias FermixCore.Home.Epoch
  alias FermixCore.Home.Moved
  alias FermixCore.Home.Role
  alias FermixCore.Home.Snapshot
  alias FermixCore.Home.Snapshot.Recipient
  alias FermixTestSupport.SafeRm

  @now ~U[2031-06-01 09:00:00Z]
  @plenty 1_099_511_627_776
  @move_id "mv-20310601T090500Z-7f3a"
  @mac %{"name" => "studio-mac", "os" => "darwin", "arch" => "aarch64", "version" => "9.9.9"}

  setup do
    tmp = SafeRm.make_tmp_dir!("candidate_return")
    on_exit(fn -> SafeRm.rm_rf!(tmp) end)
    mac = retired_mac!(Path.join(tmp, "mac"))
    desktop_key = desktop_key!(mac)
    server = server_home!(Path.join(tmp, "server"), desktop_key)
    %{tmp: tmp, mac: mac, server: server}
  end

  describe "a return from the server" do
    setup ctx do
      return_candidate!(ctx.mac)
      Map.put(ctx, :stream, stream!(ctx))
    end

    test "is put in place of the retired copy on move_commit, then the engine restarts", ctx do
      name = start_candidate!(ctx.mac)
      refute_received :awake_held

      assert {:ok, %{incoming: incoming}} = CandidateProcess.offer(name, offer(ctx.stream))
      assert_receive :awake_held
      File.cp!(ctx.stream, incoming)

      assert :ok = CandidateProcess.stage(name, @move_id, self())
      assert_receive {:candidate_staged, @move_id, {:ok, 6}}, 30_000

      staging = Candidate.staging_path(ctx.mac)
      staged = File.read!(Path.join(staging, "config.toml"))
      # This computer's own sandbox, not the server's.
      assert staged =~ "this computer's sandbox"
      refute staged =~ "the server's sandbox"
      # Its own desktop row is gone from the device list it takes back.
      assert {:ok, [%{name: "office-mac"}]} = DeviceStore.list(root: staging)

      assert {:ok, 6} = CandidateProcess.commit(name, @move_id)
      assert_received {:scheduled, :restart, _delay}

      assert {:ok, %{role: :primary}} = Role.configured(ctx.mac)
      assert {:ok, 6} = Epoch.read(ctx.mac)
      assert Moved.read(ctx.mac) == :absent
      refute Candidate.present?(ctx.mac)
      assert File.read!(Path.join([ctx.mac, "journals", "day.md"])) == "a day on the server\n"

      assert File.read!(Path.join([ctx.mac, "browser", "profiles", "owner", "Cookies"])) ==
               "signed-in sessions"

      refute File.exists?(Path.join(ctx.mac, "chatgpt_host.json"))
      refute File.exists?(DesktopLink.path(ctx.mac))

      # The computer may sleep again only as the engine restarts.
      send(Process.whereis(name), :restart)
      assert_receive first when first in [:awake_released, :candidate_restart]
      assert first == :awake_released
      assert_receive :candidate_restart
    end

    test "a staging that fails lets the computer sleep again until the next offer", ctx do
      name = start_candidate!(ctx.mac)
      assert {:ok, %{incoming: incoming}} = CandidateProcess.offer(name, offer(ctx.stream))
      assert_receive :awake_held
      File.write!(incoming, "not a snapshot")

      assert :ok = CandidateProcess.stage(name, @move_id, self())
      assert_receive {:candidate_staged, @move_id, {:error, sentence}}, 30_000
      assert sentence == "The home from north-box could not be restored here."
      assert_receive :awake_released
      assert {:ok, %{"phase" => "enrolled"}} = Candidate.read_state(ctx.mac)
    end

    test "a keychain that refuses fails the staging, naming what it did not take", ctx do
      keyring_mac!(ctx.mac)
      stream = stream!(ctx, keychain_server!(ctx.server))

      name =
        start_candidate!(ctx.mac,
          restore_opts: [
            host: "macos-aarch64",
            impl: FermixTestSupport.UnavailableSecretWriter,
            supervised: false
          ],
          secret_names: fn -> %{"anthropic_api_key" => "Anthropic key"} end
        )

      assert {:ok, %{incoming: incoming}} = CandidateProcess.offer(name, offer(stream))
      File.cp!(stream, incoming)
      assert :ok = CandidateProcess.stage(name, @move_id, self())
      assert_receive {:candidate_staged, @move_id, {:error, sentence}}, 30_000

      assert sentence ==
               "This computer's keychain did not take your Anthropic key, so Fermix did not " <>
                 "move back: unlock it, then move back again."
    end

    test "a disk with no room is refused before any byte moves, naming this Mac", ctx do
      name = start_candidate!(ctx.mac, free_bytes: fn _dir -> {:ok, 1_000} end)

      assert {:error, "move_failed", sentence} =
               CandidateProcess.offer(name, %{offer(ctx.stream) | "size_bytes" => 10_000})

      assert sentence =~
               ~r/^This Mac needs about .+ free to take Fermix back and has .+: make room on its disk, then move back again\.$/

      assert {:ok, %{"phase" => "enrolled"}} = Candidate.read_state(ctx.mac)
      refute_received :awake_held
    end

    test "one stopped part-way through putting it in place finishes at its next start", ctx do
      name = start_candidate!(ctx.mac)
      assert {:ok, %{incoming: incoming}} = CandidateProcess.offer(name, offer(ctx.stream))
      File.cp!(ctx.stream, incoming)
      assert :ok = CandidateProcess.stage(name, @move_id, self())
      assert_receive {:candidate_staged, @move_id, {:ok, 6}}, 30_000
      :ok = GenServer.stop(name)

      # move_commit came, the entries were recorded and the marker removed;
      # then the engine stopped, its settings still a device's.
      {:ok, state} = Candidate.read_state(ctx.mac)
      :ok = Candidate.put_state(ctx.mac, %{state | "phase" => "activating"}, @now)
      assert {:ok, _entries} = Activation.record_entries(ctx.mac)
      :ok = Moved.remove(ctx.mac)
      assert {:ok, %{role: :device}} = Role.configured(ctx.mac)

      _name = start_candidate!(ctx.mac)
      assert_receive :awake_held
      assert_receive {:scheduled, :restart, _delay}, 30_000
      assert {:ok, %{role: :primary}} = Role.configured(ctx.mac)
      refute Candidate.present?(ctx.mac)
    end
  end

  describe "a restore from a copy this computer holds" do
    test "stopped before it was put in place, it is dropped and offered again", ctx do
      {:ok, _state} = prepare(ctx.mac, {:local, "north-box"})

      start_candidate!(ctx.mac)

      assert HomeMove.await(fn ->
               unless Candidate.present?(ctx.mac), do: :gone
             end)

      assert {:ok, %{role: :device}} = Role.configured(ctx.mac)
      assert {:ok, _marker} = Moved.read(ctx.mac)
      refute_received {:scheduled, :restart, _delay}
    end

    test "stopped while it was being put in place, it is finished with no commit", ctx do
      {:ok, _state} = prepare(ctx.mac, {:local, "north-box"})
      pair = Recipient.generate()
      stream = Path.join(ctx.tmp, "copy.fxsnap")

      {:ok, _written} =
        Snapshot.write(ctx.server, Recipient.public(pair), stream, host: "linux-aarch64")

      assert {:ok, 6} =
               Activation.stage(ctx.mac, stream, pair, %{}, :return, host: "macos-aarch64")

      {:ok, state} = Candidate.read_state(ctx.mac)
      :ok = Candidate.put_state(ctx.mac, %{state | "phase" => "activating"}, @now)

      start_candidate!(ctx.mac)
      assert_receive {:scheduled, :restart, _delay}, 30_000
      assert {:ok, %{role: :primary}} = Role.configured(ctx.mac)
      assert {:ok, 6} = Epoch.read(ctx.mac)
      refute Candidate.present?(ctx.mac)
    end
  end

  # -- fixtures ---------------------------------------------------------------

  # The computer the home left: retired, marked, linked, with a path of its
  # own deep inside a kept directory and a stale file the server never had.
  defp retired_mac!(mac) do
    File.mkdir_p!(Path.join([mac, "browser", "profiles", "owner"]))
    File.mkdir_p!(Path.join(mac, "journals"))

    File.write!(Path.join(mac, "config.toml"), """
    [fermix_core.engine]
    role = "device"

    [fermix_core]
    secret_store = "file"

    [sandbox]
    # this computer's sandbox
    workspace_root = "#{mac}/workspace"
    """)

    File.write!(Path.join([mac, "browser", "profiles", "owner", "Cookies"]), "signed-in sessions")
    File.write!(Path.join(mac, "chatgpt_host.json"), "stale")
    File.write!(Path.join([mac, "journals", "day.md"]), "a retired day\n")
    :ok = Moved.write(mac, %{epoch: 4, moved_at: @now, to: "north-box"})
    File.mkdir_p!(Path.dirname(DesktopLink.path(mac)))
    File.write!(DesktopLink.path(mac), "{}")
    mac
  end

  defp desktop_key!(mac) do
    keypair = Noise.generate_keypair()
    :ok = DesktopLink.write_key(mac, keypair.private)
    keypair
  end

  # The server, retired into the device role for the move: its own sandbox,
  # a day of its own, and a device list holding this computer's desktop row
  # and another desktop's.
  defp server_home!(server, desktop_key) do
    File.mkdir_p!(Path.join(server, "journals"))

    File.write!(Path.join(server, "config.toml"), """
    [fermix_core.engine]
    role = "device"

    [sandbox]
    # the server's sandbox
    workspace_root = "#{server}/workspace"
    """)

    File.write!(Path.join([server, "journals", "day.md"]), "a day on the server\n")
    :ok = Epoch.write(server, 5)

    row!(
      server,
      "0d3f8a7e-5c21-4b9e-8f60-2a4c6e8b1d37",
      "studio-mac",
      desktop_key.public,
      :desktop
    )

    row!(
      server,
      "7c1d2e3f-4a5b-4c6d-8e7f-90a1b2c3d4e5",
      "office-mac",
      :crypto.strong_rand_bytes(32),
      :desktop
    )

    server
  end

  defp row!(root, id, name, noise_pk, kind) do
    {:ok, _device} =
      DeviceStore.add(
        %{
          device_id: id,
          name: name,
          model: "invented",
          noise_pk: noise_pk,
          created_at: @now,
          kind: kind
        },
        root: root
      )
  end

  # This computer kept its secrets in the keychain before the move.
  defp keyring_mac!(mac) do
    config = Path.join(mac, "config.toml")
    File.write!(config, String.replace(File.read!(config), ~s("file"), ~s("keyring")))
  end

  # The server's settings name a secret in its file store, as the forward
  # move left them.
  defp keychain_server!(server) do
    config = Path.join(server, "config.toml")

    File.write!(
      config,
      File.read!(config) <> "\n[fermix_core.providers.anthropic]\napi_key = \"@file\"\n"
    )

    File.mkdir_p!(Path.join(server, "secrets"))
    File.write!(Path.join([server, "secrets", "ANTHROPIC_API_KEY"]), "sk-ant-invented")
    server
  end

  defp return_candidate!(mac) do
    {:ok, code} = EnrollmentCode.encode(code_facts())
    {:ok, state} = prepare(mac, {:return, code})
    :ok = Candidate.drop_code(mac)

    enrolled =
      Map.merge(state, %{
        "phase" => "enrolled",
        "candidate_id" => "cand-4f2a",
        "enrolled_at" => "2031-06-01T09:00:00Z",
        "listen_until" => "2031-06-02T09:00:00Z"
      })

    :ok = Candidate.put_state(mac, enrolled, @now)
  end

  defp prepare(mac, source),
    do: Candidate.prepare_return(mac, source, now: @now, role: :device, restarts_itself?: true)

  defp stream!(ctx, server \\ nil) do
    {:ok, pair} = Candidate.recipient_pair(ctx.mac)
    stream = Path.join(ctx.tmp, "move-#{System.unique_integer([:positive])}.fxsnap")

    {:ok, _written} =
      Snapshot.write(server || ctx.server, Recipient.public(pair), stream, host: "linux-aarch64")

    stream
  end

  defp offer(stream) do
    %{
      "move_id" => @move_id,
      "attempt" => 1,
      "size_bytes" => File.stat!(stream).size,
      "source_epoch" => 5,
      "recovery_recipient" => nil
    }
  end

  defp start_candidate!(mac, opts \\ []) do
    test = self()
    name = :"candidate_return_#{System.unique_integer([:positive])}"

    start_supervised!(
      {CandidateProcess,
       [
         name: name,
         home: mac,
         clock: fn -> @now end,
         schedule: fn message, delay ->
           send(test, {:scheduled, message, delay})
           make_ref()
         end,
         restart: fn ->
           send(test, :candidate_restart)
           :ok
         end,
         restore_opts: Keyword.get(opts, :restore_opts, host: "macos-aarch64"),
         free_bytes: Keyword.get(opts, :free_bytes, fn _dir -> {:ok, @plenty} end),
         host: @mac,
         awake: held_awake(test)
       ] ++ Keyword.take(opts, [:secret_names])},
      id: name
    )

    name
  end

  # A hold on sleep that tells the test when it was taken and let go, in the
  # protocol `MoveAwake.release/1` speaks.
  defp held_awake(test) do
    fn ->
      send(test, :awake_held)

      holder =
        spawn(fn ->
          receive do
            :release -> send(test, :awake_released)
          end
        end)

      {:ok, holder}
    end
  end

  defp code_facts do
    %{
      secret: :binary.copy(<<0x5A>>, 32),
      gateway_pk: :binary.copy(<<0x3C>>, 32),
      node_id: String.duplicate("4f", 32),
      relays: [%{"url" => "https://eu1.relay.invalid/", "quic_port" => 7842}],
      relays_rev: "0123456789abcdef",
      name: "north-box",
      expires_at: ~U[2031-06-01 09:30:00Z]
    }
  end
end
