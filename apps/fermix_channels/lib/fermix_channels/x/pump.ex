defmodule FermixChannels.X.Pump do
  @moduledoc """
  Owns the X channel's flow (`priv/connect/PROTOCOL.md` §3–§6), one assignment
  at a time.

  For each `assignment` frame: verify it (`X.Assignment`), claim its row in
  `memory.db` as `accepted`, and only then answer `receipt accepted` (I7); a
  token that fails verification is answered `receipt rejected` with the first
  failing reason and nothing is stored. A second copy of a stored assignment
  is answered again and stores nothing. When no X turn is running or waiting
  for its grant, the oldest accepted assignment asks for a `start`; its
  `start_ok` moves the row to `running` under the attempt it names and this
  process's epoch, and the turn is ingested through the gateway like any other
  channel's, with the assignment as the transport proof (`Gateway.Authorizer`
  reads the row again before it admits the turn as a guest).

  The turn ends in exactly one of these ways, each a compare-and-set on the
  row, so the first ending wins and a later one is dropped:

    * the adapter's turn-result callback (`Channels.X.decision/2`) completes
      the row with its result, or fails it;
    * Connect's `cancel` stops the turn and cancels the row (`cancel_ack`);
    * the grant's `deadline_at` passes: the turn is stopped and the attempt
      fails;
    * `start_refused` fails an assignment that never ran.

  A result is sent once the row holds it, and again on every connection until
  Connect answers it (`result_ack`, or `result_rejected`, which is terminal).
  Accepted assignments past their `expires_at` are settled `expired` by a
  sweep, and nothing is sent for them.

  At start this process takes a new epoch and recovers the store (§6):
  `accepted` rows wait for a start again, `running` rows belong to a turn that
  died with an earlier process and fail with a `failed` result, and results
  Connect never answered are resent once connected. Nothing is sent while the
  socket is down; the durable rows carry every obligation across it.
  """

  use GenServer

  require Logger

  alias FermixChannels.Channels.X, as: XChannel
  alias FermixChannels.Gateway
  alias FermixChannels.Gateway.Queue
  alias FermixChannels.Telemetry, as: ChannelTelemetry
  alias FermixChannels.X.Assignment
  alias FermixChannels.X.Client
  alias FermixChannels.X.Pairing
  alias FermixCore.Agents.ConversationKey
  alias FermixCore.Memory.Config, as: MemoryConfig
  alias FermixCore.Memory.Repo
  alias FermixCore.Telemetry

  @sweep_interval_ms 30_000
  # The session's caps until `ready` names them (§3.1).
  @default_limits %{max_assignment_bytes: 32_768, max_result_bytes: 16_384}
  # Room a result frame needs beside its text, so a text over the frame cap
  # less this is failed here instead of closing the socket on every resend.
  @result_overhead_bytes 512

  # The contract's reason vocabularies (§3.2), read off the wire as these atoms
  # and never as new ones.
  @start_refusals %{
    "expired" => :expired,
    "cancelled" => :cancelled,
    "suppressed" => :suppressed,
    "stale_generation" => :stale_generation,
    "unknown_assignment" => :unknown_assignment,
    "already_settled" => :already_settled
  }
  @result_rejections %{
    "conflict" => :conflict,
    "too_long" => :too_long,
    "invalid" => :invalid,
    "stale_attempt" => :stale_attempt,
    "unknown_assignment" => :unknown_assignment
  }
  @cancel_reasons %{
    "expired" => :expired,
    "suppressed" => :suppressed,
    "unlinked" => :unlinked,
    "revoked" => :revoked,
    "operator" => :operator
  }
  @timestamp ~r/\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,6})?Z\z/

  @type connection :: :connecting | :connected | :down | {:refused, term()}
  @type status :: %{
          connection: connection(),
          pending: non_neg_integer(),
          running: 0 | 1,
          last_failure: nil | %{at: DateTime.t(), reason: term()}
        }

  # --- Client API ------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "A decoded frame from Connect, handed over by `X.Client`."
  @spec frame(map(), GenServer.server()) :: :ok
  def frame(frame, server \\ __MODULE__) when is_map(frame),
    do: GenServer.cast(server, {:frame, frame})

  @doc """
  The socket's state, from `X.Client`: `{:connected, limits}` once `ready`
  arrived, else `:connecting`, `:down` or `{:refused, reason}`.
  """
  @spec connection(term(), GenServer.server()) :: :ok
  def connection(connection, server \\ __MODULE__),
    do: GenServer.cast(server, {:connection, connection})

  @doc """
  Stages a turn's reply text on its row (the adapter's text closure). Sent, not
  awaited: the turn may run while this process is ingesting it.
  """
  @spec stage_reply(String.t(), String.t(), GenServer.server()) ::
          :ok | {:error, :x_pump_unavailable}
  def stage_reply(assignment_id, text, server \\ __MODULE__)
      when is_binary(assignment_id) and is_binary(text) do
    cast_if_running(server, {:stage_reply, assignment_id, text})
  end

  @doc "A turn's terminal outcome (the adapter's turn-result closure)."
  @spec turn_result(String.t(), term(), GenServer.server()) :: :ok | {:error, :x_pump_unavailable}
  def turn_result(assignment_id, outcome, server \\ __MODULE__) when is_binary(assignment_id) do
    cast_if_running(server, {:turn_result, assignment_id, outcome})
  end

  @doc "Where the channel stands, for the management family and the adapter's health check."
  @spec status(GenServer.server()) :: {:ok, status()} | {:error, :not_running}
  def status(server \\ __MODULE__) do
    case GenServer.whereis(server) do
      nil -> {:error, :not_running}
      _pid -> {:ok, GenServer.call(server, :status)}
    end
  end

  @doc "Runs the expiry sweep now."
  @spec sweep(GenServer.server()) :: :ok
  def sweep(server \\ __MODULE__), do: GenServer.call(server, :sweep)

  defp cast_if_running(server, message) do
    case GenServer.whereis(server) do
      nil -> {:error, :x_pump_unavailable}
      _pid -> GenServer.cast(server, message)
    end
  end

  # --- GenServer -------------------------------------------------------------

  @impl true
  def init(opts) do
    %Pairing{} = record = Keyword.fetch!(opts, :record)

    state = %{
      record: record,
      client: Keyword.get(opts, :client, Client),
      client_module: Keyword.get(opts, :client_module, Client),
      repo: Keyword.get_lazy(opts, :repo, &MemoryConfig.repo_server/0),
      clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
      agent: Keyword.get(opts, :agent, Queue),
      agent_server: Keyword.get(opts, :agent_server, Queue),
      epoch: Keyword.get_lazy(opts, :runner_epoch, &random_epoch/0),
      sweep_interval_ms: Keyword.get(opts, :sweep_interval_ms, @sweep_interval_ms),
      connection: :connecting,
      limits: @default_limits,
      queue: [],
      starting: nil,
      running: nil,
      last_failure: nil
    }

    {:ok, state, {:continue, :recover}}
  end

  @impl true
  def handle_continue(:recover, state) do
    state = state |> expire() |> sync()
    schedule_sweep(state)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:frame, frame}, state), do: {:noreply, dispatch(frame, state)}

  def handle_cast({:connection, connection}, state),
    do: {:noreply, on_connection(connection, state)}

  def handle_cast({:stage_reply, id, text}, state), do: {:noreply, stage(id, text, state)}

  def handle_cast({:turn_result, id, outcome}, state),
    do: {:noreply, on_turn_result(id, outcome, state)}

  @impl true
  def handle_call(:status, _from, state), do: {:reply, status_of(state), state}
  def handle_call(:sweep, _from, state), do: {:reply, :ok, expire(state)}

  @impl true
  def handle_info(:sweep, state) do
    state = expire(state)
    schedule_sweep(state)
    {:noreply, state}
  end

  def handle_info({:deadline, id, attempt}, %{running: %{id: id, attempt: attempt}} = state),
    do: {:noreply, on_deadline(state)}

  def handle_info({:deadline, _id, _attempt}, state), do: {:noreply, state}

  # --- frames ----------------------------------------------------------------

  defp dispatch(%{"t" => "assignment", "jws" => jws}, state) when is_binary(jws),
    do: on_assignment(jws, state)

  defp dispatch(%{"t" => "start_ok", "assignment_id" => id} = frame, state) when is_binary(id),
    do: on_start_ok(id, frame["attempt"], frame["deadline_at"], state)

  defp dispatch(%{"t" => "start_refused", "assignment_id" => id, "reason" => reason}, state)
       when is_binary(id),
       do: on_start_refused(id, known(reason, @start_refusals), state)

  defp dispatch(%{"t" => "result_ack", "assignment_id" => id, "attempt" => attempt}, state)
       when is_binary(id) and is_integer(attempt),
       do: on_result_ack(id, attempt, state)

  defp dispatch(
         %{"t" => "result_rejected", "assignment_id" => id, "attempt" => attempt} = frame,
         state
       )
       when is_binary(id) and is_integer(attempt),
       do: on_result_rejected(id, attempt, known(frame["reason"], @result_rejections), state)

  defp dispatch(%{"t" => "cancel", "assignment_id" => id, "reason" => reason}, state)
       when is_binary(id),
       do: on_cancel(id, known(reason, @cancel_reasons), state)

  defp dispatch(frame, state) do
    Logger.warning("X: ignored a Connect frame of type #{inspect(Map.get(frame, "t"))}")
    state
  end

  # A reason outside the contract's vocabulary is one word, never a new atom.
  defp known(reason, vocabulary), do: Map.get(vocabulary, reason, :unrecognized)

  # --- assignment → receipt --------------------------------------------------

  defp on_assignment(jws, state) do
    {state, duration_us} = Telemetry.timed_us(fn -> admit(jws, state) end)
    ChannelTelemetry.emit_message(:x, :inbound, 1, duration_us)
    state
  end

  defp admit(jws, state) do
    max_bytes = state.limits.max_assignment_bytes

    case Assignment.verify(jws, state.record, now(state), max_bytes: max_bytes) do
      {:ok, assignment} -> claim(assignment, jws, state)
      {:error, reason} -> refuse(jws, reason, state)
    end
  end

  defp claim(%Assignment{} = assignment, jws, state) do
    case Repo.x_claim_assignment(claim_attrs(assignment, jws, now(state)), repo_opts(state)) do
      {:ok, {_claimed_or_duplicate, row}} ->
        state |> acknowledge(row) |> track(row) |> maybe_start()

      {:error, reason} ->
        Logger.error(
          "X: assignment #{assignment.assignment_id} was not stored: #{inspect(reason)}"
        )

        note_failure(state, {:store_failed, reason})
    end
  end

  defp claim_attrs(%Assignment{} = assignment, jws, now) do
    %{
      assignment_id: assignment.assignment_id,
      interaction_id: assignment.interaction_id,
      tenant_id: assignment.tenant_id,
      instance_id: assignment.instance_id,
      requester_x_user_id: assignment.requester_x_user_id,
      conversation_id: assignment.conversation_id,
      request_sha256: assignment.request_sha256,
      jws: jws,
      expires_at: assignment.expires_at,
      claimed_at: now
    }
  end

  # The receipt goes out only after the row committed (I7), and again for
  # every copy Connect resends.
  defp acknowledge(state, row) do
    if send_frame(state, :send_receipt, [row.assignment_id, :accepted]) == :ok do
      record(Repo.x_mark_receipt_sent(row.assignment_id, now(state), repo_opts(state)))
    end

    state
  end

  defp refuse(jws, reason, state) do
    case Assignment.peek_id(jws) do
      {:ok, id} ->
        Logger.warning("X: refused assignment #{id}: #{reason}")
        send_frame(state, :send_receipt, [id, {:rejected, reason}])

      :error ->
        Logger.error("X: refused an assignment that names no id (#{reason}); nothing to answer")
    end

    note_failure(state, {:assignment_rejected, reason})
  end

  # --- start -----------------------------------------------------------------

  defp track(state, %{status: :accepted, assignment_id: id}) do
    if known_id?(state, id), do: state, else: %{state | queue: state.queue ++ [id]}
  end

  defp track(state, _row), do: state

  defp known_id?(state, id) do
    id in state.queue or state.starting == id or match?(%{id: ^id}, state.running)
  end

  # One X turn at a time (design §12.3): a start is asked for only when no turn
  # runs and none waits for its grant.
  defp maybe_start(%{connection: {:connected, _limits}} = state), do: maybe_start(state, true)
  defp maybe_start(state), do: maybe_start(state, false)

  defp maybe_start(%{starting: nil, running: nil, queue: [id | rest]} = state, true) do
    send_frame(state, :send_start, [id])
    %{state | starting: id, queue: rest}
  end

  defp maybe_start(state, _connected?), do: state

  defp on_start_ok(id, attempt, deadline_at, %{starting: id} = state) do
    with {:ok, attempt} <- positive(attempt),
         {:ok, deadline_at} <- timestamp(deadline_at) do
      grant = %{
        attempt: attempt,
        runner_epoch: state.epoch,
        deadline_at: deadline_at,
        now: now(state)
      }

      start(id, grant, %{state | starting: nil})
    else
      :error -> refuse_grant(id, %{state | starting: nil})
    end
  end

  defp on_start_ok(id, _attempt, _deadline_at, state) do
    Logger.warning("X: a start grant for #{id}, which is not waiting for one; ignored")
    state
  end

  defp start(id, grant, state) do
    case Repo.x_start_assignment(id, grant, repo_opts(state)) do
      {:ok, row} ->
        run(row, state)

      {:error, reason} ->
        Logger.warning("X: assignment #{id} could not start: #{inspect(reason)}")
        state |> note_failure({:start_failed, reason}) |> maybe_start()
    end
  end

  defp refuse_grant(id, state) do
    Logger.error("X: Connect's start grant for #{id} was malformed; the assignment fails")
    failure = %{from: :accepted, reason: :malformed_start_grant, result: nil, now: now(state)}
    record(Repo.x_fail_assignment(id, failure, repo_opts(state)))
    state |> note_failure(:malformed_start_grant) |> maybe_start()
  end

  defp on_start_refused(id, reason, state) do
    Logger.warning("X: Connect refused to start #{id}: #{reason}")
    failure = %{from: :accepted, reason: "start_refused:#{reason}", result: nil, now: now(state)}
    record(Repo.x_fail_assignment(id, failure, repo_opts(state)))

    state
    |> forget(id)
    |> note_failure({:start_refused, reason})
    |> maybe_start()
  end

  # --- the turn --------------------------------------------------------------

  defp run(row, state) do
    case Assignment.claims(row.jws) do
      {:ok, assignment} -> ingest(row, XChannel.message(assignment), state)
      {:error, :malformed} -> fail_attempt(row, :stored_assignment_unreadable, state)
    end
  end

  defp ingest(row, message, state) do
    case Gateway.ingest([message],
           channel: XChannel,
           agent: state.agent,
           agent_server: state.agent_server,
           ingress_context: %{transport: :x, assignment_id: row.assignment_id}
         ) do
      :ok -> %{state | running: running_entry(row, message, state)}
      {:error, reason} -> fail_attempt(row, {:ingest_failed, reason}, state)
    end
  end

  defp running_entry(row, message, state) do
    delay = max(DateTime.diff(row.deadline_at, now(state), :millisecond), 0)

    %{
      id: row.assignment_id,
      attempt: row.attempt,
      conversation_key: message |> Map.from_struct() |> ConversationKey.from(),
      timer: Process.send_after(self(), {:deadline, row.assignment_id, row.attempt}, delay),
      stage_error: nil
    }
  end

  defp stage(id, text, %{running: %{id: id} = running} = state) do
    case Repo.x_stage_reply(id, text, now(state), repo_opts(state)) do
      {:ok, _row} ->
        %{state | running: %{running | stage_error: nil}}

      {:error, reason} ->
        Logger.error("X: the reply for #{id} was not staged: #{inspect(reason)}")
        %{state | running: %{running | stage_error: reason}}
    end
  end

  defp stage(id, _text, state) do
    Logger.info("X: a reply for #{id}, which is not running, was dropped")
    state
  end

  defp on_turn_result(id, outcome, %{running: %{id: id} = running} = state) do
    Process.cancel_timer(running.timer)
    state = %{state | running: nil}

    case Repo.x_assignment(id, repo_opts(state)) do
      {:ok, row} ->
        seal(row, outcome, running.stage_error, state)

      {:error, reason} ->
        log_lost(id, reason)
        maybe_start(state)
    end
  end

  defp on_turn_result(id, outcome, state) do
    Logger.info("X: the outcome #{inspect(outcome)} of #{id} arrived after it ended; dropped")
    state
  end

  defp seal(row, outcome, nil = _stage_error, state) do
    case XChannel.decision(outcome, row.reply_text) do
      {:public_reply, text} -> complete_with_text(row, text, state)
      :no_reply -> complete(row, :no_reply, nil, state)
      :failed -> fail_attempt(row, turn_failure(outcome), state)
    end
  end

  defp seal(row, _outcome, stage_error, state),
    do: fail_attempt(row, {:reply_not_staged, stage_error}, state)

  defp complete_with_text(row, text, state) do
    if byte_size(text) > state.limits.max_result_bytes - @result_overhead_bytes,
      do: fail_attempt(row, :result_too_large, state),
      else: complete(row, :public_reply, text, state)
  end

  defp complete(row, decision, text, state) do
    result = result_fields(row, decision, text) |> Map.put(:now, now(state))

    case Repo.x_complete_assignment(row.assignment_id, row.attempt, result, repo_opts(state)) do
      {:ok, completed} -> send_result(state, completed)
      {:error, reason} -> log_lost(row.assignment_id, reason)
    end

    maybe_start(state)
  end

  defp turn_failure({:cancelled}), do: :turn_stopped
  defp turn_failure({:failed, reason}), do: {:turn_failed, reason}

  # A running attempt that ends without a result Connect can publish: the row
  # fails and owes Connect a `failed` result for the attempt.
  defp fail_attempt(row, reason, state) do
    failure = %{
      from: :running,
      reason: reason_text(reason),
      result: result_fields(row, :failed, nil),
      now: now(state)
    }

    case Repo.x_fail_assignment(row.assignment_id, failure, repo_opts(state)) do
      {:ok, failed} -> send_result(state, failed)
      {:error, error} -> log_lost(row.assignment_id, error)
    end

    state
    |> clear_running(row.assignment_id)
    |> note_failure(reason)
    |> maybe_start()
  end

  defp on_deadline(%{running: running} = state) do
    Logger.warning("X: assignment #{running.id} passed its deadline; the turn is stopped")
    stop_turn(running, state)
    state = %{state | running: nil}

    case Repo.x_assignment(running.id, repo_opts(state)) do
      {:ok, row} ->
        fail_attempt(row, :deadline, state)

      {:error, reason} ->
        log_lost(running.id, reason)
        maybe_start(state)
    end
  end

  defp on_cancel(id, reason, state) do
    Logger.info("X: Connect cancelled #{id} (#{reason})")
    cancellation = %{reason: "cancel:#{reason}", now: now(state)}
    record(Repo.x_cancel_assignment(id, cancellation, repo_opts(state)))
    state = stop_if_running(id, state)
    send_frame(state, :send_cancel_ack, [id])
    state |> forget(id) |> maybe_start()
  end

  defp stop_if_running(id, %{running: %{id: id} = running} = state) do
    Process.cancel_timer(running.timer)
    stop_turn(running, state)
    %{state | running: nil}
  end

  defp stop_if_running(_id, state), do: state

  # The queue answers the stopped turn's callback with `{:cancelled}`, which
  # finds the attempt already ended here and is dropped.
  defp stop_turn(running, state) do
    {:ok, outcome} = Queue.stop_turn(running.conversation_key, running.id, state.agent_server)
    Logger.info("X: stop of #{running.id}: #{outcome}")
  catch
    :exit, reason ->
      Logger.error("X: the queue holding #{running.id} is gone: #{inspect(reason)}")
  end

  # --- results ---------------------------------------------------------------

  defp result_fields(row, decision, text) do
    frame =
      %{
        "t" => "result",
        "assignment_id" => row.assignment_id,
        "attempt" => row.attempt,
        "request_sha256" => row.request_sha256,
        "decision" => Atom.to_string(decision),
        "result_sha256" => sha256_hex("#{decision}\n#{text || ""}")
      }
      |> put_text(text)

    %{
      decision: decision,
      result_sha256: frame["result_sha256"],
      result_json: Jason.encode!(frame)
    }
  end

  defp put_text(frame, nil), do: frame
  defp put_text(frame, text), do: Map.put(frame, "public_text", text)

  defp send_result(state, %{result_json: json}) when is_binary(json) do
    send_frame(state, :send_result, [Jason.decode!(json)])
  end

  defp on_result_ack(id, attempt, state) do
    record(Repo.x_ack_result(id, attempt, now(state), repo_opts(state)))
    state
  end

  defp on_result_rejected(id, attempt, reason, state) do
    Logger.error("X: Connect rejected the result of #{id} (attempt #{attempt}): #{reason}")
    record(Repo.x_reject_result(id, attempt, reason, now(state), repo_opts(state)))
    note_failure(state, {:result_rejected, reason})
  end

  # --- connection, recovery and expiry ---------------------------------------

  defp on_connection({:connected, limits}, state) when is_map(limits) do
    %{state | connection: {:connected, limits}, limits: Map.merge(@default_limits, limits)}
    |> sync()
    |> resend_start()
    |> maybe_start()
  end

  defp on_connection({:refused, reason} = refused, state) do
    note_failure(%{state | connection: refused}, {:refused, reason})
  end

  defp on_connection(connection, state) when connection in [:connecting, :down],
    do: %{state | connection: connection}

  # The store's open obligations, read again: waiting assignments are queued,
  # running rows no turn here holds are failed, and unanswered results are
  # resent while connected.
  defp sync(state) do
    case Repo.x_recoverable_assignments(repo_opts(state)) do
      {:ok, rows} ->
        state = Enum.reduce(rows, state, &recover_row/2)
        resend_results(state)

      {:error, reason} ->
        Logger.error("X: the assignment store could not be read: #{inspect(reason)}")
        note_failure(state, {:recovery_failed, reason})
    end
  end

  defp recover_row(%{status: :accepted} = row, state), do: track(state, row)

  defp recover_row(%{status: :running, assignment_id: id} = row, state) do
    if match?(%{id: ^id}, state.running),
      do: state,
      else: fail_attempt(row, :runner_restarted, state)
  end

  defp recover_row(_row, state), do: state

  defp resend_results(%{connection: {:connected, _limits}} = state) do
    case Repo.x_recoverable_assignments(repo_opts(state)) do
      {:ok, rows} ->
        rows
        |> Enum.filter(&(is_binary(&1.result_json) and is_nil(&1.result_acked_at)))
        |> Enum.each(&send_result(state, &1))

      {:error, reason} ->
        Logger.error("X: unanswered results could not be read: #{inspect(reason)}")
    end

    state
  end

  defp resend_results(state), do: state

  defp resend_start(%{starting: id} = state) when is_binary(id) do
    send_frame(state, :send_start, [id])
    state
  end

  defp resend_start(state), do: state

  defp expire(state) do
    case Repo.x_expire_assignments(now(state), repo_opts(state)) do
      {:ok, ids} ->
        Enum.each(ids, &Logger.info("X: assignment #{&1} expired before it could start"))
        Enum.reduce(ids, state, &forget(&2, &1)) |> maybe_start()

      {:error, reason} ->
        Logger.error("X: the expiry sweep failed: #{inspect(reason)}")
        state
    end
  end

  defp schedule_sweep(state), do: Process.send_after(self(), :sweep, state.sweep_interval_ms)

  # --- state helpers ---------------------------------------------------------

  defp forget(state, id) do
    starting = if state.starting == id, do: nil, else: state.starting
    %{state | queue: List.delete(state.queue, id), starting: starting}
  end

  defp clear_running(%{running: %{id: id} = running} = state, id) do
    Process.cancel_timer(running.timer)
    %{state | running: nil}
  end

  defp clear_running(state, _id), do: state

  defp status_of(state) do
    %{
      connection: connection_name(state.connection),
      pending: length(state.queue) + if(state.starting, do: 1, else: 0),
      running: if(state.running, do: 1, else: 0),
      last_failure: state.last_failure
    }
  end

  defp connection_name({:connected, _limits}), do: :connected
  defp connection_name(connection), do: connection

  defp note_failure(state, reason),
    do: %{state | last_failure: %{at: now(state), reason: reason}}

  defp log_lost(id, reason) do
    Logger.warning("X: assignment #{id} had already ended (#{inspect(reason)}); nothing changed")
  end

  # A store write whose answer changes nothing here is logged when it fails.
  defp record({:ok, _row}), do: :ok

  defp record({:error, reason}) do
    Logger.warning("X: an assignment write changed nothing: #{inspect(reason)}")
  end

  # Frames go out only on a connected socket; the rows carry every obligation
  # until the next one.
  defp send_frame(%{connection: {:connected, _limits}} = state, function, args) do
    case apply(state.client_module, function, [state.client | args]) do
      :ok ->
        :ok

      {:error, reason} = error ->
        Logger.warning("X: #{function} was not sent: #{inspect(reason)}")
        error
    end
  end

  defp send_frame(_state, _function, _args), do: {:error, :not_connected}

  defp repo_opts(state), do: [server: state.repo]

  defp now(state), do: state.clock.()

  defp reason_text(reason) when is_atom(reason), do: reason
  defp reason_text(reason), do: inspect(reason, limit: 20, printable_limit: 200)

  defp positive(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp positive(_value), do: :error

  defp timestamp(value) when is_binary(value) do
    with true <- Regex.match?(@timestamp, value),
         {:ok, at, 0} <- DateTime.from_iso8601(value) do
      {:ok, at}
    else
      _invalid -> :error
    end
  end

  defp timestamp(_value), do: :error

  defp sha256_hex(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  defp random_epoch, do: 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
end
