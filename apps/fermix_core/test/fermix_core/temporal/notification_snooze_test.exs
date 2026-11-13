defmodule FermixCore.Temporal.NotificationSnoozeTest do
  # M99 §10.1: a Snooze pressed on a computer reaches the server that holds
  # the reminder as the home service `reminders.snooze`, which is the one
  # snooze a press makes (`Registry.snooze_from_notification/3`). Every seam
  # (the Repo, the scheduler, the owner, the clock) is the test's own.
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias FermixCore.Memory.Repo
  alias FermixCore.Temporal.NotificationSnooze
  alias FermixCore.Temporal.Registry

  @tz "America/New_York"
  @busctl "/usr/bin/busctl"

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-notification-snooze-#{unique}.db")
    repo = :"notification_snooze_repo_#{unique}"
    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    %{repo: repo}
  end

  defp context(repo) do
    %{
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
  end

  # A reminder for "this computer", delivered: one that rang.
  defp rung!(repo, delivery \\ "computer") do
    opts = [
      now: ~U[2026-08-02 12:00:00Z],
      personalization: [timezone: @tz],
      jobs_config: [
        default_delivery_mode: "channel",
        default_delivery_target: [platform: "telegram", chat_id: "8217352118"],
        delivery_channels: %{"telegram" => __MODULE__.Chat}
      ],
      native: [
        placement: :here,
        provider: :dbus,
        runner: fn @busctl, _args -> {:ok, "b true\n"} end,
        find_executable: fn "busctl" -> @busctl end
      ]
    ]

    params = %{
      title: "Tea",
      kind: "explicit_reminder",
      when: %{"type" => "datetime", "date" => "2026-08-16", "time" => "15:00:00"},
      reminders: [%{"type" => "at_time"}],
      delivery: delivery
    }

    {:ok, %{reminders: [row]}} = Registry.create_event(params, context(repo), opts)
    {:ok, claimed} = Repo.claim_due_reminders(row.scheduled_for, 10, server: repo)
    hit = Enum.find(claimed, &(&1.id == row.id))

    {:ok, delivered} =
      Repo.temporal_reminder_delivered(hit.id, ~U[2026-08-16 19:00:00Z], server: repo)

    delivered
  end

  defmodule Chat do
    @moduledoc false
    def send_message(_destination, _text, _opts), do: :ok
  end

  defp service_context(repo, more \\ []) do
    reminders =
      Keyword.merge(
        [
          now: ~U[2026-08-16 19:05:00Z],
          personalization: [timezone: @tz],
          memory_repo: repo,
          temporal_scheduler: nil,
          owner_id: "default"
        ],
        more
      )

    %{
      id: "snz-0a",
      computer: "dev-studio-mac",
      origin: :computer,
      epoch: 3,
      turn: nil,
      home: "/nonexistent/server-home",
      switches: [],
      clock: &DateTime.utc_now/0,
      deadline_ms: 15_000,
      reminders: reminders
    }
  end

  test "what it is: one effect of the home, gated by nothing but the link" do
    assert NotificationSnooze.id() == :reminders
    assert NotificationSnooze.offer() == nil
    assert NotificationSnooze.ops() == ["snooze"]
    assert NotificationSnooze.effect?("snooze")
    refute NotificationSnooze.long_lived?("snooze")
    assert NotificationSnooze.bounds("snooze") == %{result_bytes: 1_024, part_bytes: 0}
    assert NotificationSnooze.target("snooze", %{"reminder_id" => "rem_1"}) == "reminder rem_1"
  end

  test "it takes a reminder's id and the minutes, and nothing else" do
    assert NotificationSnooze.validate("snooze", %{"reminder_id" => "rem_1", "minutes" => 10}) ==
             :ok

    for args <- [
          %{},
          %{"reminder_id" => "rem_1"},
          %{"reminder_id" => "rem_1", "minutes" => 10, "extra" => true},
          %{"reminder_id" => "", "minutes" => 10},
          %{"reminder_id" => String.duplicate("r", 65), "minutes" => 10},
          %{"reminder_id" => "rem_1", "minutes" => 0},
          %{"reminder_id" => "rem_1", "minutes" => 1_441},
          %{"reminder_id" => "rem_1", "minutes" => "10"}
        ] do
      assert {:error, sentence} = NotificationSnooze.validate("snooze", args), inspect(args)
      assert sentence =~ "reminder_id"
    end

    assert NotificationSnooze.validate("snooze", %{
             "reminder_id" => String.duplicate("r", 64),
             "minutes" => 1_440
           }) == :ok
  end

  test "snoozes the reminder that rang on a computer, once for a press made twice", %{repo: repo} do
    rung = rung!(repo)
    args = %{"reminder_id" => rung.id, "minutes" => 10}

    assert NotificationSnooze.run("snooze", args, nil, service_context(repo)) ==
             {:ok, %{"status" => "created"}, nil}

    assert {:ok, [snoozed]} =
             Repo.list_temporal_reminders(%{event_id: rung.event_id, status: ["pending"]},
               server: repo
             )

    assert snoozed.scheduled_for == ~U[2026-08-16 19:15:00.000000Z]

    assert NotificationSnooze.run("snooze", args, nil, service_context(repo)) ==
             {:ok, %{"status" => "existing"}, nil}
  end

  test "a refusal is the registry's own sentence", %{repo: repo} do
    rung = rung!(repo, nil)
    args = %{"reminder_id" => rung.id, "minutes" => 10}

    assert {:failed, sentence} =
             NotificationSnooze.run("snooze", args, nil, service_context(repo))

    assert sentence == Registry.describe_error(:not_rung_on_this_computer)
  end

  test "a registry that does not answer fails the press alone" do
    args = %{"reminder_id" => "rem_1", "minutes" => 10}
    context = service_context(:notification_snooze_no_such_repo)

    assert NotificationSnooze.run("snooze", args, nil, context) ==
             {:failed, "This server could not snooze the reminder now."}
  end
end
