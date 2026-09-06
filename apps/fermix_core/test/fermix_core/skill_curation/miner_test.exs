defmodule FermixCore.SkillCuration.MinerTest do
  use ExUnit.Case, async: true

  alias FermixCore.SkillCuration.Miner
  alias FermixTestSupport.ComputerHistoryCanary

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

  # MILESTONE_32 §13.6 / inv. 20 — skill curation is a surface that re-sends
  # conversation content (checkpoint summaries), so an activity-derived
  # checkpoint must never ride a chain that is not permitted to carry history.
  describe "history-tainted entries (§13.6)" do
    # async: false is unnecessary here: none of these assert on the ambient
    # Computer History config. A tainted entry rides only a LOOPBACK chain,
    # which is permitted for every grant set, and the remote/adapter cases fail
    # closed for every grant set. No test mutates the app env.
    defp tainted_entry(index, text) do
      Map.put(entry(index, text), :history_tainted, true)
    end

    defp local_routes,
      do: [
        {%{provider: :ollama, model: "llama3", base_url: "http://127.0.0.1:11434/v1"},
         [adapter: QueueAdapter]},
        {%{provider: :ollama, model: "llama3", base_url: "http://localhost:11434/v1"},
         [adapter: QueueAdapter]}
      ]

    defp remote_routes,
      do: [
        {%{provider: :openai, model: "gpt-x", base_url: "https://api.openai.com/v1"},
         [adapter: QueueAdapter]}
      ]

    defp mine_over(replies, opts, entries) do
      queue = start_queue!(replies)

      Miner.mine(
        inputs(%{history: %{entries: entries}}),
        Keyword.merge(opts, adapter_opts: [test_pid: self(), queue: queue])
      )
    end

    defp corpus(canary) do
      [
        entry("m1", "chase the unpaid invoices for acme"),
        entry("m2", "again: chase unpaid invoices please"),
        entry("m3", "invoice chasing time, same as before"),
        tainted_entry("m4", "summary of earlier work: you were reading #{canary}")
      ]
    end

    test "a loopback chain carries the tainted entry into the prompt" do
      canary = ComputerHistoryCanary.token("mine_local")

      assert {:ok, result} =
               mine_over([reply_json([])], [routes: local_routes()], corpus(canary))

      assert result.dropped_history_tainted == 0
      assert_receive {:miner_call, [_system, user]}
      assert ComputerHistoryCanary.present?(user.content, canary)
    end

    test "an ungranted-remote chain drops it from the prompt and counts it" do
      canary = ComputerHistoryCanary.token("mine_remote")

      assert {:ok, result} =
               mine_over([reply_json([])], [routes: remote_routes()], corpus(canary))

      assert result.dropped_history_tainted == 1
      assert_receive {:miner_call, messages}
      assert ComputerHistoryCanary.absent?(messages, canary)
      refute Enum.any?(messages, &(&1.content =~ "m4 |"))
    end

    test "a dropped entry cannot ground a candidate — its m-ref no longer exists" do
      canary = ComputerHistoryCanary.token("mine_ground")

      cites_dropped =
        candidate_json(%{
          "evidence" => [
            %{"ref" => "m1", "quote" => "chase"},
            %{"ref" => "m2", "quote" => "chase"},
            %{"ref" => "m4", "quote" => "you were reading"}
          ]
        })

      assert {:ok, result} =
               mine_over([reply_json([cites_dropped])], [routes: remote_routes()], corpus(canary))

      assert result.candidates == []
      assert result.dropped_grounding == 1
      assert result.dropped_history_tainted == 1
    end

    test "the same candidate grounds fine on a loopback chain" do
      canary = ComputerHistoryCanary.token("mine_ok")

      cites_tainted =
        candidate_json(%{
          "evidence" => [
            %{"ref" => "m1", "quote" => "chase"},
            %{"ref" => "m2", "quote" => "chase"},
            %{"ref" => "m4", "quote" => "you were reading"}
          ]
        })

      assert {:ok, %{candidates: [candidate]}} =
               mine_over([reply_json([cites_tainted])], [routes: local_routes()], corpus(canary))

      assert Enum.map(candidate.evidence, & &1.ref) == ["m1", "m2", "m4"]
    end

    test "an adapter-only context has no chain and fails closed" do
      canary = ComputerHistoryCanary.token("mine_adapter")

      assert {:ok, result} =
               mine_over([reply_json([])], [adapter: QueueAdapter], corpus(canary))

      assert result.dropped_history_tainted == 1
      assert_receive {:miner_call, messages}
      assert ComputerHistoryCanary.absent?(messages, canary)
    end

    test "a route_key seam gates on that single route" do
      canary = ComputerHistoryCanary.token("mine_route_key")
      loopback = %{provider: :ollama, model: "llama3", base_url: "http://127.0.0.1:11434/v1"}

      assert {:ok, result} =
               mine_over(
                 [reply_json([])],
                 [route_key: loopback, adapter: QueueAdapter],
                 corpus(canary)
               )

      # `:adapter` short-circuits routing in `provider_turn/2`, so the gate must
      # read the same world: no chain, fail closed. (A real cycle never passes
      # both; this pins the precedence so the gate can never inspect a chain the
      # call did not run on.)
      assert result.dropped_history_tainted == 1
    end

    test "an untainted corpus is untouched on every chain shape" do
      for opts <- [[routes: local_routes()], [routes: remote_routes()], [adapter: QueueAdapter]] do
        assert {:ok, result} = mine_over([reply_json([])], opts, inputs(%{}).history.entries)
        assert result.dropped_history_tainted == 0
        assert_receive {:miner_call, [_system, user]}
        assert user.content =~ "m4 | 2026-07-20"
      end
    end
  end
end
