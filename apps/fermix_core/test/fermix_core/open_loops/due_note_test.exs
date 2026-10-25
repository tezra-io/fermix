defmodule FermixCore.OpenLoops.DueNoteTest do
  # async: false — the note follows `[fermix_core.open_loops] enabled` and states
  # its dates in the personalization timezone, global `Application` env that each
  # test pins and restores.
  use ExUnit.Case, async: false

  alias FermixCore.Memory.Repo
  alias FermixCore.OpenLoops.DueNote
  alias FermixCore.OpenLoops.Registry

  defmodule FakeChannel do
    @moduledoc false
    def send_message(_destination, _payload, _opts), do: :ok
  end

  @tz "America/New_York"
  # Monday 2031-06-02, 10:00 EDT (UTC-4): when the owner said it. Every name,
  # date and id in this file is invented.
  @said ~U[2031-06-02 14:00:00Z]
  # A loop that matters by Tuesday, June 10 is medium: its first check is three
  # days before, Saturday, June 7, at the default 09:00 start (13:00 UTC).
  @first_check ~U[2031-06-07 13:00:00Z]
  @inside_window ~U[2031-06-07 14:30:00Z]
  @window_closed ~U[2031-06-07 16:00:00Z]

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-open-loop-due-note-#{unique}.db")
    repo = :"open_loop_due_note_repo_#{unique}"

    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})

    previous = Application.get_env(:fermix_core, :open_loops)
    previous_personalization = Application.get_env(:fermix_core, :personalization)
    Application.put_env(:fermix_core, :open_loops, enabled: true)
    Application.put_env(:fermix_core, :personalization, timezone: @tz)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:fermix_core, :open_loops)
        value -> Application.put_env(:fermix_core, :open_loops, value)
      end

      case previous_personalization do
        nil -> Application.delete_env(:fermix_core, :personalization)
        value -> Application.put_env(:fermix_core, :personalization, value)
      end

      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    %{repo: repo}
  end

  defp context(repo, now, overrides \\ %{}) do
    Map.merge(
      %{
        agent_name: "main",
        conversation_key: {"telegram", "40023", :root},
        source_trust: :operator,
        computer_use_origin: :interactive,
        chat_type: "private",
        memory_repo: repo,
        memory_agent_id: "main",
        memory_owner_id: "default",
        now_fn: fn -> now end
      },
      overrides
    )
  end

  defp note!(repo, intention, date) when is_binary(date),
    do: note!(repo, intention, %{"type" => "date", "date" => date})

  defp note!(repo, intention, form) when is_map(form) do
    params = %{"intention" => intention, "matters_by" => form}

    opts = [
      repo: repo,
      now: @said,
      personalization: [timezone: @tz],
      jobs_config: [delivery_channels: %{"telegram" => FakeChannel}],
      configured_owners: %{"telegram" => "40023"},
      scheduler: nil
    ]

    attended = context(repo, @said)
    {:ok, %{loop: loop}} = Registry.note(params, attended, opts)
    loop
  end

  defp come_due!(repo, at) do
    {:ok, %{due: due}} = Repo.scan_due_open_loops(at, 50, server: repo)
    due
  end

  test "nil while open loops are turned off", %{repo: repo} do
    note!(repo, "Send the Thistlewood quarterly figures", "2031-06-10")
    come_due!(repo, @first_check)
    Application.put_env(:fermix_core, :open_loops, enabled: false)

    assert DueNote.note(context(repo, @inside_window)) == nil
  end

  test "nil for a guest's turn", %{repo: repo} do
    note!(repo, "Send the Thistlewood quarterly figures", "2031-06-10")
    come_due!(repo, @first_check)

    assert DueNote.note(context(repo, @inside_window, %{source_trust: :guest})) == nil
  end

  test "nil for a turn that is not attended", %{repo: repo} do
    note!(repo, "Send the Thistlewood quarterly figures", "2031-06-10")
    come_due!(repo, @first_check)

    unattended = context(repo, @inside_window, %{computer_use_origin: :unattended})
    assert DueNote.note(unattended) == nil
  end

  test "nil for a group chat", %{repo: repo} do
    note!(repo, "Send the Thistlewood quarterly figures", "2031-06-10")
    come_due!(repo, @first_check)

    for chat_type <- ["group", "supergroup", "channel", "guild", "mpim"] do
      assert DueNote.note(context(repo, @inside_window, %{chat_type: chat_type})) == nil
    end
  end

  test "nil when no loop is due", %{repo: repo} do
    assert DueNote.note(context(repo, @inside_window)) == nil

    note!(repo, "Send the Thistlewood quarterly figures", "2031-06-10")
    assert DueNote.note(context(repo, @inside_window)) == nil
  end

  test "one due loop: the owner's words, absolute dates, and the id on its own line",
       %{repo: repo} do
    loop = note!(repo, "Send the Thistlewood quarterly figures", "2031-06-10")
    come_due!(repo, @first_check)

    note = DueNote.note(context(repo, @inside_window))

    assert note ==
             "Open loop due. On Monday, June 2, 2031 the owner said: \"Send the Thistlewood " <>
               "quarterly figures\". It matters by Tuesday, June 10, 2031. Raise it under the " <>
               "open-loop rules only if this exchange reaches a natural stopping point and the " <>
               "owner is not under pressure; otherwise leave it for Fermix to raise on its own.\n" <>
               "open_loop_id: #{loop.id}"
  end

  test "an absent chat type is an owner-private turn", %{repo: repo} do
    note!(repo, "Send the Thistlewood quarterly figures", "2031-06-10")
    come_due!(repo, @first_check)

    assert DueNote.note(context(repo, @inside_window, %{chat_type: nil})) =~ "Open loop due."
  end

  test "two due loops: one paragraph each, nearest date first", %{repo: repo} do
    # Both come due at the same first check (three days before June 10); the
    # timed one passes first, so it leads.
    later = note!(repo, "Book the Fennimore hall for the reunion", "2031-06-10")

    nearer =
      note!(repo, "Send the Thistlewood quarterly figures", %{
        "type" => "datetime",
        "date" => "2031-06-10",
        "time" => "18:00:00"
      })

    come_due!(repo, @first_check)

    note = DueNote.note(context(repo, @inside_window))
    [first, second] = String.split(note, "\n\n")

    assert first =~ "Send the Thistlewood quarterly figures"
    assert first =~ "It matters by Tuesday, June 10, 2031 at 6:00 PM EDT."
    assert String.ends_with?(first, "\nopen_loop_id: #{nearer.id}")

    assert second =~ "Book the Fennimore hall for the reunion"
    assert second =~ "It matters by Tuesday, June 10, 2031."
    assert String.ends_with?(second, "\nopen_loop_id: #{later.id}")
  end

  test "a loop whose touch window has closed yields nil", %{repo: repo} do
    note!(repo, "Send the Thistlewood quarterly figures", "2031-06-10")
    come_due!(repo, @first_check)

    assert DueNote.note(context(repo, ~U[2031-06-07 15:59:59Z])) =~ "Open loop due."
    assert DueNote.note(context(repo, @window_closed)) == nil
  end
end
