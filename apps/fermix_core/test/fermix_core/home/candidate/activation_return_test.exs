defmodule FermixCore.Home.Candidate.ActivationReturnTest do
  # A return's activation (Always On's move back): the server's staged copy
  # replaces the retired one in place, and this computer's own paths stay, at
  # any depth. The homes are built by hand; the staging is what a return's
  # staging leaves (`return_settle_test.exs` covers that).
  use ExUnit.Case, async: true

  alias FermixCore.Home.Candidate
  alias FermixCore.Home.Candidate.Activation
  alias FermixCore.Home.Moved
  alias FermixCore.Home.Snapshot.Status
  alias FermixTestSupport.SafeRm

  @now ~U[2031-06-01 09:20:00Z]

  # This computer's retired copy: its own paths, the ended tenure's
  # bookkeeping, and the stale copy of what travels.
  @retired %{
    "config.toml" => ~s([fermix_core.engine]\nrole = "device"\n),
    "memory.db" => "retired database",
    "memory.db-wal" => "retired wal",
    "memory.db-shm" => "retired shm",
    "auth.json" => "retired tokens",
    "chatgpt_host.json" => "stale, the server has none",
    "daemon.sock" => "",
    "config.toml.lock" => "",
    ".move/phase.json" => ~s({"phase":"done"}),
    "logs/fermix.log" => "this computer's log",
    "device/desktop.json" => "the link to the server",
    "device/desktop_key" => "the desktop key",
    "device/provision/srv-7f3a.json" => "the ledger with its token",
    "device/return.json" => "the return's record",
    "snapshots/2031-05-30T02:00:00Z-e6.fxsnap" => "a copy of the server's",
    "harness/runs/run-1/events.jsonl" => "a coding run's spool",
    "harness/stale.json" => "not this computer's",
    "job_runs/job_runs/run-9/output.md" => "the server deleted it",
    "browser/profiles/owner/default/Cookies" => "signed-in sessions",
    "browser/artifacts/owner/old.png" => "retired artifact",
    "plugins/compux/1.2.0/macos/Fermix.app/Contents/Info.plist" => "the helper app",
    "plugins/reinstall.json" => ~s({"pending":["stale"]}),
    "plugins/installed/notes/1.0.0/run" => "the Mac build",
    "imessage/cursor" => "rowid 4411",
    "models/stt/base.bin" => "speech weights",
    "mobile/candidates.json" => ~s({"candidates":["the server, a day ago"]}),
    "mobile/devices.toml" => "retired device list",
    "mobile/bridge.sock" => "",
    "mobile/dial-4f2a.sock" => "",
    "journals/2031-04-30.md" => "a retired day",
    "workspace/.cache/npm/index" => "package cache",
    "workspace/notes.md" => "retired notes",
    ".candidate-3F2A" => "a stray builder"
  }

  # The server's copy as the return staged it.
  @staged %{
    "config.toml" => ~s([fermix_core.engine]\nrole = "primary"\n),
    "memory.db" => "the server's database",
    "auth.json" => "the server's tokens",
    "mobile/devices.toml" => "the server's device list",
    "mobile/primary_epoch" => "7",
    "journals/2031-05-31.md" => "a day on the server",
    "plugins/installed/notes/1.0.0/run" => "the Linux build",
    "plugins/reinstall.json" => ~s({"pending":["notes"]}),
    "browser/artifacts/owner/new.png" => "the server's artifact",
    "workspace/notes.md" => "the server's notes"
  }

  # The stop case builds a home per stop, so it runs on a small copy that still
  # holds every kind of step: a path set aside in place, a kept path moved into
  # a staged entry, an entry with its database files, the ended tenure and the
  # marker.
  @small_retired Map.take(@retired, [
                   "config.toml",
                   "memory.db",
                   "memory.db-wal",
                   "chatgpt_host.json",
                   "device/desktop.json",
                   "device/desktop_key",
                   "device/return.json",
                   "harness/runs/run-1/events.jsonl",
                   "plugins/compux/1.2.0/macos/Fermix.app/Contents/Info.plist",
                   "plugins/reinstall.json"
                 ])

  @small_staged Map.take(@staged, ["config.toml", "memory.db", "plugins/reinstall.json"])

  setup do
    tmp = SafeRm.make_tmp_dir!("activation_return")
    on_exit(fn -> SafeRm.rm_rf!(tmp) end)
    %{tmp: tmp}
  end

  test "keeps this computer's own paths at depth and nothing else of the retired copy", ctx do
    home = activating_home!(ctx.tmp, "home")

    assert :ok = Activation.activate(home, :return)

    expected =
      Map.merge(
        Map.take(@retired, [
          "config.toml.lock",
          "logs/fermix.log",
          "device/provision/srv-7f3a.json",
          "device/return.json",
          "snapshots/2031-05-30T02:00:00Z-e6.fxsnap",
          "harness/runs/run-1/events.jsonl",
          "browser/profiles/owner/default/Cookies",
          "plugins/compux/1.2.0/macos/Fermix.app/Contents/Info.plist",
          "imessage/cursor",
          "models/stt/base.bin",
          "workspace/.cache/npm/index"
        ]),
        @staged
      )
      |> Map.put(Path.relative_to(Status.path(home), home), File.read!(Status.path(home)))

    assert files(home) == expected
    assert {:ok, %{run_at_boot: true}} = Status.read(home)
    assert Moved.read(home) == :absent
    refute Candidate.present?(home)
    # A top-level the staging lacks keeps its kept path and goes with the rest.
    assert File.dir?(Path.join(home, "harness"))
    refute File.exists?(Path.join(home, "job_runs"))
  end

  test "the config is primary only once the marker is gone, at every step", ctx do
    home = activating_home!(ctx.tmp, "home")
    test = self()

    after_step = fn step ->
      send(test, {:step, step, primary?(home), Moved.read(home) != :absent})
      :ok
    end

    assert :ok = Activation.activate(home, :return, after_step: after_step)

    steps = collect_steps()
    assert Enum.map(Enum.take(steps, -4), &elem(&1, 0)) == [:c, :d, :e, :f]

    for {step, primary?, marked?} <- steps do
      refute primary? and marked?, "#{inspect(step)}: the config is primary beside the marker"
    end

    assert {:e, false, false} in steps
    assert {:f, true, false} in steps
  end

  test "a stop after any step is finished by the next run from the recorded entries", ctx do
    small = {@small_retired, @small_staged}
    reference = activating_home!(ctx.tmp, "reference", small)
    test = self()
    :ok = Activation.activate(reference, :return, after_step: &send(test, {:step, &1, nil, nil}))
    expected = files(reference)
    steps = Enum.map(collect_steps(), &elem(&1, 0))
    stops = first_of_each_kind(steps)

    assert stops |> Enum.map(&kind/1) |> Enum.sort() ==
             Enum.sort([:a, :kept, :aside, :placed, :c, :d, :e, :f])

    for {step, index} <- Enum.with_index(stops) do
      home = activating_home!(ctx.tmp, "stop-#{index}", small)

      assert catch_throw(Activation.activate(home, :return, after_step: stop_at(step))) ==
               {:stopped, step}

      refute primary?(home) and Moved.read(home) != :absent, inspect(step)
      assert :ok = next_boot(home, step), inspect(step)
      assert files(home) == expected, "after a stop at #{inspect(step)}"
    end
  end

  # A kept path is named at most two names deep, so a deeper tree that is not
  # kept is set aside whole, however deep it goes, and never walked.
  test "a deep tree the return does not keep goes whole, beside a kept path", ctx do
    home = staged_home!(ctx.tmp, "home")
    deep = Enum.map_join(1..40, "/", &"n#{&1}")
    write!(home, "workspace/project/node_modules/" <> deep <> "/index.js", "retired")
    write!(home, "job_runs/old/" <> deep <> "/out.md", "the server deleted it")
    {:ok, state} = Candidate.read_state(home)
    :ok = Candidate.put_state(home, Map.put(state, "phase", "activating"), @now)
    {:ok, _entries} = Activation.record_entries(home)
    test = self()

    assert :ok =
             Activation.activate(home, :return, after_step: &send(test, {:step, &1, nil, nil}))

    steps = Enum.map(collect_steps(), &elem(&1, 0))
    assert {:a, "job_runs/old"} in steps
    refute Enum.any?(steps, &match?({:a, "job_runs/old/" <> _deeper}, &1))
    refute File.exists?(Path.join(home, "job_runs"))
    refute File.exists?(Path.join(home, "workspace/project"))
    assert File.read!(Path.join(home, "workspace/.cache/npm/index")) == "package cache"
  end

  test "a copy a boot made again between two runs gives way to the one already moved", ctx do
    home = activating_home!(ctx.tmp, "home")
    compux = "plugins/compux/1.2.0/macos/Fermix.app/Contents/Info.plist"
    stop = {:b, "plugins", {:kept, "plugins/compux"}}

    assert catch_throw(Activation.activate(home, :return, after_step: stop_at(stop))) ==
             {:stopped, stop}

    # The device boot after the stop fetched the helper again, part-way.
    write!(home, compux, "a fresh download")

    assert :ok = Activation.activate(home, :return)
    assert File.read!(Path.join(home, compux)) == "the helper app"
  end

  describe "record_entries/1" do
    test "records the staged entries once, before any rename", ctx do
      home = staged_home!(ctx.tmp, "home")

      assert {:ok, entries} = Activation.record_entries(home)
      assert entries == ~w(auth.json browser journals memory.db mobile plugins workspace)
      assert mode(Candidate.path(home, "entries.json")) == 0o600

      # Part of it is in place when the engine stops; the record stands.
      File.rename!(Path.join(Candidate.staging_path(home), "journals"), Path.join(home, "j"))
      assert {:ok, ^entries} = Activation.record_entries(home)
    end

    test "refuses a candidate that is no return, and one with nothing staged", ctx do
      home = staged_home!(ctx.tmp, "home")
      {:ok, state} = Candidate.read_state(home)
      :ok = Candidate.put_state(home, Map.delete(state, "kind"), @now)

      assert {:error, :not_a_return} = Activation.record_entries(home)

      :ok = Candidate.put_state(home, state, @now)
      SafeRm.rm!(Path.join(Candidate.staging_path(home), "config.toml"))
      assert {:error, :nothing_staged} = Activation.record_entries(home)
    end
  end

  test "activation refuses entries it did not record, and a move that did not commit", ctx do
    home = staged_home!(ctx.tmp, "home")
    {:ok, state} = Candidate.read_state(home)
    :ok = Candidate.put_state(home, Map.put(state, "phase", "activating"), @now)

    assert {:error, :entries_unrecorded} = Activation.activate(home, :return)

    {:ok, _entries} = Activation.record_entries(home)
    :ok = Candidate.put_state(home, Map.put(state, "phase", "staged"), @now)
    assert {:error, {:not_activating, "staged"}} = Activation.activate(home, :return)

    assert File.read!(Path.join(home, "config.toml")) =~ ~s(role = "device")
    assert {:ok, _marker} = Moved.read(home)
  end

  # -- homes ------------------------------------------------------------------

  defp staged_home!(tmp, name, {retired, staged} \\ {@retired, @staged}) do
    home = Path.join(tmp, name)
    for {path, contents} <- retired, do: write!(home, path, contents)

    :ok =
      Moved.write(home, %{epoch: 5, moved_at: ~U[2031-05-01 10:00:00Z], to: "hetzner-orchard"})

    {:ok, _state} =
      Candidate.prepare_return(home, {:local, "hetzner-orchard"},
        role: :device,
        restarts_itself?: true,
        now: @now
      )

    staging = Candidate.staging_path(home)
    for {path, contents} <- staged, do: write!(staging, path, contents)
    home
  end

  # The move committed: its candidate is activating, the entries recorded.
  defp activating_home!(tmp, name, fixture \\ {@retired, @staged}) do
    home = staged_home!(tmp, name, fixture)
    {:ok, state} = Candidate.read_state(home)
    :ok = Candidate.put_state(home, Map.put(state, "phase", "activating"), @now)
    {:ok, _entries} = Activation.record_entries(home)
    home
  end

  # After f the next boot is the primary's, which finishes the activation;
  # before it, the device's, whose candidate runs it again.
  defp next_boot(home, :f), do: Candidate.finish_activation(home)
  defp next_boot(home, _step), do: Activation.activate(home, :return)

  # Every kind of step a stop can follow, once: a home per stop, so the case
  # stays cheap on a loaded runner.
  defp first_of_each_kind(steps), do: Enum.uniq_by(steps, &kind/1)

  defp kind({:a, _path}), do: :a
  defp kind({:b, _entry, {:kept, _unit}}), do: :kept
  defp kind({:b, _entry, step}), do: step
  defp kind(step) when is_atom(step), do: step

  defp stop_at(stop) do
    fn
      ^stop -> throw({:stopped, stop})
      _step -> :ok
    end
  end

  defp collect_steps(acc \\ []) do
    receive do
      {:step, step, primary?, marked?} -> collect_steps([{step, primary?, marked?} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp primary?(home), do: File.read!(Path.join(home, "config.toml")) =~ ~s(role = "primary")

  # Raw writes skip the VM's one file server, which the whole suite queues on.
  defp write!(root, path, contents) do
    file = Path.join(root, path)
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, contents, [:raw])
  end

  defp mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)

  defp files(home) do
    home
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Map.new(&{Path.relative_to(&1, home), File.read!(&1)})
  end
end
