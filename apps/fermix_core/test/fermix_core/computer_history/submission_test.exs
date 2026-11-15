defmodule FermixCore.ComputerHistory.SubmissionTest do
  # M97 §8.1, §8.5: the home's half. A machine's finished sitting becomes a
  # note marked with that machine, made on the home's route from text that is
  # never written down; a purged or paused window never gains a note, in either
  # order; a sitting sent twice makes one note.
  use ExUnit.Case, async: true

  alias FermixCore.ComputerHistory.Submission
  alias FermixCore.ComputerHistory.Summarizer.EventRender
  alias FermixCore.Memory.Repo
  alias FermixTestSupport.SafeRm

  @t0 1_793_000_000_000
  @studio "studio-7f3a"
  @loft "loft-91c2"

  defmodule FakeAdapter do
    @behaviour FermixCore.Providers.Adapter

    alias FermixCore.Memory.Repo

    @impl true
    def chat(messages, _capabilities, opts) do
      Process.put(:sub_calls, [%{messages: messages, agent: opts[:agent]} | calls()])
      purge_mid_call(Process.delete(:sub_purge))

      case Process.get(:sub_reply, "The owner revised the lease summary in Notes.") do
        {:error, reason} -> {:error, reason}
        content -> {:ok, %{content: content, tool_calls: [], provider_state: nil, usage: %{}}}
      end
    end

    defp calls, do: Process.get(:sub_calls, [])

    # The owner purges while the summary call is in flight.
    defp purge_mid_call(nil), do: :ok

    defp purge_mid_call({repo, from_ts, to_ts, scope}) do
      {:ok, _purged} =
        Repo.computer_history_home(:purge_notes, [from_ts, to_ts, to_ts, scope], server: repo)

      :ok
    end

    @impl true
    def continue(_state, _results, _opts), do: {:error, :not_supported}
    @impl true
    def to_provider_tools(_caps), do: []
    @impl true
    def parse_tool_calls(_response), do: []
    @impl true
    def parse_response(response), do: response
  end

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-ch-submission-#{unique}.db")
    repo = :"ch_submission_repo_#{unique}"
    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &SafeRm.rm/1)
    end)

    %{repo: repo}
  end

  defp opts(repo, extra \\ []) do
    [
      repo: repo,
      adapter: FakeAdapter,
      config: [summarizer: :local],
      route_opts: [model: "llama3"],
      now: DateTime.from_unix!(@t0 + 60_000, :millisecond),
      contributors: [@studio, @loft]
    ]
    |> Keyword.merge(extra)
  end

  defp field(seq, ts, text) do
    %{
      id: seq,
      ts: ts,
      type: "field.value",
      bundle_id: "com.example.notes",
      window_title: "Lease — Notes",
      field_label: "Body",
      text: text
    }
  end

  defp sitting(key \\ "7-9:#{@t0}", texts \\ ["Pay the lease on the first"]) do
    events =
      texts |> Enum.with_index(7) |> Enum.map(fn {text, seq} -> field(seq, @t0 + seq, text) end)

    {input, _rendered} = EventRender.render(events, timezone: "Etc/UTC")

    %{
      "v" => Submission.version(),
      "sitting" => key,
      "from_ts" => @t0 + 7,
      "to_ts" => @t0 + 6 + length(events),
      "event_count" => length(events),
      "field_values" => length(events),
      "apps" => ["com.example.notes"],
      "sites" => [],
      "titles" => ["Lease — Notes"],
      "urls" => [],
      "text" => input
    }
  end

  defp notes(repo, computer \\ :all) do
    {:ok, rows} =
      Repo.computer_history_memories_in_window(0, @t0 * 2, 50, server: repo, computer: computer)

    rows
  end

  defp calls, do: Process.get(:sub_calls, [])

  test "a sitting becomes a note marked with its machine, made from the text it carried", ctx do
    assert %{status: :summarized, reason: nil} =
             Submission.accept(@studio, sitting(), opts(ctx.repo))

    assert [%{messages: [_system, %{content: user}], agent: "computer_history_summarizer"}] =
             calls()

    assert user =~ "Pay the lease on the first"

    assert [note] = notes(ctx.repo)
    assert note.computer_id == @studio
    assert note.summary == "The owner revised the lease summary in Notes."
    assert note.provenance_from_ts == @t0 + 7
    assert Jason.decode!(note.apps) == ["com.example.notes"]
    assert notes(ctx.repo, @loft) == []

    assert {:ok, [%{computer_id: @studio, last_status: "summarized", submitted: 1}]} =
             Repo.computer_history_home(:computer_rows, [], server: ctx.repo)
  end

  test "a sitting sent again is answered from its note: no second call, no second note", ctx do
    assert %{status: :summarized} = Submission.accept(@studio, sitting(), opts(ctx.repo))
    assert %{status: :summarized} = Submission.accept(@studio, sitting(), opts(ctx.repo))
    assert length(calls()) == 1
    assert length(notes(ctx.repo)) == 1

    # The same key from another machine is another sitting.
    assert %{status: :summarized} = Submission.accept(@loft, sitting(), opts(ctx.repo))
    assert length(notes(ctx.repo)) == 2
  end

  test "a sitting with nothing typed and one title is no_signal, with no call", ctx do
    quiet = %{sitting() | "field_values" => 0, "titles" => ["Lease — Notes"]}
    assert %{status: :no_signal} = Submission.accept(@studio, quiet, opts(ctx.repo))
    assert calls() == []
    assert notes(ctx.repo) == []
  end

  test "a purge of that machine, or of every machine, refuses a sitting in its window", ctx do
    {:ok, %{interval: id}} =
      Repo.computer_history_home(:purge_notes, [@t0, @t0 + 100, @t0 + 200, @studio],
        server: ctx.repo
      )

    assert %{status: :refused, reason: :purged, intervals: [%{id: ^id, kind: "purge"}]} =
             Submission.accept(@studio, sitting(), opts(ctx.repo))

    # Another machine's window is not this one's.
    assert %{status: :summarized} = Submission.accept(@loft, sitting(), opts(ctx.repo))

    {:ok, _purged} =
      Repo.computer_history_home(:purge_notes, [@t0, @t0 + 100, @t0 + 300, :all],
        server: ctx.repo
      )

    assert %{status: :refused, reason: :purged} =
             Submission.accept(@loft, sitting("8-9:#{@t0}"), opts(ctx.repo))

    assert calls() |> length() == 1
  end

  # history_submit HS-1: the machine records the highest interval it applies as
  # its mark, so a refusal names every pending one above the sitting's mark,
  # oldest first, never only those that reach this sitting.
  test "a refusal names every interval pending above the sitting's mark", ctx do
    {:ok, %{interval: later}} =
      Repo.computer_history_home(:purge_notes, [@t0 + 500, @t0 + 600, @t0 + 700, :all],
        server: ctx.repo
      )

    {:ok, %{interval: reaching}} =
      Repo.computer_history_home(:purge_notes, [@t0, @t0 + 100, @t0 + 800, :all],
        server: ctx.repo
      )

    assert %{status: :refused, intervals: intervals} =
             Submission.accept(@studio, sitting(), opts(ctx.repo))

    assert Enum.map(intervals, & &1.id) == [later, reaching]

    # A machine that already applied the first of this home's store is told of
    # the second alone.
    {:ok, home} = FermixCore.ComputerHistory.home_identity(repo: ctx.repo)
    applied = fn mark -> sitting() |> Map.put("mark", mark) |> Map.put("home", home) end

    assert %{status: :refused, intervals: [%{id: ^reaching}], home: ^home} =
             Submission.accept(@studio, applied.(later), opts(ctx.repo))

    # And one that applied both is taken.
    assert %{status: :summarized} = Submission.accept(@studio, applied.(reaching), opts(ctx.repo))
  end

  # The other order: the note is read before the purge and written after it.
  test "a purge that lands while the summary is made refuses the note", ctx do
    Process.put(:sub_purge, {ctx.repo, @t0, @t0 + 100, @studio})

    assert %{status: :refused, reason: :purged, intervals: [%{kind: "purge"}]} =
             Submission.accept(@studio, sitting(), opts(ctx.repo))

    assert notes(ctx.repo) == []
  end

  test "a pause from chat refuses a sitting stamped inside it", ctx do
    {:ok, _id} =
      Repo.computer_history_home(:pause_window, [@t0, @t0 + 3_600_000, @t0, :all],
        server: ctx.repo
      )

    assert %{status: :refused, reason: :paused, intervals: [%{kind: "pause"}]} =
             Submission.accept(@studio, sitting(), opts(ctx.repo))

    assert calls() == []
  end

  test "an abstention writes no note and is the machine's latest outcome", ctx do
    Process.put(:sub_reply, "NO_MEANINGFUL_ACTIVITY")
    assert %{status: :abstained} = Submission.accept(@studio, sitting(), opts(ctx.repo))
    assert notes(ctx.repo) == []

    assert {:ok, [%{computer_id: @studio, last_status: "abstained"}]} =
             Repo.computer_history_home(:computer_rows, [], server: ctx.repo)
  end

  test "the verbatim guard reads the field text the sitting carried", ctx do
    typed = "Account 4417 1234 5678 9113 routing to the landlord"
    Process.put(:sub_reply, "The owner typed #{typed} into the lease note.")

    assert %{status: :summarized} =
             Submission.accept(@studio, sitting("7-7:#{@t0}", [typed]), opts(ctx.repo))

    assert [%{summary: summary}] = notes(ctx.repo)
    refute summary =~ "4417 1234 5678"
    assert summary =~ "[…]"
  end

  test "a route that is down refuses for now, and a sitting that cannot be read never", ctx do
    Process.put(:sub_reply, {:error, :provider_unavailable})

    assert %{status: :refused, reason: :summarizer_unavailable} =
             Submission.accept(@studio, sitting(), opts(ctx.repo))

    assert %{status: :refused, reason: :invalid} =
             Submission.accept(@studio, Map.put(sitting(), "raw_events", []), opts(ctx.repo))

    assert %{status: :refused, reason: :invalid} =
             Submission.accept(@studio, %{sitting() | "v" => 2}, opts(ctx.repo))

    assert %{status: :refused, reason: :invalid} =
             Submission.accept(@studio, %{sitting() | "event_count" => %{}}, opts(ctx.repo))

    assert length(calls()) == 1
  end

  test "a note made on the machine is stored as sent, under the same checks, with no call", ctx do
    note = %{"summary" => "Planned the move in Calendar.", "model" => "on-device-llm"}
    payload = sitting() |> Map.delete("text") |> Map.put("note", note)

    assert %{status: :summarized} = Submission.accept(@studio, payload, opts(ctx.repo))
    assert calls() == []
    assert [%{summary: "Planned the move in Calendar.", model: "on-device-llm"}] = notes(ctx.repo)
  end

  # M97 §8.5: off means no further provider call for that machine's history.
  test "a sitting from a machine that no longer contributes is refused off, with no call", ctx do
    assert %{status: :refused, reason: :off, intervals: []} =
             Submission.accept(@studio, sitting(), opts(ctx.repo, contributors: [@loft]))

    assert calls() == []
    assert notes(ctx.repo) == []

    note = %{"summary" => "Planned the move in Calendar.", "model" => "on-device-llm"}
    payload = sitting("1-2:#{@t0}") |> Map.delete("text") |> Map.put("note", note)

    assert %{status: :refused, reason: :off} =
             Submission.accept(@studio, payload, opts(ctx.repo, contributors: []))

    assert notes(ctx.repo) == []
  end

  # The home's own rule (`ComputerHistory.contributors/1`): a computer whose
  # history the owner switched off from chat contributes nothing until it says
  # it switched off, and then contributes only if its offer is on again.
  test "a computer asked from chat to switch off is refused until it says it did", ctx do
    studio = %FermixCore.Computers.Computer{
      device_id: @studio,
      name: "studio Mac",
      offers: [%{id: "history", state: :on, sentence: nil, detail: nil}]
    }

    contributors = fn ->
      FermixCore.ComputerHistory.contributors(
        repo: ctx.repo,
        recording?: false,
        computers: [studio]
      )
    end

    assert {:ok, [@studio]} = contributors.()
    :ok = Repo.computer_history_home(:request_off, [@studio, @t0], server: ctx.repo)
    assert {:ok, []} = contributors.()

    {:ok, machines} = contributors.()

    assert %{status: :refused, reason: :off} =
             Submission.accept(@studio, sitting(), opts(ctx.repo, contributors: machines))

    assert calls() == []

    # An answer to an earlier request does not clear a later one.
    :ok = Repo.computer_history_home(:clear_off, [@studio, @t0 - 1], server: ctx.repo)
    assert {:ok, []} = contributors.()
    :ok = Repo.computer_history_home(:clear_off, [@studio, @t0], server: ctx.repo)
    assert {:ok, [@studio]} = contributors.()
  end

  # M97 §8.1: the home keeps purge and pause intervals for the retention
  # window alone, so a sitting older than the window is never noted: it is
  # refused, with no call, and the machine moves past it.
  test "a sitting older than the retention window is refused expired, with no call", ctx do
    late = DateTime.from_unix!(@t0 + 49 * 3_600_000, :millisecond)

    assert %{status: :refused, reason: :expired, intervals: []} =
             Submission.accept(@studio, sitting(), opts(ctx.repo, now: late))

    assert calls() == []
    assert notes(ctx.repo) == []
  end

  # M97 §8.5: a mark is the highest interval of one home's store a machine
  # applied, so a sitting that names no home, or another, is checked against
  # every interval of this one.
  test "a sitting whose mark is not this home's is checked against every interval", ctx do
    {:ok, %{interval: reaching}} =
      Repo.computer_history_home(:purge_notes, [@t0, @t0 + 100, @t0 + 800, :all],
        server: ctx.repo
      )

    assert %{status: :refused, reason: :purged, intervals: [%{id: ^reaching}]} =
             Submission.accept(@studio, Map.put(sitting(), "mark", reaching), opts(ctx.repo))

    assert calls() == []
  end

  test "an answer survives the wire" do
    answer = %{
      status: :refused,
      reason: :paused,
      intervals: [%{id: 3, from_ts: 1, to_ts: 2, issued_at: 2, kind: "pause"}],
      home: "4f2a9c1e7b3d5a60.2"
    }

    assert {:ok, ^answer} = answer |> Submission.to_wire() |> Submission.from_wire()

    assert {:error, _reason} =
             Submission.from_wire(%{"status" => "invented", "reason" => nil, "intervals" => []})

    # Intervals mean nothing without the home store they belong to.
    assert {:error, _reason} =
             answer |> Map.put(:home, nil) |> Submission.to_wire() |> Submission.from_wire()

    off = %{status: :refused, reason: :off, intervals: [], home: nil}
    assert {:ok, ^off} = off |> Submission.to_wire() |> Submission.from_wire()

    expired = %{status: :refused, reason: :expired, intervals: [], home: nil}
    assert {:ok, ^expired} = expired |> Submission.to_wire() |> Submission.from_wire()
  end
end
