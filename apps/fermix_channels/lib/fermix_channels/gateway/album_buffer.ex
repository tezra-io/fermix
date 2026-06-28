defmodule FermixChannels.Gateway.AlbumBuffer do
  @moduledoc """
  Coalesces a multi-attachment "album" into one turn, channel-agnostically.

  Some channels deliver a multi-image album as several *separate* inbound
  messages instead of one. Telegram sends album parts as distinct updates that
  share a `media_group_id` (often across poll cycles); WhatsApp — a stateless
  webhook with no group id — sends each image as its own webhook message. Without
  coalescing each part becomes its own one-image turn and the agent never sees
  the set together (M14).

  This is a *non-blocking* GenServer: it owns only the debounce timers, never the
  transport. That separation is load-bearing for Telegram — the poller blocks for
  tens of seconds inside getUpdates long-polling, so an in-poller flush timer
  could not fire until the poll returned (the original ~50s album delay).
  Buffering in this separate process flushes on time regardless of what the
  transport is doing.

  ## Per-channel policy

  Each buffering channel classifies its own inbound messages via the optional
  `c:FermixChannels.Gateway.Channel.album_classify/1` callback:

    * `{:coalesce, key}` — buffer under `key` with a reset-on-each-part debounce.
    * `{:flush, key}` — flush a pending album under `key` first, then dispatch
      this message as its own turn (a trailing text that shares the album's key).
    * `:passthrough` — dispatch immediately, touching no buffer (a message whose
      key can never collide with an album, e.g. a lone Telegram message).

  ## Merge

  Buffered parts flush as ONE message: every non-empty caption joined with `"\\n"`
  in arrival order, all attachments concatenated. Other fields come from the
  first part. The existing `MediaIngest → TurnRunner → encoder` path turns that
  into one multi-image turn — no downstream change.

  ## Ordering, idempotency, durability

    * **Ordering** is enforced by the gateway's per-conversation FIFO queue. A
      coalesce key is a subset of the conversation key, so a flushed album and a
      trailing message stay in arrival order.
    * **Idempotency** stays where the transport records it. Webhook channels
      record per message id *before* buffering (pass `idempotency_key:`); on a
      flush-time dispatch error the buffer `Idempotency.forget/2`s every buffered
      part id so a provider re-delivery can re-run. Polling channels dedup via
      offset advance and record nothing (`idempotency_key: nil` — no forget).
    * **At-most-once across restart.** A daemon restart inside the (sub-second)
      debounce window drops unflushed parts; webhook acks are already sent and
      the polling offset already advanced, so there is no re-delivery backstop.
      Acceptable for a rare restart vs. a short window; documented, not silently
      degraded.
  """

  use GenServer

  require Logger

  alias FermixChannels.Gateway
  alias FermixChannels.Gateway.Idempotency
  alias FermixChannels.Gateway.Queue

  @default_debounce_ms 3_000
  # A single album is bounded by max_parts; the number of distinct concurrently
  # buffering keys is bounded by max_keys (excess keys dispatch uncoalesced
  # rather than growing the buffer without limit).
  @default_max_parts 10
  @default_max_keys 200

  @doc "Registered name of the album buffer for `channel` (one instance per buffering channel)."
  @spec name_for(module()) :: atom()
  def name_for(channel) when is_atom(channel), do: Module.concat(channel, AlbumBuffer)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Route one inbound message through the album buffer for its channel."
  @spec ingest(map(), GenServer.server()) :: :ok
  def ingest(message, server) when is_map(message) do
    GenServer.cast(server, {:ingest, message})
  end

  @impl true
  def init(opts) do
    channel = Keyword.fetch!(opts, :channel)
    ensure_classifiable!(channel)

    state = %{
      buffers: %{},
      channel: channel,
      idempotency_key: Keyword.get(opts, :idempotency_key),
      debounce_ms: Keyword.get(opts, :debounce_ms) || configured_debounce_ms(opts),
      max_parts: Keyword.get(opts, :max_parts, @default_max_parts),
      max_keys: Keyword.get(opts, :max_keys, @default_max_keys),
      agent: Keyword.get(opts, :agent, Queue),
      agent_server: Keyword.get(opts, :agent_server, Queue),
      # Dispatch seam (default = the real gateway); tests inject a capturing fun.
      dispatch: Keyword.get(opts, :dispatch, &Gateway.ingest/2)
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:ingest, message}, state) do
    {:noreply, route(message, state)}
  end

  @impl true
  def handle_info({:flush, key, token}, state) do
    {:noreply, flush_if_current(key, token, state)}
  end

  # A flush with no current token — a timer that fired after its entry was
  # superseded (Process.cancel_timer can't recall an already-delivered message),
  # or a bare legacy {:flush, key} — is stale; ignore it so it can't dispatch a
  # since-extended album early and split a later part into its own turn.
  def handle_info({:flush, _key}, state) do
    {:noreply, state}
  end

  # --- routing ---

  defp route(message, %{debounce_ms: ms} = state) when ms <= 0 do
    deliver_single(message, state)
    state
  end

  defp route(message, state) do
    case state.channel.album_classify(message) do
      {:coalesce, key} -> buffer(message, key, state)
      {:flush, key} -> flush_then_dispatch(message, key, state)
      :passthrough -> passthrough(message, state)
    end
  end

  defp passthrough(message, state) do
    deliver_single(message, state)
    state
  end

  defp flush_then_dispatch(message, key, state) do
    state = flush_now(key, state)
    deliver_single(message, state)
    state
  end

  defp buffer(message, key, state) do
    case Map.get(state.buffers, key) do
      nil -> start_new(key, message, state)
      entry -> extend(key, entry, message, state)
    end
  end

  defp start_new(key, message, %{buffers: buffers, max_keys: max_keys} = state)
       when map_size(buffers) >= max_keys do
    Logger.warning(
      "#{inspect(state.channel)} album buffer at max_keys (#{max_keys}); " <>
        "dispatching #{inspect(key)} uncoalesced"
    )

    deliver_single(message, state)
    state
  end

  defp start_new(key, message, state) do
    {timer, token} = arm(key, state.debounce_ms)
    put_in(state, [:buffers, key], %{messages: [message], timer: timer, token: token})
  end

  defp extend(key, %{messages: messages, timer: timer}, message, state) do
    if timer, do: Process.cancel_timer(timer)
    messages = messages ++ [message]

    if length(messages) >= state.max_parts do
      deliver_album(messages, state)
      %{state | buffers: Map.delete(state.buffers, key)}
    else
      {new_timer, token} = arm(key, state.debounce_ms)
      put_in(state, [:buffers, key], %{messages: messages, timer: new_timer, token: token})
    end
  end

  # Arm a debounce timer carrying a unique token so a stale flush (from a timer
  # that fired before extend/4 could cancel it) is recognizable and ignored.
  defp arm(key, debounce_ms) do
    token = make_ref()
    timer = Process.send_after(self(), {:flush, key, token}, debounce_ms)
    {timer, token}
  end

  # Timer-driven flush: only fire if the token still matches the entry's current
  # timer (a superseded timer's token won't match → ignored).
  defp flush_if_current(key, token, state) do
    case Map.get(state.buffers, key) do
      %{token: ^token} -> flush_now(key, state)
      _stale_or_absent -> state
    end
  end

  # Unconditional flush of whatever is buffered under `key` (used by the timer
  # path via flush_if_current, and directly when a non-image message flushes a
  # pending album before dispatching).
  defp flush_now(key, state) do
    case Map.pop(state.buffers, key) do
      {nil, _buffers} ->
        state

      {%{messages: messages, timer: timer}, buffers} ->
        if timer, do: Process.cancel_timer(timer)
        deliver_album(messages, state)
        %{state | buffers: buffers}
    end
  end

  # --- merge + dispatch ---

  # Merge album parts into one message: keep every non-empty caption (WhatsApp
  # attaches a caption per message; Telegram carries one group caption — both
  # collapse to the right thing here), join them in arrival order, and
  # concatenate all attachments. Other fields come from the first part.
  defp merge_album([first | _] = messages) do
    content =
      messages
      |> Enum.map(&Map.get(&1, :content))
      |> Enum.reject(&blank?/1)
      |> Enum.join("\n")

    %{first | content: content, attachments: Enum.flat_map(messages, & &1.attachments)}
  end

  defp deliver_album([single], state), do: deliver([single], [part_id(single)], state)

  defp deliver_album(messages, state),
    do: deliver([merge_album(messages)], Enum.map(messages, &part_id/1), state)

  defp deliver_single(message, state), do: deliver([message], [part_id(message)], state)

  defp deliver(messages, forget_ids, state) do
    opts = [channel: state.channel, agent: state.agent, agent_server: state.agent_server]

    case state.dispatch.(messages, opts) do
      :ok -> :ok
      {:error, reason} -> forget(forget_ids, reason, state)
    end
  end

  # Polling channels record no idempotency (`idempotency_key` nil) — nothing to
  # forget. Webhook channels forget every buffered part id so a re-delivery can
  # re-run (the ack is already committed, so the flush is the only chance).
  defp forget(_ids, reason, %{idempotency_key: nil} = state) do
    Logger.error("#{inspect(state.channel)} album-buffer dispatch failed: #{inspect(reason)}")
    :ok
  end

  defp forget(ids, reason, %{idempotency_key: key} = state) do
    Logger.error(
      "#{inspect(state.channel)} album-buffer dispatch failed: #{inspect(reason)}; " <>
        "forgetting #{length(ids)} message id(s) so a re-delivery can re-run"
    )

    Enum.each(ids, &Idempotency.forget(key, &1))
    :ok
  end

  # --- helpers ---

  defp ensure_classifiable!(channel) do
    if Code.ensure_loaded?(channel) and function_exported?(channel, :album_classify, 1) do
      :ok
    else
      raise ArgumentError,
            "#{inspect(channel)} must implement album_classify/1 to use Gateway.AlbumBuffer"
    end
  end

  defp part_id(message), do: Map.get(message, :id) || Map.get(message, "id")

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp configured_debounce_ms(opts) do
    with key when is_atom(key) and not is_nil(key) <- Keyword.get(opts, :config_key),
         {:ok, cfg} <- FermixCore.Config.channel(key) do
      Keyword.get(cfg, :album_debounce_ms, @default_debounce_ms)
    else
      _ -> @default_debounce_ms
    end
  end
end
