defmodule FermixCore.Cues.Buckets do
  @moduledoc """
  The cue subsystem's cheap-to-lose state, in public named ETS tables owned by
  this process (M60 §5.3, §6.1, §6.7): the first child of `Cues.Supervisor`,
  because everything after it reads these tables, and a restart of it restarts
  them too.

    * **Token buckets.** Every source accepts 10 items a second with a burst of
      100, and the daemon 50 a second in all (with the same burst, so one
      source's burst passes an idle daemon). `admit/3` spends what it admits;
      `tokens/2` says what is left without spending it. Daily budgets live in
      `cue_sources`, so a restart forgets no budget.
    * **Door slots.** At most 16 bodies are read at once before
      authentication, 4 of them for one source; at most 4 authenticated
      requests are in flight, 1 for one source. A slot is held by the process
      that acquired it and comes back when that process releases it or dies.
    * **Credential fingerprints.** The SHA-256 of a source's secret, never the
      secret, kept for a minute so a request does not read the keyring each
      time and a rotated secret takes effect within a minute.
    * **Webhook signing keys.** An HMAC or Standard Webhooks signature needs
      the key itself, so a webhook source's signing key is kept the same
      minute, in a table of its own, in the daemon's memory only: never logged,
      never written anywhere.
    * **Reject counts.** What the door refused, per source and reason,
      coalesced here and written by the door in one row update per source.

  Every function that reads time takes it (`now_ms`, a monotonic millisecond
  reading).
  """

  use GenServer

  alias FermixCore.Cues.Config

  @buckets :fermix_cue_buckets
  @slots :fermix_cue_door_slots
  @fingerprints :fermix_cue_fingerprints
  @hook_keys :fermix_cue_hook_keys
  @rejects :fermix_cue_rejects

  # Tokens are kept in thousandths so a refill never rounds a partial token away.
  @milli 1_000
  @source_rate_per_s 10
  @source_burst 100
  @daemon_rate_per_s 50
  @daemon_burst 100

  @slot_limits %{read: {16, 4}, auth: {4, 1}}
  @fingerprint_ttl_ms 60_000

  @reject_reasons [
    :unauthorized,
    :rate_limited,
    :busy,
    :too_large,
    :unsupported_media_type,
    :malformed,
    :timeout,
    :unavailable
  ]

  @type slot_kind :: :read | :auth
  @type reject_reason ::
          :unauthorized
          | :rate_limited
          | :busy
          | :too_large
          | :unsupported_media_type
          | :malformed
          | :timeout
          | :unavailable
  @type slot_counts :: %{
          all: non_neg_integer(),
          by_source: %{optional(String.t()) => pos_integer()}
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Every reason the door counts a refusal under."
  @spec reject_reasons() :: [reject_reason()]
  def reject_reasons, do: @reject_reasons

  @doc """
  Admits up to `n` items for `source_ref` at `now_ms` and returns how many it
  admitted, spending them from both the source's bucket and the daemon's.
  """
  @spec admit(String.t(), non_neg_integer(), integer()) :: non_neg_integer()
  def admit(source_ref, n, now_ms)
      when is_binary(source_ref) and is_integer(n) and n >= 0 and is_integer(now_ms) do
    GenServer.call(__MODULE__, {:admit, source_ref, n, now_ms})
  end

  @doc """
  How many items `admit/3` would admit for `source_ref` at `now_ms`, spending
  nothing. Zero while the tables do not exist.
  """
  @spec tokens(String.t(), integer()) :: non_neg_integer()
  def tokens(source_ref, now_ms) when is_binary(source_ref) and is_integer(now_ms) do
    if table?(@buckets) do
      source = bucket({:source, source_ref}, @source_rate_per_s, @source_burst, now_ms)
      daemon = bucket(:daemon, @daemon_rate_per_s, @daemon_burst, now_ms)
      min(div(elem(source, 0), @milli), div(elem(daemon, 0), @milli))
    else
      0
    end
  end

  @doc """
  Takes one door slot of `kind` for `source_ref`, held by the calling process
  until `release/1` or its exit.
  """
  @spec acquire(slot_kind(), String.t()) :: {:ok, reference()} | {:error, :busy}
  def acquire(kind, source_ref) when kind in [:read, :auth] and is_binary(source_ref) do
    GenServer.call(__MODULE__, {:acquire, kind, source_ref})
  end

  @doc """
  Gives a slot back. Safe to call twice, with a token this process never
  issued, or with no `Buckets` running (a restart already zeroed every count),
  so the door can release in an `after`.
  """
  @spec release(reference()) :: :ok
  def release(token) when is_reference(token), do: GenServer.cast(__MODULE__, {:release, token})

  @doc "The slots held now, for status and tests."
  @spec counts() :: %{read: slot_counts(), auth: slot_counts()}
  def counts, do: GenServer.call(__MODULE__, :counts)

  @doc """
  The SHA-256 of a source's secret field, from the table when it was loaded
  less than a minute ago, else from `opts[:load]` (default
  `Cues.Config.secret/2`). A failed load is kept for the same minute, so a
  stream of bad requests cannot make the door read the keyring for each one.

  Options: `:now_ms` (required), `:load` (a zero-arity function returning
  `{:ok, secret} | {:error, reason}`).
  """
  @spec fingerprint({String.t(), Config.secret_field()}, keyword()) ::
          {:ok, binary()} | {:error, term()}
  def fingerprint({source_ref, field} = key, opts) when is_binary(source_ref) and is_list(opts) do
    now_ms = Keyword.fetch!(opts, :now_ms)
    load = Keyword.get(opts, :load, fn -> Config.secret(source_ref, field) end)

    if table?(@fingerprints) do
      cached(@fingerprints, key, now_ms, load, &:crypto.hash(:sha256, &1))
    else
      {:error, :unavailable}
    end
  end

  @doc """
  A webhook source's signing key itself, from the table when it was read less
  than a minute ago, else from `opts[:load]` (default `Cues.Config.secret/2`),
  read once on a miss. A failed read is kept for the same minute, as with
  `fingerprint/2`. The door calls it inside the source's authenticated slot,
  so no more than that slot's bound read the store at once.
  `{:error, :unavailable}` while the tables do not exist.

  Options: `:now_ms` (required), `:load` (a zero-arity function returning
  `{:ok, secret} | {:error, reason}`).
  """
  @spec hook_key({String.t(), Config.secret_field()}, keyword()) ::
          {:ok, binary()} | {:error, term()}
  def hook_key({source_ref, field} = key, opts) when is_binary(source_ref) and is_list(opts) do
    now_ms = Keyword.fetch!(opts, :now_ms)
    load = Keyword.get(opts, :load, fn -> Config.secret(source_ref, field) end)

    if table?(@hook_keys) do
      cached(@hook_keys, key, now_ms, load, & &1)
    else
      {:error, :unavailable}
    end
  end

  @doc """
  Counts one refusal of a request to `source_ref`. Best effort by design: with
  no table (a restart in progress) the count is dropped, as everything in this
  module may be.
  """
  @spec record_reject(String.t(), reject_reason()) :: :ok
  def record_reject(source_ref, reason)
      when is_binary(source_ref) and reason in @reject_reasons do
    if table?(@rejects) do
      _count = :ets.update_counter(@rejects, {source_ref, reason}, 1, {{source_ref, reason}, 0})
    end

    :ok
  end

  @doc "Takes every reject count, leaving none: `%{source_ref => %{reason => count}}`."
  @spec take_rejects() :: %{optional(String.t()) => %{optional(reject_reason()) => pos_integer()}}
  def take_rejects do
    if table?(@rejects) do
      @rejects
      |> :ets.select([{{:"$1", :_}, [], [:"$1"]}])
      |> Enum.flat_map(&:ets.take(@rejects, &1))
      |> Enum.reduce(%{}, &add_reject/2)
    else
      %{}
    end
  end

  # One `{ref, reason}` row is one count; keys are unique, so no merge is needed.
  defp add_reject({{ref, reason}, count}, acc),
    do: Map.update(acc, ref, %{reason => count}, &Map.put(&1, reason, count))

  # --- server ----------------------------------------------------------------

  @impl true
  def init(_opts) do
    for table <- [@buckets, @slots, @fingerprints, @hook_keys, @rejects] do
      :ets.new(table, [:named_table, :public, :set, read_concurrency: true])
    end

    {:ok, %{holders: %{}}}
  end

  @impl true
  def handle_call({:admit, ref, n, now_ms}, _from, state) do
    {:reply, spend(ref, n, now_ms), state}
  end

  def handle_call({:acquire, kind, ref}, {pid, _tag}, state) do
    case take_slot(kind, ref) do
      :ok ->
        token = Process.monitor(pid)
        {:reply, {:ok, token}, %{state | holders: Map.put(state.holders, token, {kind, ref})}}

      {:error, :busy} ->
        {:reply, {:error, :busy}, state}
    end
  end

  def handle_call(:counts, _from, state) do
    {:reply, %{read: slot_counts(:read), auth: slot_counts(:auth)}, state}
  end

  @impl true
  def handle_cast({:release, token}, state) do
    Process.demonitor(token, [:flush])
    {:noreply, give_back(state, token)}
  end

  @impl true
  def handle_info({:DOWN, token, :process, _pid, _reason}, state) do
    {:noreply, give_back(state, token)}
  end

  # --- buckets ---------------------------------------------------------------

  defp spend(ref, n, now_ms) do
    {source, source_last} = bucket({:source, ref}, @source_rate_per_s, @source_burst, now_ms)
    {daemon, daemon_last} = bucket(:daemon, @daemon_rate_per_s, @daemon_burst, now_ms)
    admitted = Enum.min([n, div(source, @milli), div(daemon, @milli)])

    :ets.insert(@buckets, [
      {{:source, ref}, source - admitted * @milli, source_last},
      {:daemon, daemon - admitted * @milli, daemon_last}
    ])

    admitted
  end

  # A bucket refilled to `now_ms`: a new one is full, a clock that moved
  # backwards refills nothing, and none ever holds more than its burst.
  defp bucket(key, rate_per_s, burst, now_ms) do
    capacity = burst * @milli

    case :ets.lookup(@buckets, key) do
      [] ->
        {capacity, now_ms}

      [{^key, tokens, last_ms}] ->
        elapsed = max(now_ms - last_ms, 0)
        {min(capacity, tokens + elapsed * rate_per_s), max(last_ms, now_ms)}
    end
  end

  # --- slots -----------------------------------------------------------------

  defp take_slot(kind, ref) do
    {all_limit, source_limit} = Map.fetch!(@slot_limits, kind)

    if count({kind, :all}) < all_limit and count({kind, ref}) < source_limit do
      _all = :ets.update_counter(@slots, {kind, :all}, 1, {{kind, :all}, 0})
      _source = :ets.update_counter(@slots, {kind, ref}, 1, {{kind, ref}, 0})
      :ok
    else
      {:error, :busy}
    end
  end

  defp give_back(state, token) do
    case Map.pop(state.holders, token) do
      {nil, _holders} ->
        state

      {{kind, ref}, holders} ->
        decrement({kind, :all})
        decrement({kind, ref})
        %{state | holders: holders}
    end
  end

  defp decrement({_kind, :all} = key) do
    _count = :ets.update_counter(@slots, key, {2, -1, 0, 0}, {key, 0})
    :ok
  end

  defp decrement(key) do
    case :ets.update_counter(@slots, key, {2, -1, 0, 0}, {key, 0}) do
      0 -> :ets.delete(@slots, key)
      _left -> true
    end

    :ok
  end

  defp count(key) do
    case :ets.lookup(@slots, key) do
      [{^key, count}] -> count
      [] -> 0
    end
  end

  defp slot_counts(kind) do
    by_source =
      for {{^kind, ref}, count} <- :ets.tab2list(@slots),
          ref != :all,
          count > 0,
          into: %{},
          do: {ref, count}

    %{all: count({kind, :all}), by_source: by_source}
  end

  # --- fingerprints and signing keys ------------------------------------------

  # `keep` turns the secret into what the table holds (its digest, or itself).
  defp cached(table, key, now_ms, load, keep) do
    case :ets.lookup(table, key) do
      [{^key, result, loaded_ms}] when now_ms - loaded_ms < @fingerprint_ttl_ms -> result
      _missing_or_stale -> load_into(table, key, now_ms, load, keep)
    end
  end

  defp load_into(table, key, now_ms, load, keep) do
    result =
      case load.() do
        {:ok, secret} when is_binary(secret) -> {:ok, keep.(secret)}
        {:error, reason} -> {:error, reason}
      end

    :ets.insert(table, {key, result, now_ms})
    result
  end

  defp table?(table), do: :ets.whereis(table) != :undefined
end
