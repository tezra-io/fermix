defmodule FermixCore.ComputerHistory.SittingsRetentionTest do
  # M97 §8.1: raw events stay on a machine for 48 hours, and the home keeps its
  # purge and pause intervals no longer than that. So a machine never sends an
  # event older than the window, even one the hourly sweep has not reached yet:
  # it goes as the sweep would take it, counted as never sent.
  use ExUnit.Case, async: true

  alias FermixCore.ComputerHistory.Sittings
  alias FermixCore.ComputerHistory.Spool
  alias FermixTestSupport.SafeRm

  @t0 ~U[2031-05-04 09:00:00.000Z]

  setup do
    dir = SafeRm.make_tmp_dir!("ch-sittings-retention")
    on_exit(fn -> SafeRm.rm_rf(dir) end)
    spool = start_supervised!({Spool, name: nil, path: Spool.path(dir)})
    %{dir: dir, spool: spool}
  end

  defp at(minutes), do: DateTime.add(@t0, minutes, :minute)

  defp typed(seq, minutes, text),
    do: %{
      boot_id: "b1",
      source_seq: seq,
      ts: DateTime.to_unix(at(minutes), :millisecond),
      type: "field.value",
      bundle_id: "com.example.notes",
      window_title: "Lease — Notes",
      field_label: "Body",
      text: text
    }

  test "an event older than the window is never sent, and is counted as expired unsent", ctx do
    {:ok, 2} =
      Spool.insert_events([typed(1, 0, "the lease"), typed(2, 1, "the rent")], server: ctx.spool)

    test = self()

    uplink = fn payload ->
      send(test, {:sent, payload})
      {:error, :unreachable}
    end

    assert {:ok, %{sittings: 0}} =
             Sittings.run(
               uplink: uplink,
               spool: ctx.spool,
               home: ctx.dir,
               now: at(49 * 60),
               timezone: "Etc/UTC",
               config: [enabled: true]
             )

    refute_received {:sent, _payload}
    assert {:ok, 0} = Spool.count_events(server: ctx.spool)
    assert {:ok, %{expired_unsent: 2}} = Spool.link(server: ctx.spool)
  end
end
