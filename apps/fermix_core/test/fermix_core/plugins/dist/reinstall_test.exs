defmodule FermixCore.Plugins.Dist.ReinstallTest do
  # The installer is a seam: these cases hold the record, the order and the
  # bounds, never the pipeline the installer's own suite proves.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias FermixCore.Plugins.Dist.Reinstall
  alias FermixCore.Plugins.Dist.Store
  alias FermixTestSupport.SafeRm

  setup do
    root = SafeRm.make_tmp_dir!("plugin-reinstall")
    on_exit(fn -> SafeRm.rm_rf!(root) end)
    Store.ensure!(root)

    for {name, version, sha} <- [
          {"invented-notes", "1.0.0", "a1"},
          {"invented-tasks", "2.1.0", "b2"},
          {"invented-mac-only", "0.3.0", "c3"},
          {"invented-broken", "4.0.0", "d4"}
        ] do
      :ok = Store.record(root, name, %{"version" => version, "sha256" => sha})
    end

    %{root: root}
  end

  test "a move's staging names the plugins to install again, and writes nothing for none",
       %{root: root} do
    assert :ok = Reinstall.request(root, [])
    refute File.exists?(Reinstall.path(root))

    assert :ok = Reinstall.request(root, ["invented-tasks", "invented-notes"])
    assert Bitwise.band(File.stat!(Reinstall.path(root)).mode, 0o777) == 0o600

    assert %{"pending" => ["invented-notes", "invented-tasks"], "failed" => %{}} =
             Jason.decode!(File.read!(Reinstall.path(root)))
  end

  test "each plugin is installed again at the version the lockfile names, through the installer",
       %{root: root} do
    :ok = Reinstall.request(root, ["invented-notes", "invented-tasks"])
    test = self()

    install = fn name, opts ->
      send(test, {:install, name, opts[:version], opts[:root]})
      {:ok, if(name == "invented-notes", do: :installed, else: :already_installed)}
    end

    assert :ok = Reinstall.run(root: root, install: install)

    assert_received {:install, "invented-notes", "1.0.0", ^root}
    assert_received {:install, "invented-tasks", "2.1.0", ^root}

    assert %{"pending" => [], "failed" => %{}} = Jason.decode!(File.read!(Reinstall.path(root)))
    assert Reinstall.outcome(root, "invented-notes") == nil

    # Nothing is left to do at the next boot.
    refute_received {:install, _name, _version, _root}

    assert :ok =
             Reinstall.run(root: root, install: fn _name, _opts -> flunk("installed twice") end)
  end

  test "one with no build here, or one that keeps failing, is recorded, logged and said",
       %{root: root} do
    :ok = Reinstall.request(root, ["invented-broken", "invented-mac-only", "invented-notes"])
    test = self()

    install = fn
      "invented-mac-only", _opts ->
        {:error, {:no_build_for_target, "linux-x86_64"}}

      "invented-broken", _opts ->
        send(test, :broken_tried)
        {:error, {:verification_failed, :invented}}

      _name, _opts ->
        {:ok, :installed}
    end

    sleep = fn ms -> send(test, {:slept, ms}) end

    log =
      capture_log(fn ->
        assert :ok = Reinstall.run(root: root, install: install, sleep: sleep)
      end)

    # Tried at most three times, with a pause between tries; no build is not
    # tried again.
    for _try <- 1..3, do: assert_received(:broken_tried)
    refute_received :broken_tried
    assert_received {:slept, 10_000}
    assert_received {:slept, 10_000}
    refute_received {:slept, _ms}

    assert Reinstall.outcome(root, "invented-broken") == :failed
    assert Reinstall.outcome(root, "invented-mac-only") == :no_build
    assert Reinstall.outcome(root, "invented-notes") == nil
    assert log =~ "invented-broken 4.0.0 could not be installed again after the move"
    assert log =~ "verification_failed"
    assert log =~ "invented-mac-only 0.3.0 has no build for linux-x86_64"
  end

  test "a try that fails once and then works is not recorded", %{root: root} do
    :ok = Reinstall.request(root, ["invented-notes"])
    {:ok, tries} = Agent.start_link(fn -> 0 end)

    install = fn _name, _opts ->
      case Agent.get_and_update(tries, &{&1, &1 + 1}) do
        0 -> {:error, {:fetch_failed, :closed}}
        _later -> {:ok, :installed}
      end
    end

    capture_log(fn ->
      assert :ok = Reinstall.run(root: root, install: install, sleep: fn _ms -> :ok end)
    end)

    assert Reinstall.outcome(root, "invented-notes") == nil
  end

  test "an install the owner runs afterwards ends what the record says", %{root: root} do
    :ok = Reinstall.request(root, ["invented-broken"])

    capture_log(fn ->
      :ok =
        Reinstall.run(
          root: root,
          install: fn _name, _opts -> {:error, :invented} end,
          sleep: fn _ms -> :ok end
        )
    end)

    assert Reinstall.outcome(root, "invented-broken") == :failed

    :ok = Store.record(root, "invented-broken", %{"version" => "4.0.1", "sha256" => "e5"})
    assert Reinstall.outcome(root, "invented-broken") == nil
  end

  # Each plugin is recorded as not installed before it is tried, so a crash
  # part-way is never silent, and the next boot carries on with the rest.
  test "a crash part-way leaves the plugin it was installing recorded", %{root: root} do
    :ok = Reinstall.request(root, ["invented-notes", "invented-tasks"])

    assert_raise RuntimeError, fn ->
      Reinstall.run(root: root, install: fn _name, _opts -> raise "invented crash" end)
    end

    assert Reinstall.outcome(root, "invented-notes") == :failed

    assert %{"pending" => ["invented-tasks"]} =
             Jason.decode!(File.read!(Reinstall.path(root)))
  end

  test "a record Fermix did not write reads as an error, not as nothing", %{root: root} do
    File.write!(Reinstall.path(root), "not json")
    assert Reinstall.outcome(root, "invented-notes") == :error
    assert Reinstall.outcome(Path.join(root, "absent"), "invented-notes") == nil
  end
end
