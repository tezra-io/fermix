defmodule FermixCore.Home.ChangedFromComputerTest do
  # M97 §19.5 (D28): a change to the server's sandbox or coding approval made
  # from one of its computers is recorded on the server, newest only, so its
  # summary and every linked computer's say it once.
  use ExUnit.Case, async: true

  alias FermixCore.Home.ChangedFromComputer
  alias FermixTestSupport.SafeRm

  @at ~U[2031-05-04 11:30:00Z]

  setup do
    home = SafeRm.make_tmp_dir!("changed_from_computer")
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    test = self()

    told = fn ->
      send(test, :status_changed)
      :ok
    end

    %{home: home, told: told}
  end

  test "a change is kept on the server, 0600, and the watch is told", ctx do
    assert ChangedFromComputer.read(ctx.home) == :absent

    change = %{at: @at, computer: "loft-linux", what: :sandbox_mode, value: "open"}
    assert :ok = ChangedFromComputer.record(ctx.home, change, status_changed: ctx.told)
    assert_received :status_changed

    assert {:ok, ^change} = ChangedFromComputer.read(ctx.home)
    assert Bitwise.band(File.stat!(ChangedFromComputer.path(ctx.home)).mode, 0o777) == 0o600

    assert Bitwise.band(File.stat!(Path.dirname(ChangedFromComputer.path(ctx.home))).mode, 0o777) ==
             0o700
  end

  test "the newest change replaces the one before", ctx do
    first = %{at: @at, computer: "loft-linux", what: :sandbox_mode, value: "open"}

    later = %{
      at: DateTime.add(@at, 600),
      computer: "studio-mac",
      what: :harness_approved,
      value: true
    }

    :ok = ChangedFromComputer.record(ctx.home, first, status_changed: ctx.told)
    :ok = ChangedFromComputer.record(ctx.home, later, status_changed: ctx.told)

    assert {:ok, ^later} = ChangedFromComputer.read(ctx.home)
  end

  test "the record as home.status carries it, read back on a computer" do
    change = %{at: @at, computer: "loft-linux", what: :harness_approved, value: false}

    assert ChangedFromComputer.view(change) == %{
             "at" => "2031-05-04T11:30:00Z",
             "computer" => "loft-linux",
             "what" => "harness_approved",
             "value" => false
           }

    assert ChangedFromComputer.from_view(ChangedFromComputer.view(change)) == {:ok, change}
    assert ChangedFromComputer.view(nil) == nil

    # A change a newer server names, or a value this engine does not know, is
    # not drawn.
    for unknown <- [
          %{"at" => "2031-05-04T11:30:00Z", "computer" => "x", "what" => "browser", "value" => 1},
          %{
            "at" => "2031-05-04T11:30:00Z",
            "computer" => "x",
            "what" => "sandbox_mode",
            "value" => "wide"
          },
          %{"at" => "later", "computer" => "x", "what" => "sandbox_mode", "value" => "open"},
          nil
        ],
        do: assert(ChangedFromComputer.from_view(unknown) == :error)
  end

  test "a change of anything else is refused by name", ctx do
    for bad <- [
          %{at: @at, computer: "loft-linux", what: :browser, value: "open"},
          %{at: @at, computer: "loft-linux", what: :sandbox_mode, value: "wide"},
          %{at: @at, computer: "loft-linux", what: :harness_approved, value: "yes"},
          %{at: @at, computer: "", what: :sandbox_mode, value: "open"}
        ] do
      assert_raise ArgumentError, ~r/no change from a computer/, fn ->
        ChangedFromComputer.record(ctx.home, bad, status_changed: ctx.told)
      end
    end

    refute_received :status_changed
    assert ChangedFromComputer.read(ctx.home) == :absent
  end

  test "a record Fermix did not write is named", ctx do
    File.mkdir_p!(Path.dirname(ChangedFromComputer.path(ctx.home)))
    File.write!(ChangedFromComputer.path(ctx.home), ~s({"v": 9}))

    assert {:error, {:invalid_record, _file}} = ChangedFromComputer.read(ctx.home)
  end
end
