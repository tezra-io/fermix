defmodule FermixChannels.X.PumpTest do
  # The X channel's flow (priv/connect/PROTOCOL.md §3–§6) against a real
  # memory store of the test's own, a fake Connect client and a fake agent:
  # every ingest goes through the real gateway and the real Authorizer, which
  # reads the stored row. The adapter's closures reach the pump by its name,
  # and the Authorizer finds the store through app env, so this module is
  # synchronous and restores both.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixChannels.Test.XConnectHelper, as: Fixtures
  alias FermixChannels.Test.XConnectHelper.FakeAgent
  alias FermixChannels.Test.XConnectHelper.FakeClient
  alias FermixChannels.X.Assignment
  alias FermixChannels.X.Pump
  alias FermixCore.Memory.Repo
  alias FermixTestSupport.SafeRm
  alias FermixTestSupport.TelemetryCapture

  @now ~U[2026-10-16 05:05:00.000000Z]
  @deadline "2026-10-16T05:06:30Z"
  @limits %{max_assignment_bytes: 32_768, max_result_bytes: 16_384}
  @answer "The parent post says caching cut cold starts from 900 ms to 410 ms."
  @request_sha Fixtures.sha256_hex("@FermixAI explain this")
  @key {"x", "1234567890:1234567890:1", "1844999999999999990"}

  setup do
    unique = System.unique_integer([:positive])
    dir = SafeRm.make_tmp_dir!("x-pump")
    repo = :"x_pump_repo_#{unique}"

    start_supervised!(
      {Repo, name: repo, enabled: true, database_path: Path.join(dir, "memory.db")}
    )

    previous_memory = Application.get_env(:fermix_core, :memory)
    Application.put_env(:fermix_core, :memory, Keyword.put(previous_memory || [], :repo, repo))

    on_exit(fn ->
      if previous_memory,
        do: Application.put_env(:fermix_core, :memory, previous_memory),
        else: Application.delete_env(:fermix_core, :memory)

      SafeRm.rm_rf(dir)
    end)

    {public, seed} = Fixtures.connect_key()
    %{repo: repo, seed: seed, record: Fixtures.record(public)}
  end

  defp start_pump(ctx, opts \\ []) do
    defaults = [
      record: ctx.record,
      client: self(),
      client_module: FakeClient,
      repo: ctx.repo,
      clock: fn -> @now end,
      agent: FakeAgent,
      agent_server: self(),
      runner_epoch: "epoch-now",
      sweep_interval_ms: 3_600_000
    ]

    start_supervised!({Pump, Keyword.merge(defaults, opts)})
  end

  defp connect!, do: Pump.connection({:connected, @limits})

  defp jws(ctx, id, overrides \\ %{}) do
    %{
      "assignment_id" => id,
      "interaction_id" => "ix_" <> id,
      "expires_at" => "2099-01-01T00:00:00Z"
    }
    |> Map.merge(overrides)
    |> Fixtures.payload()
    |> Fixtures.sign(ctx.seed)
  end

  defp assign!(ctx, id, overrides \\ %{}) do
    Pump.frame(%{"t" => "assignment", "jws" => jws(ctx, id, overrides)})
    assert_receive {:to_connect, {:receipt, ^id, :accepted}}
  end

  defp grant!(id, deadline \\ @deadline) do
    Pump.frame(%{
      "t" => "start_ok",
      "assignment_id" => id,
      "attempt" => 1,
      "deadline_at" => deadline
    })

    assert_receive {:agent_message, %{id: ^id} = message}
    message
  end

  defp row(ctx, id) do
    {:ok, row} = Repo.x_assignment(id, server: ctx.repo)
    row
  end

  # Every cast the test sent is handled before the pump answers this call.
  defp flush!, do: {:ok, _status} = Pump.status()

  describe "an assignment's life" do
    test "is received, stored, started, run as a guest and settled once", ctx do
      TelemetryCapture.attach([[:fermix, :channel, :message]], channel: :x)
      start_pump(ctx)
      connect!()

      assign!(ctx, "as_happy")
      assert_receive {:to_connect, {:start, "as_happy"}}

      assert_receive {:telemetry, [:fermix, :channel, :message], %{count: 1},
                      %{direction: :inbound}}

      stored = row(ctx, "as_happy")
      assert stored.status == :accepted
      assert stored.receipt_sent_at == @now

      message = grant!("as_happy")
      assert message.channel == "x"
      assert message.source_trust == :guest
      assert %{status: :running, attempt: 1, runner_epoch: "epoch-now"} = row(ctx, "as_happy")

      assert :ok = message.reply_fn.({:text, "a first draft"})
      assert :ok = message.reply_fn.({:text, @answer})
      assert :ok = message.turn_result_fn.({:completed})

      assert_receive {:to_connect, {:result, result}}

      assert result == %{
               "t" => "result",
               "assignment_id" => "as_happy",
               "attempt" => 1,
               "request_sha256" => @request_sha,
               "decision" => "public_reply",
               "public_text" => @answer,
               "result_sha256" => Fixtures.sha256_hex("public_reply\n" <> @answer)
             }

      Pump.frame(%{"t" => "result_ack", "assignment_id" => "as_happy", "attempt" => 1})
      assert {:ok, %{connection: :connected, pending: 0, running: 0}} = Pump.status()

      settled = row(ctx, "as_happy")
      assert settled.status == :completed
      assert settled.decision == :public_reply
      assert settled.result_acked_at == @now
    end

    test "a turn that staged no text has no reply", ctx do
      start_pump(ctx)
      connect!()
      assign!(ctx, "as_quiet")
      message = grant!("as_quiet")

      message.turn_result_fn.({:completed})

      assert_receive {:to_connect, {:result, %{"decision" => "no_reply"} = result}}
      refute Map.has_key?(result, "public_text")
      assert result["result_sha256"] == Fixtures.sha256_hex("no_reply\n")
    end

    test "a failed turn's result is failed, whatever it staged", ctx do
      start_pump(ctx)
      connect!()
      assign!(ctx, "as_broke")
      message = grant!("as_broke")

      message.reply_fn.({:text, "half an answer"})
      message.turn_result_fn.({:failed, :provider_timeout})

      assert_receive {:to_connect, {:result, %{"decision" => "failed"} = result}}
      refute Map.has_key?(result, "public_text")
      assert %{status: :failed, decision: :failed} = row(ctx, "as_broke")
    end

    test "a reply too large for a result frame fails the attempt", ctx do
      start_pump(ctx)
      connect!()
      assign!(ctx, "as_huge")
      message = grant!("as_huge")

      message.reply_fn.({:text, String.duplicate("x", 16_000)})
      message.turn_result_fn.({:completed})

      assert_receive {:to_connect, {:result, %{"decision" => "failed"}}}
      assert %{status: :failed, failure_reason: "result_too_large"} = row(ctx, "as_huge")
    end
  end

  describe "receipts" do
    test "a resent assignment is stored once, answered each time, started once", ctx do
      start_pump(ctx)
      connect!()
      frame = %{"t" => "assignment", "jws" => jws(ctx, "as_twice")}

      Pump.frame(frame)
      Pump.frame(frame)

      assert_receive {:to_connect, {:receipt, "as_twice", :accepted}}
      assert_receive {:to_connect, {:receipt, "as_twice", :accepted}}
      assert_receive {:to_connect, {:start, "as_twice"}}
      flush!()
      refute_received {:to_connect, {:start, "as_twice"}}

      assert {:ok, [%{assignment_id: "as_twice"}]} =
               Repo.x_recoverable_assignments(server: ctx.repo)
    end

    test "a token that fails verification is rejected with its reason and not stored", ctx do
      start_pump(ctx)
      connect!()
      {_public, other_seed} = Fixtures.connect_key()

      forged =
        %{"assignment_id" => "as_forged"} |> Fixtures.payload() |> Fixtures.sign(other_seed)

      Pump.frame(%{"t" => "assignment", "jws" => forged})

      assert_receive {:to_connect, {:receipt, "as_forged", {:rejected, :bad_signature}}}
      assert {:error, :not_found} = Repo.x_assignment("as_forged", server: ctx.repo)

      assert {:ok, %{pending: 0, last_failure: %{reason: {:assignment_rejected, :bad_signature}}}} =
               Pump.status()
    end
  end

  describe "starts" do
    test "one X turn at a time: the next start waits for the running turn", ctx do
      start_pump(ctx)
      connect!()
      assign!(ctx, "as_one")
      assert_receive {:to_connect, {:start, "as_one"}}
      assign!(ctx, "as_two")

      message = grant!("as_one")
      flush!()
      refute_received {:to_connect, {:start, "as_two"}}
      assert {:ok, %{pending: 1, running: 1}} = Pump.status()

      message.turn_result_fn.({:completed})
      assert_receive {:to_connect, {:result, %{"assignment_id" => "as_one"}}}
      assert_receive {:to_connect, {:start, "as_two"}}
    end

    test "start_refused fails the assignment and the next one asks", ctx do
      start_pump(ctx)
      connect!()
      assign!(ctx, "as_refused")
      assert_receive {:to_connect, {:start, "as_refused"}}
      assign!(ctx, "as_next")

      Pump.frame(%{
        "t" => "start_refused",
        "assignment_id" => "as_refused",
        "reason" => "suppressed"
      })

      assert_receive {:to_connect, {:start, "as_next"}}

      assert %{status: :failed, failure_reason: "start_refused:suppressed"} =
               row(ctx, "as_refused")

      refute_received {:to_connect, {:result, _result}}
    end
  end

  describe "stopping" do
    test "a cancel stops the running turn through the queue and is acknowledged", ctx do
      start_pump(ctx)
      connect!()
      assign!(ctx, "as_cancel")
      message = grant!("as_cancel")

      Pump.frame(%{"t" => "cancel", "assignment_id" => "as_cancel", "reason" => "operator"})

      assert_receive {:"$gen_call", from, {:stop_turn, @key, "as_cancel"}}
      GenServer.reply(from, {:ok, :stopped})
      assert_receive {:to_connect, {:cancel_ack, "as_cancel"}}
      assert %{status: :cancelled, failure_reason: "cancel:operator"} = row(ctx, "as_cancel")

      # The queue answers the stopped turn with {:cancelled}: the attempt has
      # already ended, so nothing more is sent.
      message.turn_result_fn.({:cancelled})
      flush!()
      refute_received {:to_connect, {:result, _result}}
      assert %{status: :cancelled} = row(ctx, "as_cancel")
    end

    test "a cancel before the start settles the waiting assignment", ctx do
      start_pump(ctx)
      connect!()
      assign!(ctx, "as_early")
      assert_receive {:to_connect, {:start, "as_early"}}

      Pump.frame(%{"t" => "cancel", "assignment_id" => "as_early", "reason" => "suppressed"})

      assert_receive {:to_connect, {:cancel_ack, "as_early"}}
      refute_received {:"$gen_call", _from, {:stop_turn, _key, _id}}
      assert %{status: :cancelled} = row(ctx, "as_early")
      assert {:ok, %{pending: 0}} = Pump.status()
    end

    test "a turn past its deadline is stopped and its attempt fails", ctx do
      start_pump(ctx)
      connect!()
      assign!(ctx, "as_late")
      message = grant!("as_late", "2026-10-16T05:04:00Z")

      assert_receive {:"$gen_call", from, {:stop_turn, @key, "as_late"}}
      GenServer.reply(from, {:ok, :stopped})

      assert_receive {:to_connect,
                      {:result, %{"assignment_id" => "as_late", "decision" => "failed"}}}

      assert %{status: :failed, failure_reason: "deadline"} = row(ctx, "as_late")

      message.turn_result_fn.({:cancelled})
      flush!()
      refute_received {:to_connect, {:result, _result}}
    end

    test "an accepted assignment past its expiry is expired by the sweep, silently", ctx do
      {:ok, clock} = Agent.start_link(fn -> @now end)
      start_pump(ctx, clock: fn -> Agent.get(clock, & &1) end)
      connect!()
      assign!(ctx, "as_running")
      assert_receive {:to_connect, {:start, "as_running"}}
      assign!(ctx, "as_stale", %{"expires_at" => "2026-10-16T05:15:00Z"})

      Agent.update(clock, fn _now -> ~U[2026-10-16 05:20:00Z] end)
      assert :ok = Pump.sweep()

      assert %{status: :expired} = row(ctx, "as_stale")
      assert {:ok, %{pending: 1}} = Pump.status()
      refute_received {:to_connect, {:start, "as_stale"}}
      refute_received {:to_connect, {:result, _result}}
    end
  end

  describe "durability" do
    defp seed_row!(ctx, id, claimed_at) do
      {:ok, assignment} = ctx |> jws(id) |> Assignment.claims()

      attrs = %{
        assignment_id: id,
        interaction_id: assignment.interaction_id,
        tenant_id: assignment.tenant_id,
        instance_id: assignment.instance_id,
        requester_x_user_id: assignment.requester_x_user_id,
        conversation_id: assignment.conversation_id,
        request_sha256: assignment.request_sha256,
        jws: jws(ctx, id),
        expires_at: assignment.expires_at,
        claimed_at: claimed_at
      }

      {:ok, {:claimed, _row}} = Repo.x_claim_assignment(attrs, server: ctx.repo)
    end

    defp seed_running!(ctx, id, epoch, attempt) do
      grant = %{attempt: attempt, runner_epoch: epoch, deadline_at: @now, now: @now}
      {:ok, _row} = Repo.x_start_assignment(id, grant, server: ctx.repo)
    end

    defp owed_result(id, attempt) do
      frame = %{
        "t" => "result",
        "assignment_id" => id,
        "attempt" => attempt,
        "request_sha256" => @request_sha,
        "decision" => "no_reply",
        "result_sha256" => Fixtures.sha256_hex("no_reply\n")
      }

      {frame,
       %{
         decision: :no_reply,
         result_sha256: frame["result_sha256"],
         result_json: Jason.encode!(frame),
         now: @now
       }}
    end

    test "a boot recovers each row state", ctx do
      seed_row!(ctx, "as_wait", ~U[2026-10-16 05:00:01Z])
      seed_row!(ctx, "as_dead", ~U[2026-10-16 05:00:02Z])
      seed_running!(ctx, "as_dead", "epoch-old", 2)
      seed_row!(ctx, "as_owed", ~U[2026-10-16 05:00:03Z])
      seed_running!(ctx, "as_owed", "epoch-old", 1)
      {owed_frame, owed} = owed_result("as_owed", 1)
      {:ok, _row} = Repo.x_complete_assignment("as_owed", 1, owed, server: ctx.repo)
      seed_row!(ctx, "as_settled", ~U[2026-10-16 05:00:04Z])
      seed_running!(ctx, "as_settled", "epoch-old", 1)
      {_frame, settled} = owed_result("as_settled", 1)
      {:ok, _row} = Repo.x_complete_assignment("as_settled", 1, settled, server: ctx.repo)
      {:ok, _row} = Repo.x_ack_result("as_settled", 1, @now, server: ctx.repo)

      start_pump(ctx)
      flush!()

      # A running row of an earlier process died with it: failed at once, its
      # result held until a connection exists.
      assert %{status: :failed, failure_reason: "runner_restarted"} = row(ctx, "as_dead")
      refute_received {:to_connect, _frame}

      connect!()

      assert_receive {:to_connect,
                      {:result,
                       %{"assignment_id" => "as_dead", "attempt" => 2, "decision" => "failed"}}}

      assert_receive {:to_connect, {:result, ^owed_frame}}
      assert_receive {:to_connect, {:start, "as_wait"}}
      flush!()
      refute_received {:to_connect, {:result, %{"assignment_id" => "as_settled"}}}
    end

    test "a result is resent on every connection until Connect acknowledges it", ctx do
      start_pump(ctx)
      connect!()
      assign!(ctx, "as_resend")
      grant!("as_resend").turn_result_fn.({:completed})
      assert_receive {:to_connect, {:result, %{"assignment_id" => "as_resend"} = first}}

      Pump.connection(:down)
      connect!()
      assert_receive {:to_connect, {:result, ^first}}

      Pump.frame(%{"t" => "result_ack", "assignment_id" => "as_resend", "attempt" => 1})
      Pump.connection(:down)
      connect!()
      flush!()
      refute_received {:to_connect, {:result, _result}}
    end

    test "a conflict leaves the row completed, ends the resends and is logged", ctx do
      start_pump(ctx)
      connect!()
      assign!(ctx, "as_conflict")
      message = grant!("as_conflict")
      message.reply_fn.({:text, @answer})
      message.turn_result_fn.({:completed})
      assert_receive {:to_connect, {:result, %{"assignment_id" => "as_conflict"}}}

      log =
        capture_log(fn ->
          Pump.frame(%{
            "t" => "result_rejected",
            "assignment_id" => "as_conflict",
            "attempt" => 1,
            "reason" => "conflict"
          })

          flush!()
        end)

      assert log =~ "Connect rejected the result of as_conflict (attempt 1): conflict"

      assert %{
               status: :completed,
               decision: :public_reply,
               failure_reason: "result_rejected:conflict"
             } =
               row(ctx, "as_conflict")

      Pump.connection(:down)
      connect!()
      flush!()
      refute_received {:to_connect, {:result, _result}}
    end

    test "nothing is sent while the socket is down", ctx do
      start_pump(ctx)
      connect!()
      assign!(ctx, "as_offline")
      assert_receive {:to_connect, {:start, "as_offline"}}
      Pump.connection(:down)

      Pump.frame(%{
        "t" => "start_ok",
        "assignment_id" => "as_offline",
        "attempt" => 1,
        "deadline_at" => @deadline
      })

      assert_receive {:agent_message, message}
      message.turn_result_fn.({:completed})
      flush!()
      refute_received {:to_connect, {:result, _result}}
      assert {:ok, %{connection: :down}} = Pump.status()

      connect!()
      assert_receive {:to_connect, {:result, %{"assignment_id" => "as_offline"}}}
    end
  end
end
