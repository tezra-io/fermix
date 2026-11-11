defmodule FermixCore.ComputerHistory.SpoolApplyTest do
  # M97 §8.5: how a machine applies its home's purge and pause intervals. The
  # pause horizon only ever rises, in one write, whoever applies a pause; a
  # machine with no store answers that it applied nothing.
  use ExUnit.Case, async: true

  alias FermixCore.ComputerHistory.Spool
  alias FermixTestSupport.SafeRm

  @now ~U[2031-05-04 09:00:00.000Z]

  setup do
    dir = SafeRm.make_tmp_dir!("ch-spool-apply")
    on_exit(fn -> SafeRm.rm_rf(dir) end)
    path = Path.join([dir, "device", "history.db"])
    spool = start_supervised!({Spool, name: nil, path: path})
    %{dir: dir, path: path, spool: spool}
  end

  defp pause(id, until),
    do: %{id: id, from_ts: ms(@now), to_ts: ms(until), issued_at: ms(@now), kind: "pause"}

  defp ms(at), do: DateTime.to_unix(at, :millisecond)

  defp horizon(spool) do
    {:ok, %{pause_until: until}} = Spool.state(server: spool)
    until
  end

  test "a pause applied after a later one never lowers the horizon", %{spool: spool} do
    later = ~U[2031-05-04 11:00:00.000Z]
    earlier = ~U[2031-05-04 10:00:00.000Z]

    assert :ok = Spool.apply_intervals([pause(2, later)], @now, server: spool)
    assert :ok = Spool.apply_intervals([pause(1, earlier)], @now, server: spool)

    assert horizon(spool) == DateTime.to_iso8601(later)
  end

  # Horizons are times, not strings: a horizon written without a fraction of a
  # second is earlier than one half a second later, though it sorts after it.
  test "a later horizon replaces an earlier one however its seconds are written", %{
    spool: spool
  } do
    assert :ok = Spool.set_pause_until("2031-05-04T10:00:00Z", server: spool)

    assert :ok =
             Spool.apply_intervals([pause(1, ~U[2031-05-04 10:00:00.500Z])], @now, server: spool)

    assert horizon(spool) == "2031-05-04T10:00:00.500Z"
  end

  # Ingest keeps capture paused on a horizon it cannot read, until it is
  # cleared; a pause from chat must not turn that into a finite one.
  test "a horizon that cannot be read is kept", %{spool: spool} do
    assert :ok = Spool.set_pause_until("not-a-time", server: spool)

    assert :ok =
             Spool.apply_intervals([pause(1, ~U[2031-05-04 10:00:00.000Z])], @now, server: spool)

    assert horizon(spool) == "not-a-time"
  end

  test "applied on a connection of its own, the store answers its mark", %{path: path} do
    assert {:ok, 3} = Spool.apply_at(path, [pause(3, ~U[2031-05-04 10:00:00.000Z])], @now)
    assert {:ok, 3} = Spool.apply_at(path, [pause(2, ~U[2031-05-04 10:30:00.000Z])], @now)
  end

  # A machine with no store applied nothing, so its home must not record the
  # intervals as applied there: a store it opens later starts from the first.
  test "a machine with no store answers that it applied nothing, and creates none", %{dir: dir} do
    absent = Path.join([dir, "elsewhere", "device", "history.db"])

    assert {:ok, 0} = Spool.apply_at(absent, [pause(4, ~U[2031-05-04 10:00:00.000Z])], @now)
    refute File.exists?(absent)
  end
end
