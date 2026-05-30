defmodule FermixChannels.Gateway.Idempotency do
  @moduledoc """
  In-memory idempotency cache for inbound channel events.

  Webhook providers retry on slow acknowledgements (audit F-06). Without
  deduplication, a retried event runs the agent loop twice, sends two
  replies, and stores the same memory twice.

  Keys are `{channel, platform_message_id}` tuples. Entries live for
  `@default_ttl_ms` (24h). The cache is process-local to the BEAM node:
  a daemon restart starts fresh, which is acceptable since provider
  retry windows are typically minutes, not hours.

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

  alias FermixCore.Telemetry

  @table __MODULE__.Table
  @default_ttl_ms 24 * 60 * 60 * 1_000
  @default_outbound_ttl_ms 60_000

  @type outbound_media_claim :: {term(), reference()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Returns `:fresh` if this is the first time we have seen the key, or
  `:duplicate` if it has been seen within the TTL. The check-and-set is
  atomic from the caller's perspective; concurrent callers with the
  same key will see exactly one `:fresh` and the rest `:duplicate`.
  """
  @spec check_and_record(atom(), term(), keyword()) :: :fresh | :duplicate
  def check_and_record(channel, message_id, opts \\ [])
      when is_atom(channel) and not is_nil(message_id) do
    server = Keyword.get(opts, :server, __MODULE__)
    ttl_ms = Keyword.get(opts, :ttl_ms, @default_ttl_ms)

    {result, duration_us} =
      Telemetry.timed_us(fn ->
        GenServer.call(server, {:check_and_record, {channel, message_id}, ttl_ms})
      end)

    emit_idempotency_check(channel, result, duration_us)
    result
  end

  @doc """
  Removes a previously-recorded entry. Used by the webhook controller to
  roll back the idempotency record when the async dispatch task fails to
  start — without this, a failed start_child would silently burn the
  message id and suppress the provider's retry. (Audit F-06 follow-up.)
  """
  @spec forget(atom(), term(), keyword()) :: :ok
  def forget(channel, message_id, opts \\ [])
      when is_atom(channel) and not is_nil(message_id) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:forget, {channel, message_id}})
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

    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:check_and_record, key, ttl_ms}, _from, state) do
    now_ms = System.monotonic_time(:millisecond)
    deadline = now_ms + ttl_ms

    result =
      case :ets.lookup(state.table, key) do
        [{^key, existing}] when existing > now_ms ->
          :duplicate

        _missing_or_expired ->
          :ets.insert(state.table, {key, deadline})
          :fresh
      end

    {:reply, result, state}
  end

  def handle_call({:forget, key}, _from, state) do
    :ets.delete(state.table, key)
    {:reply, :ok, state}
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

  @impl true
  def handle_info(_other, state), do: {:noreply, state}

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
      %{channel: channel, result: result}
    )
  end

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
