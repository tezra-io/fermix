defmodule FermixChannels.Desktop.Peer do
  @moduledoc """
  The primary's one place for a connected desktop engine (M75 §3, §5.2).

  When a session whose device row is a `desktop` completes `hello`, it starts
  one peer under `FermixChannels.Desktop.PeerSupervisor` and hands it every
  desktop-family event the desktop sends (`deliver/2`): the companion tunnel,
  `manage`, the executor's `invoke_*`, `loopback_request`, `snapshot_stored`
  and the `handoff_*` events. The peer puts each chunked payload back
  together (`Mobile.Chunks`, within each event's bound) and hands every
  complete event to the module its family names in `@families`, the one map
  of families. An event whose family has no module there is answered
  `error{code:"unsupported_event"}`, and the session stays open. A gap, a
  repeat, a payload past its bound, a frame whose header differs from its
  payload's first, more than 32 payloads open at once, or more than 64 MiB
  held across them (or one blob's bound, when the session's is larger)
  closes the session with `1002`.

  The peer registers in `FermixChannels.Desktop.Peers` under the desktop's
  device id, with the session it serves and when it connected, so the primary
  finds a desktop to send to (`send/4`) and lists the connected ones
  (`connected/1`). A newer session of the same desktop replaces the older
  peer. The peer ends with its session, and its family states with it.
  """

  use GenServer, restart: :temporary

  require Logger

  alias FermixChannels.Mobile.Chunks
  alias FermixChannels.Mobile.Peers
  alias FermixChannels.Mobile.Protocol

  # Family => the module implementing `Desktop.Family` for it. Each family's
  # module is added here, one line each, as it is built.
  @families %{
    executor: FermixChannels.Desktop.Invocations,
    companion: FermixChannels.Desktop.Companion,
    manage: FermixChannels.Desktop.Manage,
    loopback: FermixChannels.Desktop.LoopbackForward,
    snapshots: FermixChannels.Desktop.SnapshotCopies,
    handoff: FermixChannels.Desktop.Handoffs
  }

  @event_families %{
    "companion_open" => :companion,
    "companion_line" => :companion,
    "companion_close" => :companion,
    "manage" => :manage,
    "invoke_result" => :executor,
    "invoke_blob" => :executor,
    "invoke_receipts" => :executor,
    "loopback_request" => :loopback,
    "loopback_failed" => :loopback,
    "snapshot_stored" => :snapshots,
    "snapshot_refused" => :snapshots,
    "handoff_begin" => :handoff,
    "handoff_chunk" => :handoff,
    "handoff_wipe" => :handoff
  }
  @family_names [:companion, :manage, :executor, :loopback, :snapshots, :handoff]
  @registry FermixChannels.Desktop.Peers
  @supervisor FermixChannels.Desktop.PeerSupervisor
  @max_open_payloads 32
  # What a desktop may hold open across its unfinished payloads: a budget, so
  # 32 payloads each near its own bound cannot add up to hundreds of MiB.
  @open_bytes_budget 64 * 1_024 * 1_024
  @deliver_timeout_ms 10_000
  @replace_timeout_ms 5_000

  @typedoc "What a family is told about the desktop it serves."
  @type context :: %{
          device_id: String.t(),
          session: pid(),
          peer: pid(),
          registry: GenServer.server(),
          max_media_bytes: pos_integer(),
          options: keyword()
        }

  @typedoc "A connected desktop, as `connected/1` lists it."
  @type connected :: %{device_id: String.t(), connected_since: DateTime.t()}

  @doc "The family each desktop-family event belongs to."
  @spec event_families() :: %{String.t() => atom()}
  def event_families, do: @event_families

  @doc "Every family a desktop's events belong to."
  @spec family_names() :: [atom()]
  def family_names, do: @family_names

  @doc "The families this primary serves, each with its module."
  @spec families() :: %{atom() => module()}
  def families, do: @families

  @doc "Whether `type` is a desktop-family event, which a desktop's session hands its peer."
  @spec family_event?(String.t()) :: boolean()
  def family_event?(type) when is_binary(type), do: Map.has_key?(@event_families, type)

  @doc """
  Starts the peer of a desktop session under `supervisor`. `opts`:
  `:device_id`, `:session` (the session's process), `:max_media_bytes`, and
  optionally `:registry` and `:families` (a test's own map of families, each
  a module or `{module, options}`, the options reaching the family's `init/1`
  as the context's `options`).
  """
  @spec start(GenServer.server(), keyword()) :: DynamicSupervisor.on_start_child()
  def start(supervisor \\ @supervisor, opts) when is_list(opts),
    do: DynamicSupervisor.start_child(supervisor, {__MODULE__, opts})

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  Hands the peer one desktop-family event its session decoded. `:ok`;
  `{:error, reason}`, which the session answers with an `error` and stays open;
  or `{:close, reason}`, a protocol error the session closes `1002` on.
  """
  @spec deliver(pid(), map()) :: :ok | {:error, term()} | {:close, term()}
  def deliver(peer, %{type: type, payload: fields, bytes: bytes} = event)
      when is_pid(peer) and is_binary(type) and is_map(fields) and is_binary(bytes) do
    GenServer.call(peer, {:deliver, event}, @deliver_timeout_ms)
  catch
    :exit, reason -> {:close, {:desktop_peer_unavailable, reason}}
  end

  @doc """
  Sends the desktop `device_id` one event: `event` is its header (`"t"` and
  its fields; a chunked event's `index` and `last` are this function's to
  write) and `payload` its raw bytes, cut into chunks when the event is
  chunked. Every frame is checked before any is sent, and they go to the
  desktop's session in order. Runs in the caller, so a family can answer from
  inside its own callback.
  """
  @spec send(String.t(), map(), binary(), keyword()) ::
          :ok | {:error, :not_connected | {:not_for_desktop, String.t()} | term()}
  def send(device_id, event, payload \\ <<>>, opts \\ [])
      when is_binary(device_id) and is_map(event) and is_binary(payload) and is_list(opts) do
    registry = Keyword.get(opts, :registry, @registry)

    with {:ok, type, fields} <- header(event),
         {:ok, frames} <- frames(type, fields, payload),
         {:ok, _peer, %{session: session}} <- lookup(registry, device_id) do
      Enum.each(frames, &Kernel.send(session, {:mobile_event, &1}))
    end
  end

  @doc "Sends `message` to `family`'s `handle_info/2` in the peer of `device_id`."
  @spec tell(String.t(), atom(), term(), keyword()) :: :ok | {:error, :not_connected}
  def tell(device_id, family, message, opts \\ [])
      when is_binary(device_id) and family in @family_names and is_list(opts) do
    with {:ok, peer, _value} <- lookup(Keyword.get(opts, :registry, @registry), device_id) do
      Kernel.send(peer, {:desktop_family, family, message})
      :ok
    end
  end

  @doc "The desktops connected now, by device id, each with when it connected."
  @spec connected(GenServer.server()) :: [connected()]
  def connected(registry \\ @registry) do
    registry
    |> Registry.select([{{:"$1", :_, :"$2"}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.map(fn {device_id, value} ->
      %{device_id: device_id, connected_since: value.connected_since}
    end)
    |> Enum.sort_by(& &1.device_id)
  end

  @doc "The peer serving `device_id` and what it registered, or `:not_connected`."
  @spec lookup(GenServer.server(), String.t()) ::
          {:ok, pid(), %{session: pid(), connected_since: DateTime.t()}}
          | {:error, :not_connected}
  def lookup(registry \\ @registry, device_id) when is_binary(device_id) do
    case Registry.lookup(registry, device_id) do
      [{peer, value}] -> {:ok, peer, value}
      [] -> {:error, :not_connected}
    end
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    state = build_state(opts)
    Process.monitor(state.session)
    since = Keyword.get_lazy(opts, :connected_since, &DateTime.utc_now/0)
    value = %{session: state.session, connected_since: since}

    with :ok <- register(state.registry, state.device_id, value),
         {:ok, families} <- init_families(Keyword.get(opts, :families, @families), state) do
      {:ok, %{state | families: families}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:deliver, event}, _from, state) do
    case route(event, state) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
      {:close, reason, state} -> {:reply, {:close, reason}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, session, _reason}, %{session: session} = state),
    do: {:stop, :normal, state}

  def handle_info({:desktop_family, family, message}, state) do
    case Map.fetch(state.families, family) do
      {:ok, {module, family_state}} ->
        {:ok, family_state} = module.handle_info(message, family_state)
        {:noreply, put_family(state, family, module, family_state)}

      :error ->
        Logger.warning("desktop peer: a message for #{family}, which this primary does not serve")
        {:noreply, state}
    end
  end

  # Exits are trapped only so the families' `terminate/2` runs on shutdown;
  # GenServer handles the parent's exit itself. A family links nothing to the
  # peer, so any other exit is a fault that ends it.
  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, {:linked_exit, reason}, state}
  def handle_info(_message, state), do: {:noreply, state}

  # The key goes first, so a newer peer of the same desktop waiting in
  # `register/3` finds it free the moment this one is gone.
  @impl true
  def terminate(reason, state) do
    _ = Registry.unregister(state.registry, state.device_id)

    Enum.each(state.families, fn {_family, {module, family_state}} ->
      :ok = module.terminate(reason, family_state)
    end)
  end

  defp build_state(opts) do
    %{
      device_id: Keyword.fetch!(opts, :device_id),
      session: Keyword.fetch!(opts, :session),
      registry: Keyword.get(opts, :registry, @registry),
      max_media_bytes: Keyword.fetch!(opts, :max_media_bytes),
      open_bytes_budget: Keyword.get(opts, :open_bytes_budget, @open_bytes_budget),
      families: %{},
      open: %{}
    }
  end

  # A desktop that reconnected has a newer session; its older peer goes, its
  # families' `terminate/2` run, and the newer one takes the name.
  defp register(registry, device_id, value) do
    case Registry.register(registry, device_id, value) do
      {:ok, _owner} -> :ok
      {:error, {:already_registered, older}} -> replace(registry, device_id, value, older)
    end
  end

  defp replace(registry, device_id, value, older) do
    :ok = stop_older(older)

    case Registry.register(registry, device_id, value) do
      {:ok, _owner} -> :ok
      {:error, reason} -> {:error, {:desktop_peer_not_registered, reason}}
    end
  end

  defp stop_older(older) do
    GenServer.stop(older, :replaced, @replace_timeout_ms)
  catch
    :exit, :noproc -> :ok
    :exit, {:noproc, _call} -> :ok
  end

  defp init_families(families, state) do
    context = %{
      device_id: state.device_id,
      session: state.session,
      peer: self(),
      registry: state.registry,
      max_media_bytes: state.max_media_bytes
    }

    Enum.reduce_while(families, {:ok, %{}}, fn {family, entry}, {:ok, acc} ->
      {module, options} = family_entry(entry)

      case module.init(Map.put(context, :options, options)) do
        {:ok, family_state} -> {:cont, {:ok, Map.put(acc, family, {module, family_state})}}
        {:error, reason} -> {:halt, {:error, {:desktop_family_init_failed, family, reason}}}
      end
    end)
  end

  # A family is its module, or `{module, options}` (a test's own seams), which
  # its `init/1` reads from the context's `options`.
  defp family_entry({module, options}) when is_atom(module) and is_list(options),
    do: {module, options}

  defp family_entry(module) when is_atom(module), do: {module, []}

  defp route(%{type: type, payload: fields, bytes: bytes}, state) do
    family = Map.fetch!(@event_families, type)

    case Map.fetch(state.families, family) do
      {:ok, {module, _family_state}} -> take(type, fields, bytes, family, module, state)
      :error -> {:error, {:unsupported_event, type}, state}
    end
  end

  defp take(type, fields, bytes, family, module, state) do
    if Chunks.chunked?(type) do
      take_chunk(type, fields, bytes, family, module, state)
    else
      dispatch(type, fields, bytes, family, module, state)
    end
  end

  defp take_chunk(type, fields, bytes, family, module, state) do
    header = Map.drop(fields, ["index", "last"])
    key = payload_key(type, fields)

    with {:ok, open} <- open_payload(key, type, header, state),
         :ok <- same_header(open.header, header, type),
         :ok <- within_budget(bytes, state) do
      case Chunks.add(open.acc, fields["index"], fields["last"], bytes) do
        {:more, acc} -> {:ok, put_in(state.open[key], %{open | acc: acc})}
        {:done, payload} -> dispatch(type, header, payload, family, module, drop(state, key))
        {:error, reason} -> {:close, reason, drop(state, key)}
      end
    else
      {:error, reason} -> {:close, reason, drop(state, key)}
    end
  end

  defp payload_key(type, fields) do
    {:ok, field} = Chunks.key_field(type)
    {type, Map.fetch!(fields, field)}
  end

  defp open_payload(key, type, header, state) do
    case Map.fetch(state.open, key) do
      {:ok, open} ->
        {:ok, open}

      :error when map_size(state.open) >= @max_open_payloads ->
        {:error, {:too_many_open_payloads, @max_open_payloads}}

      :error ->
        {:ok, bound} = Chunks.bound(type, state.max_media_bytes)
        {:ok, %{header: header, acc: Chunks.new(bound)}}
    end
  end

  # The bytes every open payload holds, and this frame's: within the budget, or
  # one blob's bound where the session allows a larger one.
  defp within_budget(bytes, state) do
    budget = max(state.open_bytes_budget, state.max_media_bytes)
    held = Enum.reduce(state.open, 0, fn {_key, open}, sum -> sum + open.acc.size end)

    if held + byte_size(bytes) <= budget,
      do: :ok,
      else: {:error, {:open_payload_bytes, budget}}
  end

  defp same_header(header, header, _type), do: :ok
  defp same_header(_first, _later, type), do: {:error, {:chunk_header_changed, type}}

  defp drop(state, key), do: %{state | open: Map.delete(state.open, key)}

  defp dispatch(type, fields, payload, family, module, state) do
    {^module, family_state} = Map.fetch!(state.families, family)

    case module.handle_event(type, fields, payload, family_state) do
      {:ok, family_state} ->
        {:ok, put_family(state, family, module, family_state)}

      {:error, reason, family_state} ->
        {:error, reason, put_family(state, family, module, family_state)}
    end
  end

  defp put_family(state, family, module, family_state),
    do: %{state | families: Map.put(state.families, family, {module, family_state})}

  defp header(%{"t" => type} = event) when is_binary(type) do
    fields = Map.delete(event, "t")

    cond do
      not Peers.server_event?(:desktop, type) -> {:error, {:not_for_desktop, type}}
      Chunks.chunked?(type) and has_chunk_fields?(fields) -> {:error, {:reserved_field, type}}
      true -> {:ok, type, fields}
    end
  end

  defp header(event), do: {:error, {:invalid_event, Map.keys(event)}}

  defp has_chunk_fields?(fields),
    do: Map.has_key?(fields, "index") or Map.has_key?(fields, "last")

  defp frames(type, fields, payload) do
    pieces =
      if Chunks.chunked?(type),
        do: chunked_pieces(type, fields, payload),
        else: {:ok, [{fields, payload}]}

    with {:ok, pieces} <- pieces do
      checked_frames(type, pieces)
    end
  end

  # A server event's bound never depends on the media cap: only the
  # desktop's `invoke_blob` does, and the primary never sends one.
  defp chunked_pieces(type, fields, payload) do
    {:ok, bound} = Chunks.bound(type, 1)

    if byte_size(payload) <= bound do
      {:ok,
       for {index, last, bytes} <- Chunks.split(payload) do
         {Map.merge(fields, %{"index" => index, "last" => last}), bytes}
       end}
    else
      {:error, {:payload_too_large, type, byte_size(payload), bound}}
    end
  end

  # The session encodes each frame again at its own sequence; this proves
  # every one encodes before the first is handed over.
  defp checked_frames(type, pieces) do
    Enum.reduce_while(pieces, {:ok, []}, fn {fields, bytes}, {:ok, frames} ->
      case Protocol.encode_server_frame(type, fields, 1, bytes) do
        {:ok, _frame} ->
          {:cont, {:ok, [Map.merge(fields, %{"t" => type, "bytes" => bytes}) | frames]}}

        {:error, reason} ->
          {:halt, {:error, {:invalid_event, type, reason}}}
      end
    end)
    |> then(fn
      {:ok, frames} -> {:ok, Enum.reverse(frames)}
      {:error, _reason} = error -> error
    end)
  end
end
