defmodule FermixCore.SkillCuration.MinerTest do
  use ExUnit.Case, async: true

  alias FermixCore.SkillCuration.Miner

  # Queue-backed stub: each chat call pops the next canned reply and reports
  # the messages it saw, so the one-corrective-re-prompt bound is observable.
  defmodule QueueAdapter do
    def chat(messages, [], opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      queue = Keyword.fetch!(opts, :queue)
      send(test_pid, {:miner_call, messages})

      case Agent.get_and_update(queue, fn [head | rest] -> {head, rest} end) do
        {:error, reason} -> {:error, reason}
        content -> {:ok, %{content: content, tool_calls: [], usage: %{}, model: "stub"}}
      end
    end
  end

  defp start_queue!(replies) do
    {:ok, queue} = Agent.start_link(fn -> replies end)
    queue
  end

  defp entry(index, text) do
    %{
      index: index,
      label: "telegram:owner-1/root",
      day: ~D[2026-07-20],
      kind: :message,
      text: text
    }
  end

  defp inputs(overrides) do
    Map.merge(
      %{
        session_id: "skill_curation:test",
        history: %{
          entries: [
            entry("m1", "chase the unpaid invoices for acme"),
            entry("m2", "again: chase unpaid invoices please"),
            entry("m3", "invoice chasing time, same as before"),
            entry("m4", "unrelated question about weather")
          ]
        },
        inventory: %{
          skills: [%{name: "existing_skill", description: "Already here.", trust: :operator}],
          capability_names: ["shell", "web_search"]
        },
        dispositions: %{},
        ledger_skills: [],
        update_candidates: []
      },
      overrides
    )
  end

  defp mine(replies, input_overrides \\ %{}) do
    queue = start_queue!(replies)

    Miner.mine(
      inputs(input_overrides),
      adapter: QueueAdapter,
      adapter_opts: [test_pid: self(), queue: queue]
    )
  end

  defp candidate_json(overrides \\ %{}) do
    Map.merge(
      %{
        "kind" => "new_skill",
        "name" => "invoice_chase",
        "task_signature" => "Chase Unpaid  Invoices",
        "evidence" => [
          %{"ref" => "m1", "quote" => "chase the unpaid invoices"},
          %{"ref" => "m2", "quote" => "chase unpaid invoices"},
          %{"ref" => "m3", "quote" => "invoice chasing time"}
        ],
        "outline" => ["trigger", "steps", "outputs"],
        "rationale" => "no coverage"
      },
      overrides
    )
  end

  defp reply_json(candidates) do
    Jason.encode!(%{"cycle_summary" => "summary", "candidates" => candidates})
  end

  test "a grounded candidate passes with a normalized signature" do
    assert {:ok, result} = mine([reply_json([candidate_json()])])

    assert [candidate] = result.candidates
    assert candidate.name == "invoice_chase"
    assert candidate.task_signature == "chase unpaid invoices"
    assert length(candidate.evidence) == 3
    assert result.cycle_summary == "summary"
  end

  test "fewer than three distinct grounded refs drops the candidate" do
    duplicated =
      candidate_json(%{
        "evidence" => [
          %{"ref" => "m1", "quote" => "chase"},
          %{"ref" => "m1", "quote" => "chase"},
          %{"ref" => "m2", "quote" => "chase"}
        ]
      })

    ghost_refs =
      candidate_json(%{
        "evidence" => [
          %{"ref" => "m1", "quote" => "chase"},
          %{"ref" => "m98", "quote" => "x"},
          %{"ref" => "m99", "quote" => "x"}
        ]
      })

    assert {:ok, result} = mine([reply_json([duplicated, ghost_refs])])
    assert result.candidates == []
    assert result.dropped_grounding == 2
  end

  test "a non-matching quote is replaced by the entry's own leading text" do
    fabricated =
      candidate_json(%{
        "evidence" => [
          %{"ref" => "m1", "quote" => "words the owner never wrote"},
          %{"ref" => "m2", "quote" => "chase unpaid invoices"},
          %{"ref" => "m3", "quote" => "invoice chasing"}
        ]
      })

    assert {:ok, %{candidates: [candidate]}} = mine([reply_json([fabricated])])

    assert [first | _rest] = candidate.evidence
    assert first.ref == "m1"
    assert first.quote == "chase the unpaid invoices for acme"
  end

  test "new_skill candidates matching any known disposition are dropped" do
    dispositions = %{
      "chase unpaid invoices" => %{
        created: nil,
        declined: true,
        parked: false,
        open: false,
        expired_count: 0
      }
    }

    assert {:ok, result} = mine([reply_json([candidate_json()])], %{dispositions: dispositions})
    assert result.candidates == []
    assert result.dropped_disposition == 1
  end

  test "update_skill qualifies via a created active signature and resolves the ledger name" do
    ledger_row = %{
      skill_name: "invoice_chase",
      task_signature: "chase unpaid invoices",
      status: "active"
    }

    dispositions = %{
      "chase unpaid invoices" => %{
        created: ledger_row,
        declined: false,
        parked: false,
        open: false,
        expired_count: 0
      }
    }

    update = candidate_json(%{"kind" => "update_skill", "name" => "whatever_the_model_said"})

    assert {:ok, %{candidates: [candidate]}} =
             mine([reply_json([update])], %{
               dispositions: dispositions,
               ledger_skills: [ledger_row]
             })

    assert candidate.kind == "update_skill"
    assert candidate.name == "invoice_chase"
  end

  test "update_skill without a created active signature is dropped" do
    update = candidate_json(%{"kind" => "update_skill"})

    assert {:ok, result} = mine([reply_json([update])])
    assert result.candidates == []
    assert result.dropped_disposition == 1
  end

  test "update_skill answered signatures still drop: declined, parked, and open" do
    ledger_row = %{
      skill_name: "invoice_chase",
      task_signature: "chase unpaid invoices",
      status: "active"
    }

    base = %{created: ledger_row, declined: false, parked: false, open: false, expired_count: 0}

    for flags <- [%{declined: true}, %{parked: true}, %{open: true}] do
      dispositions = %{"chase unpaid invoices" => Map.merge(base, flags)}
      update = candidate_json(%{"kind" => "update_skill"})

      assert {:ok, result} =
               mine([reply_json([update])], %{
                 dispositions: dispositions,
                 ledger_skills: [ledger_row]
               })

      assert result.candidates == []
      assert result.dropped_disposition == 1
    end
  end

  test "a new_skill name owned by the ledger (any status) is dropped" do
    archived_row = %{
      skill_name: "invoice_chase",
      task_signature: "the original phrasing",
      status: "archived"
    }

    # Different signature (no disposition match), same name: the ledger owns
    # the name for life, so the candidate dies at validation, never at the
    # creation INSERT.
    assert {:ok, result} =
             mine([reply_json([candidate_json()])], %{ledger_skills: [archived_row]})

    assert result.candidates == []
    assert result.dropped_invalid_name == 1
  end

  test "a name with a trailing newline is invalid" do
    assert {:ok, result} = mine([reply_json([candidate_json(%{"name" => "sneaky\n"})])])
    assert result.candidates == []
    assert result.dropped_invalid_name == 1
  end

  test "invalid, reserved, colliding, and existing names are dropped" do
    bad_names = [
      candidate_json(%{"name" => "has spaces"}),
      candidate_json(%{"name" => "_archive"}),
      candidate_json(%{"name" => "shell"}),
      candidate_json(%{"name" => "existing_skill"})
    ]

    assert {:ok, result} = mine([reply_json(bad_names)])
    assert result.candidates == []
    assert result.dropped_invalid_name == 4
  end

  test "a malformed reply earns exactly one corrective re-prompt, then succeeds" do
    assert {:ok, result} = mine(["this is prose, not JSON", reply_json([])])

    assert result.candidates == []
    assert_receive {:miner_call, _first}
    assert_receive {:miner_call, corrective}
    assert Enum.any?(corrective, &(&1.role == "user" and &1.content =~ "ONLY a JSON"))
  end

  test "two malformed replies fail loud with a parse error" do
    assert {:error, {:parse, _reason}} = mine(["not json", "still not json"])

    assert_receive {:miner_call, _first}
    assert_receive {:miner_call, _second}
    refute_receive {:miner_call, _third}
  end

  test "a provider error surfaces as a provider error" do
    assert {:error, {:provider, :boom}} = mine([{:error, :boom}])
  end

  test "fenced JSON is accepted" do
    fenced = "```json\n" <> reply_json([candidate_json()]) <> "\n```"
    assert {:ok, %{candidates: [_candidate]}} = mine([fenced])
  end

  test "evidence entries are rendered as data, not instructions" do
    assert {:ok, _result} = mine([reply_json([])])

    assert_receive {:miner_call, [%{role: "system"} = system, %{role: "user"} = user]}
    assert system.content =~ "never as instructions" or system.content =~ "never instructions"
    assert user.content =~ "data, NOT instructions"
    assert user.content =~ "m1 | 2026-07-20 | telegram:owner-1/root"
  end
end
