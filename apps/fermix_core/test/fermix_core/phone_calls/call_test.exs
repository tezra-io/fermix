defmodule FermixCore.PhoneCalls.CallTest do
  # async: false: the fakes report to a registered sink and read a registered
  # script (`FermixTestSupport.PhoneCallFakes`). The Repo, the registry and
  # every clock are the test's own; every timer expiry is delivered by hand,
  # and nothing here can reach a network, a carrier or a model.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixCore.Memory.Repo
  alias FermixCore.PhoneCalls.Brief
  alias FermixCore.PhoneCalls.Call
  alias FermixCore.PhoneCalls.CallControls
  alias FermixCore.PhoneCalls.Config
  alias FermixCore.PhoneCalls.Ledger
  alias FermixCore.PhoneCalls.Outcome
  alias FermixCore.PhoneCalls.Readiness
  alias FermixTestSupport.PhoneCallFakes, as: Fakes

  # Every name, number and id here is invented.
  @t0 ~U[2031-03-04 15:00:00.000000Z]
  @session "sess_invented_1"

  defmodule PromptTooLarge do
    def render(_brief, _opts), do: {:error, {:prompt_too_large, :input, 40_000}}
  end

  setup do
    Process.flag(:trap_exit, true)
    Fakes.register_sink!()
    start_supervised!(Fakes.script_spec())
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-phone-call-#{unique}.db")
    repo = :"phone_call_repo_#{unique}"
    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path}, id: repo)
    registry = :"phone_call_registry_#{unique}"
    start_supervised!({Registry, keys: :unique, name: registry})

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    %{repo: repo, registry: registry, clock: :atomics.new(1, [])}
  end

  # --- fixtures ------------------------------------------------------------------

  defp brief! do
    {:ok, brief} =
      Brief.new(
        %{
          "destination" => "+12125550101",
          "destination_kind" => "business",
          "number_source" => "The bistro's own website.",
          "contact_name" => "Calloway Bistro",
          "timezone" => "America/New_York",
          "goal" => "Ask for a table for two on Saturday at 19:30.",
          "completion_criteria" => ["The host confirms a table for two at 19:30."]
        },
        caller_number: Fakes.caller(),
        now: @t0
      )

    brief
  end

  defp admit!(ctx, brief, voice) do
    attrs = %{
      request_id: "main-#{System.unique_integer([:positive])}",
      owner_id: "default",
      authorization: "direct",
      origin_kind: "chat",
      delivery_mode: "origin",
      platform: "telegram",
      destination: "40017",
      mandate: Brief.to_map(brief),
      mandate_hash: Brief.hash(brief),
      model: "gpt-live-1",
      voice: voice,
      prompt_version: "phone-test-1",
      carrier_profile: "telnyx_credential_v1"
    }

    {:ok, {:admitted, row}} = Ledger.admit(attrs, @t0, server: ctx.repo)
    row
  end

  # Starts a worker linked to this test, which stands in for the Manager.
  # `:row_voice` in `overrides` is the voice the row was admitted with.
  defp start!(ctx, overrides \\ %{}, prepare \\ fn _id -> :ok end) do
    brief = brief!()
    {voice, overrides} = Map.pop(overrides, :row_voice, "marin")
    row = admit!(ctx, brief, voice)
    prepare.(row.id)

    args =
      %{
        call_id: row.id,
        row: row,
        brief: brief,
        manager: self(),
        repo: ctx.repo,
        now_fn: fn -> @t0 end,
        session_id: "phone_call_" <> row.id,
        parent_session: row.request_id,
        registry: ctx.registry
      }
      |> Map.merge(Fakes.seams(ctx.clock))
      |> Map.merge(overrides)

    {:ok, pid} = Call.start_link(args)
    %{pid: pid, id: row.id, brief: brief}
  end

  defp create! do
    assert_receive {:create, task, request}
    {task, request}
  end

  defp created!(call, session \\ @session) do
    {task, request} = create!()
    Fakes.answer(task, {:ok, %{session_id: session, http_status: 201, transport_type: "sip"}})
    assert_receive {:attach, sideband, ^session, "sk-invented-phone-key"}
    Map.merge(call, %{sideband: sideband, session: session, request: request})
  end

  defp attached!(call) do
    sideband!(call, :attached)
    call
  end

  defp live!(ctx, overrides \\ %{}, prepare \\ fn _id -> :ok end) do
    call = ctx |> start!(overrides, prepare) |> created!() |> attached!()
    event!(call, {:answered, %{session_id: @session, event_id: "evt_answered"}})
    assert_receive {:said, nil, _opening}
    call
  end

  defp sideband!(call, payload), do: send(call.pid, {:phone_sideband, call.sideband, payload})
  defp event!(call, event), do: sideband!(call, {:event, event})

  defp said!(call, speaker, text, start_ms \\ nil, end_ms \\ nil) do
    event!(
      call,
      {:transcript,
       %{speaker: speaker, text: text, start_ms: start_ms, end_ms: end_ms, event_id: nil}}
    )
  end

  defp closed!(call, seconds, reason \\ "close_requested") do
    event!(call, {:session_closed, %{reason: reason, seconds: seconds, event_id: "evt_closed"}})
  end

  defp usage!(call, seconds) do
    event!(
      call,
      {:usage, %{seconds: seconds, cumulative: true, context_usage_ratio: nil, event_id: nil}}
    )
  end

  defp delegation!(call, id, target \\ "client") do
    event!(call, {:delegation, %{id: id, target: target, offset_ms: 4_000, event_id: nil}})
  end

  # A delegation that runs its turn; answers the request the delegate got.
  defp running!(call, id) do
    delegation!(call, id)
    fire!(call, {:settle, id})
    assert_receive {:delegate_run, %{delegation_id: ^id} = request}
    request
  end

  defp answer!(call, request, reply, usage \\ nil) do
    send(
      call.pid,
      {:phone_call_delegation, call.id, request.delegation_id, request.revision,
       {:ok, %{reply: reply, backend_usage: usage}}}
    )
  end

  defp sync!(call), do: :sys.get_state(call.pid)

  # The worker does the kill, so the trigger waits until the target has taken
  # this monitor in.
  defp monitored!(pid) do
    ref = Process.monitor(pid)
    assert {:monitored_by, monitors} = Process.info(pid, :monitored_by)
    assert self() in monitors
    ref
  end

  # Delivers the newest armed timer of `kind`: an older one's token is stale.
  defp fire!(call, kind) do
    sync!(call)
    message = latest_timer!(kind)
    send(call.pid, message)
    message
  end

  defp latest_timer!(kind) do
    assert_receive {:scheduled, {:phone_call_timer, ^kind, _token} = message, _ms}
    newest_timer(kind, message)
  end

  defp newest_timer(kind, last) do
    receive do
      {:scheduled, {:phone_call_timer, ^kind, _token} = message, _ms} ->
        newest_timer(kind, message)
    after
      0 -> last
    end
  end

  # Moves the monotonic clock past any speech the worker has taken in, so an
  # end does not wait for it.
  defp quiet!(ctx, call) do
    sync!(call)
    :atomics.add(ctx.clock, 1, 60_000)
  end

  defp ended!(call) do
    pid = call.pid
    assert_receive {:phone_call_ended, id, report}
    assert id == call.id
    assert_receive {:EXIT, ^pid, :normal}
    report
  end

  # The documented end: one hangup, the drain, `session.closed`, the report.
  defp hung_up_and_closed!(call, seconds) do
    session = call.session
    assert_receive {:hangup, _task, ^session}
    assert_receive {:scheduled, {:phone_call_timer, :drain, _token}, 5_000}
    closed!(call, seconds)
    ended!(call)
  end

  defp row!(ctx, id) do
    {:ok, row} = Ledger.get(id, server: ctx.repo)
    row
  end

  defp consume!(ctx, id, counter, times) do
    for _ <- 1..times, do: {:ok, _row} = Ledger.consume(id, counter, server: ctx.repo)
    :ok
  end

  # --- dispatch -----------------------------------------------------------------------

  describe "dispatch" do
    test "claims the dispatch, then sends one create with the snapshot and the brief's numbers",
         ctx do
      call = start!(ctx)
      {task, request} = create!()

      row = row!(ctx, call.id)
      assert row.status == "dispatching"
      assert %DateTime{} = row.dispatch_claimed_at

      assert request.model == "gpt-live-1"
      assert request.voice == "marin"
      assert request.destination == "+12125550101"
      assert request.api_key == "sk-invented-phone-key"
      assert [_brief_text, _opening] = request.input
      assert request.instructions =~ "Delegation policy"

      assert request.trunk == %{
               provider_url: "sips:sip.telnyx.com:5061",
               username: "fermixtrunk01",
               password: "invented-trunk-secret",
               caller_number: Fakes.caller()
             }

      assert_receive {:scheduled, {:phone_call_timer, :create_watchdog, _token}, 90_000}

      # The credentials live in the create's task, never in the worker: not
      # anywhere in its state's bytes, whatever its printing hides.
      held = :erlang.term_to_binary(sync!(call))
      assert :binary.match(held, "invented-trunk-secret") == :nomatch
      assert :binary.match(held, "sk-invented-phone-key") == :nomatch

      vendor = %{message: "Rate limit reached", code: "rate_limit_exceeded", type: "requests"}
      Fakes.answer(task, {:error, {:rejected, 429, vendor}})

      report = ended!(call)
      assert report.status == "failed"
      assert report.failure_reason == "create_rejected: HTTP 429"
      assert report.vendor_message == "Rate limit reached"
      assert report.voice_seconds == 0
      assert report.usage_state == "voice_duration_confirmed"
      assert report.outcome == "unknown"
      refute_received {:create, _task, _request}
      refute_received {:attach, _sideband, _session, _key}
    end

    test "phone calls turned off before the claim: failed, nothing claimed or dialed", ctx do
      call = start!(ctx, %{config: fn -> %{Fakes.config() | enabled: false} end})

      report = ended!(call)
      assert report.status == "failed"
      assert report.failure_reason == "phone_calls_disabled"
      assert is_nil(row!(ctx, call.id).dispatch_claimed_at)
      refute_received {:create, _task, _request}
    end

    test "a credential missing at the I/O boundary: failed, nothing claimed or dialed", ctx do
      call = start!(ctx, %{credentials: fn %Config{} -> {:error, :sip_password_missing} end})

      report = ended!(call)
      assert report.failure_reason == "sip_password_missing"
      assert Readiness.sentence(:sip_password_missing) =~ "password"
      assert is_nil(row!(ctx, call.id).dispatch_claimed_at)
      refute_received {:create, _task, _request}
    end

    test "readiness is asked once more, over the section read for it and this worker's backend",
         ctx do
      test = self()

      readiness = fn inputs ->
        send(test, {:readiness, inputs})
        Fakes.readiness(inputs)
      end

      call = start!(ctx, %{readiness: readiness})
      assert_receive {:readiness, inputs}
      assert Keyword.fetch!(inputs, :config) == Fakes.config()
      assert Keyword.fetch!(inputs, :call_backend?) == true
      {task, _request} = create!()
      Fakes.answer(task, {:error, {:not_sent, :econnrefused}})
      assert ended!(call).failure_reason =~ "create_not_sent"
      refute_received {:readiness, _again}
    end

    for {name, delegate} <- [none: nil, not_a_delegate: String] do
      @delegate delegate
      test "with no usable backend (#{name}): failed in Readiness's words, nothing dialed",
           ctx do
        call = start!(ctx, %{delegate: @delegate})

        report = ended!(call)
        assert report.status == "failed"
        assert report.failure_reason == "call_backend_missing"
        assert is_nil(row!(ctx, call.id).dispatch_claimed_at)
        refute_received {:create, _task, _request}
        refute_received {:delegate_run, _request}
      end
    end

    test "a requirement lost since admission: failed naming each, in Readiness's words", ctx do
      Fakes.script(:readiness, {:needs_setup, [:openai_api_key_missing, :sip_username_missing]})
      call = start!(ctx)

      report = ended!(call)
      assert report.failure_reason == "openai_api_key_missing; sip_username_missing"
      assert is_nil(row!(ctx, call.id).dispatch_claimed_at)
      refute_received {:create, _task, _request}
    end

    test "a prompt over its bound: failed, nothing claimed or dialed", ctx do
      call = start!(ctx, %{prompt: PromptTooLarge})

      assert ended!(call).failure_reason == "prompt_too_large: input"
      assert is_nil(row!(ctx, call.id).dispatch_claimed_at)
      refute_received {:create, _task, _request}
    end

    test "a row the Manager ended before the claim is never dialed", ctx do
      call =
        start!(ctx, %{}, fn id ->
          {:ok, _row} = Ledger.fail_undispatched(id, "cancelled_by_owner", @t0, server: ctx.repo)
        end)

      report = ended!(call)
      assert report.status == "failed"
      assert report.failure_reason == "dispatch_claim_refused: failed"
      refute_received {:create, _task, _request}
    end

    test "a create provably not sent: failed in its own words, sent once", ctx do
      call = start!(ctx)
      {task, _request} = create!()
      Fakes.answer(task, {:error, {:not_sent, :proxy_unsupported_transport}})

      report = ended!(call)
      assert report.status == "failed"
      assert report.failure_reason == "create_not_sent: :proxy_unsupported_transport"
      refute_received {:create, _task, _request}
    end

    test "a create whose answer was lost: dispatch_unknown, never sent again, nothing hung up",
         ctx do
      call = start!(ctx)
      {task, _request} = create!()
      Fakes.answer(task, {:error, {:unknown, {:transport, :timeout}}})

      report = ended!(call)
      assert report.status == "dispatch_unknown"
      assert report.outcome == "unknown"
      assert report.usage_state == "incomplete"
      assert is_nil(report.voice_seconds)
      refute_received {:create, _task, _request}
      refute_received {:hangup, _task, _session}
      refute_received {:attach, _sideband, _session, _key}
    end

    test "a create with no answer by the watchdog is stopped and unknown, never sent again",
         ctx do
      call = start!(ctx)
      {task, _request} = create!()
      task_ref = monitored!(task)
      fire!(call, :create_watchdog)

      assert_receive {:DOWN, ^task_ref, :process, ^task, :killed}
      report = ended!(call)
      assert report.status == "dispatch_unknown"
      assert report.failure_reason =~ "create_unknown"
      refute_received {:create, _task, _request}
    end

    test "a create task that crashes leaves the dispatch unknown", ctx do
      Fakes.script(:create, :crash)

      capture_log(fn ->
        call = start!(ctx)
        assert_receive {:create, _task, _request}
        report = ended!(call)
        assert report.status == "dispatch_unknown"
        assert report.failure_reason =~ "create_stopped"
      end)

      refute_received {:create, _task, _request}
    end

    test "a dispatch claim that times out dials nothing and says so", ctx do
      Fakes.script({:ledger, :claim_dispatch}, {:result, {:error, :timeout}})
      call = start!(ctx)

      report = ended!(call)
      assert report.status == "failed"
      assert report.failure_reason == "dispatch_claim_timeout"
      refute_received {:create, _task, _request}
    end

    test "the create speaks in the voice the call was admitted with, not today's setting",
         ctx do
      call =
        start!(ctx, %{
          row_voice: "cedar",
          config: fn -> %{Fakes.config() | voice: "marin"} end
        })

      {task, request} = create!()
      assert request.voice == "cedar"
      Fakes.answer(task, {:error, {:not_sent, :proxy_unsupported_transport}})
      ended!(call)
    end
  end

  # --- attaching --------------------------------------------------------------------

  describe "attaching" do
    test "records the session first, then attaches once and arms the row's deadlines", ctx do
      call = ctx |> start!() |> created!()

      row = row!(ctx, call.id)
      assert row.status == "connecting"
      assert row.provider_session_id == @session
      assert_receive {:scheduled, {:phone_call_timer, :ringing, _token}, 60_000}
      assert_receive {:scheduled, {:phone_call_timer, :deadline, _token}, 600_000}
      assert_receive {:scheduled, {:phone_call_timer, :attach, _token}, 10_000}

      Call.cancel(call.pid, :owner)
      assert_receive {:sideband_stopped, _sideband}
      assert_receive {:hangup, _task, @session}
      assert ended!(call).status == "closure_unconfirmed"
    end

    test "a failed attach hangs up the known session once and never reconnects", ctx do
      call = ctx |> start!() |> created!()
      sideband!(call, {:attach_failed, {:http_status, 404, "Not Found"}})

      assert_receive {:hangup, _task, @session}

      assert_receive {:extract, [], %{answered: false, end_reason: :connection_lost}, _opts}

      report = ended!(call)
      assert report.status == "closure_unconfirmed"
      assert report.failure_reason == "attach_failed"
      assert report.usage_state == "incomplete"
      refute_received {:attach, _sideband, _session, _key}
      refute_received {:hangup, _task, _session}
    end

    test "an attach late past its deadline is stopped, and the call hung up once", ctx do
      call = ctx |> start!() |> created!()
      fire!(call, :attach)

      sideband = call.sideband
      assert_receive {:sideband_stopped, ^sideband}
      assert_receive {:hangup, _task, @session}
      report = ended!(call)
      assert report.status == "closure_unconfirmed"
      assert report.failure_reason == "attach_timeout"
      refute_received {:attach, _sideband, _session, _key}
    end

    test "a sideband that cannot start: the session is hung up, closure unconfirmed", ctx do
      Fakes.script(:attach, {:error, :proxy_unsupported_transport})

      capture_log(fn ->
        call = start!(ctx)
        {task, _request} = create!()
        Fakes.answer(task, {:ok, %{session_id: @session, http_status: 200, transport_type: nil}})

        assert_receive {:hangup, _task, @session}
        report = ended!(call)
        assert report.status == "closure_unconfirmed"
        assert report.failure_reason == "attach_failed"
      end)

      refute_received {:attach, _sideband, _session, _key}
    end

    test "a session id the ledger refuses is still hung up, never attached", ctx do
      capture_log(fn ->
        call = start!(ctx)
        {task, _request} = create!()

        {:ok, _row} =
          Ledger.record_session(call.id, "sess_someone_else", @t0, server: ctx.repo)

        Fakes.answer(
          task,
          {:ok, %{session_id: @session, http_status: 201, transport_type: "sip"}}
        )

        assert_receive {:hangup, _task, @session}
        report = ended!(call)
        assert report.status == "closure_unconfirmed"
        assert report.failure_reason == "session_not_recorded"
      end)

      refute_received {:attach, _sideband, _session, _key}
    end

    test "a session record that times out is hung up, never attached", ctx do
      Fakes.script({:ledger, :record_session}, {:result, {:error, :timeout}})

      capture_log(fn ->
        call = ctx |> start!()
        {task, _request} = create!()

        Fakes.answer(
          task,
          {:ok, %{session_id: @session, http_status: 201, transport_type: "sip"}}
        )

        assert_receive {:hangup, _task, @session}
        assert ended!(call).failure_reason == "session_not_recorded"
      end)

      refute_received {:attach, _sideband, _session, _key}
    end

    # The deadlines are the row's absolute ones: a slow create eats the
    # ringing budget, never extends it.
    test "a slow create leaves only what remains of the row's deadlines", ctx do
      wall = :atomics.new(1, [])
      now_fn = fn -> DateTime.add(@t0, :atomics.get(wall, 1), :millisecond) end
      call = start!(ctx, %{now_fn: now_fn})
      {task, _request} = create!()

      :atomics.put(wall, 1, 45_000)
      Fakes.answer(task, {:ok, %{session_id: @session, http_status: 201, transport_type: "sip"}})

      assert_receive {:scheduled, {:phone_call_timer, :ringing, _token}, 15_000}
      assert_receive {:scheduled, {:phone_call_timer, :deadline, _token}, 555_000}
      assert row!(ctx, call.id).ringing_deadline_at == DateTime.add(@t0, 60, :second)
    end
  end

  # --- progress -------------------------------------------------------------------------

  describe "progress" do
    test "ringing is optional, a late ringing never regresses, a second answer changes nothing",
         ctx do
      call = live!(ctx)
      sync!(call)
      row = row!(ctx, call.id)
      assert row.status == "active"
      assert %DateTime{} = row.answered_at
      assert is_nil(row.ringing_at)

      event!(call, {:ringing, %{session_id: @session, event_id: "evt_late_ringing"}})
      event!(call, {:answered, %{session_id: @session, event_id: "evt_answered_again"}})
      sync!(call)
      assert row!(ctx, call.id).status == "active"
      refute_received {:said, nil, _opening}

      quiet!(ctx, call)
      Call.cancel(call.pid, :owner)
      assert hung_up_and_closed!(call, 3).status == "ended"
    end

    test "the recipient's words make the call active when answered was missed", ctx do
      call = ctx |> start!() |> created!() |> attached!()
      event!(call, {:ringing, %{session_id: @session, event_id: "evt_ringing"}})
      said!(call, :remote, "Calloway Bistro, how can I help?")

      assert_receive {:said, nil, _opening}
      sync!(call)
      assert row!(ctx, call.id).status == "active"

      # Its ringing timer was stopped: a late expiry ends nothing.
      fire!(call, :ringing)
      sync!(call)
      refute_received {:hangup, _task, _session}

      quiet!(ctx, call)
      Call.cancel(call.pid, :owner)
      hung_up_and_closed!(call, 9)
    end

    test "no answer by the ringing deadline: hung up once, ended as no answer", ctx do
      call = ctx |> start!() |> created!() |> attached!()
      event!(call, {:ringing, %{session_id: @session, event_id: "evt_ringing"}})
      fire!(call, :ringing)

      report = hung_up_and_closed!(call, 0)
      assert_receive {:extract, [], %{answered: false, end_reason: :no_answer}, _opts}
      assert report.status == "ended"
      assert report.failure_reason == "no_answer"
      assert report.usage_state == "voice_duration_confirmed"
      refute_received {:hangup, _task, _session}
    end

    test "the operational deadline hangs up an answered call", ctx do
      call = live!(ctx)
      quiet!(ctx, call)
      fire!(call, :deadline)

      report = hung_up_and_closed!(call, 600)
      assert_receive {:extract, _entries, %{answered: true, end_reason: :deadline}, _opts}
      assert report.failure_reason == "call_deadline_reached"
      assert report.voice_seconds == 600
    end

    test "recipient silence ends the call; each of their words re-arms the bound", ctx do
      call = live!(ctx)
      assert_receive {:scheduled, {:phone_call_timer, :silence, _token} = first, 120_000}
      said!(call, :remote, "One moment, please.")
      sync!(call)

      send(call.pid, first)
      sync!(call)
      refute_received {:hangup, _task, _session}

      quiet!(ctx, call)
      fire!(call, :silence)
      report = hung_up_and_closed!(call, 130)
      assert report.failure_reason == "recipient_silence_timeout"
    end

    test "the recipient hangs up: no hangup request, ended, final usage confirmed", ctx do
      call = live!(ctx)
      usage!(call, 41.2)
      sync!(call)
      assert row!(ctx, call.id).voice_seconds == 42

      closed!(call, 42.5, "remote_hangup")

      sideband = call.sideband
      assert_receive {:closed_by_worker, ^sideband}
      assert_receive {:extract, _entries, %{answered: true, end_reason: :hangup}, _opts}
      report = ended!(call)
      assert report.status == "ended"
      assert report.voice_seconds == 43
      assert report.usage_state == "voice_duration_confirmed"
      assert is_nil(report.failure_reason)
      refute_received {:hangup, _task, _session}
    end

    # The row the closure settles and the report the Manager writes keep one
    # voice time: a part of a second rounds up in both (`Ledger.whole_voice_seconds/1`).
    test "a call's settled and reported voice times are the same whole seconds", ctx do
      call = live!(ctx)
      closed!(call, 42.2, "remote_hangup")
      report = ended!(call)

      assert report.usage_state == "voice_duration_confirmed"
      assert report.voice_seconds == 43
      assert row!(ctx, call.id).voice_seconds == report.voice_seconds
    end

    test "an unconfirmed call reports the voice time its last usage recorded", ctx do
      call = live!(ctx)
      usage!(call, 12.3)
      sync!(call)
      recorded = row!(ctx, call.id).voice_seconds
      assert recorded == 13

      capture_log(fn -> sideband!(call, {:closed, :connection_lost}) end)
      assert_receive {:hangup, _task, @session}
      report = ended!(call)

      assert report.usage_state == "incomplete"
      assert report.voice_seconds == recorded
    end

    test "a failed call is hung up once and reported failed in the carrier's words", ctx do
      call = ctx |> start!() |> created!() |> attached!()

      event!(
        call,
        {:call_failed,
         %{session_id: @session, code: "sip_486", message: "Busy Here", param: nil, event_id: nil}}
      )

      report = hung_up_and_closed!(call, 0)
      assert_receive {:extract, [], %{answered: false, end_reason: :failed}, _opts}
      assert report.status == "failed"
      assert report.vendor_message == "Busy Here"
      assert report.failure_reason == "call_failed"
    end
  end

  # --- the sideband lost ---------------------------------------------------------------

  describe "a lost sideband" do
    test "stops backend work before the hangup, never reconnects, closure unconfirmed", ctx do
      call = live!(ctx)
      request = running!(call, "del_1")
      usage!(call, 12.0)
      quiet!(ctx, call)

      capture_log(fn -> sideband!(call, {:closed, :connection_lost}) end)

      assert_receive {:hangup, _task, @session}
      report = ended!(call)
      assert Fakes.recorded() == [{:delegate_cancel, request.delegation_id}, {:hangup, @session}]
      assert report.status == "closure_unconfirmed"
      assert report.failure_reason == "sideband_lost"
      assert report.usage_state == "incomplete"
      assert report.voice_seconds == 12
      refute_received {:scheduled, {:phone_call_timer, :drain, _token}, _ms}
      refute_received {:attach, _sideband, _session, _key}
    end

    test "a sideband that exits without a close is lost the same way", ctx do
      call = live!(ctx)
      quiet!(ctx, call)
      capture_log(fn -> send(call.sideband, {:exit, :boom}) end)

      assert_receive {:hangup, _task, @session}
      report = ended!(call)
      assert report.status == "closure_unconfirmed"
      assert report.failure_reason == "sideband_lost"
    end
  end

  # --- the transcript --------------------------------------------------------------------

  describe "the transcript" do
    test "reaches the extraction as it arrived: in order, unmerged, with speakers and offsets",
         ctx do
      call = live!(ctx)
      said!(call, :remote, "Calloway ", 100, 600)
      said!(call, :remote, "Bistro.", 600, 900)
      said!(call, :assistant, " Hello, I am an AI assistant.", 1_000, 2_400)
      said!(call, :remote, "Yes?", nil, nil)
      quiet!(ctx, call)
      Call.cancel(call.pid, :owner)
      hung_up_and_closed!(call, 20)

      assert_receive {:extract, entries, %{answered: true, end_reason: :cancelled}, opts}

      assert entries == [
               %{speaker: :remote, text: "Calloway ", start_ms: 100, end_ms: 600},
               %{speaker: :remote, text: "Bistro.", start_ms: 600, end_ms: 900},
               %{
                 speaker: :assistant,
                 text: " Hello, I am an AI assistant.",
                 start_ms: 1_000,
                 end_ms: 2_400
               },
               %{speaker: :remote, text: "Yes?", start_ms: nil, end_ms: nil}
             ]

      assert opts[:session_id] == "phone_call_" <> call.id
      assert opts[:started_at] == @t0
    end

    test "at its byte bound the call ends with its evidence incomplete, and no reading", ctx do
      call = live!(ctx)
      chunk = String.duplicate("a", div(65_536, 4))
      for _ <- 1..4, do: said!(call, :remote, chunk)
      sync!(call)
      refute_received {:hangup, _task, _session}

      quiet!(ctx, call)
      said!(call, :remote, "b")

      report = hung_up_and_closed!(call, 300)
      assert report.failure_reason == "transcript_limit_reached"
      assert report.outcome == "unknown"
      assert report.uncertainty =~ "size limit"
      refute_received {:extract, _entries, _facts, _opts}
    end
  end

  # --- delegations -------------------------------------------------------------------------

  describe "delegations" do
    test "consume a backend turn first, wait for late words, then run one scoped turn", ctx do
      call = live!(ctx)
      delegation!(call, "del_1")
      sync!(call)
      assert row!(ctx, call.id).core_turns == 1
      refute_received {:delegate_run, _request}
      assert_receive {:scheduled, {:phone_call_timer, {:settle, "del_1"}, _token} = settle, 1_000}

      said!(call, :remote, "For two at seven thirty.")
      sync!(call)
      send(call.pid, settle)

      assert_receive {:delegate_run, request}
      assert request.call_id == call.id
      assert request.delegation_id == "del_1"
      assert request.revision == 1
      assert request.session_id == "phone_call_" <> call.id
      assert request.deadline_ms == 30_000
      assert request.max_steps == 12
      assert request.reply_to == call.pid
      assert request.brief == call.brief
      assert is_binary(request.handle) and byte_size(request.handle) >= 24
      assert List.last(request.window).text == "For two at seven thirty."
      assert_receive {:scheduled, {:phone_call_timer, {:turn_timeout, "del_1"}, _token}, 30_000}

      # The real turn's measure (`Agents.PhoneCallTurn`): tokens and loop
      # iterations, string keys, and no cost.
      answer!(call, request, "Seven thirty fits the brief.", %{
        "total_tokens" => 900,
        "iterations" => 2
      })

      assert_receive {:said, "del_1", "Seven thirty fits the brief."}

      quiet!(ctx, call)
      Call.cancel(call.pid, :owner)
      report = hung_up_and_closed!(call, 30)
      assert report.backend_usage == %{"total_tokens" => 900, "iterations" => 2, "turns" => 1}
    end

    test "backend usage sums each turn's measure and counts the turns that had none", ctx do
      call = live!(ctx)
      first = running!(call, "del_1")
      answer!(call, first, "Done.", %{"total_tokens" => 900, "iterations" => 2})
      assert_receive {:said, "del_1", "Done."}
      second = running!(call, "del_2")
      answer!(call, second, "Done again.", %{"total_tokens" => 300, "iterations" => 1})
      assert_receive {:said, "del_2", "Done again."}
      running!(call, "del_3")
      fire!(call, {:turn_timeout, "del_3"})

      quiet!(ctx, call)
      Call.cancel(call.pid, :owner)
      report = hung_up_and_closed!(call, 30)

      assert report.backend_usage == %{
               "total_tokens" => 1_200,
               "iterations" => 3,
               "turns" => 3,
               "turns_unmeasured" => 1
             }
    end

    test "one runs and one waits; a third is answered honestly, never queued", ctx do
      call = live!(ctx)
      delegation!(call, "del_1")
      delegation!(call, "del_2")
      delegation!(call, "del_3")

      assert_receive {:said, "del_3", busy}
      assert busy =~ "earlier request"
      sync!(call)
      assert row!(ctx, call.id).core_turns == 1

      fire!(call, {:settle, "del_1"})
      assert_receive {:delegate_run, first}
      answer!(call, first, "Done.")
      assert_receive {:said, "del_1", "Done."}

      sync!(call)
      assert row!(ctx, call.id).core_turns == 2
      fire!(call, {:settle, "del_2"})
      assert_receive {:delegate_run, %{delegation_id: "del_2"}}
      refute_received {:delegate_run, %{delegation_id: "del_3"}}
    end

    test "a repeated delegation id and another target run nothing", ctx do
      call = live!(ctx)
      delegation!(call, "del_1")
      delegation!(call, "del_1")
      delegation!(call, "del_9", "server")
      sync!(call)

      assert row!(ctx, call.id).core_turns == 1
      assert_receive {:scheduled, {:phone_call_timer, {:settle, "del_1"}, _token}, 1_000}
      refute_received {:scheduled, {:phone_call_timer, {:settle, _id}, _token}, _ms}
    end

    test "an answer acts only for this call, a current delegation and revision", ctx do
      call = live!(ctx)
      request = running!(call, "del_1")
      result = {:ok, %{reply: "A stale answer.", backend_usage: nil}}

      send(call.pid, {:phone_call_delegation, call.id, "del_1", 2, result})
      send(call.pid, {:phone_call_delegation, call.id, "del_other", 1, result})
      send(call.pid, {:phone_call_delegation, "pc_000000000000", "del_1", 1, result})
      sync!(call)
      refute_received {:said, _id, _text}

      answer!(call, request, "The current answer.")
      answer!(call, request, "The same answer again.")
      sync!(call)
      assert_received {:said, "del_1", "The current answer."}
      refute_received {:said, _id, _text}
    end

    test "a turn past its time is stopped, said so once, and its late answer is fenced", ctx do
      call = live!(ctx)
      request = running!(call, "del_1")
      fire!(call, {:turn_timeout, "del_1"})

      assert_receive {:delegate_cancel, _call_id, "del_1"}
      assert_receive {:said, "del_1", line}
      assert line =~ "taking too long"

      answer!(call, request, "Too late to say.")
      sync!(call)
      refute_received {:said, _id, _text}
      refute_received {:hangup, _task, _session}
    end

    test "an answer that arrives once the call is ending cannot speak", ctx do
      call = live!(ctx)
      request = running!(call, "del_1")
      quiet!(ctx, call)
      Call.cancel(call.pid, :owner)
      assert_receive {:delegate_cancel, _call_id, "del_1"}

      answer!(call, request, "Too late to say.")
      sync!(call)
      refute_received {:said, _id, _text}
      hung_up_and_closed!(call, 10)
    end

    test "the call's last backend turn spent: one honest line, and the call ends", ctx do
      call = live!(ctx, %{}, &consume!(ctx, &1, :core_turns, 8))
      delegation!(call, "del_1")

      assert_receive {:said, "del_1", line}
      assert line =~ "anything more"
      assert_receive {:scheduled, {:phone_call_timer, :speech, _token} = speech, 1_500}
      quiet!(ctx, call)
      send(call.pid, speech)

      report = hung_up_and_closed!(call, 60)
      assert report.failure_reason == "core_turn_limit_reached"
      refute_received {:delegate_run, _request}
    end

    test "a turn the delegate refuses to start is answered honestly", ctx do
      Fakes.script(:delegate_run, {:error, :queue_full})

      capture_log(fn ->
        call = live!(ctx)
        delegation!(call, "del_1")
        fire!(call, {:settle, "del_1"})
        assert_receive {:delegate_run, _request}
        assert_receive {:said, "del_1", line}
        assert line =~ "get that done"
      end)
    end

    test "a stuck stop of a timed-out turn is never waited on", ctx do
      Fakes.script(:delegate_cancel, :wait)
      call = live!(ctx)
      running!(call, "del_1")
      fire!(call, {:turn_timeout, "del_1"})

      assert_receive {:said, "del_1", line}
      assert line =~ "taking too long"
      assert_receive {:delegate_cancel_from, stopper}
      assert Process.alive?(call.pid)
      refute stopper == call.pid
    end
  end

  # --- the keypad -------------------------------------------------------------------------

  describe "press_keys/3" do
    defp press(ctx, call, handle, keys),
      do:
        Task.async(fn ->
          CallControls.press_keys(call.id, handle, keys, registry: ctx.registry)
        end)

    defp ack!(call, key, event_id),
      do: event!(call, {:dtmf_sent, %{key: key, client_event_id: event_id, event_id: nil}})

    test "one key per event, each counted first, the next only after its acknowledgement", ctx do
      call = live!(ctx)
      request = running!(call, "del_1")
      press = press(ctx, call, request.handle, "12#")

      assert_receive {:dtmf, "1", first}
      assert_receive {:scheduled, {:phone_call_timer, :dtmf_ack, _token}, 3_000}
      sync!(call)
      assert row!(ctx, call.id).dtmf_keys == 1
      refute_received {:dtmf, _key, _event_id}

      ack!(call, "1", first)
      assert_receive {:dtmf, "2", second}
      ack!(call, "2", second)
      assert_receive {:dtmf, "#", third}
      ack!(call, "#", third)

      assert {:ok, %{confirmed: "12#", unconfirmed: "", stopped: nil}} = Task.await(press)
      assert row!(ctx, call.id).dtmf_keys == 3
    end

    test "a missing acknowledgement stops the presses; the key is never sent again", ctx do
      call = live!(ctx)
      request = running!(call, "del_1")
      press = press(ctx, call, request.handle, "123")

      assert_receive {:dtmf, "1", first}
      ack!(call, "1", first)
      assert_receive {:dtmf, "2", second}
      fire!(call, :dtmf_ack)

      assert {:ok, %{confirmed: "1", unconfirmed: "23", stopped: :ack_timeout}} =
               Task.await(press)

      ack!(call, "2", second)
      sync!(call)
      refute_received {:dtmf, _key, _event_id}
      assert row!(ctx, call.id).dtmf_keys == 2
    end

    test "a refused key stops the presses in the vendor's terms", ctx do
      call = live!(ctx)
      request = running!(call, "del_1")
      press = press(ctx, call, request.handle, "9")
      assert_receive {:dtmf, "9", event_id}

      event!(
        call,
        {:vendor_error,
         %{
           type: "invalid_request_error",
           code: "dtmf_rejected",
           message: "Keypad input is not available.",
           param: nil,
           client_event_id: event_id,
           event_id: nil
         }}
      )

      assert {:ok, %{confirmed: "", unconfirmed: "9", stopped: :refused}} = Task.await(press)
    end

    test "refusals before any key, each in its own class", ctx do
      call = ctx |> start!() |> created!() |> attached!()
      request = running!(call, "del_1")
      opts = [registry: ctx.registry]

      assert {:error, :invalid_key} =
               CallControls.press_keys(call.id, request.handle, "12x", opts)

      too_many = String.duplicate("1", 33)

      assert {:error, :too_many_keys} =
               CallControls.press_keys(call.id, request.handle, too_many, opts)

      assert {:error, :unknown_call} =
               CallControls.press_keys("pc_0123456789ab", request.handle, "1", opts)

      assert {:error, :bad_handle} = CallControls.press_keys(call.id, "not-the-handle", "1", opts)
      # Not answered yet: there is no menu to press into.
      assert {:error, :not_active} = CallControls.press_keys(call.id, request.handle, "1", opts)

      event!(call, {:answered, %{session_id: @session, event_id: nil}})
      answer!(call, request, "Done.")
      assert_receive {:said, "del_1", "Done."}
      assert {:error, :stale_handle} = CallControls.press_keys(call.id, request.handle, "1", opts)
      refute_received {:dtmf, _key, _event_id}
    end

    test "the call's keys spent: refused before anything is sent", ctx do
      call = live!(ctx, %{}, &consume!(ctx, &1, :dtmf_keys, 32))
      request = running!(call, "del_1")

      assert {:error, {:cap_reached, :dtmf_keys}} =
               CallControls.press_keys(call.id, request.handle, "1", registry: ctx.registry)

      refute_received {:dtmf, _key, _event_id}
    end

    test "a second press while one waits is refused; an ending call stops the first", ctx do
      call = live!(ctx)
      request = running!(call, "del_1")
      press = press(ctx, call, request.handle, "12")
      assert_receive {:dtmf, "1", _event_id}

      assert {:error, :keypad_busy} =
               CallControls.press_keys(call.id, request.handle, "3", registry: ctx.registry)

      quiet!(ctx, call)
      Call.cancel(call.pid, :owner)

      assert {:ok, %{confirmed: "", unconfirmed: "12", stopped: :call_ending}} =
               Task.await(press)

      hung_up_and_closed!(call, 15)
    end

    test "a turn that runs out of time stops its presses; no key goes out after", ctx do
      call = live!(ctx)
      request = running!(call, "del_1")
      press = press(ctx, call, request.handle, "123")
      assert_receive {:dtmf, "1", first}

      fire!(call, {:turn_timeout, "del_1"})

      assert {:ok, %{confirmed: "", unconfirmed: "123", stopped: :turn_ended}} =
               Task.await(press)

      ack!(call, "1", first)
      sync!(call)
      refute_received {:dtmf, _key, _event_id}
    end

    test "a turn that answers stops what is left of its presses", ctx do
      call = live!(ctx)
      request = running!(call, "del_1")
      press = press(ctx, call, request.handle, "45")
      assert_receive {:dtmf, "4", first}
      ack!(call, "4", first)
      assert_receive {:dtmf, "5", _second}

      answer!(call, request, "Pressed.")

      assert {:ok, %{confirmed: "4", unconfirmed: "5", stopped: :turn_ended}} =
               Task.await(press)

      sync!(call)
      refute_received {:dtmf, _key, _event_id}
    end

    for {scripted, stopped} <- [
          {{:error, {:not_sent, :sideband_down}}, :not_sent},
          {{:error, {:unknown, :send_timeout}}, :send_unknown},
          {{:error, :invalid_dtmf_key}, :invalid_key}
        ] do
      test "a key the sideband answers #{inspect(scripted)} stops as #{stopped}", ctx do
        Fakes.script(:dtmf, unquote(Macro.escape(scripted)))
        call = live!(ctx)
        request = running!(call, "del_1")
        press = press(ctx, call, request.handle, "78")
        assert_receive {:dtmf, "7", _event_id}

        assert {:ok, %{confirmed: "", unconfirmed: "78", stopped: unquote(stopped)}} =
                 Task.await(press)

        sync!(call)
        refute_received {:dtmf, _key, _event_id}
      end
    end

    test "a key count that times out sends no key", ctx do
      Fakes.script({:ledger, {:consume, :dtmf_keys}}, {:result, {:error, :timeout}})
      call = live!(ctx)
      request = running!(call, "del_1")

      capture_log(fn ->
        assert {:ok, %{confirmed: "", unconfirmed: "1", stopped: :not_sent}} =
                 CallControls.press_keys(call.id, request.handle, "1", registry: ctx.registry)
      end)

      refute_received {:dtmf, _key, _event_id}
    end
  end

  # --- finish ----------------------------------------------------------------------------

  describe "finish/4" do
    test ":done ends the call once its turn's answer has been said", ctx do
      call = live!(ctx)
      request = running!(call, "del_1")
      quiet!(ctx, call)

      assert :ok =
               CallControls.finish(call.id, request.handle, :done, nil, registry: ctx.registry)

      sync!(call)
      refute_received {:hangup, _task, _session}

      answer!(call, request, "Thank you, goodbye.")
      assert_receive {:said, "del_1", "Thank you, goodbye."}
      # The goodbye is being spoken: the hangup waits for it, bounded.
      assert_receive {:scheduled, {:phone_call_timer, :speech, _token} = speech, 1_500}
      sync!(call)
      refute_received {:hangup, _task, _session}
      quiet!(ctx, call)
      send(call.pid, speech)

      report = hung_up_and_closed!(call, 75)
      assert_receive {:extract, _entries, %{answered: true, end_reason: :hangup}, _opts}
      assert report.status == "ended"
      assert is_nil(report.failure_reason)
    end

    test ":needs_owner ends as needs_owner with the options heard and the turn's note", ctx do
      heard = %Outcome{
        outcome: :options,
        options: ["Sunday at 19:00"],
        excerpts: [%{speaker: :remote, text: "Sunday at seven?", start_ms: 10, end_ms: 20}]
      }

      Fakes.script(:extract, {:result, {:ok, heard}})
      call = live!(ctx)
      request = running!(call, "del_1")
      note = "They need a deposit, which the brief does not allow."

      assert :ok =
               CallControls.finish(call.id, request.handle, :needs_owner, note,
                 registry: ctx.registry
               )

      answer!(call, request, "The owner will follow up.")
      quiet!(ctx, call)
      fire!(call, :speech)

      report = hung_up_and_closed!(call, 50)
      assert report.outcome == "needs_owner"

      assert Map.take(report.outcome_facts, ["options", "note"]) ==
               %{"options" => ["Sunday at 19:00"], "note" => note}

      assert [%{speaker: "recipient", text: "Sunday at seven?"}] = report.evidence
    end

    # The owner's decision: on voicemail or a machine, nothing is left on it.
    test ":voicemail hangs up at once and says nothing: no reply, no line, no wait", ctx do
      call = live!(ctx)
      request = running!(call, "del_1")
      # The machine's greeting is still playing; that is no reason to wait.
      said!(call, :assistant, "Hello, I am calling for")

      assert :ok =
               CallControls.finish(call.id, request.handle, :voicemail, nil,
                 registry: ctx.registry
               )

      assert_receive {:hangup, _task, @session}
      assert_receive {:delegate_cancel, _call_id, "del_1"}
      answer!(call, request, "Ending the call.")
      sync!(call)
      refute_received {:said, _id, _text}
      refute_received {:scheduled, {:phone_call_timer, :speech, _token}, _ms}

      hung_up_and_closed_after_hangup!(call, 8)
      assert_receive {:extract, _entries, %{answered: true, end_reason: :voicemail}, _opts}
      refute_received {:said, _id, _text}
    end

    test "a turn that finishes but fails to answer leaves no engine sentence on the line",
         ctx do
      for reason <- [:done, :cannot_proceed] do
        assert failed_finish_says(ctx, reason) == [], "#{reason} put a line on the call"
      end
    end

    test ":needs_owner whose turn fails to answer still tells the person the owner follows up",
         ctx do
      assert [{"del_1", line}] = failed_finish_says(ctx, :needs_owner)
      assert line == "The owner will follow up with you about this."
    end

    test "a turn that finishes and then runs out of time still ends the call", ctx do
      call = live!(ctx)
      request = running!(call, "del_1")

      assert :ok =
               CallControls.finish(call.id, request.handle, :cannot_proceed, nil,
                 registry: ctx.registry
               )

      fire!(call, {:turn_timeout, "del_1"})
      quiet!(ctx, call)
      fire!(call, :speech)

      report = hung_up_and_closed!(call, 33)
      assert report.failure_reason == "cannot_proceed"
    end

    test "refusals, each in its own class", ctx do
      call = live!(ctx)
      request = running!(call, "del_1")
      opts = [registry: ctx.registry]

      assert {:error, :invalid_reason} =
               CallControls.finish(call.id, request.handle, :hold_on, nil, opts)

      assert {:error, :invalid_note} =
               CallControls.finish(call.id, request.handle, :done, <<255>>, opts)

      assert {:error, :unknown_call} =
               CallControls.finish("pc_0123456789ab", request.handle, :done, nil, opts)

      assert {:error, :bad_handle} = CallControls.finish(call.id, "forged", :done, nil, opts)
      assert :ok = CallControls.finish(call.id, request.handle, :done, nil, opts)

      assert {:error, :already_finishing} =
               CallControls.finish(call.id, request.handle, :done, nil, opts)
    end
  end

  # --- ending -------------------------------------------------------------------------------

  describe "ending" do
    test "a reply still being spoken gets a bounded wait, then the hangup goes regardless", ctx do
      call = live!(ctx)
      Call.cancel(call.pid, :owner)

      # The clock never moves: the voice never goes quiet.
      for _check <- 1..5 do
        fire!(call, :speech)
        sync!(call)
        refute_received {:hangup, _task, _session}
      end

      fire!(call, :speech)
      sync!(call)
      assert row!(ctx, call.id).status == "closing"
      hung_up_and_closed!(call, 4)
    end

    test "no session.closed within the drain: closure unconfirmed, usage incomplete", ctx do
      call = live!(ctx)
      usage!(call, 30.0)
      quiet!(ctx, call)
      Call.cancel(call.pid, :owner)

      assert_receive {:hangup, _task, @session}
      fire!(call, :drain)
      sideband = call.sideband
      assert_receive {:closed_by_worker, ^sideband}

      report = ended!(call)
      assert report.status == "closure_unconfirmed"
      assert report.usage_state == "incomplete"
      assert report.voice_seconds == 30
      assert report.failure_reason == "cancelled_by_owner"
      refute_received {:hangup, _task, _session}
    end

    test "a refused hangup is kept in the record, and never sent again", ctx do
      vendor = %{message: "Session is not active.", code: nil, type: nil}
      Fakes.script(:hangup, {:result, {:error, {:rejected, 400, vendor}}})
      call = live!(ctx)
      quiet!(ctx, call)
      Call.cancel(call.pid, :owner)

      assert_receive {:hangup, _task, @session}
      fire!(call, :drain)
      report = ended!(call)
      assert report.status == "closure_unconfirmed"
      assert report.failure_reason =~ "hangup rejected, HTTP 400: Session is not active."
      refute_received {:hangup, _task, _session}
    end

    test "the session's cleanup attempts spent: no hangup request at all", ctx do
      call = live!(ctx, %{}, &consume!(ctx, &1, :cleanup_attempts, 3))
      quiet!(ctx, call)

      capture_log(fn ->
        Call.cancel(call.pid, :owner)
        fire!(call, :drain)
        assert ended!(call).status == "closure_unconfirmed"
      end)

      refute_received {:hangup, _task, _session}
    end

    test "a hangup with no answer by its watchdog is stopped, then drained", ctx do
      Fakes.script(:hangup, :wait)
      call = live!(ctx)
      quiet!(ctx, call)
      Call.cancel(call.pid, :owner)

      assert_receive {:hangup, task, @session}
      task_ref = monitored!(task)
      fire!(call, :hangup_watchdog)
      assert_receive {:DOWN, ^task_ref, :process, ^task, :killed}

      closed!(call, 12)
      assert ended!(call).status == "ended"
    end

    test "session.closed while the hangup is in flight ends at once; nothing is sent again",
         ctx do
      Fakes.script(:hangup, :wait)
      call = live!(ctx)
      quiet!(ctx, call)
      Call.cancel(call.pid, :owner)

      assert_receive {:hangup, task, @session}
      task_ref = monitored!(task)
      closed!(call, 18)

      report = ended!(call)
      assert report.status == "ended"
      assert report.voice_seconds == 18
      assert_receive {:DOWN, ^task_ref, :process, ^task, _reason}
      refute_received {:hangup, _task, _session}
    end

    test "a stuck stop of the running turn never holds up the hangup, and ends with the call",
         ctx do
      Fakes.script(:delegate_cancel, :wait)
      call = live!(ctx)
      running!(call, "del_1")
      quiet!(ctx, call)
      :ok = Call.cancel(call.pid, :owner)

      assert_receive {:delegate_cancel_from, stopper}
      stopper_ref = monitored!(stopper)
      assert_receive {:hangup, _task, @session}

      assert hung_up_and_closed_after_hangup!(call, 9).status == "ended"
      assert_receive {:DOWN, ^stopper_ref, :process, ^stopper, _reason}
    end

    test "a hangup that provably never left is sent again, spaced, inside the window", ctx do
      not_sent = {:error, {:not_sent, {:transport, :econnrefused}}}
      Fakes.script(:hangup, {:sequence, [not_sent, {:ok, :accepted}]})
      call = live!(ctx)
      quiet!(ctx, call)
      Call.cancel(call.pid, :owner)

      assert_receive {:hangup, _task, @session}
      assert_receive {:scheduled, {:phone_call_timer, :hangup_resend, _token} = resend, 2_000}
      sync!(call)
      refute_received {:hangup, _task, _session}
      send(call.pid, resend)

      assert_receive {:hangup, _task, @session}
      assert hung_up_and_closed_after_hangup!(call, 6).status == "ended"
      assert row!(ctx, call.id).cleanup_attempts == 2
      refute_received {:hangup, _task, _session}
    end

    test "an unknown hangup is never sent again", ctx do
      Fakes.script(:hangup, {:result, {:error, {:unknown, {:transport, :timeout}}}})
      call = live!(ctx)
      quiet!(ctx, call)
      Call.cancel(call.pid, :owner)

      assert_receive {:hangup, _task, @session}
      fire!(call, :drain)
      assert ended!(call).status == "closure_unconfirmed"
      refute_received {:scheduled, {:phone_call_timer, :hangup_resend, _token}, _ms}
      refute_received {:hangup, _task, _session}
    end

    test "a hangup that never left is not sent again past the window", ctx do
      Fakes.script(:hangup, :wait)
      call = live!(ctx)
      quiet!(ctx, call)
      Call.cancel(call.pid, :owner)
      assert_receive {:hangup, task, @session}

      :atomics.add(ctx.clock, 1, 29_000)
      Fakes.answer(task, {:error, {:not_sent, {:transport, :nxdomain}}})
      fire!(call, :drain)

      assert ended!(call).status == "closure_unconfirmed"
      refute_received {:scheduled, {:phone_call_timer, :hangup_resend, _token}, _ms}
      refute_received {:hangup, _task, _session}
    end

    test "a hangup that never left is not sent again past the cleanup cap", ctx do
      Fakes.script(:hangup, {:result, {:error, {:not_sent, {:transport, :econnrefused}}}})
      call = live!(ctx, %{}, &consume!(ctx, &1, :cleanup_attempts, 2))
      quiet!(ctx, call)

      capture_log(fn ->
        Call.cancel(call.pid, :owner)
        assert_receive {:hangup, _task, @session}
        fire!(call, :hangup_resend)
        fire!(call, :drain)
        assert ended!(call).status == "closure_unconfirmed"
      end)

      refute_received {:hangup, _task, _session}
      assert row!(ctx, call.id).cleanup_attempts == 3
    end

    test "a cleanup count that times out sends no hangup", ctx do
      Fakes.script({:ledger, {:consume, :cleanup_attempts}}, {:result, {:error, :timeout}})
      call = live!(ctx)
      quiet!(ctx, call)

      capture_log(fn ->
        Call.cancel(call.pid, :owner)
        fire!(call, :drain)
        assert ended!(call).status == "closure_unconfirmed"
      end)

      refute_received {:hangup, _task, _session}
    end
  end

  # --- the engine stopping --------------------------------------------------------------

  describe "an engine stop in the ending tail" do
    test "during the wait for speech: hung up at once, nothing read, said so", ctx do
      call = live!(ctx)
      fire!(call, :deadline)
      assert_receive {:scheduled, {:phone_call_timer, :speech, _token}, 1_500}

      :ok = Call.cancel(call.pid, :shutdown)
      assert_receive {:hangup, _task, @session}
      report = hung_up_and_closed_after_hangup!(call, 40)

      assert report.status == "ended"
      assert report.outcome == "unknown"
      assert report.uncertainty =~ "Fermix stopped"
      assert report.failure_reason == "call_deadline_reached; engine_stopped"
      refute_received {:extract, _entries, _facts, _opts}
    end

    test "while its outcome is read: the reading is abandoned and the report goes at once",
         ctx do
      Fakes.script(:extract, :wait)
      call = live!(ctx)
      closed!(call, 33, "remote_hangup")
      assert_receive {:extract, _entries, _facts, _opts}

      :ok = Call.cancel(call.pid, :shutdown)
      report = ended!(call)
      assert report.status == "ended"
      assert report.voice_seconds == 33
      assert report.outcome == "unknown"
      assert report.uncertainty =~ "Fermix stopped"
      assert report.failure_reason == "engine_stopped"
    end

    test "with a hangup outstanding: only the stop's own hangup wait is left", ctx do
      Fakes.script(:hangup, :wait)
      call = live!(ctx)
      quiet!(ctx, call)
      :ok = Call.cancel(call.pid, :owner)
      assert_receive {:hangup, _task, @session}
      assert_receive {:scheduled, {:phone_call_timer, :hangup_watchdog, _token}, 30_000}

      :ok = Call.cancel(call.pid, :shutdown)
      assert_receive {:scheduled, {:phone_call_timer, :hangup_watchdog, _token}, 3_000}
    end

    test "an owner stop or the off switch in the tail changes nothing", ctx do
      call = live!(ctx)
      fire!(call, :deadline)
      assert_receive {:scheduled, {:phone_call_timer, :speech, _token}, 1_500}

      :ok = Call.cancel(call.pid, :owner)
      :ok = Call.cancel(call.pid, :disabled)
      sync!(call)
      refute_received {:hangup, _task, _session}
    end
  end

  # --- the ledger stalling ------------------------------------------------------------

  describe "a ledger write that times out" do
    test "for progress or usage is logged once per call, and the call goes on", ctx do
      Fakes.script({:ledger, :advance}, {:result, {:error, :timeout}})
      Fakes.script({:ledger, :record_usage}, {:result, {:error, :timeout}})

      log =
        capture_log(fn ->
          call = live!(ctx)
          usage!(call, 10.0)
          usage!(call, 20.0)
          quiet!(ctx, call)
          Call.cancel(call.pid, :owner)
          report = hung_up_and_closed!(call, 25)
          assert report.status == "ended"
        end)

      assert length(String.split(log, "advance not recorded")) == 2
      assert length(String.split(log, "usage not recorded")) == 2
    end
  end

  # --- what a crash or a status read can print ------------------------------------------

  describe "its printed status" do
    test "carries no transcript, brief, opening, reply, handle or credential", ctx do
      call = live!(ctx)
      request = running!(call, "del_1")
      said!(call, :remote, "The account ends in 4417.")
      _press = press(ctx, call, request.handle, "9")
      assert_receive {:dtmf, "9", _event_id}
      sync!(call)

      secrets = [
        request.handle,
        "4417",
        "+12125550101",
        "Calloway",
        "Open the call",
        "sk-invented-phone-key",
        "invented-trunk-secret"
      ]

      printed = inspect(:sys.get_status(call.pid), limit: :infinity, printable_limit: :infinity)
      for secret <- secrets, do: refute(printed =~ secret, "status printed #{secret}")

      handled = [
        {:phone_call_delegation, call.id, "del_1", 1,
         {:ok, %{reply: "The account ends in 4417.", backend_usage: nil}}},
        {:phone_sideband, call.sideband,
         {:event,
          {:transcript,
           %{speaker: :remote, text: "It ends 4417", start_ms: 1, end_ms: 2, event_id: nil}}}},
        {:"$gen_call", {self(), make_ref()}, {:press_keys, request.handle, "4417"}},
        {:"$gen_call", {self(), make_ref()}, {:finish, request.handle, :done, "Calloway 4417"}}
      ]

      # What `format_status/1` hands on carries none of them in its very bytes,
      # however a consumer prints it.
      for message <- handled do
        status = Call.format_status(%{state: :sys.get_state(call.pid), message: message})
        bytes = :erlang.term_to_binary(status)

        for secret <- secrets,
            do: assert(:binary.match(bytes, secret) == :nomatch, "#{inspect(elem(message, 0))}")
      end

      held = :erlang.term_to_binary(:sys.get_state(call.pid))
      assert :binary.match(held, "invented-trunk-secret") == :nomatch
      assert :binary.match(held, "sk-invented-phone-key") == :nomatch
      assert {:error, :unknown_request} = GenServer.call(call.pid, :not_a_request)

      # A fragment with no text fails a clause that takes the whole state, so
      # the crash's stack frame carries the state as an argument.
      pid = call.pid

      log =
        capture_log(fn ->
          sideband!(call, {:event, {:transcript, %{speaker: :remote}}})
          assert_receive {:EXIT, ^pid, _reason}
        end)

      assert log =~ "terminating"
      for secret <- secrets, do: refute(log =~ secret, "the crash report printed #{secret}")
    end
  end

  # --- cancel -------------------------------------------------------------------------------

  describe "cancel/2" do
    test "a create in flight cannot be retracted: its session is only closed", ctx do
      call = start!(ctx)
      {task, _request} = create!()
      :ok = Call.cancel(call.pid, :owner)
      sync!(call)
      refute_received {:hangup, _task, _session}

      Fakes.answer(task, {:ok, %{session_id: @session, http_status: 201, transport_type: "sip"}})
      assert_receive {:hangup, _task, @session}
      assert_receive {:extract, [], %{answered: false, end_reason: :cancelled}, _opts}

      report = ended!(call)
      assert report.status == "closure_unconfirmed"
      assert report.failure_reason == "cancelled_by_owner"
      assert row!(ctx, call.id).provider_session_id == @session
      refute_received {:attach, _sideband, _session, _key}
      refute_received {:create, _task, _request}
    end

    test "a create in flight whose answer is lost stays unknown after the switch", ctx do
      call = start!(ctx)
      {task, _request} = create!()
      :ok = Call.cancel(call.pid, :disabled)
      Fakes.answer(task, {:error, {:unknown, {:transport, :closed}}})

      assert ended!(call).status == "dispatch_unknown"
      refute_received {:hangup, _task, _session}
      refute_received {:create, _task, _request}
    end

    test "the off switch on a live call stops its turn before the hangup", ctx do
      call = live!(ctx)
      _request = running!(call, "del_1")
      quiet!(ctx, call)
      :ok = Call.cancel(call.pid, :disabled)

      assert_receive {:hangup, _task, @session}
      assert Fakes.recorded() == [{:delegate_cancel, "del_1"}, {:hangup, @session}]

      report = hung_up_and_closed_after_hangup!(call, 22)
      assert report.failure_reason == "phone_calls_disabled"
      assert_receive {:extract, _entries, %{answered: true, end_reason: :cancelled}, _opts}
    end

    test "a second cancel, or one while ending, sends nothing more", ctx do
      call = live!(ctx)
      quiet!(ctx, call)
      :ok = Call.cancel(call.pid, :owner)
      :ok = Call.cancel(call.pid, :disabled)
      assert_receive {:hangup, _task, @session}
      :ok = Call.cancel(call.pid, :owner)

      report = hung_up_and_closed_after_hangup!(call, 5)
      assert report.failure_reason == "cancelled_by_owner"
      refute_received {:hangup, _task, _session}
    end
  end

  # A call whose turn finishes it with `reason`, then fails to answer (the
  # bridge withheld its reply): what was said on the call after the finish.
  # The row is ended afterwards so the next call in the same test is admitted.
  defp failed_finish_says(ctx, reason) do
    call = live!(ctx)
    request = running!(call, "del_1")
    quiet!(ctx, call)
    :ok = CallControls.finish(call.id, request.handle, reason, nil, registry: ctx.registry)

    send(
      call.pid,
      {:phone_call_delegation, call.id, "del_1", request.revision,
       {:error, {:reply_withheld, :too_long}}}
    )

    sync!(call)
    said = collect_said([])

    if said != [] do
      quiet!(ctx, call)
      fire!(call, :speech)
    end

    hung_up_and_closed!(call, 5)
    {:ok, _row} = Ledger.terminalize(call.id, "ended", %{ended_at: @t0}, server: ctx.repo)
    said
  end

  defp collect_said(said) do
    receive do
      {:said, id, text} -> collect_said([{id, text} | said])
    after
      0 -> Enum.reverse(said)
    end
  end

  defp hung_up_and_closed_after_hangup!(call, seconds) do
    assert_receive {:scheduled, {:phone_call_timer, :drain, _token}, 5_000}
    closed!(call, seconds)
    ended!(call)
  end

  # --- the outcome ---------------------------------------------------------------------------

  describe "the end report" do
    test "carries the reading's outcome, evidence and uncertainty", ctx do
      confirmed = %Outcome{
        outcome: :confirmed,
        facts: %{date: "2031-03-08", local_time: "19:30", timezone: "America/New_York"},
        excerpts: [%{speaker: :remote, text: "Booked for two.", start_ms: 1, end_ms: 2}],
        uncertainty: "No reference number was given."
      }

      Fakes.script(:extract, {:result, {:ok, confirmed}})
      call = live!(ctx)
      closed!(call, 95.0, "remote_hangup")

      report = ended!(call)
      assert report.status == "ended"
      assert report.outcome == "confirmed"
      assert report.outcome_facts["local_time"] == "19:30"
      assert [%{speaker: "recipient", text: "Booked for two."}] = report.evidence
      assert report.uncertainty == "No reference number was given."
      assert report.voice_seconds == 95
    end

    test "a reading past its watchdog leaves the outcome unknown, said so", ctx do
      Fakes.script(:extract, :wait)

      capture_log(fn ->
        call = live!(ctx)
        closed!(call, 7, "remote_hangup")
        assert_receive {:extract, _entries, _facts, _opts}

        assert_receive {:scheduled, {:phone_call_timer, :extract_watchdog, _token} = watchdog,
                        35_000}

        send(call.pid, watchdog)

        report = ended!(call)
        assert report.outcome == "unknown"
        assert report.uncertainty =~ "could not read"
      end)
    end
  end
end
