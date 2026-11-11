defmodule FermixCore.ComputerHistory.SittingsOwnActivityTest do
  # M97 §8.7, D11: while Fermix on the server drives this computer's screen, the
  # events the recorder sees are Fermix's own; the sitting marks them, so the
  # summary never reports the agent's clicks as the owner's.
  use ExUnit.Case, async: true

  alias FermixCore.ComputerHistory.Sittings
  alias FermixCore.ComputerHistory.Spool
  alias FermixCore.ComputerUse.ServerControl
  alias FermixTestSupport.SafeRm

  @t0 ~U[2026-11-11 09:00:00.000Z]

  setup do
    home = SafeRm.make_tmp_dir!("sittings_own_activity")
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    spool = start_supervised!({Spool, path: Spool.path(home), name: nil})
    %{home: home, spool: spool}
  end

  defp at(minutes), do: DateTime.add(@t0, minutes, :minute)

  defp field(seq, minutes, text) do
    %{
      boot_id: "b",
      source_seq: seq,
      ts: DateTime.to_unix(at(minutes), :millisecond),
      type: "field.value",
      bundle_id: "com.example.notes",
      field_label: "Body",
      text: text
    }
  end

  defp send_sittings(ctx) do
    test_pid = self()

    uplink = fn payload ->
      send(test_pid, {:sent, payload})
      {:ok, %{status: :summarized, reason: nil, intervals: []}}
    end

    Sittings.run(
      uplink: uplink,
      spool: ctx.spool,
      home: ctx.home,
      now: at(60),
      timezone: "Etc/UTC",
      config: [enabled: true]
    )
  end

  test "an event stamped while the server held the screen is marked as Fermix's own", ctx do
    :ok = ServerControl.started(ctx.home, "cua_x1", at(2))
    :ok = ServerControl.ended(ctx.home, "cua_x1", at(4), :closed)

    events = [
      field(1, 1, "owner wrote the grocery list"),
      field(2, 3, "the agent filled the form"),
      field(3, 5, "owner wrote again")
    ]

    {:ok, 3} = Spool.insert_events(events, server: ctx.spool)

    assert {:ok, %{sent: 1}} = send_sittings(ctx)
    assert_received {:sent, %{"text" => text}}

    [owner, agent, again] =
      text |> String.split("\n") |> Enum.filter(&(&1 =~ "field.value"))

    refute owner =~ "by=fermix"
    assert agent =~ "by=fermix"
    refute again =~ "by=fermix"
  end

  test "a stretch still open runs to now", ctx do
    :ok = ServerControl.started(ctx.home, "cua_x2", at(2))
    {:ok, 1} = Spool.insert_events([field(1, 3, "the agent typed")], server: ctx.spool)

    assert {:ok, %{sent: 1}} = send_sittings(ctx)
    assert_received {:sent, %{"text" => text}}
    assert text =~ "by=fermix"
  end
end
