defmodule FermixCore.ComputerHistory.SummarizerTest do
  @moduledoc """
  MILESTONE_32 §10 — the on-device summarizer. Proves raw events reach only the
  intended provider (inv. 1 / 1b), the pinned route never failovers, a
  non-loopback local route refuses (inv. 17), the rendered batch is bounded and
  keeps its evidence, the output contract redacts verbatim field text, and
  memories accrete instead of superseding each other.

  A fake adapter records every call in the process dictionary (run_cycle is
  synchronous and in-process). The provider/model/base_url are injected via
  `:route_opts` and the timezone is pinned per call, so no global config is
  read or mutated (hermetic).
  """
  use ExUnit.Case, async: false

  alias FermixCore.ComputerHistory.Ingest
  alias FermixCore.ComputerHistory.Locality
  alias FermixCore.ComputerHistory.Recall
  alias FermixCore.ComputerHistory.Summarizer
  alias FermixCore.Memory.Repo

  # --- fake adapter (records calls, canned response) ----------------------

  defmodule FakeAdapter do
    @behaviour FermixCore.Providers.Adapter

    @impl true
    def chat(messages, _capabilities, opts) do
      call = %{
        messages: messages,
        base_url: opts[:base_url],
        model: opts[:model],
        session_id: opts[:session_id],
        agent: opts[:agent]
      }

      Process.put(:ch_calls, [call | Process.get(:ch_calls, [])])

      respond(Process.get(:ch_behavior, :ok), opts)
    end

    defp respond(:error, _opts), do: {:error, :provider_unavailable}

    # Fails from the nth call on, so a mid-cycle route failure can be asserted.
    defp respond({:error_after, calls}, opts) do
      if length(Process.get(:ch_calls, [])) > calls,
        do: {:error, :provider_unavailable},
        else: respond(:ok, opts)
    end

    defp respond(:ok, opts) do
      content = Process.get(:ch_content, "The owner used Safari and read a page.")
      {:ok, turn(content, opts[:model])}
    end

    @impl true
    def continue(_state, _results, _opts), do: {:error, :not_supported}
    @impl true
    def to_provider_tools(_caps), do: []
    @impl true
    def parse_tool_calls(_response), do: []
    @impl true
    def parse_response(response), do: response

    defp turn(content, model) do
      %{
        content: content,
        tool_calls: [],
        provider_state: nil,
        usage: %{prompt_tokens: 1, completion_tokens: 1, total_tokens: 2},
        model: model
      }
    end
  end

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-ch-summarizer-#{unique}.db")
    repo_name = :"ch_summarizer_repo_#{unique}"
    start_supervised!({Repo, name: repo_name, enabled: true, database_path: db_path})

    original = Application.get_env(:fermix_core, :computer_history)
    Process.delete(:ch_calls)
    Process.delete(:ch_behavior)
    Process.delete(:ch_content)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:fermix_core, :computer_history)
        value -> Application.put_env(:fermix_core, :computer_history, value)
      end

      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    %{repo: repo_name}
  end

  defp enable(kw), do: Application.put_env(:fermix_core, :computer_history, [enabled: true] ++ kw)

  defp insert(repo, events),
    do: {:ok, _} = Repo.computer_history_insert_events(events, server: repo)

  defp event(seq, ts, text),
    do: %{
      boot_id: "b1",
      source_seq: seq,
      ts: ts,
      type: "field.value",
      bundle_id: "com.apple.Safari",
      text: text
    }

  defp raw_event(seq, ts, attrs),
    do: Map.merge(%{boot_id: "b1", source_seq: seq, ts: ts, type: "app.activated"}, attrs)

  defp field_event(seq, ts, label, text),
    do:
      raw_event(seq, ts, %{
        type: "field.value",
        bundle_id: "com.apple.TextEdit",
        field_label: label,
        text: text
      })

  defp ms(datetime), do: DateTime.to_unix(datetime, :millisecond)

  defp calls, do: Process.get(:ch_calls, [])

  # Oldest call first — the order the batches ran in.
  defp ordered_calls, do: Enum.reverse(calls())

  defp user_message(call), do: call.messages |> Enum.at(1) |> Map.fetch!(:content)

  defp local_opts(repo, opts \\ []) do
    opts ++
      [
        repo: repo,
        macos?: true,
        adapter: FakeAdapter,
        route_opts: [model: "llama3"],
        timezone: "Etc/UTC"
      ]
  end

  defp stored_memory(repo) do
    {:ok, [memory]} =
      Repo.computer_history_memories_in_window(0, 9_999_999_999_999, 100, server: repo)

    memory
  end

  # 80 events whose values all clip to the same rendered line, so the batch
  # renders to the same 62-line prompt at any size (measured 21_870 against
  # 21_889 characters, a 0.09% difference): what scales is only the field bytes
  # the verbatim guard projects behind those clipped lines.
  defp sized_batch(per_event) do
    Enum.map(1..80, fn seq ->
      event(seq, 1_000 + seq, "#{seq}-#{String.duplicate("qwertyuiop asdfghjkl ", per_event)}")
    end)
  end

  # One cycle on its own fresh spool, measured in REDUCTIONS — the BEAM's own
  # unit of work — rather than microseconds. A cost property asserted in
  # reductions holds on a runner of any speed and under any load.
  defp cycle_cost(events, content) do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-ch-cost-#{unique}.db")
    repo = :"ch_cost_repo_#{unique}"

    start_supervised!(
      Supervisor.child_spec({Repo, name: repo, enabled: true, database_path: db_path}, id: repo)
    )

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    insert(repo, events)
    Process.put(:ch_content, content)

    {:reductions, before} = Process.info(self(), :reductions)
    result = Summarizer.run_cycle(local_opts(repo))
    {:reductions, spent} = Process.info(self(), :reductions)

    %{reductions: spent - before, result: result}
  end

  # --- inv. 1: local summarizer, raw reaches the loopback route -----------

  test "local summarizer sends raw events to the loopback route only (inv. 1)", %{repo: repo} do
    enable(summarizer: :local)
    canary = FermixTestSupport.ComputerHistoryCanary.token("raw")
    insert(repo, [event(1, 1_000, "typed #{canary}")])

    assert {:ok, %{memory_written: true, events: 1}} = Summarizer.run_cycle(local_opts(repo))

    assert [call] = calls()
    assert Locality.loopback?(call.base_url)
    assert FermixTestSupport.ComputerHistoryCanary.present?(call.messages, canary)
    assert {:ok, 1} = Repo.computer_history_count_memories(server: repo)
  end

  # --- inv. 1b: Tier-3 pins to the named vendor, never failovers ----------

  test "Tier-3 sends raw only to the named provider (inv. 1b)", %{repo: repo} do
    enable(summarizer: :anthropic)
    canary = FermixTestSupport.ComputerHistoryCanary.token("raw")
    insert(repo, [event(1, 1_000, "typed #{canary}")])

    opts = [
      repo: repo,
      macos?: true,
      adapter: FakeAdapter,
      route_opts: [model: "claude-x", api_key: "test-key"]
    ]

    assert {:ok, %{memory_written: true}} = Summarizer.run_cycle(opts)

    assert [call] = calls()
    assert call.base_url == "https://api.anthropic.com/v1"
    assert FermixTestSupport.ComputerHistoryCanary.present?(call.messages, canary)
  end

  test "a Tier-3 route down refuses without failing over to another vendor (inv. 1b)", %{
    repo: repo
  } do
    enable(summarizer: :anthropic)
    insert(repo, [event(1, 1_000, "some text")])
    Process.put(:ch_behavior, :error)

    opts = [
      repo: repo,
      macos?: true,
      adapter: FakeAdapter,
      route_opts: [model: "claude-x", api_key: "k"]
    ]

    assert {:error, :provider_unavailable} = Summarizer.run_cycle(opts)

    # Exactly one call — no failover to a second vendor.
    assert length(calls()) == 1
    assert {:ok, 0} = Repo.computer_history_count_memories(server: repo)

    {:ok, state} = Repo.computer_history_fetch_state(server: repo)
    assert state.paused_reason == "route_down"
  end

  # --- inv. 17: a non-loopback local route refuses ------------------------

  test "a local route repointed off-loopback refuses and emits no request (inv. 17)", %{
    repo: repo
  } do
    enable(summarizer: :local)
    insert(repo, [event(1, 1_000, "text")])

    opts = [
      repo: repo,
      macos?: true,
      adapter: FakeAdapter,
      route_opts: [model: "llama3", base_url: "http://10.0.0.5:11434/v1"]
    ]

    assert {:paused, :route_not_permitted} = Summarizer.run_cycle(opts)
    assert calls() == []
    assert {:ok, 0} = Repo.computer_history_count_memories(server: repo)
  end

  # --- output contract: verbatim field text is redacted -------------------

  test "a summary that echoes a whole field value has the echo redacted", %{repo: repo} do
    enable(summarizer: :local)
    secret_field = "my-private-note-abcdefghijklmnop"
    insert(repo, [event(1, 1_000, secret_field)])
    # Force the model to echo the field value verbatim.
    Process.put(:ch_content, "The owner typed #{secret_field} into a field.")

    assert {:ok, %{memory_written: true}} = Summarizer.run_cycle(local_opts(repo))

    summary = stored_memory(repo).summary
    refute summary =~ secret_field
    assert summary =~ "[…]"
    assert summary =~ "The owner typed"
    assert summary =~ "into a field."

    {:ok, state} = Repo.computer_history_fetch_state(server: repo)
    assert state.last_status == "ok"
  end

  test "verbatim_middle: an interior copy is redacted, the sentence around it survives", %{
    repo: repo
  } do
    enable(summarizer: :local)
    middle = "the account number is 4915 6612 0093 7714 and it "
    text = "#{String.duplicate("h", 40)}#{middle}#{String.duplicate("t", 40)}"
    assert String.length(middle) == 49
    insert(repo, [event(1, 1_000, text)])

    # The 24-char edges of the source differ from anything in the summary; only
    # a run from the MIDDLE of the field was echoed.
    Process.put(:ch_content, "The owner wrote #{middle} into the payment form.")

    assert {:ok, %{memory_written: true}} = Summarizer.run_cycle(local_opts(repo))

    summary = stored_memory(repo).summary
    refute summary =~ middle
    refute summary =~ "4915"
    assert summary =~ "The owner wrote"
    assert summary =~ "into the payment form."
  end

  test "redaction keeps the unrelated event's information", %{repo: repo} do
    enable(summarizer: :local)
    echoed = "quarterly revenue was 4.2 million dollars this year"

    insert(repo, [
      event(1, 1_000, echoed),
      %{
        boot_id: "b1",
        source_seq: 2,
        ts: 2_000,
        type: "window.focused",
        bundle_id: "com.apple.dt.Xcode",
        window_title: "Fermix — summarizer.ex"
      }
    ])

    Process.put(:ch_content, "The owner typed #{echoed}. They also edited Fermix in Xcode.")

    assert {:ok, %{memory_written: true, events: 2}} = Summarizer.run_cycle(local_opts(repo))

    summary = stored_memory(repo).summary
    refute summary =~ echoed
    assert summary =~ "They also edited Fermix in Xcode."
  end

  test "a reflowed copy of a field is redacted as one run", %{repo: repo} do
    enable(summarizer: :local)
    field = "Amy Chen\n5 Vine St\nSSN 512-88-9031\nDOB 1979-04-02\nsalary 214000"
    insert(repo, [event(1, 1_000, field)])

    # Same characters, different whitespace and punctuation — a byte-comparison
    # guard sees nothing here.
    Process.put(
      :ch_content,
      "The owner opened a record: Amy Chen, 5 Vine St, SSN 512-88-9031, " <>
        "DOB 1979-04-02, salary 214000. They then switched to Mail."
    )

    assert {:ok, %{memory_written: true}} = Summarizer.run_cycle(local_opts(repo))

    summary = stored_memory(repo).summary
    refute summary =~ "512-88-9031"
    refute summary =~ "Amy Chen"
    refute summary =~ "214000"
    assert summary =~ "The owner opened a record:"
    assert summary =~ "They then switched to Mail."
    # One contiguous run, one marker.
    assert length(String.split(summary, "[…]")) == 2
  end

  test "a case- and punctuation-shifted copy of a field is redacted", %{repo: repo} do
    enable(summarizer: :local)
    field = "Amy Chen\n5 Vine St\nSSN 512-88-9031\nDOB 1979-04-02\nsalary 214000"
    insert(repo, [event(1, 1_000, field)])

    Process.put(
      :ch_content,
      "Record seen: AMY CHEN, 5 VINE ST; SSN 512 88 9031; DOB 1979/04/02; " <>
        "salary 214000! Then Mail."
    )

    assert {:ok, %{memory_written: true}} = Summarizer.run_cycle(local_opts(repo))

    summary = stored_memory(repo).summary
    refute summary =~ "AMY CHEN"
    refute summary =~ "9031"
    assert summary =~ "Record seen:"
    assert summary =~ "Then Mail."
  end

  test "a second run starting inside the first match's span is still redacted", %{repo: repo} do
    enable(summarizer: :local)
    insert(repo, [event(1, 1_000, "abcdefghijklmnopqrstuvwxy")])

    # The second run starts 5 bytes into the first — inside the region a
    # non-overlapping scan skips.
    Process.put(
      :ch_content,
      "The owner typed abcdefghijklmnopqrst. Then zed. Then fghijklmnopqrstuvwxy. Done."
    )

    assert {:ok, %{memory_written: true}} = Summarizer.run_cycle(local_opts(repo))

    assert stored_memory(repo).summary ==
             "The owner typed […]. Then zed. Then […]. Done."
  end

  test "a redacted multibyte summary stays valid UTF-8", %{repo: repo} do
    enable(summarizer: :local)
    field = "réunion budgétaire trimestrielle à Paris — 2026"
    insert(repo, [event(1, 1_000, field)])
    Process.put(:ch_content, "The owner reviewed #{field} in Calendar.")

    assert {:ok, %{memory_written: true}} = Summarizer.run_cycle(local_opts(repo))

    summary = stored_memory(repo).summary
    assert String.valid?(summary)
    refute summary =~ "budgétaire"
    assert summary =~ "The owner reviewed"
    assert summary =~ "in Calendar."
  end

  test "an NFD source field is redacted from an NFC summary", %{repo: repo} do
    enable(summarizer: :local)
    phrase = "Réunion budget négociation privée totale"
    # macOS Accessibility hands out decomposed text; a model writes composed.
    insert(repo, [event(1, 1_000, :unicode.characters_to_nfd_binary(phrase))])
    Process.put(:ch_content, "The owner drafted #{phrase} in Pages.")

    assert {:ok, %{memory_written: true}} = Summarizer.run_cycle(local_opts(repo))

    summary = stored_memory(repo).summary
    assert String.valid?(summary)
    refute summary =~ "négociation"
    assert summary =~ "The owner drafted"
    assert summary =~ "in Pages."
  end

  test "a projected run shorter than the floor is left alone", %{repo: repo} do
    enable(summarizer: :local)
    # 24 raw bytes, but only 18 letters and digits once punctuation is dropped.
    insert(repo, [event(1, 1_000, "a-b-c d.e, f/g h_i (jkl)")])
    Process.put(:ch_content, "The owner typed a-b-c d.e, f/g h_i (jkl) somewhere.")

    assert {:ok, %{memory_written: true}} = Summarizer.run_cycle(local_opts(repo))
    assert stored_memory(repo).summary == "The owner typed a-b-c d.e, f/g h_i (jkl) somewhere."
  end

  test "two runs separated only by punctuation redact to a single marker", %{repo: repo} do
    enable(summarizer: :local)
    insert(repo, [event(1, 1_000, "quarterly revenue projection deck; final approval memo")])

    Process.put(
      :ch_content,
      "Saw quarterly revenue projection deck — final approval memo today."
    )

    assert {:ok, %{memory_written: true}} = Summarizer.run_cycle(local_opts(repo))

    summary = stored_memory(repo).summary
    refute summary =~ "[…][…]"
    assert length(String.split(summary, "[…]")) == 2
  end

  # The guard projects and scans every source byte once, so its cost is LINEAR in
  # the field bytes behind a batch. That is the property. Microseconds are not:
  # the same cycle measured 159 ms idle and 1_444 ms under load on one developer
  # machine minutes apart, and 2.4-3.2 s on the Intel macOS CI leg, so a
  # wall-clock bound grades the runner. Reductions do not move with the
  # hardware: 8x the field bytes cost 7.42-7.51x the reductions on every sample,
  # loaded or idle and under `+S 1:1` through `+S 8:8`, while the per-position
  # scan this guard's design replaced costs ~63x for the same 8x — quadratic.
  test "the verbatim guard's cost stays linear in the field bytes it scans" do
    enable(summarizer: :local)
    summary = String.duplicate("The owner reviewed the plan. ", 40)

    # Same 80 events, same 62 rendered lines, 8x the field bytes: 0.67 MB
    # against 5.4 MB.
    small = cycle_cost(sized_batch(400), summary)
    large = cycle_cost(sized_batch(3_200), summary)

    assert {:ok, %{memory_written: true}} = small.result
    assert {:ok, %{memory_written: true}} = large.result

    growth = large.reductions / small.reductions

    assert growth < 12,
           "8x the field bytes cost #{Float.round(growth, 2)}x the work " <>
             "(#{small.reductions} → #{large.reductions} reductions): the guard is superlinear"

    # A floor under the slope, so a linear but costlier pure-BEAM pass is caught
    # too: projecting each text twice measures 11.5 reductions per byte, three
    # times 14.5, so this ceiling fires at roughly 5x pure-BEAM inflation —
    # about the sensitivity the deleted 1 s wall-clock bound had on a fast
    # machine, expressed machine-independently. What NO reduction gate sees is
    # work moved into a NIF: reinstating a regex projection costs 2.8x the wall
    # clock yet only 6.8 reductions per byte, UNDER the shipped guard's own
    # 8.46, because reductions under-count NIF time. Measured 8.46-8.48 here.
    per_byte = large.reductions / (80 * 3_200 * 21)

    assert per_byte < 20,
           "the guard spent #{Float.round(per_byte, 2)} reductions per source byte"
  end

  # The degenerate shape: EVERY window matches, so this is the case that walks
  # `extend/4`. Dropping the covered-span skip in `absorb_match/4` — one line —
  # makes each match re-walk its run to the end of the field, and 8x the bytes
  # then costs ~63x the work (measured against this module). That is what this
  # ratio refuses; at this fixture size the regressed cycle is slow enough that
  # ExUnit's own timeout may fire first, which is the same red.
  test "the verbatim guard's cost stays linear on a degenerate repeated field" do
    enable(summarizer: :local)
    summary = String.duplicate("a", 5_000)

    small = cycle_cost([event(1, 1_000, String.duplicate("a", 65_536))], summary)
    large = cycle_cost([event(1, 1_000, String.duplicate("a", 524_288))], summary)

    assert {:ok, _small_cycle} = small.result
    assert {:ok, _large_cycle} = large.result

    growth = large.reductions / small.reductions

    assert growth < 12,
           "8x the repeated field cost #{Float.round(growth, 2)}x the work " <>
             "(#{small.reductions} → #{large.reductions} reductions): the guard is superlinear"
  end

  test "a summary that is nothing but an echoed field writes no memory", %{repo: repo} do
    enable(summarizer: :local)
    echoed = "the quarterly revenue projection deck for next year"
    insert(repo, [event(1, 1_000, echoed)])
    Process.put(:ch_content, echoed)

    assert {:ok, %{memory_written: false}} = Summarizer.run_cycle(local_opts(repo))
    assert {:ok, 0} = Repo.computer_history_count_memories(server: repo)

    {:ok, state} = Repo.computer_history_fetch_state(server: repo)
    assert state.last_status == "summarized_empty"

    assert Recall.recent_digest(
             repo: repo,
             now: DateTime.from_unix!(1_000, :millisecond),
             timezone: "Etc/UTC"
           ) == nil
  end

  test "a source text under the verbatim floor is not redacted", %{repo: repo} do
    enable(summarizer: :local)
    insert(repo, [event(1, 1_000, "budget")])
    Process.put(:ch_content, "The owner opened the budget spreadsheet.")

    assert {:ok, %{memory_written: true}} = Summarizer.run_cycle(local_opts(repo))
    assert stored_memory(repo).summary == "The owner opened the budget spreadsheet."
  end

  test "a reply that is not valid UTF-8 is refused like any malformed reply", %{repo: repo} do
    enable(summarizer: :local)
    insert(repo, [event(1, 1_000, "some text here")])
    Process.put(:ch_content, <<"ok", 255>>)

    assert {:error, :invalid_summary} = Summarizer.run_cycle(local_opts(repo))
    assert {:ok, 0} = Repo.computer_history_count_memories(server: repo)

    {:ok, state} = Repo.computer_history_fetch_state(server: repo)
    assert state.paused_reason == "route_down"
  end

  test "empty_output: whitespace-only content writes no memory but advances the cursor", %{
    repo: repo
  } do
    enable(summarizer: :local)
    insert(repo, [event(1, 1_000, "some text here")])
    Process.put(:ch_content, "   \n  ")

    assert {:ok, %{memory_written: false}} = Summarizer.run_cycle(local_opts(repo))
    assert {:ok, 0} = Repo.computer_history_count_memories(server: repo)

    {:ok, state} = Repo.computer_history_fetch_state(server: repo)
    assert state.last_summarized_id > 0
    assert state.last_status == "summarized_empty"
  end

  test "the abstention marker never becomes a memory", %{repo: repo} do
    enable(summarizer: :local)
    insert(repo, [event(1, 1_000, "idle noise")])
    Process.put(:ch_content, "NO_MEANINGFUL_ACTIVITY.")

    assert {:ok, %{memory_written: false}} = Summarizer.run_cycle(local_opts(repo))
    assert {:ok, 0} = Repo.computer_history_count_memories(server: repo)

    {:ok, state} = Repo.computer_history_fetch_state(server: repo)
    assert state.last_status == "summarized_empty"
  end

  test "output_budget: a 135,000-char answer is stored bounded and recall stays bounded", %{
    repo: repo
  } do
    enable(summarizer: :local)
    insert(repo, [event(1, 1_000, "some text here")])
    Process.put(:ch_content, String.duplicate("The owner reviewed the plan. ", 4_655))

    assert {:ok, %{memory_written: true}} = Summarizer.run_cycle(local_opts(repo))

    summary = stored_memory(repo).summary
    assert String.length(summary) <= 900
    # Cut at a sentence end, not mid-word.
    assert String.ends_with?(summary, "plan.")

    {:ok, recall} =
      Recall.query("today",
        repo: repo,
        now: DateTime.from_unix!(1_000, :millisecond),
        timezone: "Etc/UTC"
      )

    assert String.length(recall) < 2_000
  end

  test "a summary with no sentence end is hard-cut and marked", %{repo: repo} do
    enable(summarizer: :local)
    insert(repo, [event(1, 1_000, "some text here")])
    Process.put(:ch_content, String.duplicate("x", 5_000))

    assert {:ok, %{memory_written: true}} = Summarizer.run_cycle(local_opts(repo))

    summary = stored_memory(repo).summary
    assert String.length(summary) == 901
    assert String.ends_with?(summary, "…")
  end

  # --- accretion + cursor -------------------------------------------------

  test "overlap_loss: a late event reaching back never hides the earlier memory", %{repo: repo} do
    enable(summarizer: :local)

    Process.put(:ch_content, "reviewed the quarterly plan")
    insert(repo, [event(1, 1_000, "a"), event(2, 2_000, "b")])
    assert {:ok, %{memory_written: true}} = Summarizer.run_cycle(local_opts(repo))

    # A late-flushed event whose ts reaches back inside the first memory's
    # provenance window, plus one beyond it.
    Process.put(:ch_content, "drafted the release notes")
    insert(repo, [event(3, 1_500, "c"), event(4, 2_500, "d")])
    assert {:ok, %{memory_written: true}} = Summarizer.run_cycle(local_opts(repo))

    # Both memories remain: each event was summarized exactly once, so the
    # second memory never covers the first one's sources.
    assert {:ok, 2} = Repo.computer_history_count_memories(server: repo)

    {:ok, text} =
      Recall.query("today",
        repo: repo,
        now: DateTime.from_unix!(2_500, :millisecond),
        timezone: "Etc/UTC"
      )

    assert text =~ "reviewed the quarterly plan"
    assert text =~ "drafted the release notes"
  end

  test "a cycle with no new events writes nothing", %{repo: repo} do
    enable(summarizer: :local)
    insert(repo, [event(1, 1_000, "a")])
    assert {:ok, %{memory_written: true}} = Summarizer.run_cycle(local_opts(repo))

    # Second cycle: cursor is past every event.
    assert {:ok, %{memory_written: false, events: 0}} = Summarizer.run_cycle(local_opts(repo))
  end

  # --- stored artifacts are ranked and bounded (§9.4) ---------------------

  describe "stored artifacts" do
    test "artifact_noise: the title most of the batch carried leads a bounded list", %{repo: repo} do
      incidental =
        Enum.map(1..60, fn index ->
          raw_event(index, 1_000 + index, %{
            type: "window.focused",
            bundle_id: "com.apple.Safari",
            window_title: "incidental-#{index}"
          })
        end)

      carried =
        Enum.map(61..70, fn index ->
          raw_event(index, 2_000 + index, %{
            type: "window.focused",
            bundle_id: "com.apple.Safari",
            window_title: "Apollo migration plan"
          })
        end)

      enable(summarizer: :local)
      insert(repo, incidental ++ carried)

      assert {:ok, %{memory_written: true}} = Summarizer.run_cycle(local_opts(repo))

      titles = repo |> stored_memory() |> Map.fetch!(:titles) |> Jason.decode!()
      assert length(titles) == 12
      assert hd(titles) == "Apollo migration plan"
    end

    test "page_title_loss: a page title with no window title is still a stored title", %{
      repo: repo
    } do
      enable(summarizer: :local)

      insert(repo, [
        raw_event(1, 1_000, %{
          type: "browser.navigated",
          bundle_id: "com.apple.Safari",
          page_title: "Q3 Report — Docs",
          host: "docs.example.com",
          url: "https://docs.example.com/q3"
        })
      ])

      assert {:ok, %{memory_written: true}} = Summarizer.run_cycle(local_opts(repo))

      memory = stored_memory(repo)
      assert Jason.decode!(memory.titles) == ["Q3 Report — Docs"]
      assert Jason.decode!(memory.urls) == ["https://docs.example.com/q3"]
      assert Jason.decode!(memory.sites) == ["docs.example.com"]
    end
  end

  # --- rendered input (§10) ----------------------------------------------

  describe "rendered input" do
    test "missing_evidence: url, flags, coverage markers and gap bounds all reach the model", %{
      repo: repo
    } do
      enable(summarizer: :local)

      insert(repo, [
        raw_event(1, 1_000, %{
          type: "browser.navigated",
          bundle_id: "com.apple.Safari",
          page_title: "Migration plan",
          host: "docs.example.com",
          url: "https://docs.example.com/apollo/plan",
          content_withheld: true,
          char_len: 4_211,
          scan_flag: "injection"
        }),
        raw_event(2, 2_000, %{
          type: "observer.gap",
          gap_reason: "sleep",
          gap_from_ts: 1_200,
          gap_to_ts: 1_900
        })
      ])

      assert {:ok, %{memory_written: true}} = Summarizer.run_cycle(local_opts(repo))

      [call] = calls()
      input = user_message(call)
      assert input =~ "Activity events (Jan 1, times in Etc/UTC):"
      assert input =~ ~s(url="https://docs.example.com/apollo/plan")
      assert input =~ ~s(page="Migration plan")
      assert input =~ "host=docs.example.com"
      assert input =~ "withheld"
      assert input =~ "chars=4211"
      assert input =~ "flag=injection"
      assert input =~ "gap=sleep 00:00:01→00:00:01"
    end

    test "long_field_tail: the end of a long value survives the clip", %{repo: repo} do
      enable(summarizer: :local)
      text = String.duplicate("x", 5_600) <> " The decision is to postpone the migration."
      insert(repo, [event(1, 1_000, text)])

      assert {:ok, %{memory_written: true}} = Summarizer.run_cycle(local_opts(repo))

      input = calls() |> hd() |> user_message()
      assert input =~ "The decision is to postpone the migration."
      assert input =~ "chars omitted…]"
    end

    test "500 identical field values render as one line with a repeat count", %{repo: repo} do
      enable(summarizer: :local)

      insert(
        repo,
        Enum.map(1..500, fn seq -> event(seq, 1_000 + seq, "unchanged draft text") end)
      )

      assert {:ok, %{memory_written: true, events: 500}} = Summarizer.run_cycle(local_opts(repo))

      input = calls() |> hd() |> user_message()
      assert input =~ "×500"
      # One header line plus exactly one event line.
      assert length(String.split(input, "\n")) == 2
    end

    test "a growing field renders only what changed", %{repo: repo} do
      enable(summarizer: :local)
      base = String.duplicate("a", 400)

      insert(repo, [
        field_event(1, 1_000, "Body", base),
        field_event(2, 2_000, "Body", base <> " and then the new sentence.")
      ])

      assert {:ok, %{memory_written: true}} = Summarizer.run_cycle(local_opts(repo))

      input = calls() |> hd() |> user_message()
      assert input =~ "text(unchanged first 400 chars)=\" and then the new sentence.\""
    end

    test "the batch header spans the earliest and latest event, not the id order", %{repo: repo} do
      enable(summarizer: :local)

      # A late-flushed event: id order puts the LATER day first.
      insert(repo, [
        raw_event(1, ms(~U[2026-08-16 10:00:00Z]), %{bundle_id: "com.a"}),
        raw_event(2, ms(~U[2026-08-15 09:00:00Z]), %{bundle_id: "com.a"})
      ])

      assert {:ok, _cycle} = Summarizer.run_cycle(local_opts(repo))

      input = calls() |> hd() |> user_message()
      assert input =~ "Activity events (Aug 15–Aug 16, times in Etc/UTC):"
    end

    test "an unusable timezone renders the batch header in UTC", %{repo: repo} do
      enable(summarizer: :local)
      insert(repo, [event(1, 1_000, "text")])

      assert {:ok, _cycle} =
               Summarizer.run_cycle(local_opts(repo, timezone: "America/New York"))

      input = calls() |> hd() |> user_message()
      assert input =~ "times in Etc/UTC"
      refute input =~ "America/New York"
    end

    test "two unlabelled fields are never collapsed into a delta", %{repo: repo} do
      enable(summarizer: :local)
      base = String.duplicate("u", 340)

      insert(repo, [
        raw_event(1, 1_000, %{
          type: "field.value",
          bundle_id: "com.apple.TextEdit",
          text: base <> " first"
        }),
        raw_event(2, 2_000, %{
          type: "field.value",
          bundle_id: "com.apple.TextEdit",
          text: base <> " second"
        })
      ])

      assert {:ok, %{memory_written: true, events: 2}} = Summarizer.run_cycle(local_opts(repo))

      input = calls() |> hd() |> user_message()
      # Without a label these are two different fields, not one field edited.
      refute input =~ "text(unchanged first"
      assert input =~ "#{base} first"
      assert input =~ "#{base} second"
    end

    test "input_budget: the batch is cut to the budget and the next batch continues", %{
      repo: repo
    } do
      enable(summarizer: :local)

      events =
        Enum.map(1..500, fn seq ->
          event(seq, 1_000 + seq, "#{seq}-#{String.duplicate("z", 4_000)}")
        end)

      insert(repo, events)
      # A maximal note: every batch after the first carries the previous one's
      # summary, and it comes out of the same budget as the events.
      Process.put(:ch_content, String.duplicate("The owner reviewed the migration plan. ", 24))

      assert {:ok, %{memory_written: true, events: summarized}} =
               Summarizer.run_cycle(local_opts(repo))

      messages = Enum.map(ordered_calls(), &user_message/1)
      assert Enum.all?(messages, &(String.length(&1) <= 60_000))
      assert messages |> Enum.at(1) |> String.starts_with?("Previous note (continuity only")
      # One `text="` per rendered event: the cycle's count is what was rendered.
      rendered = Enum.map(messages, &(length(String.split(&1, "text=\"")) - 1))
      assert Enum.sum(rendered) == summarized
      assert summarized < 500

      # The second call starts where the first stopped — the cursor advanced only
      # past what was rendered.
      first_count = hd(rendered)
      assert messages |> Enum.at(1) |> String.contains?("text=\"#{first_count + 1}-")
    end

    test "a 70,000-char gap reason still renders one line and advances the cursor", %{repo: repo} do
      enable(summarizer: :local)

      gap = %{
        boot_id: "b1",
        source_seq: 1,
        ts: 1_000,
        type: "observer.gap",
        gap_reason: String.duplicate("g", 70_000),
        gap_from_ts: 900,
        gap_to_ts: 1_000
      }

      # App-less, so an empty allowlist still admits it (§8.4 metadata kinds).
      assert {:ok, %{written: 1}} = Ingest.ingest([gap], repo: repo, apps: [], sites: [])

      assert {:ok, %{memory_written: true, events: 1}} = Summarizer.run_cycle(local_opts(repo))

      input = calls() |> hd() |> user_message()
      assert String.length(input) <= 60_000
      assert length(String.split(input, "\n")) == 2

      {:ok, state} = Repo.computer_history_fetch_state(server: repo)
      assert state.last_summarized_id > 0
    end

    test "a 70,000-char event type still renders one line and advances the cursor", %{repo: repo} do
      enable(summarizer: :local)

      event = %{
        boot_id: "b1",
        source_seq: 1,
        ts: 1_000,
        type: String.duplicate("k", 70_000),
        bundle_id: "com.apple.Safari"
      }

      assert {:ok, %{written: 1}} =
               Ingest.ingest([event], repo: repo, apps: ["com.apple.Safari"], sites: [])

      assert {:ok, %{memory_written: true, events: 1}} = Summarizer.run_cycle(local_opts(repo))

      input = calls() |> hd() |> user_message()
      assert String.length(input) <= 60_000

      {:ok, state} = Repo.computer_history_fetch_state(server: repo)
      assert state.last_summarized_id > 0
    end

    test "one oversized event still fits: a line is bounded by clipping", %{repo: repo} do
      enable(summarizer: :local)

      insert(repo, [
        raw_event(1, 1_000, %{
          type: "field.value",
          bundle_id: "com.apple.TextEdit",
          window_title: String.duplicate("w", 100_000),
          field_label: String.duplicate("f", 100_000),
          text: String.duplicate("t", 100_000)
        })
      ])

      assert {:ok, %{memory_written: true, events: 1}} = Summarizer.run_cycle(local_opts(repo))

      input = calls() |> hd() |> user_message()
      assert String.length(input) <= 60_000
    end
  end

  # --- continuity (§10) ---------------------------------------------------

  describe "continuity" do
    test "the previous note is offered as context to the next batch", %{repo: repo} do
      enable(summarizer: :local)
      Process.put(:ch_content, "Drafted the Apollo migration plan.")
      insert(repo, [event(1, 1_000, "a")])
      assert {:ok, %{memory_written: true}} = Summarizer.run_cycle(local_opts(repo))

      Process.put(:ch_content, "Continued the plan.")
      insert(repo, [event(2, 60_000, "b")])
      assert {:ok, %{memory_written: true}} = Summarizer.run_cycle(local_opts(repo))

      second = ordered_calls() |> Enum.at(1) |> user_message()

      assert second =~
               "Previous note (continuity only; new evidence wins): " <>
                 "Drafted the Apollo migration plan."
    end

    test "an oversized legacy note cannot starve the render budget", %{repo: repo} do
      enable(summarizer: :local)

      # A memory written before the summary cap existed, inside the 2 h window.
      {:ok, _id} =
        Repo.computer_history_insert_memory(
          %{
            created_at: 1_000,
            provenance_from_ts: 500,
            provenance_to_ts: 1_000,
            summary: String.duplicate("legacy ", 20_000),
            model: "ollama",
            event_count: 1
          },
          server: repo
        )

      insert(repo, [event(1, 60_000, "a normal field value")])

      assert {:ok, %{memory_written: true, events: 1}} = Summarizer.run_cycle(local_opts(repo))

      message = calls() |> hd() |> user_message()
      assert String.length(message) <= 60_000
      assert message =~ "Activity events ("

      {:ok, state} = Repo.computer_history_fetch_state(server: repo)
      assert state.last_summarized_id > 0
    end

    test "a note older than the continuity window is not offered", %{repo: repo} do
      enable(summarizer: :local)
      Process.put(:ch_content, "Drafted the Apollo migration plan.")
      insert(repo, [event(1, 1_000, "a")])
      assert {:ok, %{memory_written: true}} = Summarizer.run_cycle(local_opts(repo))

      # Three hours later: a different sitting.
      insert(repo, [event(2, 1_000 + 3 * 3_600_000, "b")])
      assert {:ok, %{memory_written: true}} = Summarizer.run_cycle(local_opts(repo))

      second = ordered_calls() |> Enum.at(1) |> user_message()
      refute second =~ "Previous note"
    end
  end

  # --- bounded catch-up (§10) --------------------------------------------

  describe "catch-up" do
    test "batch_boundary: a full batch and its successor are summarized in one cycle", %{
      repo: repo
    } do
      enable(summarizer: :local)

      incidental =
        Enum.map(1..500, fn seq ->
          raw_event(seq, 1_000 + seq, %{
            type: "window.focused",
            bundle_id: "com.apple.Safari",
            window_title: "incidental-#{seq}"
          })
        end)

      important =
        raw_event(501, 2_000, %{
          type: "window.focused",
          bundle_id: "com.apple.mail",
          window_title: "IMPORTANT-DEADLINE"
        })

      insert(repo, incidental ++ [important])

      assert {:ok, %{memory_written: true, events: 501}} = Summarizer.run_cycle(local_opts(repo))

      messages = Enum.map(ordered_calls(), &user_message/1)
      assert length(messages) == 2
      refute hd(messages) =~ "IMPORTANT-DEADLINE"
      assert Enum.at(messages, 1) =~ "IMPORTANT-DEADLINE"
    end

    test "the catch-up loop stops after its batch cap", %{repo: repo} do
      enable(summarizer: :local)
      insert(repo, Enum.map(1..35, fn seq -> event(seq, 1_000 + seq, "text-#{seq}") end))

      # Seven full batches of five are available; the cycle takes six.
      assert {:ok, %{events: 30}} = Summarizer.run_cycle(local_opts(repo, limit: 5))
      assert length(calls()) == 6

      {:ok, state} = Repo.computer_history_fetch_state(server: repo)
      assert state.last_summarized_id == 30
    end

    test "a route failure on the second batch keeps the first batch's memory", %{repo: repo} do
      enable(summarizer: :local)
      insert(repo, Enum.map(1..4, fn seq -> event(seq, 1_000 + seq, "text-#{seq}") end))
      Process.put(:ch_behavior, {:error_after, 1})

      assert {:error, :provider_unavailable} = Summarizer.run_cycle(local_opts(repo, limit: 2))

      assert {:ok, 1} = Repo.computer_history_count_memories(server: repo)
      {:ok, state} = Repo.computer_history_fetch_state(server: repo)
      assert state.last_summarized_id == 2
      assert state.paused_reason == "route_down"
    end
  end
end
