defmodule FermixCore.PhoneCalls.DeliveryTest do
  # async: false: the stub channel adapter and the stub dispatcher report to a
  # registered name this module's tests share.
  use ExUnit.Case, async: false

  alias FermixCore.Memory.Repo
  alias FermixCore.PhoneCalls.Continuation
  alias FermixCore.PhoneCalls.Delivery
  alias FermixCore.PhoneCalls.DeliveryWorker
  alias FermixCore.PhoneCalls.Ledger
  alias FermixCore.PhoneCalls.Limits

  @sink :phone_delivery_test_sink
  # Every name, number and id here is invented.
  @t0 ~U[2031-03-04 15:00:00.000000Z]

  defmodule SinkAdapter do
    def send_message(destination, text, opts) do
      send(:phone_delivery_test_sink, {:sent, destination, text, opts})
      :ok
    end
  end

  defmodule FailingAdapter do
    def send_message(_destination, _text, _opts), do: {:error, :channel_down}
  end

  defmodule SinkDispatcher do
    def dispatch(notice) do
      send(:phone_delivery_test_sink, {:dispatched, notice})
      :ok
    end
  end

  defmodule RefusingDispatcher do
    def dispatch(_notice), do: {:error, {:no_owner_configured, "telegram"}}
  end

  setup do
    Process.register(self(), @sink)
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-phone-delivery-#{unique}.db")
    repo = :"phone_delivery_repo_#{unique}"
    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path}, id: repo)

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    %{repo: repo}
  end

  defp terminal_row!(ctx, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          request_id: "main-#{System.unique_integer([:positive])}",
          owner_id: "default",
          authorization: "direct",
          origin_kind: "chat",
          delivery_mode: "origin",
          platform: "telegram",
          destination: "40017",
          thread: "88",
          mandate: %{"contact_name" => "Calloway Bistro", "destination_kind" => "business"},
          mandate_hash: String.duplicate("b2", 32),
          model: "gpt-live-1",
          voice: "marin",
          prompt_version: "phone-1",
          carrier_profile: "telnyx_credential_v1"
        },
        overrides
      )

    {:ok, {:admitted, row}} = Ledger.admit(attrs, @t0, server: ctx.repo)
    {:ok, _row} = Ledger.claim_dispatch(row.id, @t0, server: ctx.repo)

    {:ok, ended} =
      Ledger.terminalize(
        row.id,
        "ended",
        %{ended_at: DateTime.add(@t0, 90, :second), outcome: "unavailable"},
        server: ctx.repo
      )

    ended
  end

  defp hand_off_opts(ctx, extra) do
    Keyword.merge(
      [repo: ctx.repo, now_fn: fn -> DateTime.add(@t0, 100, :second) end, delivery_opts: []],
      extra
    )
  end

  describe "snapshot/3" do
    test "a chat turn's destination is its own conversation, frozen" do
      context = %{conversation_key: {"telegram", "40017", "88"}}

      assert {:ok, snapshot} = Delivery.snapshot(context, false)
      assert snapshot.origin_kind == "chat"
      assert snapshot.delivery_mode == "origin"

      assert {snapshot.platform, snapshot.destination, snapshot.thread} ==
               {"telegram", "40017", "88"}

      assert snapshot.origin_conversation == ["telegram", "40017", "88"]
    end

    test "a voice turn's destination is the owner's own inbox, or it is refused" do
      owners = [owner_inbox: [jobs_config: [], configured_owners: %{"signal" => "+14155550111"}]]

      assert {:ok, snapshot} =
               Delivery.snapshot(%{conversation_key: {"voice", "u-1", :root}}, true, owners)

      assert snapshot.origin_kind == "voice"
      assert snapshot.delivery_mode == "channel"
      assert {snapshot.platform, snapshot.destination} == {"signal", "+14155550111"}

      none = [owner_inbox: [jobs_config: [], configured_owners: %{}]]
      assert {:error, :no_owner_inbox} = Delivery.snapshot(%{}, true, none)
    end

    test "a scheduled or unknown origin has no chat to report into" do
      assert {:error, {:unresolvable_delivery_origin, :nope}} =
               Delivery.snapshot(%{conversation_key: :nope}, false)
    end
  end

  describe "the continuation notice" do
    test "is the composed report and Fermix's closing, marked a depth-1 follow-up" do
      row = %{
        id: "pc_0a1b2c3d4e5f",
        status: "ended",
        outcome: "options",
        usage_state: "incomplete",
        origin_kind: "chat",
        platform: "telegram",
        destination: "40017",
        thread: nil,
        evidence: [%{"speaker" => "recipient", "text" => "Only 21:00 is open."}]
      }

      assert {:ok, notice} = Continuation.notice(row)
      assert notice.content =~ "[phone call pc_0a1b2c3d4e5f] ended"
      assert notice.content =~ ~s(<untrusted_tool_result source="phone_call_recipient">)
      assert notice.content =~ "Do not place another call from this turn"
      assert notice.metadata.harness_continuation == true
      assert notice.metadata.harness_continuation_depth == 1
      refute Map.has_key?(notice.metadata, :harness_run_id)
      assert is_nil(notice.client_origin)
    end

    test "only a chat origin continues, and never the owner's own stop" do
      assert Continuation.continuable?(%{origin_kind: "chat"})
      assert Continuation.continuable?(%{origin_kind: "chat", failure_reason: "worker_lost"})
      refute Continuation.continuable?(%{origin_kind: "voice"})

      refute Continuation.continuable?(%{
               origin_kind: "chat",
               failure_reason: "cancelled_by_owner"
             })
    end
  end

  describe "hand_off/2" do
    test "a chat origin re-enters its conversation once and is written", ctx do
      row = terminal_row!(ctx)

      :ok =
        Delivery.hand_off(
          row,
          hand_off_opts(ctx, continuation_opts: [dispatcher: SinkDispatcher])
        )

      assert_receive {:dispatched, %{destination: "40017", thread: "88"}}
      refute_received {:sent, _destination, _text, _opts}

      assert {:ok, %{report_status: "written", delivery_attempts: 0}} =
               Ledger.get(row.id, server: ctx.repo)
    end

    test "a refused continuation falls to one inline send", ctx do
      row = terminal_row!(ctx)

      :ok =
        Delivery.hand_off(
          row,
          hand_off_opts(ctx,
            continuation_opts: [dispatcher: RefusingDispatcher],
            delivery_opts: [adapter: SinkAdapter]
          )
        )

      assert_receive {:sent, "40017", text, opts}
      assert text =~ "[phone call #{row.id}] ended"
      assert Keyword.get(opts, :message_thread_id) == "88"
      assert {:ok, %{report_status: "written"}} = Ledger.get(row.id, server: ctx.repo)
    end

    test "a voice origin is sent as text to the frozen inbox", ctx do
      row =
        terminal_row!(ctx, %{
          origin_kind: "voice",
          delivery_mode: "channel",
          platform: "signal",
          destination: "+14155550111",
          thread: nil
        })

      :ok =
        Delivery.hand_off(
          row,
          hand_off_opts(ctx,
            continuation_opts: [dispatcher: SinkDispatcher],
            delivery_opts: [adapter: SinkAdapter]
          )
        )

      assert_receive {:sent, "+14155550111", _text, _opts}
      refute_received {:dispatched, _notice}
    end

    test "a failed inline send is the first attempt, left pending for the worker", ctx do
      row = terminal_row!(ctx, %{origin_kind: "voice", delivery_mode: "channel"})

      :ok =
        Delivery.hand_off(
          row,
          hand_off_opts(ctx, delivery_opts: [adapter: FailingAdapter, delivery_backoff_ms: 0])
        )

      assert {:ok, pending} = Ledger.get(row.id, server: ctx.repo)
      assert pending.report_status == "pending"
      assert pending.delivery_attempts == 1
      assert pending.last_delivery_error =~ "channel_down"
      assert pending.next_delivery_at == DateTime.add(@t0, 130, :second)
    end
  end

  describe "the delivery worker" do
    # The worker's clock: an Agent the test moves forward between ticks.
    defp start_worker(ctx, adapter, now) do
      clock = start_supervised!({Agent, fn -> now end}, id: :phone_worker_clock)

      worker =
        start_supervised!(
          {DeliveryWorker,
           name: :"phone_delivery_worker_#{System.unique_integer([:positive])}",
           repo: ctx.repo,
           timer_enabled: false,
           now_fn: fn -> Agent.get(clock, & &1) end,
           delivery_opts: [adapter: adapter, delivery_backoff_ms: 0]}
        )

      {worker, clock}
    end

    defp advance(clock, seconds), do: Agent.update(clock, &DateTime.add(&1, seconds, :second))

    defp tick(worker) do
      send(worker, :tick)
      :sys.get_state(worker)
    end

    test "sends a due report once, labelled as a resend, and marks it written", ctx do
      row = terminal_row!(ctx, %{origin_kind: "voice", delivery_mode: "channel"})

      {:ok, _row} =
        Ledger.mark_report(
          row.id,
          %{delivery_attempts: 1, next_delivery_at: DateTime.add(@t0, 120, :second)},
          server: ctx.repo
        )

      {worker, _clock} = start_worker(ctx, SinkAdapter, DateTime.add(@t0, 200, :second))
      tick(worker)

      assert_receive {:sent, "40017", text, _opts}
      assert text =~ "(Sent again: an earlier attempt"
      assert {:ok, %{report_status: "written"}} = Ledger.get(row.id, server: ctx.repo)

      tick(worker)
      refute_received {:sent, _destination, _text, _opts}
    end

    test "after the attempt limit the report is delivery_unconfirmed and never sent again", ctx do
      row = terminal_row!(ctx, %{origin_kind: "voice", delivery_mode: "channel"})
      {:ok, _row} = Ledger.mark_report(row.id, %{delivery_attempts: 1}, server: ctx.repo)

      late = DateTime.add(@t0, 10 * 86_400, :second)
      {worker, clock} = start_worker(ctx, FailingAdapter, late)

      for _attempt <- 2..Limits.max_report_delivery_attempts() do
        tick(worker)
        advance(clock, 3_600)
      end

      assert {:ok, row} = Ledger.get(row.id, server: ctx.repo)
      assert row.report_status == "delivery_unconfirmed"
      assert row.delivery_attempts == Limits.max_report_delivery_attempts()
      assert row.last_delivery_error =~ "channel_down"

      assert {:ok, []} =
               Ledger.pending_reports(DateTime.add(late, 86_400, :second), 10, server: ctx.repo)
    end

    test "the backoff doubles from 30 s and is capped at 30 min" do
      assert DeliveryWorker.backoff_ms(1) == 30_000
      assert DeliveryWorker.backoff_ms(2) == 60_000
      assert DeliveryWorker.backoff_ms(40) == 1_800_000
    end
  end
end
