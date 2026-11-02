defmodule FermixCore.Home.EngineCeilingTest do
  # Always On's move back, design §6: a server always runs exactly the Fermix
  # of the computers it serves as primary for, so the home can always move
  # back. The primary records each desktop's engine version from its hello;
  # the ceiling is the oldest among the desktops seen in the last 30 days.
  use ExUnit.Case, async: true

  alias FermixCore.Home.DeviceLocal
  alias FermixCore.Home.EngineCeiling
  alias FermixTestSupport.SafeRm

  @studio "6f1e2d3c-4b5a-4968-8778-695a4b3c2d1e"
  @office "0d3f8a7e-5c21-4b9e-8f60-2a4c6e8b1d37"
  @now ~U[2031-06-01 09:00:00Z]

  setup do
    home = SafeRm.make_tmp_dir!("engine_ceiling")
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    %{home: home}
  end

  test "lives in device/, on this machine alone, and stays through a move back", %{home: home} do
    assert EngineCeiling.dir(home) == Path.join([home, "device", "engine_ceiling"])
    assert DeviceLocal.excluded?("device/engine_ceiling/#{@studio}.json")
    assert DeviceLocal.kept_through_return?("device/engine_ceiling")
  end

  test "no desktop seen: no ceiling", %{home: home} do
    assert EngineCeiling.ceiling(home, @now) == {:ok, nil}
  end

  test "each desktop's version is kept on its own, 0600 under a 0700 directory",
       %{home: home} do
    assert :ok = EngineCeiling.record(home, @studio, "0.17.0", @now)
    assert EngineCeiling.ceiling(home, @now) == {:ok, "0.17.0"}

    file = Path.join(EngineCeiling.dir(home), "#{@studio}.json")
    assert mode(file) == 0o600
    assert mode(EngineCeiling.dir(home)) == 0o700
    assert mode(Path.join(home, "device")) == 0o700

    # The desktop updated: its own entry moves, and with it the ceiling.
    assert :ok = EngineCeiling.record(home, @studio, "0.18.0", DateTime.add(@now, 60))
    assert EngineCeiling.ceiling(home, @now) == {:ok, "0.18.0"}
  end

  test "the ceiling is the oldest version among the desktops", %{home: home} do
    :ok = EngineCeiling.record(home, @studio, "0.18.0", @now)
    :ok = EngineCeiling.record(home, @office, "0.17.2", @now)

    assert EngineCeiling.ceiling(home, @now) == {:ok, "0.17.2"}
    # Compared as versions, not as text.
    :ok = EngineCeiling.record(home, @office, "0.9.0", @now)
    assert EngineCeiling.ceiling(home, @now) == {:ok, "0.9.0"}
  end

  test "a desktop unseen for 30 days drops out, and its entry goes at the next record",
       %{home: home} do
    long_ago = DateTime.add(@now, -31 * 86_400)
    :ok = EngineCeiling.record(home, @office, "0.16.0", long_ago)
    :ok = EngineCeiling.record(home, @studio, "0.18.0", DateTime.add(@now, -29 * 86_400))

    assert EngineCeiling.ceiling(home, @now) == {:ok, "0.18.0"}
    assert EngineCeiling.ceiling(home, DateTime.add(@now, 2 * 86_400)) == {:ok, nil}

    :ok = EngineCeiling.record(home, @studio, "0.18.0", @now)
    refute File.exists?(Path.join(EngineCeiling.dir(home), "#{@office}.json"))
  end

  test "a device id or a version that is not one is refused, and nothing is written",
       %{home: home} do
    assert {:error, {:invalid_device_id, "../escape"}} =
             EngineCeiling.record(home, "../escape", "0.17.0", @now)

    assert {:error, {:invalid_version, "latest"}} =
             EngineCeiling.record(home, @studio, "latest", @now)

    assert {:error, {:invalid_version, nil}} = EngineCeiling.record(home, @studio, nil, @now)
    refute File.exists?(EngineCeiling.dir(home))
  end

  test "an entry Fermix did not write is named, never read as a version", %{home: home} do
    :ok = EngineCeiling.record(home, @studio, "0.17.0", @now)
    file = Path.join(EngineCeiling.dir(home), "#{@office}.json")
    File.write!(file, "{")

    assert EngineCeiling.ceiling(home, @now) == {:error, {:invalid_entry, file}}
  end

  defp mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)
end
