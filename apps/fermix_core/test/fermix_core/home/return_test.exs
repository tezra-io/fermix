defmodule FermixCore.Home.ReturnTest do
  use ExUnit.Case, async: true

  alias FermixCore.Home.DeviceLocal
  alias FermixCore.Home.Epoch
  alias FermixCore.Home.Return
  alias FermixTestSupport.SafeRm

  @started ~U[2031-06-01 09:00:00Z]
  @moving ~U[2031-06-01 09:05:00Z]
  @back ~U[2031-06-01 09:20:00Z]

  setup do
    home = SafeRm.make_tmp_dir!("home_return")
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    %{home: home}
  end

  test "lives in device/, which stays on this machine and through the return", %{home: home} do
    assert Return.path(home) == Path.join([home, "device", "return.json"])
    assert DeviceLocal.excluded?("device/return.json")
    assert DeviceLocal.kept_through_return?("device/return.json")
  end

  test "a computer that never moved back is absent", %{home: home} do
    assert Return.read(home) == :absent
  end

  test "write then read round-trips the record, 0600 under a 0700 device/", %{home: home} do
    record = %{
      from: "hetzner-cx22-orchard",
      provider_server: "srv-7f3a",
      primary_epoch: 5,
      started_at: @started
    }

    assert :ok = Return.write(home, record)
    assert Return.read(home) == {:ok, record}
    assert mode(Return.path(home)) == 0o600
    assert mode(Path.dirname(Return.path(home))) == 0o700

    moving = Map.merge(record, %{move_started_at: @moving, candidate_id: "c-91", move_id: "m-12"})
    assert :ok = Return.write(home, moving)
    assert Return.read(home) == {:ok, moving}
  end

  test "an own server has no ledger row, so the record names none", %{home: home} do
    record = %{from: "home-nas", primary_epoch: 3, started_at: @started}

    :ok = Return.write(home, record)
    assert {:ok, read} = Return.read(home)
    refute Map.has_key?(read, :provider_server)
  end

  test "a record that is not the documented shape is refused by name, written or read",
       %{home: home} do
    file = Return.path(home)

    for bad <- [
          %{from: "", started_at: @started},
          %{from: "line\nbreak", started_at: @started},
          %{from: "x", started_at: "yesterday"},
          %{from: "x", started_at: @started, primary_epoch: 0},
          %{from: "x", started_at: @started, unknown: true}
        ] do
      assert {:error, {:invalid_record, ^file, _detail}} = Return.write(home, bad), inspect(bad)
    end

    refute File.exists?(file)
    File.mkdir_p!(Path.dirname(file))

    for contents <- [
          "",
          "[]",
          ~s({"v":2,"from":"x","started_at":"2031-06-01T09:00:00Z"}),
          ~s({"v":1,"from":"x","started_at":"yesterday"}),
          ~s({"v":1,"started_at":"2031-06-01T09:00:00Z"})
        ] do
      File.write!(file, contents)
      assert {:error, {:invalid_record, ^file, _detail}} = Return.read(home), inspect(contents)
    end
  end

  describe "done/2, at the primary's boot" do
    test "records when this computer became the primary again, at the epoch it holds",
         %{home: home} do
      :ok = Return.write(home, moving_record())
      :ok = Epoch.write(home, 7)

      assert :ok = Return.done(home, @back)
      assert {:ok, %{moved_at: @back, epoch: 7} = record} = Return.read(home)
      assert record.move_id == "m-12"

      # A later boot keeps the first answer.
      assert :ok = Return.done(home, ~U[2031-06-02 08:00:00Z])
      assert {:ok, %{moved_at: @back, epoch: 7}} = Return.read(home)
    end

    test "has nothing to say on a computer that never moved back", %{home: home} do
      :ok = Epoch.write(home, 7)

      assert :ok = Return.done(home, @back)
      assert Return.read(home) == :absent
    end

    test "a return with no move from the server (a copy restored here) is finished too", %{
      home: home
    } do
      :ok = Return.write(home, %{from: "hetzner-cx22-orchard", started_at: @started})
      :ok = Epoch.write(home, 7)

      assert :ok = Return.done(home, @back)
      assert {:ok, %{moved_at: @back, epoch: 7}} = Return.read(home)
    end

    test "a home with no epoch to record is refused by name", %{home: home} do
      :ok = Return.write(home, moving_record())

      assert {:error, :no_epoch} = Return.done(home, @back)
      assert {:ok, record} = Return.read(home)
      refute Map.has_key?(record, :moved_at)
    end

    test "an unreadable record is named, not overwritten", %{home: home} do
      File.mkdir_p!(Path.dirname(Return.path(home)))
      File.write!(Return.path(home), "{")
      :ok = Epoch.write(home, 7)

      assert {:error, {:invalid_record, _file, _detail}} = Return.done(home, @back)
      assert File.read!(Return.path(home)) == "{"
    end
  end

  test "remove takes the record away; an absent one is already removed", %{home: home} do
    :ok = Return.write(home, moving_record())

    assert :ok = Return.remove(home)
    assert Return.read(home) == :absent
    assert :ok = Return.remove(home)
  end

  defp moving_record do
    %{
      from: "hetzner-cx22-orchard",
      provider_server: "srv-7f3a",
      primary_epoch: 5,
      started_at: @started,
      move_started_at: @moving,
      candidate_id: "c-91",
      move_id: "m-12"
    }
  end

  defp mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)
end
