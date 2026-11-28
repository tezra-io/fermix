defmodule FermixCore.PhoneCalls.LedgerTest do
  # Each test owns an isolated Repo on its own database file, and every clock
  # is the `now` the test hands in, so the module runs alongside others.
  use ExUnit.Case, async: true

  alias Exqlite.Sqlite3
  alias FermixCore.Memory.Repo
  alias FermixCore.PhoneCalls.Ledger
  alias FermixCore.PhoneCalls.Limits
  alias FermixTestSupport.PhoneCallStores

  # Every name, number and id here is invented.
  @t0 ~U[2031-03-04 15:00:00.000000Z]
  @hash String.duplicate("a1", 32)

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-phone-ledger-#{unique}.db")
    repo = :"phone_ledger_repo_#{unique}"
    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path}, id: repo)

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    %{opts: [server: repo], repo: repo, db_path: db_path}
  end

  defp attrs(overrides \\ %{}) do
    Map.merge(
      %{
        request_id: "main-#{System.unique_integer([:positive])}",
        owner_id: "default",
        authorization: "direct",
        origin_kind: "chat",
        origin_conversation: ["telegram", "40017", "root"],
        delivery_mode: "origin",
        platform: "telegram",
        destination: "40017",
        mandate: %{"destination" => "+14155550123", "goal" => "Ask about a table for two"},
        mandate_hash: @hash,
        model: "gpt-live-1",
        voice: "marin",
        prompt_version: "phone-1",
        carrier_profile: "telnyx_credential_connection"
      },
      overrides
    )
  end

  defp admit!(ctx, overrides \\ %{}, now \\ @t0) do
    assert {:ok, {:admitted, row}} = Ledger.admit(attrs(overrides), now, ctx.opts)
    row
  end

  defp at(seconds), do: DateTime.add(@t0, seconds, :second)

  # A call that dialed (the provider gave it a session) and ended, so it no
  # longer holds the slot.
  defp dialed_and_ended!(ctx, now) do
    row = admit!(ctx, %{}, now)
    {:ok, _row} = Ledger.claim_dispatch(row.id, now, ctx.opts)
    {:ok, _row} = Ledger.record_session(row.id, "sess_#{row.id}", now, ctx.opts)
    {:ok, ended} = Ledger.terminalize(row.id, "ended", %{ended_at: now}, ctx.opts)
    ended
  end

  # A call the provider gave a session, still live, so it holds the slot.
  defp dialed!(ctx) do
    row = admit!(ctx)
    {:ok, _row} = Ledger.claim_dispatch(row.id, @t0, ctx.opts)
    {:ok, row} = Ledger.record_session(row.id, "sess_#{row.id}", @t0, ctx.opts)
    row
  end

  # An uncertain call holds the slot past its end until the owner's word.
  defp slot_freed!(ctx, %{status: status} = row)
       when status in ["closure_unconfirmed", "dispatch_unknown"] do
    {:ok, _row} = Ledger.release_slot(row.id, :owner_confirmed, at(10), ctx.opts)
    :ok
  end

  defp slot_freed!(_ctx, _row), do: :ok

  # One call of every outcome a store before `finished` could hold, each made
  # by the write that makes it, its slot freed for the next.
  defp calls_of_every_outcome!(ctx) do
    said = [%{speaker: "recipient", text: "Yes, two at seven thirty is booked."}]

    confirmed = %{
      outcome: "confirmed",
      evidence: said,
      outcome_facts: %{"local_time" => "19:30"},
      usage: %{"seconds" => 120},
      voice_seconds: 120,
      usage_state: "voice_duration_confirmed",
      uncertainty: "Whether the patio is open that night."
    }

    for {status, fields} <- [
          {"ended", confirmed},
          {"ended", %{outcome: "unavailable", evidence: said}},
          {"ended", %{outcome: "options", outcome_facts: %{"options" => ["8:00 PM"]}}},
          {"ended", %{outcome: "needs_owner", backend_usage: %{"turns" => 1}}},
          {"closure_unconfirmed", %{outcome: "unknown", failure_reason: "sideband_lost"}},
          {"dispatch_unknown", %{outcome: "unknown", vendor_message: "No word on the create."}},
          {"failed", %{outcome: "unknown", failure_reason: "call_failed"}}
        ] do
      row = dialed!(ctx)
      fields = Map.put(fields, :ended_at, at(9))
      {:ok, ended} = Ledger.terminalize(row.id, status, fields, ctx.opts)
      :ok = slot_freed!(ctx, ended)
      ended
    end
  end

  defp reopen!(ctx, tag) do
    name = :"#{ctx.repo}_#{tag}"
    start_supervised!({Repo, name: name, enabled: true, database_path: ctx.db_path}, id: name)
    name
  end

  # One statement on the store with its Repo stopped: its own answer.
  defp raw(db_path, sql) do
    {:ok, conn} = Sqlite3.open(db_path)
    result = Sqlite3.execute(conn, sql)
    :ok = Sqlite3.close(conn)
    result
  end

  # A terminal call's outcome set to `finished` past the Ledger: the table's
  # own CHECK alone decides.
  defp finished_sql(id), do: "UPDATE phone_calls SET outcome = 'finished' WHERE id = '#{id}'"

  # A create that placed nothing: claimed, then failed with no session (the
  # provider refused it, or it provably never left).
  defp refused_create!(ctx, now) do
    row = admit!(ctx, %{}, now)
    {:ok, _row} = Ledger.claim_dispatch(row.id, now, ctx.opts)

    {:ok, failed} =
      Ledger.terminalize(row.id, "failed", %{ended_at: now, failure_reason: "rejected"}, ctx.opts)

    failed
  end

  # A store that never answers: every call to it reaches its timeout.
  defmodule StalledStore do
    use GenServer
    def start_link, do: GenServer.start_link(__MODULE__, :ok)
    @impl true
    def init(:ok), do: {:ok, :ok}
    @impl true
    def handle_call(_request, _from, state), do: {:noreply, state}
  end

  test "a call id is pc_ and 12 lowercase hex characters" do
    id = Ledger.generate_id()
    assert id =~ ~r/^pc_[0-9a-f]{12}$/
    assert Ledger.call_id?(id)
    refute Ledger.call_id?("hr_0123456789ab")
    refute Ledger.generate_id() == Ledger.generate_id()
  end

  describe "admission" do
    test "persists the evidence, the frozen destination, the mandate and the snapshot", ctx do
      row = admit!(ctx, %{authorization: "confirmed", access_intent: "intent-7"})

      assert row.status == "admitted"
      assert row.outcome == "pending"
      assert row.usage_state == "provisional"
      assert row.report_status == "pending"
      assert row.operation == "phone_call.start"
      assert row.authorization == "confirmed"
      assert row.access_intent == "intent-7"
      assert row.origin_conversation == ["telegram", "40017", "root"]

      assert row.mandate == %{
               "destination" => "+14155550123",
               "goal" => "Ask about a table for two"
             }

      assert row.mandate_hash == @hash
      assert {row.model, row.voice, row.prompt_version} == {"gpt-live-1", "marin", "phone-1"}
      assert row.created_at == @t0
      assert is_nil(row.provider_session_id) and is_nil(row.carrier_call_id)
      assert is_nil(row.dispatch_claimed_at)
      assert {:ok, ^row} = Ledger.get(row.id, ctx.opts)
    end

    test "the same originating request answers the call it already made", ctx do
      row = admit!(ctx, %{request_id: "req_41"})

      assert {:ok, {:existing, ^row}} =
               Ledger.admit(attrs(%{request_id: "req_41"}), at(5), ctx.opts)

      assert {:ok, [^row]} = Ledger.list_recent("default", ctx.opts)
    end

    test "the same request with a different brief is a new mandate, admitted like any other",
         ctx do
      first = admit!(ctx, %{request_id: "req_42"})
      other = String.duplicate("b3", 32)

      assert {:error, {:slot_held, holder}} =
               Ledger.admit(attrs(%{request_id: "req_42", mandate_hash: other}), at(1), ctx.opts)

      assert holder == first.id
      {:ok, _row} = Ledger.fail_undispatched(first.id, "cancelled_by_owner", at(2), ctx.opts)

      assert {:ok, {:admitted, second}} =
               Ledger.admit(attrs(%{request_id: "req_42", mandate_hash: other}), at(3), ctx.opts)

      refute second.id == first.id

      assert {:ok, {:existing, %{id: id}}} =
               Ledger.admit(attrs(%{request_id: "req_42", mandate_hash: other}), at(4), ctx.opts)

      assert id == second.id
    end

    # The review's scenario: a per-boot counter gave a turn "main-1" before a
    # restart and again after it. A row an earlier boot wrote under that id
    # never answers a new request, which carries an identity of its own.
    test "a row from an earlier boot with an old-style id never captures a new request", ctx do
      old = dialed_and_ended!(ctx, @t0)
      {:ok, _row} = Ledger.mark_report(old.id, %{report_status: "written"}, ctx.opts)

      assert {:ok, {:admitted, fresh}} =
               Ledger.admit(
                 attrs(%{request_id: "req_0a1b2c3d4e5f60718293a4b5"}),
                 at(60),
                 ctx.opts
               )

      refute fresh.id == old.id
      assert fresh.status == "admitted"
    end

    test "a second request is refused while a call holds the slot, and consumes nothing", ctx do
      row = admit!(ctx)
      assert {:error, {:slot_held, holder}} = Ledger.admit(attrs(), at(1), ctx.opts)
      assert holder == row.id
      assert {:ok, [_only]} = Ledger.list_recent("default", ctx.opts)
    end

    test "refuses malformed evidence before it reaches the store", ctx do
      assert {:error, {:invalid, :authorization, "model_said_so"}} =
               Ledger.admit(attrs(%{authorization: "model_said_so"}), @t0, ctx.opts)

      assert {:error, {:invalid, :mandate_hash, "short"}} =
               Ledger.admit(attrs(%{mandate_hash: "short"}), @t0, ctx.opts)

      assert {:error, {:invalid, :request_id, nil}} =
               Ledger.admit(Map.delete(attrs(), :request_id), @t0, ctx.opts)

      assert {:ok, []} = Ledger.list_recent("default", ctx.opts)
    end
  end

  describe "the day's attempts" do
    test "a create that placed nothing uses no attempt", ctx do
      for n <- 1..(Limits.max_attempts_per_day() + 2), do: refused_create!(ctx, at(n * 60))

      assert {:ok, {:admitted, _row}} = Ledger.admit(attrs(), at(3_600), ctx.opts)
    end

    test "a dispatch whose answer is unknown, or one with a session that then failed, counts",
         ctx do
      cap = Limits.max_attempts_per_day()
      for n <- 1..(cap - 3), do: dialed_and_ended!(ctx, at(n * 60))

      unknown_at = at(cap * 60)
      unknown = admit!(ctx, %{}, unknown_at)
      {:ok, _row} = Ledger.claim_dispatch(unknown.id, unknown_at, ctx.opts)
      ended_at = DateTime.add(unknown_at, 1, :second)

      {:ok, _row} =
        Ledger.terminalize(unknown.id, "dispatch_unknown", %{ended_at: ended_at}, ctx.opts)

      # Past the unknown dispatch's own slot, so only the day's count can refuse.
      late =
        DateTime.add(
          ended_at,
          Limits.provider_lifetime_bound_ms() + Limits.max_create_wait_ms(),
          :millisecond
        )

      for n <- 1..2 do
        row = admit!(ctx, %{}, DateTime.add(late, n, :second))
        {:ok, _row} = Ledger.claim_dispatch(row.id, DateTime.add(late, n, :second), ctx.opts)

        {:ok, _row} =
          Ledger.record_session(row.id, "sess_f#{n}", DateTime.add(late, n, :second), ctx.opts)

        {:ok, _row} =
          Ledger.terminalize(
            row.id,
            "failed",
            %{ended_at: DateTime.add(late, n, :second)},
            ctx.opts
          )
      end

      assert {:error, {:daily_attempts_exhausted, ^cap}} =
               Ledger.admit(attrs(), DateTime.add(late, 10, :second), ctx.opts)
    end

    test "the attempt past the limit in a rolling window is refused and writes nothing", ctx do
      cap = Limits.max_attempts_per_day()
      for n <- 1..cap, do: dialed_and_ended!(ctx, at(n * 60))

      assert {:error, {:daily_attempts_exhausted, ^cap}} =
               Ledger.admit(attrs(), at(3_600), ctx.opts)

      assert {:ok, rows} = Ledger.list_recent("default", ctx.opts)
      assert length(rows) == min(cap, Limits.max_recent_calls())
    end

    test "a call proven never to have dialed gives its attempt back", ctx do
      cap = Limits.max_attempts_per_day()
      for n <- 1..(cap - 1), do: dialed_and_ended!(ctx, at(n * 60))

      undialed = admit!(ctx, %{}, at(cap * 60))

      {:ok, _row} =
        Ledger.fail_undispatched(
          undialed.id,
          "cancelled_before_dispatch",
          at(cap * 60 + 1),
          ctx.opts
        )

      assert {:ok, {:admitted, _last}} = Ledger.admit(attrs(), at(cap * 60 + 100), ctx.opts)
    end

    test "the window is the attempt window ending now, its start included", ctx do
      window_s = div(Limits.attempt_window_ms(), 1_000)
      cap = Limits.max_attempts_per_day()
      for _n <- 1..cap, do: dialed_and_ended!(ctx, @t0)

      # Exactly one window later they all still count (`created_at >= start`).
      assert {:error, {:daily_attempts_exhausted, ^cap}} =
               Ledger.admit(attrs(), at(window_s), ctx.opts)

      # A microsecond past it, none does.
      later = DateTime.add(at(window_s), 1, :microsecond)
      assert {:ok, {:admitted, _row}} = Ledger.admit(attrs(), later, ctx.opts)
    end
  end

  describe "an uncertain call's slot" do
    test "the slot outlasts the latest moment the session could have started", ctx do
      row = admit!(ctx)
      {:ok, claimed} = Ledger.claim_dispatch(row.id, @t0, ctx.opts)

      bound = Limits.max_create_wait_ms() + Limits.provider_lifetime_bound_ms()
      assert claimed.slot_expires_at == DateTime.add(@t0, bound, :millisecond)
    end

    test "a dispatch_unknown call holds the slot until the provider's bound has passed", ctx do
      row = admit!(ctx)
      {:ok, claimed} = Ledger.claim_dispatch(row.id, @t0, ctx.opts)

      {:ok, unknown} =
        Ledger.terminalize(row.id, "dispatch_unknown", %{ended_at: at(30)}, ctx.opts)

      bound_s = div(Limits.max_create_wait_ms() + Limits.provider_lifetime_bound_ms(), 1_000)
      assert claimed.slot_expires_at == at(bound_s)
      assert unknown.outcome == "unknown"
      assert unknown.usage_state == "incomplete"

      assert {:error, {:slot_held, holder}} = Ledger.admit(attrs(), at(bound_s - 1), ctx.opts)
      assert holder == row.id
      assert Ledger.holds_slot?(unknown, at(bound_s - 1))

      refute Ledger.holds_slot?(unknown, at(bound_s))
      assert {:ok, {:admitted, _next}} = Ledger.admit(attrs(), at(bound_s), ctx.opts)
      assert {:ok, %{outcome: "unknown"}} = Ledger.get(row.id, ctx.opts)
    end

    test "the owner's word releases a closure_unconfirmed call's slot, outcome kept", ctx do
      row = admit!(ctx)
      {:ok, _row} = Ledger.claim_dispatch(row.id, @t0, ctx.opts)
      {:ok, _row} = Ledger.record_session(row.id, "sess_invented_1", at(1), ctx.opts)

      {:ok, _row} =
        Ledger.terminalize(row.id, "closure_unconfirmed", %{ended_at: at(60)}, ctx.opts)

      assert {:error, {:slot_held, _holder}} = Ledger.admit(attrs(), at(61), ctx.opts)

      assert {:ok, released} =
               Ledger.release_slot(row.id, :owner_confirmed, at(70), ctx.opts)

      assert released.slot_released_at == at(70)
      assert released.outcome == "unknown"
      assert {:ok, {:admitted, _next}} = Ledger.admit(attrs(), at(71), ctx.opts)

      assert {:error, {:not_releasable, "closure_unconfirmed"}} =
               Ledger.release_slot(row.id, :owner_confirmed, at(72), ctx.opts)
    end

    # Nothing verifies a termination, so nothing releases a slot that way.
    test "the owner's word is the one reason a slot is released", ctx do
      row = admit!(ctx)

      assert_raise FunctionClauseError, fn ->
        Ledger.release_slot(row.id, :verified_termination, at(1), ctx.opts)
      end
    end

    test "only an uncertain row can be released", ctx do
      row = admit!(ctx)

      assert {:error, {:not_releasable, "admitted"}} =
               Ledger.release_slot(row.id, :owner_confirmed, at(1), ctx.opts)
    end

    test "unresolved lists the uncertain rows still holding the slot", ctx do
      row = admit!(ctx)
      {:ok, _row} = Ledger.claim_dispatch(row.id, @t0, ctx.opts)
      {:ok, _row} = Ledger.terminalize(row.id, "dispatch_unknown", %{ended_at: at(1)}, ctx.opts)

      assert {:ok, [%{id: id}]} = Ledger.unresolved(at(2), ctx.opts)
      assert id == row.id
      assert {:ok, [%{id: ^id}]} = Ledger.outstanding(at(2), ctx.opts)

      bound_s = div(Limits.max_create_wait_ms() + Limits.provider_lifetime_bound_ms(), 1_000)
      assert {:ok, []} = Ledger.unresolved(at(bound_s), ctx.opts)
    end
  end

  describe "the dispatch claim" do
    test "moves admitted to dispatching with its absolute deadlines, once", ctx do
      row = admit!(ctx)
      assert {:ok, claimed} = Ledger.claim_dispatch(row.id, at(2), ctx.opts)

      assert claimed.status == "dispatching"
      assert claimed.dispatch_claimed_at == at(2)

      assert claimed.call_deadline_at ==
               DateTime.add(at(2), Limits.call_deadline_ms(), :millisecond)

      # The ring window is the session's: it starts once the session exists.
      assert is_nil(claimed.ringing_deadline_at)

      assert {:error, {:not_admitted, "dispatching"}} =
               Ledger.claim_dispatch(row.id, at(3), ctx.opts)
    end

    # A create that took 60 s still rings for the whole ring window.
    test "the ring window starts when the session is recorded, not at the claim", ctx do
      row = admit!(ctx)
      {:ok, _row} = Ledger.claim_dispatch(row.id, at(2), ctx.opts)
      assert {:ok, session} = Ledger.record_session(row.id, "sess_ring_1", at(62), ctx.opts)

      assert session.ringing_deadline_at ==
               DateTime.add(at(62), Limits.ringing_timeout_ms(), :millisecond)

      assert session.call_deadline_at ==
               DateTime.add(at(2), Limits.call_deadline_ms(), :millisecond)
    end

    test "a row cancelled before its claim can never be claimed, so it is never dialed", ctx do
      row = admit!(ctx)
      assert {:ok, failed} = Ledger.fail_undispatched(row.id, "disabled", at(1), ctx.opts)
      assert failed.status == "failed"
      assert failed.failure_reason == "disabled"
      assert failed.voice_seconds == 0

      assert {:error, {:not_admitted, "failed"}} = Ledger.claim_dispatch(row.id, at(2), ctx.opts)
    end

    test "a claimed row is never failed as undispatched", ctx do
      row = admit!(ctx)
      {:ok, _row} = Ledger.claim_dispatch(row.id, at(1), ctx.opts)

      assert {:error, {:dispatched, "dispatching"}} =
               Ledger.fail_undispatched(row.id, "disabled", at(2), ctx.opts)
    end

    test "a session id is refused on a row that never dispatched", ctx do
      row = admit!(ctx)
      assert {:error, :not_dispatched} = Ledger.record_session(row.id, "sess_x", at(1), ctx.opts)
    end

    test "an unknown id is not found", ctx do
      assert {:error, :not_found} = Ledger.claim_dispatch("pc_000000000000", @t0, ctx.opts)
    end
  end

  describe "the worker's forward steps" do
    setup ctx do
      row = admit!(ctx)
      {:ok, _row} = Ledger.claim_dispatch(row.id, @t0, ctx.opts)
      %{id: row.id}
    end

    test "the provider's session id is recorded once, exactly as given", ctx do
      assert {:ok, row} = Ledger.record_session(ctx.id, "sess_invented_2", at(1), ctx.opts)
      assert row.status == "connecting"
      assert row.provider_session_id == "sess_invented_2"
      assert row.connecting_at == at(1)
      assert is_nil(row.carrier_call_id)

      assert {:ok, ^row} = Ledger.record_session(ctx.id, "sess_invented_2", at(2), ctx.opts)

      assert {:error, :session_mismatch} =
               Ledger.record_session(ctx.id, "sess_other", at(3), ctx.opts)
    end

    test "steps go forward only; ringing is optional and a late one changes nothing", ctx do
      {:ok, _row} = Ledger.record_session(ctx.id, "sess_invented_4", at(1), ctx.opts)

      assert {:ok, %{status: "active"} = active} =
               Ledger.advance(ctx.id, "active", at(5), ctx.opts)

      assert active.answered_at == at(5)
      assert is_nil(active.ringing_at)

      assert {:ok, ^active} = Ledger.advance(ctx.id, "ringing", at(6), ctx.opts)
      assert {:ok, ^active} = Ledger.advance(ctx.id, "active", at(7), ctx.opts)

      assert {:ok, %{status: "closing"} = closing} =
               Ledger.advance(ctx.id, "closing", at(9), ctx.opts)

      assert {:ok, ^closing} = Ledger.advance(ctx.id, "active", at(10), ctx.opts)

      assert {:error, {:invalid, :step, "connecting"}} =
               Ledger.advance(ctx.id, "connecting", at(11), ctx.opts)
    end

    test "no step is taken before the session is known", ctx do
      assert {:ok, %{status: "dispatching"}} = Ledger.advance(ctx.id, "ringing", at(1), ctx.opts)
    end

    test "a terminal row takes no step", ctx do
      {:ok, _row} = Ledger.record_session(ctx.id, "sess_invented_5", at(1), ctx.opts)
      {:ok, ended} = Ledger.terminalize(ctx.id, "ended", %{ended_at: at(2)}, ctx.opts)
      assert {:ok, ^ended} = Ledger.advance(ctx.id, "active", at(3), ctx.opts)
    end

    test "a counter is consumed before its side effect, and stops at its cap", ctx do
      for n <- 1..Limits.max_dtmf_keys() do
        assert {:ok, %{dtmf_keys: ^n}} = Ledger.consume(ctx.id, :dtmf_keys, ctx.opts)
      end

      assert {:error, {:cap_reached, :dtmf_keys}} = Ledger.consume(ctx.id, :dtmf_keys, ctx.opts)
      assert {:ok, %{core_turns: 1}} = Ledger.consume(ctx.id, :core_turns, ctx.opts)
      assert {:error, {:invalid, :counter, :minutes}} = Ledger.consume(ctx.id, :minutes, ctx.opts)
    end

    test "usage snapshots replace each other, never sum, and an older one is left out", ctx do
      assert {:ok, row} = Ledger.record_usage(ctx.id, %{"seconds" => 40}, 40, ctx.opts)
      assert {row.usage, row.voice_seconds} == {%{"seconds" => 40}, 40}

      assert {:ok, row} = Ledger.record_usage(ctx.id, %{"seconds" => 95}, 95, ctx.opts)
      assert {row.usage, row.voice_seconds} == {%{"seconds" => 95}, 95}

      assert {:ok, row} = Ledger.record_usage(ctx.id, %{"seconds" => 60}, 60, ctx.opts)
      assert row.voice_seconds == 95
    end
  end

  describe "a recorded closure" do
    setup ctx do
      row = admit!(ctx)
      {:ok, _row} = Ledger.claim_dispatch(row.id, @t0, ctx.opts)
      %{id: row.id}
    end

    test "is kept on a live call once, never regresses, and changes no status", ctx do
      {:ok, _row} = Ledger.record_session(ctx.id, "sess_close_1", at(1), ctx.opts)
      {:ok, _row} = Ledger.advance(ctx.id, "active", at(2), ctx.opts)
      closure = %{at: at(90), reason: "remote_hangup", voice_seconds: 87.6}

      assert {:ok, row} = Ledger.record_closure(ctx.id, closure, ctx.opts)
      assert row.status == "active"
      assert row.closed_at == at(90)
      assert row.closure_reason == "remote_hangup"
      assert row.voice_seconds == 88

      later = %{at: at(95), reason: "close_requested", voice_seconds: 3}
      assert {:ok, ^row} = Ledger.record_closure(ctx.id, later, ctx.opts)
    end

    test "needs a known session and a live row", ctx do
      closure = %{at: at(9), reason: nil, voice_seconds: nil}

      assert {:error, {:not_connected, "dispatching"}} =
               Ledger.record_closure(ctx.id, closure, ctx.opts)

      {:ok, _row} = Ledger.record_session(ctx.id, "sess_close_2", at(1), ctx.opts)
      {:ok, _row} = Ledger.terminalize(ctx.id, "ended", %{ended_at: at(5)}, ctx.opts)
      assert {:error, :already_terminal} = Ledger.record_closure(ctx.id, closure, ctx.opts)
    end

    # Billing rounds a part second up, and so does every writer of voice time.
    test "keeps its voice time in whole seconds, a part rounded up", ctx do
      {:ok, _row} = Ledger.record_session(ctx.id, "sess_close_3", at(1), ctx.opts)
      closure = %{at: at(70), reason: nil, voice_seconds: 61.2}

      assert {:ok, %{voice_seconds: 62}} = Ledger.record_closure(ctx.id, closure, ctx.opts)
      assert Ledger.whole_voice_seconds(61) == 61
      assert Ledger.whole_voice_seconds(0.4) == 1
    end

    test "refuses what is not a closure", ctx do
      assert {:error, {:invalid, :closure, _bad}} =
               Ledger.record_closure(ctx.id, %{at: "later"}, ctx.opts)
    end
  end

  describe "a stalled store" do
    test "answers every call with a timeout instead of exiting the caller" do
      {:ok, store} = StalledStore.start_link()
      opts = [server: store, timeout: 20]

      assert {:error, :timeout} = Ledger.get("pc_000000000000", opts)
      assert {:error, :timeout} = Ledger.claim_dispatch("pc_000000000000", @t0, opts)
      assert {:error, :timeout} = Ledger.admit(attrs(), @t0, opts)
      assert {:error, :timeout} = Ledger.prune(@t0, opts)
      assert Process.alive?(self())
    end
  end

  describe "the terminal write" do
    setup ctx do
      row = admit!(ctx)
      {:ok, _row} = Ledger.claim_dispatch(row.id, @t0, ctx.opts)
      {:ok, _row} = Ledger.record_session(row.id, "sess_invented_6", at(1), ctx.opts)
      %{id: row.id}
    end

    test "is once only", ctx do
      assert {:ok, _row} = Ledger.terminalize(ctx.id, "ended", %{ended_at: at(9)}, ctx.opts)

      assert {:error, :already_terminal} =
               Ledger.terminalize(ctx.id, "failed", %{ended_at: at(10)}, ctx.opts)

      assert {:error, :not_found} =
               Ledger.terminalize("pc_ffffffffffff", "ended", %{ended_at: at(10)}, ctx.opts)
    end

    test "an ended call with no outcome is unknown, never confirmed", ctx do
      assert {:ok, row} = Ledger.terminalize(ctx.id, "ended", %{ended_at: at(9)}, ctx.opts)
      assert row.status == "ended"
      assert row.outcome == "unknown"
      assert row.usage_state == "incomplete"
      assert row.ended_at == at(9)
    end

    test "keeps the outcome's own uncertainty note, bounded, apart from the failure words",
         ctx do
      note =
        "The recipient's words conflict on a detail that was never settled. " <>
          String.duplicate("y", 900)

      assert {:ok, row} =
               Ledger.terminalize(
                 ctx.id,
                 "ended",
                 %{ended_at: at(9), outcome: "unknown", uncertainty: note},
                 ctx.opts
               )

      assert String.starts_with?(row.outcome_uncertainty, "The recipient's words conflict")
      assert byte_size(row.outcome_uncertainty) <= 500
      assert is_nil(row.failure_reason)
    end

    test "an outcome with no uncertainty note stores none", ctx do
      assert {:ok, %{outcome_uncertainty: nil}} =
               Ledger.terminalize(ctx.id, "ended", %{ended_at: at(9), uncertainty: nil}, ctx.opts)
    end

    test "confirmed needs evidence", ctx do
      assert {:error, {:invalid, :outcome, :no_evidence}} =
               Ledger.terminalize(
                 ctx.id,
                 "ended",
                 %{ended_at: at(9), outcome: "confirmed"},
                 ctx.opts
               )

      fields = %{
        ended_at: at(9),
        outcome: "confirmed",
        outcome_facts: %{"time" => "19:30", "party" => 2},
        evidence: [%{speaker: "recipient", text: "Yes, two at seven thirty is booked."}],
        usage: %{"seconds" => 120},
        voice_seconds: 120,
        usage_state: "voice_duration_confirmed",
        vendor_message: nil
      }

      assert {:ok, row} = Ledger.terminalize(ctx.id, "ended", fields, ctx.opts)
      assert row.outcome == "confirmed"
      assert row.outcome_facts == %{"time" => "19:30", "party" => 2}

      assert row.evidence == [
               %{"speaker" => "recipient", "text" => "Yes, two at seven thirty is booked."}
             ]

      assert row.usage_state == "voice_duration_confirmed"
    end

    test "a dispatch_unknown call is always unknown, and only terminal statuses end a call",
         ctx do
      assert {:error, {:invalid, :status, "admitted"}} =
               Ledger.terminalize(ctx.id, "admitted", %{ended_at: at(9)}, ctx.opts)

      assert {:error, {:invalid, :outcome, "options"}} =
               Ledger.terminalize(
                 ctx.id,
                 "dispatch_unknown",
                 %{ended_at: at(9), outcome: "options"},
                 ctx.opts
               )
    end

    test "the vendor's own words are kept, bounded", ctx do
      words = "Busy here. " <> String.duplicate("x", 2_000)

      assert {:ok, row} =
               Ledger.terminalize(
                 ctx.id,
                 "failed",
                 %{ended_at: at(9), failure_reason: "busy", vendor_message: words},
                 ctx.opts
               )

      assert row.failure_reason == "busy"
      assert String.starts_with?(row.vendor_message, "Busy here.")
      assert byte_size(row.vendor_message) <= 500
    end
  end

  # A call that was answered, read and hung up with nothing established.
  describe "a finished outcome" do
    test "is kept on an ended call, with or without evidence", ctx do
      said = [%{speaker: "recipient", text: "Thanks, that's all I needed."}]

      for evidence <- [[], said] do
        row = dialed!(ctx)
        fields = %{ended_at: at(9), outcome: "finished", evidence: evidence}

        assert {:ok, finished} = Ledger.terminalize(row.id, "ended", fields, ctx.opts)
        assert {finished.status, finished.outcome} == {"ended", "finished"}
        assert length(finished.evidence || []) == length(evidence)
        :ok = slot_freed!(ctx, finished)
      end
    end

    test "is refused on a call not shown to end: failed, placement or closure unknown", ctx do
      row = dialed!(ctx)

      for status <- ["failed", "dispatch_unknown", "closure_unconfirmed"] do
        assert {:error, {:invalid, :outcome, {:finished_on, ^status}}} =
                 Ledger.terminalize(
                   row.id,
                   status,
                   %{ended_at: at(9), outcome: "finished"},
                   ctx.opts
                 )
      end

      assert {:ok, %{status: "connecting", outcome: "pending"}} = Ledger.get(row.id, ctx.opts)
    end
  end

  describe "reports" do
    test "a terminal row's pending report is due once its lease ends", ctx do
      row = admit!(ctx)
      {:ok, _row} = Ledger.claim_dispatch(row.id, @t0, ctx.opts)

      {:ok, _row} =
        Ledger.terminalize(
          row.id,
          "failed",
          %{ended_at: at(5), next_delivery_at: at(125)},
          ctx.opts
        )

      assert {:ok, []} = Ledger.pending_reports(at(124), 10, ctx.opts)
      assert {:ok, [%{id: id}]} = Ledger.pending_reports(at(125), 10, ctx.opts)
      assert id == row.id

      assert {:ok, written} =
               Ledger.mark_report(
                 row.id,
                 %{report_status: "written", delivered_at: at(126)},
                 ctx.opts
               )

      assert written.report_status == "written"
      assert {:ok, []} = Ledger.pending_reports(at(200), 10, ctx.opts)
    end

    test "a live row has no report to mark", ctx do
      row = admit!(ctx)

      assert {:error, {:not_terminal, "admitted"}} =
               Ledger.mark_report(row.id, %{report_status: "written"}, ctx.opts)
    end
  end

  describe "owner scope and lists" do
    test "a call is read only by its own owner", ctx do
      row = admit!(ctx, %{owner_id: "owner-a"})
      assert {:ok, %{id: id}} = Ledger.get_for_owner(row.id, "owner-a", ctx.opts)
      assert id == row.id
      assert {:error, :not_found} = Ledger.get_for_owner(row.id, "owner-b", ctx.opts)
      assert {:ok, []} = Ledger.list_recent("owner-b", ctx.opts)
    end

    test "unsettled lists every non-terminal row", ctx do
      first = dialed_and_ended!(ctx, @t0)
      second = admit!(ctx, %{}, at(10))

      assert {:ok, [%{id: id}]} = Ledger.unsettled(ctx.opts)
      assert id == second.id
      refute id == first.id
    end
  end

  describe "retention" do
    test "deletes terminal rows past the audit period and clears excerpts past theirs", ctx do
      old = admit!(ctx, %{}, @t0)
      {:ok, _row} = Ledger.claim_dispatch(old.id, @t0, ctx.opts)

      evidence = [%{speaker: "recipient", text: "We are fully booked tonight."}]

      {:ok, _row} =
        Ledger.terminalize(
          old.id,
          "ended",
          %{ended_at: at(60), outcome: "unavailable", evidence: evidence},
          ctx.opts
        )

      eight_days = at(8 * 86_400)
      assert {:ok, %{deleted: 0, excerpts_cleared: 1}} = Ledger.prune(eight_days, ctx.opts)
      assert {:ok, pruned} = Ledger.get(old.id, ctx.opts)
      assert is_nil(pruned.evidence)
      assert pruned.evidence_pruned_at == eight_days
      assert pruned.outcome == "unavailable"

      ninety_one_days = at(91 * 86_400)
      assert {:ok, %{deleted: 1}} = Ledger.prune(ninety_one_days, ctx.opts)
      assert {:error, :not_found} = Ledger.get(old.id, ctx.opts)
    end

    test "never deletes a row that is still live", ctx do
      live = admit!(ctx, %{}, @t0)
      assert {:ok, %{deleted: 0}} = Ledger.prune(at(400 * 86_400), ctx.opts)
      assert {:ok, _row} = Ledger.get(live.id, ctx.opts)
    end
  end

  describe "the migration" do
    test "a fresh store gets the table and version 67 once", ctx do
      assert {:ok, versions} = Repo.migration_versions(server: ctx.repo)
      assert Enum.count(versions, &(&1 == 67)) == 1
      assert :ok = Repo.migrate(server: ctx.repo)
      assert {:ok, versions} = Repo.migration_versions(server: ctx.repo)
      assert Enum.count(versions, &(&1 == 67)) == 1
    end

    test "a store at 66 gains it on open", ctx do
      :ok = stop_supervised(ctx.repo)

      {:ok, conn} = Sqlite3.open(ctx.db_path)
      :ok = Sqlite3.execute(conn, "DROP TABLE phone_calls")
      :ok = Sqlite3.execute(conn, "DELETE FROM schema_migrations WHERE version IN (67, 68)")
      :ok = Sqlite3.close(conn)

      reopened = :"#{ctx.repo}_at_66"
      start_supervised!({Repo, name: reopened, enabled: true, database_path: ctx.db_path})
      assert {:ok, versions} = Repo.migration_versions(server: reopened)
      assert Enum.count(versions, &(&1 == 67)) == 1
      assert {:ok, {:admitted, _row}} = Ledger.admit(attrs(), @t0, server: reopened)
    end

    test "a fresh store is at the ledger's final shape and records 68 once", ctx do
      assert {:ok, versions} = Repo.migration_versions(server: ctx.repo)
      assert Enum.count(versions, &(&1 == 68)) == 1
      assert :ok = Repo.migrate(server: ctx.repo)
      assert {:ok, versions} = Repo.migration_versions(server: ctx.repo)
      assert Enum.count(versions, &(&1 == 68)) == 1
    end

    # A call from before 68 used the requesting turn's session as its request
    # id, so that session is kept as its trace parent; the table ends exactly
    # as a fresh store's, its definition and its indexes.
    test "a store 67 laid down is rebuilt on open, every call kept, as a fresh one", ctx do
      row = admit!(ctx, %{request_id: "main-1"})
      fresh = PhoneCallStores.schema!(ctx.db_path)
      :ok = stop_supervised(ctx.repo)
      :ok = PhoneCallStores.as_67!(ctx.db_path)
      refute PhoneCallStores.schema!(ctx.db_path) == fresh

      reopened = :"#{ctx.repo}_at_67"

      start_supervised!({Repo, name: reopened, enabled: true, database_path: ctx.db_path},
        id: reopened
      )

      assert {:ok, versions} = Repo.migration_versions(server: reopened)
      assert Enum.count(versions, &(&1 == 68)) == 1

      assert {:ok, %{id: id, outcome_uncertainty: nil, closed_at: nil, parent_session: "main-1"}} =
               Ledger.get(row.id, server: reopened)

      assert id == row.id
      :ok = stop_supervised(reopened)
      assert PhoneCallStores.schema!(ctx.db_path) == fresh
    end

    # Other features' upgrade tests forget every version after an old one and
    # reopen the store, so 67, 68 and 77 run again over a table already at the
    # latest shape: each must recognise its own work and end where a fresh
    # store ends.
    test "a store at the latest schema rolled back to before 67 reopens as a fresh one", ctx do
      row = admit!(ctx, %{request_id: "req_rolled_back"})
      fresh = PhoneCallStores.schema!(ctx.db_path)
      :ok = stop_supervised(ctx.repo)

      {:ok, conn} = Sqlite3.open(ctx.db_path)
      :ok = Sqlite3.execute(conn, "DELETE FROM schema_migrations WHERE version >= 67")
      :ok = Sqlite3.close(conn)

      reopened = :"#{ctx.repo}_rolled_back"

      start_supervised!({Repo, name: reopened, enabled: true, database_path: ctx.db_path},
        id: reopened
      )

      assert {:ok, versions} = Repo.migration_versions(server: reopened)
      assert Enum.count(versions, &(&1 in [67, 68, 77])) == 3
      assert {:ok, %{id: id}} = Ledger.get(row.id, server: reopened)
      assert id == row.id
      :ok = stop_supervised(reopened)

      assert PhoneCallStores.schema!(ctx.db_path) == fresh
    end

    # Migration 77: a call hung up with nothing established reads `finished`, one more word in
    # the outcome's CHECK, which SQLite changes only by making the table again.
    test "a store 68 rebuilt is rebuilt on open, every call and column kept, then takes finished",
         ctx do
      [first | _rest] = rows = calls_of_every_outcome!(ctx)
      live = dialed!(ctx)
      ids = Enum.map(rows ++ [live], & &1.id)
      before = Enum.map(ids, &Ledger.get(&1, ctx.opts))
      fresh = PhoneCallStores.schema!(ctx.db_path)
      :ok = stop_supervised(ctx.repo)

      :ok = PhoneCallStores.as_68!(ctx.db_path)
      refute PhoneCallStores.schema!(ctx.db_path) == fresh
      assert {:error, _check} = raw(ctx.db_path, finished_sql(first.id))

      reopened = reopen!(ctx, :at_68)
      assert {:ok, versions} = Repo.migration_versions(server: reopened)
      assert Enum.count(versions, &(&1 == 77)) == 1
      assert Enum.map(ids, &Ledger.get(&1, server: reopened)) == before

      assert {:ok, %{outcome: "finished"}} =
               Ledger.terminalize(
                 live.id,
                 "ended",
                 %{ended_at: at(9), outcome: "finished"},
                 server: reopened
               )

      :ok = stop_supervised(reopened)
      assert PhoneCallStores.schema!(ctx.db_path) == fresh
    end

    # A fresh store's table is made from the one definition, which takes the
    # word already: 77 finds its work done and leaves the table as it is (an
    # index of the test's own, which a rebuild would drop, is still there).
    test "a fresh store takes finished as it stands, and 77 run again leaves it alone", ctx do
      row = admit!(ctx, %{request_id: "req_left_alone"})
      assert {:ok, versions} = Repo.migration_versions(server: ctx.repo)
      assert Enum.count(versions, &(&1 == 77)) == 1
      assert :ok = Repo.migrate(server: ctx.repo)
      :ok = stop_supervised(ctx.repo)

      probe = "CREATE INDEX idx_phone_calls_probe ON phone_calls(platform)"
      :ok = raw(ctx.db_path, probe)
      :ok = raw(ctx.db_path, "DELETE FROM schema_migrations WHERE version = 77")
      with_probe = PhoneCallStores.schema!(ctx.db_path)

      reopened = reopen!(ctx, :fresh_again)
      assert {:ok, versions} = Repo.migration_versions(server: reopened)
      assert Enum.count(versions, &(&1 == 77)) == 1
      assert {:ok, %{id: id}} = Ledger.get(row.id, server: reopened)
      assert id == row.id
      :ok = stop_supervised(reopened)

      assert PhoneCallStores.schema!(ctx.db_path) == with_probe
    end

    test "a store 67 laid down goes through 68 and 77 and ends at the one definition", ctx do
      ended = dialed_and_ended!(ctx, @t0)
      fresh = PhoneCallStores.schema!(ctx.db_path)
      :ok = stop_supervised(ctx.repo)
      :ok = PhoneCallStores.as_67!(ctx.db_path)
      assert {:error, _check} = raw(ctx.db_path, finished_sql(ended.id))

      reopened = reopen!(ctx, :through_68)
      assert {:ok, versions} = Repo.migration_versions(server: reopened)
      assert Enum.count(versions, &(&1 in [68, 77])) == 2

      assert {:ok, %{outcome: "unknown", parent_session: parent}} =
               Ledger.get(ended.id, server: reopened)

      assert parent == ended.request_id
      :ok = stop_supervised(reopened)

      assert PhoneCallStores.schema!(ctx.db_path) == fresh
      assert :ok = raw(ctx.db_path, finished_sql(ended.id))
    end

    test "a call ledger of any other shape is refused, never cut", ctx do
      _row = admit!(ctx)
      :ok = stop_supervised(ctx.repo)
      :ok = PhoneCallStores.as_68!(ctx.db_path)
      :ok = raw(ctx.db_path, "ALTER TABLE phone_calls ADD COLUMN invented_extra TEXT")
      odd = PhoneCallStores.schema!(ctx.db_path)

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, _reason} =
                 start_supervised(
                   {Repo, name: :"#{ctx.repo}_odd", enabled: true, database_path: ctx.db_path},
                   id: :odd
                 )
      end)

      assert PhoneCallStores.schema!(ctx.db_path) == odd
    end

    test "the table refuses a row past admitted with no dispatch claim", ctx do
      row = admit!(ctx)
      :ok = stop_supervised(ctx.repo)

      {:ok, conn} = Sqlite3.open(ctx.db_path)

      assert {:error, _reason} =
               Sqlite3.execute(
                 conn,
                 "UPDATE phone_calls SET status = 'dispatching' WHERE id = '#{row.id}'"
               )

      assert {:error, _reason} =
               Sqlite3.execute(
                 conn,
                 "UPDATE phone_calls SET outcome = 'confirmed' WHERE id = '#{row.id}'"
               )

      :ok = Sqlite3.close(conn)
    end
  end
end
