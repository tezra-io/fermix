defmodule FermixChannels.Channels.IMessage.Listener do
  @moduledoc """
  Turns the Fermix Messages helper's rows into gateway turns
  (docs/design/MILESTONE_54_IMESSAGE_CHANNEL.md §7.3, §7.4, §9.2, §9.3).

  **Gate.** Nothing is subscribed until `probe` reports a user session, Full
  Disk Access, a readable database, a confirmed policy, Automation, a
  signed-in Messages and an owner who is not one of that account's own aliases
  (`IMessage.probe_gate/2`). Until then `status/1` names the first missing
  thing and the probe is retried every 30 s, logged once per change of class,
  with one `:degraded` transport event and one `:recovered`.

  **Posture.** The account posture is the helper's, never config's: once the
  gate opens, `policy.get` answers the posture it derived when it confirmed the
  recipients, and admission follows it. A `policy.state` notification
  (`owner_is_this_mac`: Messages here is now signed in as the owner) stops the
  channel with that class until the probe shows a separate account again.

  **Cursor.** `FERMIX_HOME/imessage/cursor` holds `{generation, rowid}`, written
  by atomic rename. A row is acknowledged only once it is settled: dropped by
  admission, already handed off (dedupe on its guid), or accepted by
  `Gateway.ingest/2`. A daemon crash after the in-memory hand-off loses that
  turn, exactly as on every remote channel (D11). The cursor is valid only for
  the database generation it was written under; a different generation at
  `initialize`, or `db.state {generation_changed}`, resets it to now with one
  log line.

  **Replay and overflow.** The first subscription after start replays at most
  50 rows no older than 10 minutes and reports how many it skipped. A
  `watch.overflow` is recovered without any bound: the Listener pages
  `messages.after` from its own acknowledged row until `has_more` is false and
  then subscribes again from there.

  **A failed hand-off** forgets the guid, keeps the cursor on the last settled
  row and pages again from it after 5 s. After three failed attempts on the
  same row the row is dropped with an error naming its guid, so one message
  the gateway can never accept cannot wedge the channel.

  **Admission** is one function with the two posture clauses of §9.2. In the
  own posture a chat that produces more than six admitted rows in a minute is
  paused for a minute (`:loop_suspected`), a bound on a runaway rather than a
  second echo filter: the helper's ledger is the echo filter (§9.3).
  """

  use GenServer

  require Logger

  alias FermixChannels.Channels.IMessage
  alias FermixChannels.Channels.IMessage.Port, as: HelperPort
  alias FermixChannels.Channels.IMessage.Protocol
  alias FermixChannels.Gateway
  alias FermixChannels.Gateway.Idempotency
  alias FermixChannels.Gateway.Queue
  alias FermixChannels.Telemetry, as: ChannelTelemetry
  alias FermixCore.IMessage.Control

  @probe_retry_ms 30_000
  @handoff_retry_ms 5_000
  @max_handoff_attempts 3
  @boot_replay %{"max_rows" => 50, "max_age_s" => 600}
  @buffer_limit 256
  @page_limit 64
  @loop_max_rows 6
  @loop_window_ms 60_000
  @loop_pause_ms 60_000
  @call_timeout_ms 15_000

  @type phase :: :starting | :helper_down | :waiting | :live | :paging
  @type status :: %{
          phase: phase(),
          class: term(),
          replay_skipped: non_neg_integer(),
          cursor: non_neg_integer() | nil
        }
  @type drop_reason ::
          :reaction | :group | :not_in_policy | :sms_not_supported | :service_not_imessage

  # --- Public API ------------------------------------------------------------

  @doc """
  Starts the listener. Options: `:home` and `:recipients` (required, an
  `IMessage.recipients()`); `:helper` and `:server` (default `IMessage.Port`);
  `:agent` and `:agent_server` (default `Gateway.Queue`); `:name`; and
  `:probe_retry_ms`, `:handoff_retry_ms`, `:loop_pause_ms` (tests shrink these).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Where the channel stands, for readiness and health."
  @spec status(GenServer.server()) :: status()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc """
  The admission rule (§9.2): no tapback, a direct chat, the posture's own
  clause, and iMessage on both the handle and the chat. Anything else is
  dropped with its reason; the helper's ledger has already removed Fermix's
  own sends (§9.3).
  """
  @spec admit(map(), IMessage.policy()) :: :admit | {:drop, drop_reason()}
  def admit(row, policy) when is_map(row) and is_map(policy) do
    cond do
      row["reaction"] != nil -> {:drop, :reaction}
      nested(row, "chat", "group") != false -> {:drop, :group}
      not posture_match?(row, policy) -> {:drop, :not_in_policy}
      true -> service_check(row)
    end
  end

  # --- GenServer ---------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    state = %{
      helper: Keyword.get(opts, :helper, HelperPort),
      server: Keyword.get(opts, :server, HelperPort),
      home: Keyword.fetch!(opts, :home),
      recipients: Keyword.fetch!(opts, :recipients),
      # The recipients plus the posture the helper derived, set by `policy.get`
      # before every subscription; nothing is admitted while it is nil.
      policy: nil,
      agent: Keyword.get(opts, :agent, Queue),
      agent_server: Keyword.get(opts, :agent_server, Queue),
      probe_retry_ms: Keyword.get(opts, :probe_retry_ms, @probe_retry_ms),
      handoff_retry_ms: Keyword.get(opts, :handoff_retry_ms, @handoff_retry_ms),
      loop_pause_ms: Keyword.get(opts, :loop_pause_ms, @loop_pause_ms),
      phase: :starting,
      class: nil,
      degraded: 0,
      probe_timer: nil,
      generation: nil,
      cursor: :unloaded,
      booted?: false,
      replay_skipped: 0,
      retry: nil,
      sms_logged: MapSet.new(),
      loop: %{},
      paused: %{}
    }

    {:ok, state, {:continue, :attach}}
  end

  @impl GenServer
  def handle_continue(:attach, state) do
    case state.helper.attach(state.server, self()) do
      {:ok, handshake} -> {:noreply, helper_up(state, handshake)}
      {:error, {_kind, _message, data}} -> {:noreply, helper_down(state, Map.get(data, "class"))}
    end
  end

  @impl GenServer
  def handle_call(:status, _from, state) do
    status = Map.take(state, [:phase, :class, :replay_skipped])
    {:reply, Map.put(status, :cursor, cursor_rowid(state.cursor)), state}
  end

  @impl GenServer
  def handle_info({:imessage_event, "message", row}, %{phase: :live} = state),
    do: {:noreply, live_rows(state, [row])}

  # Outside a live subscription a pushed row is covered by the page or the
  # subscription that follows from the acknowledged cursor.
  def handle_info({:imessage_event, "message", _row}, state), do: {:noreply, state}

  def handle_info({:imessage_event, "watch.overflow", params}, %{phase: :live} = state) do
    Logger.warning(
      "iMessage watch overflowed (#{inspect(params["dropped"])} rows not pushed); " <>
        "paging from the acknowledged cursor"
    )

    {:noreply, begin_recovery(state, 0)}
  end

  def handle_info({:imessage_event, "watch.overflow", _params}, state), do: {:noreply, state}

  def handle_info({:imessage_event, "db.state", %{"state" => "unavailable"} = params}, state),
    do: {:noreply, db_unavailable(state, params["class"], params["db_generation"])}

  def handle_info({:imessage_event, "db.state", %{"state" => "available"}}, state),
    do: {:noreply, db_available(state)}

  def handle_info({:imessage_event, "policy.state", params}, state),
    do: {:noreply, policy_state(state, params)}

  def handle_info({:imessage_event, "send.reconciled", params}, state) do
    Logger.info(
      "iMessage send #{inspect(params["idempotency_key"])} reconciled after a helper " <>
        "restart: #{inspect(params["disposition"])}"
    )

    {:noreply, state}
  end

  def handle_info({:imessage_helper, :down, class}, state),
    do: {:noreply, helper_down(state, class)}

  def handle_info({:imessage_helper, :up, handshake}, state),
    do: {:noreply, helper_up(cancel_probe(state), handshake)}

  def handle_info(:probe, %{phase: :waiting} = state),
    do: {:noreply, start_watch(%{state | probe_timer: nil})}

  def handle_info(:probe, state), do: {:noreply, %{state | probe_timer: nil}}
  def handle_info(:page, %{phase: :paging} = state), do: {:noreply, page(state)}
  def handle_info(:page, state), do: {:noreply, state}
  def handle_info({:loop_resume, chat}, state), do: {:noreply, resume_chat(state, chat)}

  def handle_info(message, state) do
    Logger.warning("iMessage listener ignored an unexpected message: #{inspect(message)}")
    {:noreply, state}
  end

  # --- Helper lifecycle and the probe gate --------------------------------------

  defp helper_up(state, handshake) do
    state
    |> adopt_generation(handshake["db_generation"])
    |> start_watch()
  end

  defp helper_down(state, class) do
    %{state | phase: :helper_down}
    |> note_class(class || :helper_unavailable)
  end

  defp start_watch(state) do
    with :ok <- probe(state),
         {:ok, posture} <- derived_posture(state) do
      subscribe(%{state | policy: Map.put(state.recipients, :posture, posture)})
    else
      {:error, class} -> wait(state, class)
    end
  end

  defp probe(state) do
    with {:ok, raw} <- probe_call(state),
         {:ok, probe} <- decode_probe(raw) do
      IMessage.probe_gate(probe, state.recipients.owner)
    end
  end

  # The posture the helper derived when it confirmed the recipients. A result
  # outside the protocol is a helper defect, waited out like any refusal.
  defp derived_posture(state) do
    case call(state, "policy.get", %{}) do
      {:ok, raw} -> decoded_posture(Control.decode_policy(raw))
      {:error, {kind, _message, _data}} -> {:error, kind}
    end
  end

  defp decoded_posture({:ok, %{posture: posture}}), do: {:ok, posture}

  defp decoded_posture({:error, {:helper_protocol, reason}}) do
    Logger.error("iMessage policy.get answered outside the protocol: #{inspect(reason)}")
    {:error, :protocol_error}
  end

  # Before the helper has answered `initialize` there is nothing to stop; the
  # probe gate names the same state once it is up.
  defp policy_state(%{phase: phase} = state, _params) when phase in [:starting, :helper_down],
    do: state

  defp policy_state(state, %{"state" => "owner_is_this_mac"}), do: wait(state, :owner_is_this_mac)

  defp policy_state(state, params) do
    Logger.warning("iMessage policy.state outside the protocol: #{inspect(params["state"])}")
    state
  end

  defp probe_call(state) do
    case call(state, "probe", %{}) do
      {:ok, raw} -> {:ok, raw}
      {:error, {kind, _message, _data}} -> {:error, kind}
    end
  end

  defp decode_probe(raw) do
    case Control.decode_probe(raw) do
      {:ok, probe} -> {:ok, probe}
      {:error, {:helper_protocol, reason}} -> {:error, {:protocol_error, reason}}
    end
  end

  # One re-probe pending at a time, so no event can multiply the timers.
  defp wait(state, class) do
    state = cancel_probe(state)
    timer = Process.send_after(self(), :probe, state.probe_retry_ms)

    %{state | phase: :waiting, probe_timer: timer}
    |> note_class(class)
    |> note_degraded(class)
  end

  defp cancel_probe(%{probe_timer: nil} = state), do: state

  defp cancel_probe(%{probe_timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | probe_timer: nil}
  end

  defp note_class(%{class: class} = state, class), do: state

  defp note_class(state, class) do
    Logger.warning("iMessage channel is not receiving: #{inspect(class)}")
    %{state | class: class}
  end

  defp note_degraded(%{degraded: 0} = state, class) do
    ChannelTelemetry.emit_transport(:imessage, :degraded, 1, class_atom(class))
    %{state | degraded: 1}
  end

  defp note_degraded(state, _class), do: %{state | degraded: state.degraded + 1}

  defp note_live(%{degraded: 0} = state), do: %{state | class: nil}

  defp note_live(state) do
    Logger.warning("iMessage channel is receiving again after #{state.degraded} failed attempts")
    ChannelTelemetry.emit_transport(:imessage, :recovered, state.degraded, :none)
    %{state | degraded: 0, class: nil}
  end

  defp class_atom({kind, _detail}) when is_atom(kind), do: kind
  defp class_atom(class) when is_atom(class), do: class
  defp class_atom(_class), do: :helper_unavailable

  # Before the helper has answered `initialize` there is no cursor to reset and
  # nothing to watch; `{:imessage_helper, :up, _}` re-probes from scratch.
  defp db_unavailable(%{phase: phase} = state, _class, _generation)
       when phase in [:starting, :helper_down],
       do: state

  # The helper names the generation it now sees, so the cursor it resets is
  # written under that generation and the next boot adopts it without a second
  # reset.
  defp db_unavailable(state, "generation_changed", generation) do
    state
    |> Map.put(:generation, generation)
    |> reset_cursor("the Messages database was replaced")
    |> cancel_probe()
    |> Map.merge(%{phase: :waiting, class: :generation_changed})
    |> schedule_probe()
  end

  defp db_unavailable(state, class, _generation), do: wait(state, db_class(class))

  defp db_available(%{phase: :waiting} = state) do
    state
    |> cancel_probe()
    |> unsubscribe()
    |> start_watch()
  end

  defp db_available(state), do: state

  defp schedule_probe(state),
    do: %{state | probe_timer: Process.send_after(self(), :probe, state.probe_retry_ms)}

  defp db_class(class) when is_binary(class) do
    case Protocol.decode_error_kind(class) do
      {:ok, kind} -> kind
      {:error, {:unknown_error_kind, _class}} -> :db_unavailable
    end
  end

  defp db_class(_class), do: :db_unavailable

  # --- Subscription, paging, recovery -------------------------------------------

  defp subscribe(state) do
    params = %{
      "since_rowid" => cursor_rowid(state.cursor),
      "replay" => replay_bounds(state),
      "buffer_limit" => @buffer_limit
    }

    case call(state, "watch.subscribe", params) do
      {:ok, %{"started_at_rowid" => started, "replay_skipped" => skipped}}
      when is_integer(started) and is_integer(skipped) ->
        subscribed(state, started, skipped)

      {:ok, other} ->
        Logger.error("iMessage watch.subscribe answered outside the protocol: #{inspect(other)}")
        wait(state, :protocol_error)

      {:error, {kind, _message, _data}} ->
        wait(state, kind)
    end
  end

  # The boot bounds belong to the first subscription after a start, and only
  # when there is a cursor to replay from (§7.3).
  defp replay_bounds(%{booted?: false, cursor: rowid}) when is_integer(rowid), do: @boot_replay
  defp replay_bounds(_state), do: nil

  defp subscribed(state, started, skipped) do
    state = if state.cursor == nil, do: ack(state, started), else: state
    state = if state.booted?, do: state, else: note_replay_skipped(state, skipped)
    Logger.info("iMessage channel subscribed from row #{cursor_rowid(state.cursor)}")
    note_live(%{state | phase: :live, booted?: true, retry: nil})
  end

  defp note_replay_skipped(state, 0), do: state

  defp note_replay_skipped(state, skipped) do
    Logger.warning("iMessage: #{skipped} messages from before the restart were not replayed")
    %{state | replay_skipped: skipped}
  end

  defp unsubscribe(state) do
    case call(state, "watch.unsubscribe", %{}) do
      {:ok, _result} ->
        state

      {:error, {kind, message, _data}} ->
        Logger.warning("iMessage watch.unsubscribe refused (#{kind}): #{message}")
        state
    end
  end

  defp begin_recovery(state, delay_ms) do
    state = unsubscribe(state)
    Process.send_after(self(), :page, delay_ms)
    %{state | phase: :paging}
  end

  defp page(state) do
    params = %{"since_rowid" => state.cursor, "limit" => @page_limit}

    case call(state, "messages.after", params) do
      {:ok, %{"messages" => rows, "has_more" => more?}}
      when is_list(rows) and is_boolean(more?) ->
        paged(state, rows, more?)

      {:ok, other} ->
        Logger.error("iMessage messages.after answered outside the protocol: #{inspect(other)}")
        wait(state, :protocol_error)

      {:error, {kind, _message, _data}} ->
        wait(state, kind)
    end
  end

  defp paged(state, rows, more?) do
    case process_rows(state, rows) do
      {:ok, next} -> after_page(state.cursor, next, more?)
      {:error, row, reason, next} -> handoff_failed(next, row, reason)
    end
  end

  defp after_page(_before, state, false), do: subscribe(state)

  # A page that reports more but moves nothing would loop forever; it is a
  # helper defect, waited out like any other refusal.
  defp after_page(before, %{cursor: before} = state, true) do
    Logger.error("iMessage helper reported more rows but paged none past row #{before}")
    wait(state, :protocol_error)
  end

  defp after_page(_before, state, true) do
    send(self(), :page)
    state
  end

  defp live_rows(state, rows) do
    case process_rows(state, rows) do
      {:ok, state} -> state
      {:error, row, reason, state} -> handoff_failed(state, row, reason)
    end
  end

  defp handoff_failed(state, row, reason) do
    attempts = retry_attempts(state.retry, row["rowid"]) + 1

    if attempts >= @max_handoff_attempts do
      Logger.error(
        "iMessage message #{row["guid"]} dropped after #{attempts} failed hand-offs: #{inspect(reason)}"
      )

      continue_after_drop(%{ack(state, row["rowid"]) | retry: nil})
    else
      Logger.error(
        "iMessage hand-off of #{row["guid"]} failed (attempt #{attempts} of " <>
          "#{@max_handoff_attempts}): #{inspect(reason)}; retrying from the acknowledged row"
      )

      retry_later(%{state | retry: %{rowid: row["rowid"], attempts: attempts}})
    end
  end

  defp retry_attempts(%{rowid: rowid, attempts: attempts}, rowid), do: attempts
  defp retry_attempts(_retry, _rowid), do: 0

  defp retry_later(%{phase: :live} = state), do: begin_recovery(state, state.handoff_retry_ms)

  defp retry_later(state) do
    Process.send_after(self(), :page, state.handoff_retry_ms)
    %{state | phase: :paging}
  end

  defp continue_after_drop(%{phase: :paging} = state) do
    send(self(), :page)
    state
  end

  defp continue_after_drop(state), do: state

  # --- Rows: admit, map, hand off, acknowledge -----------------------------------

  # Rows are settled in rowid order; the cursor ends on the last settled row,
  # and a failed hand-off stops the batch there.
  defp process_rows(state, rows) do
    pending = pending_rows(rows, state.cursor)
    {decisions, state} = Enum.map_reduce(pending, state, &decide_row/2)

    messages =
      decisions
      |> Enum.flat_map(fn {row, decision} -> if decision == :admit, do: [row], else: [] end)
      |> IMessage.parse_batch(state.policy, %{helper: state.helper, server: state.server})
      |> Map.new(&{&1.metadata.rowid, &1})

    pending
    |> Enum.reduce_while({:ok, state.cursor}, fn row, {:ok, settled} ->
      case hand_off(Map.get(messages, row["rowid"]), state) do
        :ok -> {:cont, {:ok, row["rowid"]}}
        {:error, reason} -> {:halt, {:error, settled, row, reason}}
      end
    end)
    |> settle(state)
  end

  defp settle({:ok, settled}, state), do: {:ok, ack(state, settled)}

  defp settle({:error, settled, row, reason}, state),
    do: {:error, row, reason, ack(state, settled)}

  defp pending_rows(rows, cursor) do
    {valid, invalid} = Enum.split_with(rows, &(is_map(&1) and is_integer(&1["rowid"])))

    Enum.each(invalid, fn row ->
      Logger.error("iMessage helper sent a row without a rowid: #{inspect(row)}")
    end)

    valid
    |> Enum.filter(&(&1["rowid"] > (cursor || -1)))
    |> Enum.sort_by(& &1["rowid"])
    |> Enum.uniq_by(& &1["rowid"])
  end

  defp decide_row(row, state) do
    case admit(row, state.policy) do
      :admit -> loop_check(row, state)
      {:drop, :sms_not_supported} -> {{row, {:drop, :sms_not_supported}}, note_sms(state, row)}
      {:drop, reason} -> {{row, {:drop, reason}}, state}
    end
  end

  defp hand_off(nil, _state), do: :ok

  defp hand_off(message, state) do
    case Idempotency.check_and_record(:imessage, message.id) do
      :duplicate -> :ok
      :fresh -> ingest(message, state)
    end
  end

  defp ingest(message, state) do
    opts = [channel: IMessage, agent: state.agent, agent_server: state.agent_server]

    case Gateway.ingest([message], opts) do
      :ok ->
        :ok

      {:error, reason} ->
        :ok = Idempotency.forget(:imessage, message.id)
        {:error, reason}
    end
  end

  defp note_sms(state, row) do
    sender = nested(row, "sender", "handle") || nested(row, "chat", "identifier") || "unknown"

    if MapSet.member?(state.sms_logged, sender) do
      state
    else
      Logger.warning(
        "iMessage sms_not_supported: an SMS from #{Protocol.redact_handle(sender)} was refused; " <>
          "Fermix answers iMessage only"
      )

      %{state | sms_logged: MapSet.put(state.sms_logged, sender)}
    end
  end

  # --- The own-posture loop breaker (§9.3) ----------------------------------------

  defp loop_check(row, %{policy: %{posture: :own_account}} = state) do
    chat = nested(row, "chat", "identifier")
    now = System.monotonic_time(:millisecond)
    recent = state.loop |> Map.get(chat, []) |> Enum.filter(&(now - &1 < @loop_window_ms))

    cond do
      Map.has_key?(state.paused, chat) ->
        {{row, {:drop, :loop_suspected}}, update_in(state.paused[chat], &(&1 + 1))}

      length(recent) >= @loop_max_rows ->
        {{row, {:drop, :loop_suspected}}, pause_chat(state, chat, length(recent) + 1)}

      true ->
        {{row, :admit}, put_in(state.loop[chat], [now | recent])}
    end
  end

  defp loop_check(row, state), do: {{row, :admit}, state}

  defp pause_chat(state, chat, rows) do
    Logger.error(
      "iMessage loop suspected: #{rows} rows in under a minute in the self chat; " <>
        "admission paused for #{state.loop_pause_ms} ms"
    )

    ChannelTelemetry.emit_transport(:imessage, :degraded, rows, :loop_suspected)
    Process.send_after(self(), {:loop_resume, chat}, state.loop_pause_ms)
    put_in(state.paused[chat], 1)
  end

  defp resume_chat(state, chat) do
    {suppressed, paused} = Map.pop(state.paused, chat, 0)
    Logger.warning("iMessage self chat admission resumed after #{suppressed} suppressed rows")
    ChannelTelemetry.emit_transport(:imessage, :recovered, suppressed, :none)
    %{state | paused: paused, loop: Map.delete(state.loop, chat)}
  end

  # --- Cursor file -----------------------------------------------------------------

  defp adopt_generation(%{cursor: :unloaded} = state, generation) do
    state = %{state | generation: generation}

    case read_cursor(state.home) do
      {:ok, %{"generation" => ^generation, "rowid" => rowid}} when generation != nil ->
        %{state | cursor: rowid}

      :none ->
        %{state | cursor: nil}

      {:ok, _other_generation} ->
        reset_cursor(state, "the Messages database generation changed")

      {:error, reason} ->
        reset_cursor(state, "the cursor file is unreadable (#{inspect(reason)})")
    end
  end

  defp adopt_generation(%{generation: generation} = state, generation) when generation != nil,
    do: state

  defp adopt_generation(state, generation) do
    reset_cursor(%{state | generation: generation}, "the Messages database generation changed")
  end

  defp reset_cursor(state, why) do
    Logger.warning("iMessage cursor reset to now: #{why}")
    %{state | cursor: nil}
  end

  defp read_cursor(home) do
    case File.read(cursor_path(home)) do
      {:ok, body} -> decode_cursor(body)
      {:error, :enoent} -> :none
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_cursor(body) do
    case Jason.decode(body) do
      {:ok, %{"rowid" => rowid} = cursor} when is_integer(rowid) and rowid >= 0 -> {:ok, cursor}
      _other -> {:error, :corrupt}
    end
  end

  defp ack(state, rowid) when is_integer(rowid) and rowid != state.cursor do
    write_cursor(state, rowid)
    %{state | cursor: rowid}
  end

  defp ack(state, _unchanged), do: state

  # Written by rename, so a crash mid-write leaves the previous cursor intact.
  defp write_cursor(state, rowid) do
    dir = Path.join(state.home, "imessage")
    path = cursor_path(state.home)
    body = Jason.encode!(%{"generation" => state.generation, "rowid" => rowid})

    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, 0o700),
         :ok <- File.write(path <> ".tmp", body),
         :ok <- File.rename(path <> ".tmp", path) do
      :ok
    else
      {:error, reason} ->
        Logger.error(
          "iMessage cursor could not be saved (#{inspect(reason)}); a restart replays from " <>
            "the last saved row"
        )
    end
  end

  defp cursor_path(home), do: Path.join([home, "imessage", "cursor"])

  defp cursor_rowid(rowid) when is_integer(rowid), do: rowid
  defp cursor_rowid(_none), do: nil

  # --- Shared ------------------------------------------------------------------------

  defp call(state, method, params),
    do: state.helper.call(state.server, method, params, @call_timeout_ms)

  defp posture_match?(row, %{posture: :dedicated_account, handles: handles}) do
    nested(row, "sender", "is_me") == false and
      normalized_member?(nested(row, "sender", "handle"), handles)
  end

  defp posture_match?(row, %{posture: :own_account, owner: owner}) do
    nested(row, "sender", "is_me") == true and
      Protocol.normalize_handle(nested(row, "chat", "identifier")) == {:ok, owner}
  end

  defp service_check(row) do
    services = [nested(row, "sender", "service"), nested(row, "chat", "service")]

    cond do
      Enum.all?(services, &(&1 == "iMessage")) -> :admit
      "SMS" in services -> {:drop, :sms_not_supported}
      true -> {:drop, :service_not_imessage}
    end
  end

  defp normalized_member?(handle, handles) do
    case Protocol.normalize_handle(handle) do
      {:ok, normalized} -> normalized in handles
      {:error, :invalid_handle} -> false
    end
  end

  defp nested(row, outer, inner) do
    case Map.get(row, outer) do
      %{} = map -> Map.get(map, inner)
      _other -> nil
    end
  end
end
