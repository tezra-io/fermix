defmodule FermixCore.Home.EngineCeilingTest do
  # Always On's move back, design §6: a server always runs exactly the Fermix
  # of the computers it serves as primary for, so the home can always move
  # back. The primary records each computer's engine version from its hello
  # (M97: the computers' own records, `Computers.Store`); the ceiling is the
  # oldest among the computers seen in the last 30 days.
  use ExUnit.Case, async: true

  alias FermixCore.Computers.Store
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

  test "reads the computers' records, on this machine alone, kept through a move back",
       %{home: home} do
    assert EngineCeiling.dir(home) == Path.join([home, "device", "computers"])
    assert DeviceLocal.excluded?("device/computers/#{@studio}.json")
    assert DeviceLocal.kept_through_return?("device/computers")
  end

  test "no computer seen: no ceiling", %{home: home} do
    assert EngineCeiling.ceiling(home, @now) == {:ok, nil}
  end

  test "a computer that updated moves the ceiling with it", %{home: home} do
    :ok = seen(home, @studio, "0.17.0", @now)
    assert EngineCeiling.ceiling(home, @now) == {:ok, "0.17.0"}

    :ok = seen(home, @studio, "0.18.0", DateTime.add(@now, 60))
    assert EngineCeiling.ceiling(home, @now) == {:ok, "0.18.0"}
  end

  test "the ceiling is the oldest version among the computers", %{home: home} do
    :ok = seen(home, @studio, "0.18.0", @now)
    :ok = seen(home, @office, "0.17.2", @now)

    assert EngineCeiling.ceiling(home, @now) == {:ok, "0.17.2"}
    # Compared as versions, not as text.
    :ok = seen(home, @office, "0.9.0", @now)
    assert EngineCeiling.ceiling(home, @now) == {:ok, "0.9.0"}
  end

  test "a computer unseen for 30 days drops out", %{home: home} do
    :ok = seen(home, @office, "0.16.0", DateTime.add(@now, -31 * 86_400))
    :ok = seen(home, @studio, "0.18.0", DateTime.add(@now, -29 * 86_400))

    assert EngineCeiling.ceiling(home, @now) == {:ok, "0.18.0"}
    assert EngineCeiling.ceiling(home, DateTime.add(@now, 2 * 86_400)) == {:ok, nil}
  end

  test "a computer whose version was never heard holds nothing back", %{home: home} do
    :ok = Store.record(home, @studio, %{seen_at: @now})
    assert EngineCeiling.ceiling(home, @now) == {:ok, nil}
  end

  test "a record Fermix did not write is named, never read as a version", %{home: home} do
    :ok = seen(home, @studio, "0.17.0", @now)
    file = Path.join(EngineCeiling.dir(home), "#{@office}.json")
    File.write!(file, "{")

    assert EngineCeiling.ceiling(home, @now) == {:error, {:invalid_entry, file}}
  end

  defp seen(home, id, version, at),
    do: Store.record(home, id, %{engine_version: version, seen_at: at})
end
