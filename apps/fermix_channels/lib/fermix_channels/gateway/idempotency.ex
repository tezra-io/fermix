defmodule FermixChannels.Gateway.Idempotency do
  @moduledoc """
  Idempotency for inbound channel events, and the claims that keep one
  outbound media send from going out twice.

  Webhook providers retry on slow acknowledgements (audit F-06). Without
  deduplication, a retried event runs the agent loop twice, sends two
  replies, and stores the same memory twice.

  Keys are `{channel, platform_message_id}` tuples. Entries live for
  `@default_ttl_ms` (24h).

  **Inbound ids are durable (M75 B15).** Every inbound id is also recorded in
  `memory.db` (the `channel_event_ids` table, migration 53, through
  `FermixCore.Memory.Repo`) for the same window. The ETS table is the hot
  path: a live id is answered `:duplicate` from ETS without touching SQLite;
  an id ETS does not hold is claimed in SQLite once, and the answer (recorded,
  or the live row's expiry) is kept in ETS, so an id reaches SQLite at most
  once per process until its window passes or `forget/3` drops it. A restart
  therefore keeps every id it had seen, and because `memory.db` moves with the
  home (an archive, a snapshot, or the move to another host), the ids move
  too: a Slack or WhatsApp retry that straddles a cutover reaches the new host
  as a duplicate, not as a second turn.

  Where memory is turned off (`[fermix_core.memory] enabled = false`) there
  is no `memory.db`, and inbound ids live in this process only: a restart
  forgets them. That is a configuration, read once at start (`:store`), never
  a path taken when the Repo fails. A Repo error answers `{:error, reason}`,
  and the transport refuses the event so the provider sends it again.

  Expired rows are pruned on the sweep below, at most `@prune_batch` per
  sweep through the expiry index, so a sweep reads only the rows it deletes;
  a larger backlog drains over the following sweeps.

  Outbound media claims stay in memory: they last 60 seconds and guard one
  send in this process, so there is nothing for a restart to carry.

  The TTL is enforced on two paths and both are required: a lookup of the
  SAME key ignores an expired row, and a periodic `:sweep` deletes every
  expired row so the table cannot grow without bound. Without the sweep the
  declared TTL only ever applied to a key that was asked about again —
  outbound media claims (60s TTL, one row per media send, reachable in the
  DEFAULT config) accumulated for the life of the daemon.

  Atomicity model (audit F-06 second-pass review):

  The check-and-set runs inside the GenServer's `handle_call/3`, so
  concurrent callers are serialized by the BEAM mailbox. There is no
  in-flight window where two callers can both observe the same state
  and both decide they are `:fresh` — the prior `:ets.insert_new` + a
  later `:ets.insert` for the expired-entry path had exactly that
  window (review at audit follow-up commit 88e1eb6). The throughput
  cost — one GenServer.call per inbound webhook message — is fine for
  the single-user daemon's QPS budget, and the simplicity is worth
  more than a clever ETS CAS at this scale.

  ETS is still used as the storage backend so reads outside the
  GenServer (e.g. operational dashboards) can `:ets.tab2list/1` the
  table without blocking the writer.
  """

  use GenServer

  require Logger

  alias FermixCore.Memory.Config, as: MemoryConfig
  alias FermixCore.Memory.Repo
  alias FermixCore.Telemetry
  alias FermixCore.Timeouts

  @table __MODULE__.Table
  @default_ttl_ms 24 * 60 * 60 * 1_000
  # Expired `memory.db` rows one sweep deletes at most.
  @prune_batch 1_000
  @default_outbound_ttl_ms 60_000
  # Short relative to the 24h inbound TTL, because the shortest-lived rows are
  # the 60s outbound media claims: they set the reclaim latency, not the TTL.
  @sweep_interval_ms 5 * 60 * 1_000

  @type outbound_media_claim :: {term(), reference()}
  @type store :: :memory | {:repo, GenServer.server()}

  @doc """
  Starts the cache. `:store` is where inbound ids are kept beyond ETS:
  `{:repo, server}` (the default while memory is on, with
  `FermixCore.Memory.Repo`) or `:memory`. `:wall_clock` (Unix milliseconds)
  stamps the durable rows; a test injects it.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Returns `:fresh` if this is the first time we have seen the key, or
  `:duplicate` if it has been seen within the TTL. The check-and-set is
  atomic from the caller's perspective; concurrent callers with the
  same key will see exactly one `:fresh` and the rest `:duplicate`.
  `{:error, reason}` when the durable store could not answer: nothing was
  recorded, and the caller refuses the event so its provider retries.
  """
  @spec check_and_record(atom(), String.t(), keyword()) :: :fresh | :duplicate | {:error, term()}
  def check_and_record(channel, message_id, opts \\ [])
      when is_atom(channel) and is_binary(message_id) and message_id != "" do
    server = Keyword.get(opts, :server, __MODULE__)
    ttl_ms = Keyword.get(opts, :ttl_ms, @default_ttl_ms)

    {result, duration_us} =
      Telemetry.timed_us(fn ->
        GenServer.call(server, {:check_and_record, {channel, message_id}, ttl_ms}, call_timeout())
      end)

    emit_idempotency_check(channel, result, duration_us)
    result
  end

  @doc """
  Removes a previously-recorded entry, from ETS and from `memory.db`. Used
  by the webhook hand-off to roll back the idempotency record when the async
  dispatch task fails to start — without this, a failed start_child would
  silently burn the message id and suppress the provider's retry. (Audit
  F-06 follow-up.) A durable delete that fails is logged here and answered.
  """
  @spec forget(atom(), String.t(), keyword()) :: :ok | {:error, term()}
  def forget(channel, message_id, opts \\ [])
      when is_atom(channel) and is_binary(message_id) and message_id != "" do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:forget, {channel, message_id}}, call_timeout())
  end

  @spec claim_outbound_media(atom(), String.t(), map(), keyword()) ::
          {:ok, {:fresh, outbound_media_claim()} | :duplicate} | {:error, term()}
  def claim_outbound_media(channel, chat_id, media_part, opts \\ [])
      when is_atom(channel) and is_binary(chat_id) and is_map(media_part) do
    {result, duration_us} =
      Telemetry.timed_us(fn ->
        with {:ok, key} <- outbound_media_key(channel, chat_id, media_part) do
          server = Keyword.get(opts, :server, __MODULE__)
          ttl_ms = Keyword.get(opts, :ttl_ms, @default_outbound_ttl_ms)
          GenServer.call(server, {:claim_outbound_media, key, ttl_ms})
        end
      end)

    emit_outbound_media_claim(channel, result, duration_us)
    result
  end

  @spec release_outbound_media_claim(outbound_media_claim(), keyword()) :: :ok
  def release_outbound_media_claim({key, claim_ref}, opts \\ []) when is_reference(claim_ref) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:release_outbound_media_claim, key, claim_ref})
  end

  @impl true
  def init(opts) do
    table = Keyword.get(opts, :table, @table)

    case :ets.whereis(table) do
      :undefined ->
        :ets.new(table, [:named_table, :public, :set, read_concurrency: true])

      _existing ->
        :ok
    end

    {:ok,
     %{
       table: table,
       sweep_timer: schedule_sweep(),
       store: store!(Keyword.get_lazy(opts, :store, &default_store/0)),
       wall_clock: Keyword.get(opts, :wall_clock, fn -> System.os_time(:millisecond) end)
     }}
  end

  defp default_store, do: if(MemoryConfig.enabled?(), do: {:repo, Repo}, else: :memory)

  defp store!(:memory), do: :memory
  defp store!({:repo, server} = store) when is_atom(server) or is_pid(server), do: store

  @impl true
  def handle_call({:check_and_record, key, ttl_ms}, _from, state) do
    now_ms = System.monotonic_time(:millisecond)

    result =
      case :ets.lookup(state.table, key) do
        [{^key, existing}] when existing > now_ms -> :duplicate
        _missing_or_expired -> record_inbound(state, key, ttl_ms, now_ms)
      end

    {:reply, result, state}
  end

  def handle_call({:forget, key}, _from, state) do
    :ets.delete(state.table, key)
    {:reply, forget_durable(state, key), state}
  end

  def handle_call({:claim_outbound_media, key, ttl_ms}, _from, state) do
    now_ms = System.monotonic_time(:millisecond)
    deadline = now_ms + ttl_ms

    result =
      case :ets.lookup(state.table, key) do
        [{^key, existing}] ->
          if expired?(existing, now_ms) do
            fresh_outbound_claim(state.table, key, deadline)
          else
            {:ok, :duplicate}
          end

        _missing_or_expired ->
          fresh_outbound_claim(state.table, key, deadline)
      end

    {:reply, result, state}
  end

  def handle_call({:release_outbound_media_claim, key, claim_ref}, _from, state) do
    case :ets.lookup(state.table, key) do
      [{^key, {_deadline, ^claim_ref}}] -> :ets.delete(state.table, key)
      _missing_or_reclaimed -> :ok
    end

    {:reply, :ok, state}
  end

  # MUST stay above the catch-all below. A `handle_info(_other, state)` placed
  # first swallows `:sweep`, the timer never re-arms, and the declared TTL goes
  # back to being enforced only on a lookup of the same key.
  @impl true
  def handle_info(:sweep, state) do
    sweep_expired(state.table, System.monotonic_time(:millisecond))
    prune_durable(state)
    {:noreply, %{state | sweep_timer: schedule_sweep()}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)

  # The Repo answers within its own bound, and the caller waits for that and
  # for the calls queued ahead of it here.
  defp call_timeout, do: 2 * Timeouts.repo_call()

  defp repo_opts(server), do: Repo.periodic_opts(server, Timeouts.repo_call())

  defp record_inbound(%{store: :memory} = state, key, ttl_ms, now_ms) do
    :ets.insert(state.table, {key, now_ms + ttl_ms})
    :fresh
  end

  # The durable answer is cached either way, so the same id does not reach
  # SQLite again while ETS holds it: a duplicate keeps the live row's
  # remaining window, measured on this process's monotonic clock.
  defp record_inbound(%{store: {:repo, server}} = state, {channel, id} = key, ttl_ms, now_ms) do
    wall_ms = state.wall_clock.()

    case Repo.claim_inbound_event(channel, id, wall_ms, ttl_ms, repo_opts(server)) do
      {:ok, :fresh} ->
        :ets.insert(state.table, {key, now_ms + ttl_ms})
        :fresh

      {:ok, {:duplicate, expires_at_ms}} ->
        :ets.insert(state.table, {key, now_ms + (expires_at_ms - wall_ms)})
        :duplicate

      {:error, reason} ->
        Logger.error(
          "Idempotency: #{channel} event #{inspect(id)} could not be recorded in memory.db: " <>
            inspect(reason)
        )

        {:error, {:idempotency_store, reason}}
    end
  end

  defp forget_durable(%{store: :memory}, _key), do: :ok

  defp forget_durable(%{store: {:repo, server}}, {channel, id}) do
    case Repo.forget_inbound_event(channel, id, repo_opts(server)) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "Idempotency: #{channel} event #{inspect(id)} stays recorded in memory.db, so its " <>
            "retry will be dropped as a duplicate: #{inspect(reason)}"
        )

        {:error, {:idempotency_store, reason}}
    end
  end

  # At most @prune_batch rows a sweep; a failure is logged and the next sweep
  # tries again.
  defp prune_durable(%{store: :memory}), do: :ok

  defp prune_durable(%{store: {:repo, server}} = state) do
    case Repo.prune_inbound_events(state.wall_clock.(), @prune_batch, repo_opts(server)) do
      {:ok, _deleted} ->
        :ok

      {:error, reason} ->
        Logger.warning("Idempotency: expired event ids were not pruned: #{inspect(reason)}")
    end
  end

  # Two match specs because the table stores two value shapes — a bare deadline
  # (inbound message ids) and `{deadline, claim_ref}` (outbound media claims).
  # This mirrors the discrimination `expired?/2` makes on lookup; a third shape
  # invented here would drift from it.
  defp sweep_expired(table, now_ms) do
    bare = [{{:_, :"$1"}, [{:is_integer, :"$1"}, {:"=<", :"$1", now_ms}], [true]}]
    claimed = [{{:_, {:"$1", :_}}, [{:is_integer, :"$1"}, {:"=<", :"$1", now_ms}], [true]}]

    :ets.select_delete(table, bare) + :ets.select_delete(table, claimed)
  end

  defp fresh_outbound_claim(table, key, deadline) do
    claim_ref = make_ref()
    :ets.insert(table, {key, {deadline, claim_ref}})
    {:ok, {:fresh, {key, claim_ref}}}
  end

  defp outbound_media_key(channel, chat_id, media_part) do
    with {:ok, path} <- required_string(media_part, :path),
         {:ok, digest} <- file_digest(path) do
      key_parts = [
        Atom.to_string(channel),
        chat_id,
        Atom.to_string(Map.get(media_part, :kind, :document)),
        Map.get(media_part, :caption, ""),
        Map.get(media_part, :filename, ""),
        Map.get(media_part, :mime_type, ""),
        digest
      ]

      {:ok, {:outbound_media, :crypto.hash(:sha256, :erlang.term_to_binary(key_parts))}}
    end
  end

  defp expired?(deadline, now_ms) when is_integer(deadline), do: deadline <= now_ms
  defp expired?({deadline, _claim_ref}, now_ms) when is_integer(deadline), do: deadline <= now_ms

  defp required_string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, {:missing_media_field, key}}
    end
  end

  defp file_digest(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, file} ->
        try do
          digest_file(file, :crypto.hash_init(:sha256))
        after
          File.close(file)
        end

      {:error, reason} ->
        {:error, {:file_digest_failed, reason}}
    end
  end

  defp digest_file(file, context) do
    case IO.binread(file, 64_000) do
      :eof -> {:ok, :crypto.hash_final(context)}
      data when is_binary(data) -> digest_file(file, :crypto.hash_update(context, data))
      {:error, reason} -> {:error, {:file_digest_failed, reason}}
    end
  end

  defp emit_idempotency_check(channel, result, duration_us) do
    :telemetry.execute(
      [:fermix, :idempotency, :check],
      %{duration_us: duration_us},
      %{channel: channel, result: check_result(result)}
    )
  end

  defp check_result({:error, _reason}), do: :error
  defp check_result(result) when result in [:fresh, :duplicate], do: result

  defp emit_outbound_media_claim(channel, result, duration_us) do
    :telemetry.execute(
      [:fermix, :idempotency, :outbound_media_claim],
      %{duration_us: duration_us},
      %{channel: channel, result: outbound_media_claim_result(result)}
    )
  end

  defp outbound_media_claim_result({:ok, {:fresh, _claim}}), do: :fresh
  defp outbound_media_claim_result({:ok, :duplicate}), do: :duplicate
  defp outbound_media_claim_result({:error, _reason}), do: :error
end
