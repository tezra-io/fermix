defmodule FermixCore.Capabilities.MCP.Remote.Budget do
  @moduledoc """
  Hard per-turn ceilings and fixed argument guards for the remote MCP rail
  (M27 §8.4).

  These are **enforcement**, not prompt advice. A model that is told "at most 20
  calls" and then makes 40 has made 40; a charge that fails before dispatch has
  made 20. Every ceiling here is charged atomically *before* network dispatch —
  including a permitted replay, which is a second network attempt and costs a
  second unit.

  State is keyed by `{source_id, session_id}`, so two turns, two sources, and
  two plugins never share a budget. The owning turn process is monitored: its
  `:DOWN` deletes the entry, `finish/2` deletes it on normal turn completion,
  and a bounded orphan TTL sweeps whatever neither path reached. A budget table
  that only ever grows is a leak with a security label on it.

  Setup, discovery, and doctor charge against their own **named lifecycle**
  identity (`lifecycle_key/2`) with its own fixed ceiling. They never borrow an
  agent turn's identity, so a setup workspace probe cannot spend the agent's
  call budget (or hide inside it).

  The two argument guards are fixed core code. The signed manifest picks *which*
  field is guarded and *how many* items are allowed; it cannot weaken either
  guard, and there is no plugin-supplied guard code.
  """

  use GenServer

  # A turn that neither completed nor died observably still cannot hold state
  # forever. 15 minutes is far beyond any agent turn and far below "forever".
  @orphan_ttl_ms 15 * 60 * 1000
  @sweep_interval_ms 60_000

  # Setup/discovery/doctor are operator-driven and bounded by their own budget.
  @lifecycle_calls 20

  # Query keys that carry a credential or a presigned grant. A URL handed to a
  # third-party service with one of these attached has leaked it, whatever the
  # host is.
  @sensitive_query_keys ~w(
    signature sig token access_token id_token api_key apikey key password secret
    auth authorization credential x-amz-signature x-amz-credential
    x-amz-security-token x-goog-signature se sp sv sr st
  )

  @max_url_bytes 2048
  @max_ascii_item_bytes 256

  @type source_id :: {atom(), String.t()}
  @type key :: {source_id(), String.t() | {:lifecycle, atom()}}
  @type kind :: :call | :paginated_call
  @type limits :: %{turn_calls: pos_integer(), turn_paginated_calls: pos_integer()}

  @type opt ::
          {:name, GenServer.name()}
          | {:sweep_interval_ms, pos_integer()}
          | {:orphan_ttl_ms, pos_integer()}

  @spec start_link([opt()]) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "The budget identity of one agent turn against one source."
  @spec turn_key(source_id(), String.t()) :: key()
  def turn_key({kind, name} = source_id, session_id)
      when is_atom(kind) and is_binary(name) and is_binary(session_id) and session_id != "",
      do: {source_id, session_id}

  @doc """
  The budget identity of a non-agent lifecycle operation.

  Setup, discovery, and doctor are `{:lifecycle, kind}`, never a session id, so
  they can neither spend nor hide inside an agent turn's ceiling.
  """
  @spec lifecycle_key(source_id(), atom()) :: key()
  def lifecycle_key({kind, name} = source_id, lifecycle)
      when is_atom(kind) and is_binary(name) and lifecycle in [:setup, :discovery, :doctor],
      do: {source_id, {:lifecycle, lifecycle}}

  @doc """
  Charge one network attempt. Returns `{:error, {:budget_exhausted, which}}`
  when the ceiling is already spent — the caller must not dispatch.

  `owner` is the process whose death releases the entry (the turn process).
  """
  @spec charge(GenServer.server(), key(), kind(), limits(), pid()) ::
          :ok | {:error, {:budget_exhausted, atom()}}
  def charge(server \\ __MODULE__, key, kind, limits, owner)
      when kind in [:call, :paginated_call] and is_map(limits) and is_pid(owner) do
    GenServer.call(server, {:charge, key, kind, limits, owner})
  end

  @doc "Release a turn's budget entry. Idempotent."
  @spec finish(GenServer.server(), key()) :: :ok
  def finish(server \\ __MODULE__, key), do: GenServer.call(server, {:finish, key})

  @doc "Current usage for a key, for status surfaces and tests."
  @spec usage(GenServer.server(), key()) ::
          {:ok, %{calls: non_neg_integer(), paginated: non_neg_integer()}} | :error
  def usage(server \\ __MODULE__, key), do: GenServer.call(server, {:usage, key})

  @doc "Sweep orphaned entries now (the periodic sweep calls the same code)."
  @spec sweep(GenServer.server()) :: {:ok, non_neg_integer()}
  def sweep(server \\ __MODULE__), do: GenServer.call(server, :sweep)

  # --- fixed argument guards ---------------------------------------------

  @doc """
  Apply every signed argument guard to the model's arguments.

  Runs before network I/O: an input above a limit fails at the boundary rather
  than being trimmed to fit, because a silently trimmed batch is a batch the
  operator never authorized.
  """
  @spec check_arguments([map()], map()) :: :ok | {:error, {:argument_guard, String.t(), atom()}}
  def check_arguments(guards, args) when is_list(guards) and is_map(args) do
    Enum.reduce_while(guards, :ok, fn guard, :ok ->
      case check_guard(guard, args) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc """
  Inject the signed default request limit when the model omitted it, and refuse
  a larger one.
  """
  @spec apply_request_limit(map() | nil, map()) :: {:ok, map()} | {:error, {:collection, atom()}}
  def apply_request_limit(nil, args) when is_map(args), do: {:ok, args}

  def apply_request_limit(policy, args) when is_map(policy) and is_map(args) do
    with {:ok, segments} <- pointer(Map.get(policy, "request_limit_pointer")) do
      settle_limit(policy, args, segments)
    end
  end

  @doc """
  Refuse an oversized RETURNED collection.

  Truncating it would hand the agent a silently partial answer it would then
  reason about as if it were complete.
  """
  @spec check_returned_items(map() | nil, term()) :: :ok | {:error, {:collection, atom()}}
  def check_returned_items(nil, _body), do: :ok

  def check_returned_items(policy, body) when is_map(policy) do
    with {:ok, segments} <- pointer(Map.get(policy, "result_items_pointer")) do
      count_items(policy, body, segments)
    end
  end

  # --- server ------------------------------------------------------------

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :sweep_interval_ms, @sweep_interval_ms)
    {:ok, timer} = :timer.send_interval(interval, :sweep)

    {:ok,
     %{
       entries: %{},
       monitors: %{},
       timer: timer,
       orphan_ttl_ms: Keyword.get(opts, :orphan_ttl_ms, @orphan_ttl_ms)
     }}
  end

  @impl true
  def terminate(_reason, %{timer: timer}) do
    _ = :timer.cancel(timer)
    :ok
  end

  @impl true
  def handle_call({:charge, key, kind, limits, owner}, _from, state) do
    {entry, state} = ensure_entry(state, key, owner)

    case admit(entry, kind, ceiling(key, limits)) do
      {:ok, entry} -> {:reply, :ok, put_entry(state, key, entry)}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:finish, key}, _from, state), do: {:reply, :ok, drop(state, key)}

  def handle_call({:usage, key}, _from, state) do
    case Map.fetch(state.entries, key) do
      {:ok, entry} -> {:reply, {:ok, %{calls: entry.calls, paginated: entry.paginated}}, state}
      :error -> {:reply, :error, state}
    end
  end

  def handle_call(:sweep, _from, state) do
    {swept, state} = sweep_expired(state)
    {:reply, {:ok, swept}, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    {_swept, state} = sweep_expired(state)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, monitors} -> {:noreply, %{state | monitors: monitors}}
      {key, monitors} -> {:noreply, drop(%{state | monitors: monitors}, key)}
    end
  end

  defp ensure_entry(state, key, owner) do
    case Map.fetch(state.entries, key) do
      {:ok, entry} ->
        {entry, state}

      :error ->
        ref = Process.monitor(owner)
        entry = %{calls: 0, paginated: 0, ref: ref, started_at: now()}
        {entry, %{state | monitors: Map.put(state.monitors, ref, key)}}
    end
  end

  defp put_entry(state, key, entry),
    do: %{state | entries: Map.put(state.entries, key, %{entry | started_at: now()})}

  defp drop(state, key) do
    case Map.pop(state.entries, key) do
      {nil, _entries} ->
        state

      {entry, entries} ->
        Process.demonitor(entry.ref, [:flush])
        %{state | entries: entries, monitors: Map.delete(state.monitors, entry.ref)}
    end
  end

  defp sweep_expired(state) do
    cutoff = now() - state.orphan_ttl_ms

    expired =
      state.entries
      |> Enum.filter(fn {_key, entry} -> entry.started_at < cutoff end)
      |> Enum.map(&elem(&1, 0))

    {length(expired), Enum.reduce(expired, state, &drop(&2, &1))}
  end

  # A lifecycle identity has its own fixed ceiling; only an agent turn spends
  # the manifest's signed per-turn budget.
  defp ceiling({_source_id, {:lifecycle, _kind}}, _limits),
    do: %{turn_calls: @lifecycle_calls, turn_paginated_calls: @lifecycle_calls}

  defp ceiling({_source_id, session_id}, limits) when is_binary(session_id), do: limits

  defp admit(entry, :call, %{turn_calls: max_calls}) do
    if entry.calls >= max_calls,
      do: {:error, {:budget_exhausted, :agent_turn_calls}},
      else: {:ok, %{entry | calls: entry.calls + 1}}
  end

  defp admit(entry, :paginated_call, ceiling) do
    with {:ok, entry} <- admit(entry, :call, ceiling) do
      admit_paginated(entry, ceiling)
    end
  end

  defp admit_paginated(entry, %{turn_paginated_calls: max_paginated}) do
    if entry.paginated >= max_paginated,
      do: {:error, {:budget_exhausted, :agent_turn_paginated_calls}},
      else: {:ok, %{entry | paginated: entry.paginated + 1}}
  end

  defp now, do: System.monotonic_time(:millisecond)

  # --- guards ------------------------------------------------------------

  defp check_guard(%{"pointer" => raw, "kind" => kind, "max_items" => max_items}, args) do
    with {:ok, segments} <- guard_pointer(raw, kind) do
      check_items(fetch_in(args, segments), kind, max_items)
    end
  end

  defp guard_pointer(raw, kind) do
    case pointer(raw) do
      {:ok, segments} -> {:ok, segments}
      {:error, _reason} -> {:error, {:argument_guard, kind, :invalid_pointer}}
    end
  end

  # An absent guarded field is not a violation: the guard bounds a field that is
  # present, and a schema-required field is the schema's job.
  defp check_items(:error, _kind, _max_items), do: :ok

  defp check_items({:ok, items}, kind, max_items) when is_list(items) do
    if length(items) > max_items,
      do: {:error, {:argument_guard, kind, :too_many_items}},
      else: validate_items(items, kind)
  end

  defp check_items({:ok, _other}, kind, _max_items),
    do: {:error, {:argument_guard, kind, :not_an_array}}

  defp validate_items(items, "public_http_url_array"),
    do: reduce_items(items, "public_http_url_array", &public_http_url/1)

  defp validate_items(items, "bounded_visible_ascii_array"),
    do: reduce_items(items, "bounded_visible_ascii_array", &visible_ascii/1)

  defp validate_items(_items, kind), do: {:error, {:argument_guard, kind, :unknown_guard_kind}}

  defp reduce_items(items, kind, check) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case check.(item) do
        :ok -> {:cont, :ok}
        {:error, class} -> {:halt, {:error, {:argument_guard, kind, class}}}
      end
    end)
  end

  defp visible_ascii(item) when is_binary(item) do
    cond do
      byte_size(item) == 0 -> {:error, :empty_item}
      byte_size(item) > @max_ascii_item_bytes -> {:error, :item_too_long}
      not visible_ascii?(item) -> {:error, :non_visible_ascii}
      true -> :ok
    end
  end

  defp visible_ascii(_item), do: {:error, :not_a_string}

  defp visible_ascii?(value),
    do: value |> :binary.bin_to_list() |> Enum.all?(&(&1 >= 0x21 and &1 <= 0x7E))

  # Structural only, and deliberately so: the fetch happens on the *server's*
  # network, not ours, so resolving DNS here would prove nothing about what the
  # peer resolves. What this can prove is that the URL we hand over is a public
  # HTTP(S) URL carrying no credential.
  defp public_http_url(item) when is_binary(item) do
    with :ok <- bound_url(item), {:ok, uri} <- parse_url(item) do
      inspect_url(uri)
    end
  end

  defp public_http_url(_item), do: {:error, :not_a_string}

  defp bound_url(item) do
    cond do
      byte_size(item) == 0 -> {:error, :empty_item}
      byte_size(item) > @max_url_bytes -> {:error, :item_too_long}
      String.match?(item, ~r/[\x00-\x20\x7f]/) -> {:error, :control_characters}
      true -> :ok
    end
  end

  defp parse_url(item) do
    case URI.new(item) do
      {:ok, %URI{} = uri} -> {:ok, uri}
      {:error, _part} -> {:error, :unparseable_url}
    end
  end

  defp inspect_url(uri) do
    cond do
      uri.scheme not in ["http", "https"] -> {:error, :scheme_not_http}
      uri.userinfo != nil -> {:error, :userinfo_present}
      not global_host?(uri.host) -> {:error, :non_global_host}
      sensitive_query?(uri.query) -> {:error, :sensitive_query_key}
      true -> :ok
    end
  end

  defp global_host?(host) when is_binary(host) and host != "" do
    lowered = String.downcase(host)

    not (lowered in ~w(localhost broadcasthost) or
           String.ends_with?(lowered, [".localhost", ".local", ".internal", ".home.arpa"]) or
           private_ip?(lowered))
  end

  defp global_host?(_host), do: false

  defp private_ip?(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} -> not global_address?(address)
      {:error, :einval} -> false
    end
  end

  defp global_address?({127, _b, _c, _d}), do: false
  defp global_address?({10, _b, _c, _d}), do: false
  defp global_address?({192, 168, _c, _d}), do: false
  defp global_address?({169, 254, _c, _d}), do: false
  defp global_address?({172, b, _c, _d}) when b >= 16 and b <= 31, do: false
  defp global_address?({100, b, _c, _d}) when b >= 64 and b <= 127, do: false
  defp global_address?({0, _b, _c, _d}), do: false
  defp global_address?({_a, _b, _c, _d}), do: true
  defp global_address?({0, 0, 0, 0, 0, 0, 0, 0}), do: false
  defp global_address?({0, 0, 0, 0, 0, 0, 0, 1}), do: false

  defp global_address?({a, _b, _c, _d, _e, _f, _g, _h}) when a >= 0xFC00 and a <= 0xFDFF,
    do: false

  defp global_address?({a, _b, _c, _d, _e, _f, _g, _h}) when a >= 0xFE80 and a <= 0xFEBF,
    do: false

  defp global_address?(_address), do: true

  defp sensitive_query?(nil), do: false

  defp sensitive_query?(query) do
    query
    |> String.split("&", trim: true)
    |> Enum.any?(fn pair ->
      pair |> String.split("=", parts: 2) |> hd() |> String.downcase() |> sensitive_key?()
    end)
  end

  defp sensitive_key?(key), do: key in @sensitive_query_keys

  # --- collection policy -------------------------------------------------

  defp settle_limit(policy, args, segments) do
    default = Map.fetch!(policy, "default_limit")
    max_items = Map.fetch!(policy, "max_returned_items")

    case fetch_in(args, segments) do
      :error -> {:ok, put_in_path(args, segments, default)}
      {:ok, value} when is_integer(value) and value >= 1 -> bound_limit(args, value, max_items)
      {:ok, _invalid} -> {:error, {:collection, :invalid_request_limit}}
    end
  end

  defp bound_limit(args, value, max_items) do
    if value > max_items,
      do: {:error, {:collection, :request_limit_too_large}},
      else: {:ok, args}
  end

  defp count_items(policy, body, segments) do
    max_items = Map.fetch!(policy, "max_returned_items")

    case fetch_in(body, segments) do
      {:ok, items} when is_list(items) -> bound_returned(items, max_items)
      # The collection is absent from an error body; the classifier owns that.
      _absent -> :ok
    end
  end

  defp bound_returned(items, max_items) do
    if length(items) > max_items,
      do: {:error, {:collection, :oversized_returned_collection}},
      else: :ok
  end

  # --- RFC 6901 pointers (no wildcards, bounded depth) -------------------

  defp pointer(raw) when is_binary(raw) do
    if String.starts_with?(raw, "/") and not String.contains?(raw, "*"),
      do: split_pointer(raw),
      else: {:error, {:collection, :invalid_pointer}}
  end

  defp pointer(_raw), do: {:error, {:collection, :invalid_pointer}}

  defp split_pointer(raw) do
    segments = raw |> String.split("/") |> tl()

    if segments == [] or Enum.any?(segments, &(&1 == "")) or length(segments) > 8,
      do: {:error, {:collection, :invalid_pointer}},
      else: {:ok, Enum.map(segments, &unescape/1)}
  end

  defp unescape(segment),
    do: segment |> String.replace("~1", "/") |> String.replace("~0", "~")

  defp fetch_in(data, segments) do
    Enum.reduce_while(segments, {:ok, data}, fn segment, {:ok, node} ->
      case node do
        %{} = map -> step(map, segment)
        _leaf -> {:halt, :error}
      end
    end)
  end

  defp step(map, segment) do
    case Map.fetch(map, segment) do
      {:ok, value} -> {:cont, {:ok, value}}
      :error -> {:halt, :error}
    end
  end

  defp put_in_path(data, [segment], value), do: Map.put(data, segment, value)

  defp put_in_path(data, [segment | rest], value) do
    child = Map.get(data, segment, %{})
    Map.put(data, segment, put_in_path(child, rest, value))
  end
end
