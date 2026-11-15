defmodule FermixCore.Home.ChangedFromComputerTest do
  # M97 §19.5 (D28): a change to the server's sandbox or coding approval made
  # from one of its computers is recorded on the server, one record for each
  # limit, so its summary and every linked computer's say it once.
  use ExUnit.Case, async: true

  alias FermixCore.Home.ChangedFromComputer
  alias FermixTestSupport.SafeRm

  @at ~U[2031-05-04 11:30:00.250Z]

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
    assert ChangedFromComputer.read(ctx.home, :sandbox_mode) == :absent

    change = %{at: @at, computer: "loft-linux", what: :sandbox_mode, value: "open"}
    assert :ok = ChangedFromComputer.record(ctx.home, change, status_changed: ctx.told)
    assert_received :status_changed

    assert {:ok, ^change} = ChangedFromComputer.read(ctx.home, :sandbox_mode)
    file = ChangedFromComputer.path(ctx.home, :sandbox_mode)
    assert Bitwise.band(File.stat!(file).mode, 0o777) == 0o600
    assert Bitwise.band(File.stat!(Path.dirname(file)).mode, 0o777) == 0o700
    assert Bitwise.band(File.stat!(Path.dirname(Path.dirname(file))).mode, 0o777) == 0o700
  end

  # The review's failure: a later change of another limit took the place of
  # the one before, so what the sandbox was set to was no longer said.
  test "each limit keeps its own newest change, and the newest of all comes first", ctx do
    mode = %{at: @at, computer: "loft-linux", what: :sandbox_mode, value: "open"}
    profile = %{mode | what: :sandbox_profile, value: "extended"}

    approved = %{
      at: DateTime.add(@at, 600),
      computer: "studio-mac",
      what: :harness_approved,
      value: true
    }

    stricter = %{mode | at: DateTime.add(@at, 900), value: "strict"}

    for change <- [mode, profile, approved, stricter],
        do: :ok = ChangedFromComputer.record(ctx.home, change, status_changed: ctx.told)

    assert {:ok, ^stricter} = ChangedFromComputer.read(ctx.home, :sandbox_mode)
    assert {:ok, ^profile} = ChangedFromComputer.read(ctx.home, :sandbox_profile)
    assert {:ok, ^approved} = ChangedFromComputer.read(ctx.home, :harness_approved)
    assert ChangedFromComputer.read(ctx.home, :sandbox_env_allow) == :absent

    # Newest first; one write's changes, sharing a time, in the sandbox's
    # own row order.
    allowed = %{profile | what: :sandbox_env_allow, value: ["LEDGER_TOKEN"]}

    assert ChangedFromComputer.newest_first([allowed, profile, approved, stricter]) ==
             [stricter, approved, profile, allowed]
  end

  test "the record as home.status carries it, read back on a computer" do
    change = %{at: @at, computer: "loft-linux", what: :harness_approved, value: false}

    assert ChangedFromComputer.view(change) == %{
             "at" => "2031-05-04T11:30:00.250Z",
             "computer" => "loft-linux",
             "what" => "harness_approved",
             "value" => false
           }

    for change <- [
          change,
          %{change | what: :sandbox_profile, value: "assistant"},
          %{change | what: :sandbox_env_allow, value: ["LEDGER_TOKEN", "GARDEN_TOKEN"]},
          %{change | what: :sandbox_mode, value: "standard"}
        ],
        do:
          assert(ChangedFromComputer.from_view(ChangedFromComputer.view(change)) == {:ok, change})

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
          %{
            "at" => "2031-05-04T11:30:00Z",
            "computer" => "x",
            "what" => "sandbox_env_allow",
            "value" => [1]
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
          %{at: @at, computer: "loft-linux", what: :sandbox_profile, value: "open"},
          %{at: @at, computer: "loft-linux", what: :sandbox_env_allow, value: "LEDGER_TOKEN"},
          %{at: @at, computer: "loft-linux", what: :harness_approved, value: "yes"},
          %{at: @at, computer: "", what: :sandbox_mode, value: "open"}
        ] do
      assert_raise ArgumentError, ~r/no change from a computer/, fn ->
        ChangedFromComputer.record(ctx.home, bad, status_changed: ctx.told)
      end
    end

    refute_received :status_changed

    for what <- ChangedFromComputer.whats(),
        do: assert(ChangedFromComputer.read(ctx.home, what) == :absent)
  end

  test "a record Fermix did not write is named", ctx do
    file = ChangedFromComputer.path(ctx.home, :sandbox_profile)
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, ~s({"v": 9}))

    assert {:error, {:invalid_record, ^file}} =
             ChangedFromComputer.read(ctx.home, :sandbox_profile)

    # A record under another limit's name is not that limit's.
    other = %{at: @at, computer: "loft-linux", what: :sandbox_mode, value: "open"}
    :ok = ChangedFromComputer.record(ctx.home, other, status_changed: ctx.told)
    File.cp!(ChangedFromComputer.path(ctx.home, :sandbox_mode), file)

    assert {:error, {:invalid_record, ^file}} =
             ChangedFromComputer.read(ctx.home, :sandbox_profile)
  end
end
