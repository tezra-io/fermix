defmodule FermixChannels.Desktop.TwoEnginesNotificationsTest do
  # M99 §10.1: a reminder for "this computer" that comes due on an Always On
  # server rings on the owner's computer, over the real link (`TwoEngines`):
  # the server's reminder rail sends it as `Temporal.Delivery` does, through
  # `ChannelSend` to `Native.Notifications` placed on the computers, and the
  # computer's own engine posts it on its session bus, a replayed busctl
  # here. A Snooze pressed there goes back up the link to the server, which
  # holds the reminder. The server path cannot run on a Mac
  # (`Home.ServerPrimary` refuses macOS), so the placement is named; every
  # other step is the real one. async: false: the relay's dial names are
  # VM-wide.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias FermixChannels.Desktop.ReminderUplink
  alias FermixChannels.Home.Link, as: HomeLink
  alias FermixChannels.Test.TwoEngines
  alias FermixCore.BuildInfo
  alias FermixCore.Computers.Journal
  alias FermixCore.Computers.Registry
  alias FermixCore.Delivery.ChannelSend
  alias FermixCore.Delivery.Error
  alias FermixCore.Memory.Repo
  alias FermixCore.Native.Notifications
  alias FermixCore.Temporal.Registry, as: Reminders

  @busctl "/usr/bin/busctl"
  @text "Tea, today at 16:05."
  @tz "America/New_York"
  @owner_on %{"NameHasOwner" => {:ok, "b true\n"}, "Notify" => {:ok, "u 7\n"}}
  @no_server %{"NameHasOwner" => {:ok, "b false\n"}}

  defmodule Scheduler do
    @moduledoc false
    # The server's reminder scheduler, which tells the test it was woken.
    use GenServer

    def start_link(opts),
      do: GenServer.start_link(__MODULE__, Keyword.fetch!(opts, :test), name: opts[:name])

    @impl true
    def init(test), do: {:ok, test}

    @impl true
    def handle_cast(message, test) do
      send(test, {:scheduler, message})
      {:noreply, test}
    end
  end

  # The computer's own session bus: a busctl that answers as the test's
  # agent says, and tells the test each call it was made.
  defp computer_bus do
    test = self()
    answers = start_supervised!({Agent, fn -> @owner_on end}, id: :computer_bus)

    runner = fn @busctl, args ->
      member = Enum.find(["NameHasOwner", "Notify"], &(&1 in args))
      send(test, {:busctl, member, args})
      answers |> Agent.get(& &1) |> Map.fetch!(member)
    end

    native = [
      placement: :here,
      provider: :dbus,
      runner: runner,
      find_executable: fn "busctl" -> @busctl end
    ]

    {native, answers}
  end

  defp start!(more \\ []) do
    {native, answers} = computer_bus()
    engines = TwoEngines.start!([notifications: native] ++ more)
    Map.put(engines, :bus, answers)
  end

  # The server's own notifications: placed on its computers, the home's list
  # joined from the computer's row and the server's live view of it.
  defp server(e, connected? \\ true) do
    row = %{
      device_id: e.device_id,
      name: "studio Mac",
      platform: "macos",
      last_seen: ~U[2026-11-09 22:40:00Z],
      backups: nil,
      connected: connected?,
      since: if(connected?, do: DateTime.utc_now())
    }

    [
      placement: :computers,
      provider: :dbus,
      computers: [
        role: :primary,
        rows: fn -> {:ok, [row]} end,
        live: Registry.live(e.registry),
        records: %{},
        version: BuildInfo.product_version()
      ],
      call_opts: TwoEngines.call_opts(e)
    ]
  end

  # `Temporal.Delivery.attempt/4`'s shape: one send under the watchdog, the
  # row's title, id and proactive key, its whole result normalized.
  defp rail_send(server_opts, key \\ "temporal:rem_1") do
    send_opts = [title: "Tea", reminder_id: "rem_1", proactive_key: key] ++ server_opts

    60_000
    |> ChannelSend.with_timeout(fn ->
      ChannelSend.send(
        Notifications.platform(),
        Notifications.destination(),
        @text,
        send_opts,
        channels: %{Notifications.platform() => Notifications},
        delivery_max_attempts: 1
      )
    end)
    |> Error.normalize()
  end

  test "a reminder due on the server rings on the computer, once for its key" do
    e = start!()

    assert rail_send(server(e)) == :ok
    assert_received {:busctl, "NameHasOwner", _owner}
    assert_received {:busctl, "Notify", notify}
    assert "Tea" in notify and @text in notify

    # The rail's retry after a lost answer carries the same key: nothing shows twice.
    assert rail_send(server(e)) == :ok
    refute_received {:busctl, _member, _args}

    # The computer journals what its server did there: a reminder, never its text.
    assert {:ok, %{entries: entries}} = Journal.list(Journal.dir(e.root))

    assert [%{capability: "notifications", op: "post", target: "reminder rem_1"} | _rest] =
             Enum.filter(entries, &(&1.capability == "notifications"))

    assert Enum.all?(entries, &(&1.origin == "background"))
  end

  test "the computer's master switch off refuses it, and the rail does not retry" do
    e = start!()
    Agent.update(e.switch_agent, &Keyword.put(&1, :enabled, false))

    assert {:error, error} = rail_send(server(e))
    assert error == {:permanent, :authorization}
    refute Error.retryable?(error)
    refute_received {:busctl, _member, _args}
  end

  test "a computer whose bus has no notification server is retried, and its key let go" do
    e = start!()
    Agent.update(e.bus, fn _answers -> @no_server end)

    assert {:error, error} = rail_send(server(e))
    assert error == {:transport, :connection_refused}
    assert Error.retryable?(error)
    assert_received {:busctl, "NameHasOwner", _owner}

    Agent.update(e.bus, fn _answers -> @owner_on end)
    assert rail_send(server(e)) == :ok
    assert_received {:busctl, "Notify", _notify}
  end

  test "with no computer connected the rail tries again later" do
    e = start!()

    assert {:error, error} = rail_send(server(e, false))
    assert error == {:transport, :connection_refused}
    assert Error.retryable?(error)
    refute_received {:busctl, _member, _args}
  end

  test "readiness is the computer's own, asked with no prompt" do
    e = start!()
    turn = TwoEngines.turn()

    assert Notifications.ready(turn, server(e)) == :ok

    Agent.update(e.bus, fn _answers -> @no_server end)

    assert Notifications.ready(turn, server(e)) ==
             {:error,
              "studio Mac answers that no desktop notification server is running on this machine"}

    # Readiness is no thing Fermix did on the computer: its journal holds none.
    assert {:ok, %{entries: entries}} = Journal.list(Journal.dir(e.root))
    refute Enum.any?(entries, &(&1.capability == "notifications"))
  end

  describe "a Snooze pressed on the computer" do
    setup do
      unique = System.unique_integer([:positive])
      db_path = Path.join(System.tmp_dir!(), "fermix-two-engines-snooze-#{unique}.db")
      repo = :"two_engines_snooze_repo_#{unique}"
      start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})

      on_exit(fn ->
        Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
      end)

      scheduler = :"two_engines_snooze_scheduler_#{unique}"
      start_supervised!({Scheduler, name: scheduler, test: self()})
      %{repo: repo, scheduler: scheduler}
    end

    test "snoozes the server's reminder that rang there", %{repo: repo, scheduler: scheduler} do
      rung = rung_on_the_computer!(repo)

      reminders = [
        now: ~U[2026-08-16 19:05:00Z],
        personalization: [timezone: @tz],
        memory_repo: repo,
        temporal_scheduler: scheduler,
        owner_id: "default"
      ]

      e = start!(reminders: reminders)
      start_supervised!({ReminderUplink, relay: e.relay})

      # The press as the computer's native host hands it to its link.
      assert HomeLink.snooze_reminder(rung.id, 10) == :ok
      assert_receive {:scheduler, :event_changed}, 10_000

      assert {:ok, pending} =
               Repo.list_temporal_reminders(%{event_id: rung.event_id, status: ["pending"]},
                 server: repo
               )

      assert [snoozed] = pending
      assert snoozed.scheduled_for == ~U[2026-08-16 19:15:00.000000Z]
      assert snoozed.delivery_platform == "computer"
    end
  end

  # A reminder delivered to "this computer" on the server, as one that rang.
  defp rung_on_the_computer!(repo) do
    context = %{
      agent_name: "main",
      conversation_key: {"telegram", "555", :root},
      session_id: "sess-1",
      source_trust: :operator,
      computer_use_origin: :interactive,
      memory_agent_id: "main",
      memory_owner_id: "default",
      memory_repo: repo,
      temporal_scheduler: nil
    }

    opts = [
      now: ~U[2026-08-02 12:00:00Z],
      personalization: [timezone: @tz],
      native: [
        placement: :here,
        provider: :dbus,
        runner: fn _busctl, _args -> {:ok, "b true\n"} end,
        find_executable: fn "busctl" -> @busctl end
      ]
    ]

    params = %{
      title: "Tea",
      kind: "explicit_reminder",
      when: %{"type" => "datetime", "date" => "2026-08-16", "time" => "15:00:00"},
      reminders: [%{"type" => "at_time"}],
      delivery: "computer"
    }

    {:ok, %{reminders: [row]}} = Reminders.create_event(params, context, opts)
    {:ok, claimed} = Repo.claim_due_reminders(row.scheduled_for, 10, server: repo)
    hit = Enum.find(claimed, &(&1.id == row.id))

    {:ok, delivered} =
      Repo.temporal_reminder_delivered(hit.id, ~U[2026-08-16 19:00:00Z], server: repo)

    delivered
  end
end
