defmodule FermixCore.PhoneCalls.OutcomeReportTest do
  # `Outcome.to_report/1` fits the ledger's bounds after encoding: the worst
  # case the claim's bounds allow is written through the real ledger, on an
  # isolated Repo of its own, and read back whole. Every name, number and id
  # is invented; numbers are in the 555-01XX range.
  use ExUnit.Case, async: true

  alias FermixCore.Memory.Repo
  alias FermixCore.PhoneCalls.Brief
  alias FermixCore.PhoneCalls.Ledger
  alias FermixCore.PhoneCalls.Outcome
  alias FermixCore.PhoneCalls.Outcome.Claim

  @t0 ~U[2031-03-04 15:00:00.000000Z]
  @now ~U[2026-11-18 16:00:00Z]

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-phone-outcome-report-#{unique}.db")
    repo = :"phone_outcome_report_repo_#{unique}"
    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path}, id: repo)

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    %{opts: [server: repo]}
  end

  defp brief do
    {:ok, brief} =
      Brief.new(
        %{
          "destination" => "+13125550123",
          "destination_kind" => "business",
          "number_source" => "Listed on the restaurant's own website.",
          "contact_name" => "Marrow & Sage",
          "timezone" => "America/Chicago",
          "goal" => "Reserve a table for four on Saturday, December 5, 2026 at 7:30 PM.",
          "completion_criteria" => ["The restaurant confirms a table for four."],
          "must_not_commit" => ["a deposit"],
          "times" => [%{"label" => "Requested table", "at" => "2026-12-05T19:30"}]
        },
        caller_number: "+14155550142",
        now: @now
      )

    brief
  end

  defp said(speaker, text, start_ms),
    do: %{speaker: speaker, text: text, start_ms: start_ms, end_ms: start_ms + 2_000}

  defp call do
    [
      said(:remote, "A table for four, Saturday December 5th at 7:30, reference 4417.", 0),
      said(:assistant, "So four on December 5 at 7:30 PM. Is that booked?", 2_500),
      said(:remote, "Yes, it's booked. We have 6:00, 6:15, 6:30, 6:45, 8:45 or 9:00 too.", 5_000)
    ]
  end

  # Values at their bound: all quotes (twice their size once escaped), all
  # control characters (six times, before they are stripped), and a mix with
  # backslashes and a line separator.
  @quotes String.duplicate(~s("), 200)
  @controls String.duplicate("\u0001", 199) <> "x"
  @mixed String.duplicate("\"\\\u0001\u2028", 50) |> binary_part(0, 200)

  defp claim(overrides) do
    %{
      "outcome" => "confirmed",
      "commitment" => "completed",
      "confirmation_quote" => "Yes, it's booked",
      "criteria" => [%{"index" => 1, "quote" => "A table for four"}],
      "facts" => [
        %{"field" => "date", "value" => "2026-12-05", "quote" => "Saturday December 5th"},
        %{"field" => "local_time", "value" => "19:30", "quote" => "at 7:30"},
        %{"field" => "party", "value" => @quotes, "quote" => "A table for four"},
        %{"field" => "terms", "value" => @controls, "quote" => "Saturday December 5th"},
        %{"field" => "reference", "value" => @mixed, "quote" => "reference 4417"}
      ],
      "note" => String.duplicate(~s("), 400)
    }
    |> Map.merge(overrides)
    |> Claim.from_map()
    |> then(fn {:ok, claim} -> claim end)
  end

  defp written!(report, ctx) do
    attrs = %{
      request_id: "main-#{System.unique_integer([:positive])}",
      owner_id: "default",
      authorization: "direct",
      origin_kind: "chat",
      origin_conversation: ["telegram", "40017", "root"],
      delivery_mode: "origin",
      platform: "telegram",
      destination: "40017",
      mandate: %{"destination" => "+13125550123"},
      mandate_hash: String.duplicate("a1", 32),
      model: "gpt-live-1",
      voice: "marin",
      prompt_version: "phone-1",
      carrier_profile: "telnyx_credential_connection"
    }

    {:ok, {:admitted, row}} = Ledger.admit(attrs, @t0, ctx.opts)
    {:ok, _row} = Ledger.claim_dispatch(row.id, @t0, ctx.opts)
    {:ok, _row} = Ledger.record_session(row.id, "sess_#{row.id}", @t0, ctx.opts)

    assert {:ok, _row} =
             Ledger.terminalize(row.id, "ended", Map.put(report, :ended_at, @t0), ctx.opts)

    {:ok, stored} = Ledger.get(row.id, ctx.opts)
    stored
  end

  # One owner per number: the outcome's excerpts and the record's fitting read
  # the ledger's own bounds.
  test "a report is fitted to the ledger's own bounds" do
    assert Outcome.Record.bounds() == Ledger.report_bounds()
  end

  test "a confirmed outcome at the claim's worst case is written whole", ctx do
    outcome = Outcome.verify(brief(), call(), claim(%{}))
    assert outcome.outcome == :confirmed

    report = Outcome.to_report(outcome)
    stored = written!(report, ctx)

    assert stored.outcome == "confirmed"
    assert stored.outcome_facts == Jason.decode!(Jason.encode!(report.outcome_facts))
    assert Enum.map(stored.evidence, & &1["text"]) == Enum.map(report.evidence, & &1.text)
    assert stored.outcome_uncertainty == report.uncertainty

    for {_key, value} <- report.outcome_facts,
        is_binary(value),
        do: refute(value =~ ~r/[\p{Cc}\x{2028}\x{2029}]/u)
  end

  test "options at the claim's worst case are written whole", ctx do
    options =
      for minutes <- ~w(6:00 6:15 6:30 6:45 8:45 9:00),
          do: %{"value" => @quotes, "quote" => minutes}

    outcome =
      Outcome.verify(
        brief(),
        call(),
        claim(%{"outcome" => "options", "commitment" => "offered", "options" => options})
      )

    assert {outcome.outcome, length(outcome.options)} == {:options, 6}

    report = Outcome.to_report(outcome)
    stored = written!(report, ctx)

    assert stored.outcome_facts == Jason.decode!(Jason.encode!(report.outcome_facts))
  end

  # The worker adds the end tool's note after `to_report/1`; whoever adds
  # fits again, and nothing the addition carried escapes the one-line rule.
  test "a report added to afterwards is fitted again, whole", ctx do
    options =
      for minutes <- ~w(6:00 6:15 6:30 6:45 8:45 9:00),
          do: %{"value" => @quotes, "quote" => minutes}

    claim = claim(%{"outcome" => "options", "commitment" => "offered", "options" => options})
    report = brief() |> Outcome.verify(call(), claim) |> Outcome.to_report()
    end_note = String.duplicate("\u0001\"", 150)
    added = put_in(report, [:outcome_facts, "note"], end_note)

    fitted = Outcome.fit_report(added)

    assert byte_size(Jason.encode!(fitted.outcome_facts)) <=
             Ledger.report_bounds().facts_json_bytes

    for {_key, value} <- fitted.outcome_facts,
        is_binary(value),
        do: refute(value =~ ~r/[\p{Cc}\x{2028}\x{2029}]/u)

    assert written!(fitted, ctx).outcome_facts ==
             Jason.decode!(Jason.encode!(fitted.outcome_facts))
  end

  # A hand-built outcome past every bound: the least important entries go
  # first, the rest shorten, and the uncertainty says details were left out.
  test "any outcome is fitted, deterministically, in the stated order", ctx do
    huge = String.duplicate("\"", 3_000)

    outcome = %Outcome{
      outcome: :confirmed,
      confirmation: :stated,
      facts: %{
        date: "2026-12-05",
        local_time: "19:30",
        timezone: "America/Chicago",
        party: huge,
        terms: huge,
        reference: huge,
        commitment: "completed",
        confirmation: "the recipient stated the details"
      },
      basis: %{
        date: :verified,
        local_time: :verified,
        party: :read,
        terms: :read,
        reference: :read
      },
      options: List.duplicate(huge, 6),
      extraction_note: huge,
      excerpts: [%{speaker: :remote, text: "Yes, it's booked", start_ms: 0, end_ms: 1}],
      uncertainty: String.duplicate("u", 600)
    }

    report = Outcome.to_report(outcome)

    assert report == Outcome.to_report(outcome)

    assert byte_size(Jason.encode!(report.outcome_facts)) <=
             Ledger.report_bounds().facts_json_bytes

    assert byte_size(report.uncertainty) <= Ledger.report_bounds().text_bytes
    assert report.uncertainty =~ Outcome.reason(:details_left_out)

    facts = report.outcome_facts

    for left_out <- ~w(extraction_note options terms party reference),
        do: refute(Map.has_key?(facts, left_out))

    assert %{
             "date" => "2026-12-05",
             "local_time" => "19:30",
             "verified" => ["date", "local_time"]
           } =
             facts

    refute Map.has_key?(facts, "read")

    assert written!(report, ctx).outcome_facts == Jason.decode!(Jason.encode!(facts))
  end
end
