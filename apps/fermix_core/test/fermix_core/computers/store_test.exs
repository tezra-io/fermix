defmodule FermixCore.Computers.StoreTest do
  # M97 §3.2, §17: what the home last heard from each computer, kept on the
  # primary so an away computer is listed with its last offers.
  use ExUnit.Case, async: true

  alias FermixCore.Computers.Store
  alias FermixCore.Home.DeviceLocal
  alias FermixTestSupport.SafeRm

  @studio "6f1e2d3c-4b5a-4968-8778-695a4b3c2d1e"
  @loft "0d3f8a7e-5c21-4b9e-8f60-2a4c6e8b1d37"
  @at ~U[2031-06-01 09:00:00Z]
  @offers [%{id: "files", state: :on, sentence: nil, detail: nil}]

  setup do
    home = SafeRm.make_tmp_dir!("computer_store")
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    %{home: home}
  end

  test "lives in device/, on this machine alone, and stays through a move back", %{home: home} do
    assert Store.dir(home) == Path.join([home, "device", "computers"])
    assert DeviceLocal.excluded?("device/computers/#{@studio}.json")
  end

  test "a record merges its fields and keeps the rest, 0600 under 0700", %{home: home} do
    assert {:ok, %{}} = Store.read_all(home)
    assert :ok = Store.record(home, @studio, %{engine_version: "0.19.0", seen_at: @at})
    assert :ok = Store.record(home, @studio, %{offers: @offers, offers_rev: "0123456789abcdef"})

    assert {:ok, %{@studio => entry}} = Store.read_all(home)

    assert entry == %{
             engine_version: "0.19.0",
             seen_at: @at,
             offers_rev: "0123456789abcdef",
             offers: @offers
           }

    file = Path.join(Store.dir(home), "#{@studio}.json")
    assert Bitwise.band(File.stat!(file).mode, 0o777) == 0o600
    assert Bitwise.band(File.stat!(Store.dir(home)).mode, 0o777) == 0o700
    refute File.read!(file) =~ "null,\"state\""

    # A refused payload records nothing offered, its revision gone too.
    assert :ok = Store.record(home, @studio, %{offers: [], offers_rev: nil})

    assert {:ok, %{@studio => %{offers: [], offers_rev: nil, engine_version: "0.19.0"}}} =
             Store.read_all(home)
  end

  test "a field or an id that is not one is refused, and nothing is written", %{home: home} do
    assert {:error, {:invalid_device_id, "../escape"}} =
             Store.record(home, "../escape", %{seen_at: @at})

    assert {:error, {:invalid_field, :engine_version, "latest"}} =
             Store.record(home, @studio, %{engine_version: "latest"})

    assert {:error, {:invalid_field, :offers_rev, "XYZ"}} =
             Store.record(home, @studio, %{offers_rev: "XYZ"})

    refute File.exists?(Store.dir(home))
  end

  test "a record Fermix did not write is named, never read", %{home: home} do
    :ok = Store.record(home, @studio, %{seen_at: @at})
    file = Path.join(Store.dir(home), "#{@loft}.json")
    File.write!(file, ~s({"v":1,"offers":[{"id":"files","state":"off"}]}))

    assert Store.read_all(home) == {:error, {:invalid_entry, file}}
  end

  test "at most 64 computers are recorded", %{home: home} do
    for index <- 1..64 do
      id = "00000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(index), 12, "0")
      :ok = Store.record(home, id, %{seen_at: @at})
    end

    assert {:error, {:too_many, 64}} = Store.record(home, @studio, %{seen_at: @at})
    # One already recorded is still written.
    assert :ok = Store.record(home, "00000000-0000-4000-8000-000000000001", %{seen_at: @at})
  end

  test "forget drops one record, and one with none has nothing to drop", %{home: home} do
    :ok = Store.record(home, @studio, %{seen_at: @at})
    assert :ok = Store.forget(home, @studio)
    assert :ok = Store.forget(home, @studio)
    assert {:ok, %{}} = Store.read_all(home)
  end
end
