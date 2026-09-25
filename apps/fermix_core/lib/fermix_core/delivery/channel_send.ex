defmodule FermixCore.Delivery.ChannelSend do
  @moduledoc """
  The generic channel-send primitive shared by every outbound delivery path.

  This is the single place that turns a resolved `{platform, destination}` pair
  into an adapter `send_message/3` (or `send_media/3`) call: it resolves the adapter (from an
  injected `:adapter` or the configured `[:fermix_core, :jobs, :delivery_channels]`
  map), runs the bounded transient-retry loop (only the connection-unavailable
  pool-checkout error is retried — every other error fails fast), rescues the
  RuntimeError that some send paths raise instead of returning, and offers a
  `with_timeout/2` watchdog so a slow send can never wedge the caller. The
  watched send runs in a process linked to its caller, so it does not outlive
  the caller either (except in the few instructions between the watchdog's
  unlink and its kill).

  `Jobs.Delivery` and `Harness.Delivery` both consume this module so the retry,
  rescue, and adapter-resolution behaviour can never drift between the scheduler
  and the coding-harness rails. Job-specific delivery-mode/target logic stays in
  the callers; this module only knows platforms, adapters, and one send.

  The channels map stays keyed on `[:fermix_core, :jobs, :delivery_channels]` —
  one source of truth; harness callers pass it through rather than inventing a
  second channels config.
  """

  require Logger

  alias FermixCore.Net.HttpClient
  alias FermixCore.Reply

  @default_delivery_attempts 3
  @default_delivery_backoff_ms 1_000
  # Ceiling for the logged text of a crash inside a watched send: enough for the
  # exception and its top frames, bounded like every other raw-payload log.
  @crash_log_max 2_000

  @type send_result :: :ok | {:error, term()}

  @doc """
  Sends `text` to `destination` on `platform` through the resolved channel
  adapter, retrying only the transient connection-unavailable error.

  `send_opts` is passed verbatim to `adapter.send_message/3`. `opts` may carry:

    * `:adapter` — an explicit adapter module (bypasses channel resolution);
    * `:channels` — the channels map (defaults to the configured jobs map);
    * `:delivery_max_attempts` — retry ceiling (default 3; pass `1` for a single
      attempt owned by an outer retry loop);
    * `:delivery_backoff_ms` — linear backoff base between transient retries;
    * `:dispatch` — `{:send_proposal, token}` routes through the adapter's
      optional `send_proposal/3` (skill-curation two-button proposals,
      MILESTONE_26_SKILL_CURATION §6.6) instead of `send_message/3`; adapter
      resolution then requires that callback. Default `:send_message`.
  """
  @spec send(String.t(), String.t(), String.t(), keyword(), keyword()) :: send_result()
  def send(platform, destination, text, send_opts \\ [], opts \\ [])
      when is_binary(platform) and is_binary(destination) and is_binary(text) and
             is_list(send_opts) and is_list(opts) do
    case resolve_adapter(platform, opts) do
      {:ok, adapter} -> run_send(adapter, destination, text, send_opts, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Sends `part` — a `FermixCore.Reply.media_part/0` — to `destination` on
  `platform` through the resolved channel adapter's `send_media/3`.

  Same adapter resolution, RuntimeError rescue, attempt ceiling and
  narrow transient retry as `send/5`: only the connection-unavailable
  pool-checkout error is retried, and it fires before any bytes reach the
  channel, so a retry cannot duplicate an upload. `send_opts` (thread/topic
  options, request options, the proactive key) is passed verbatim to the
  adapter, which owns its own byte caps and idempotency claim. An adapter
  without `send_media/3` is refused as `{:invalid_delivery_adapter, module}`
  rather than degraded to a text message (M46 §7.3).
  """
  @spec send_media(String.t(), String.t(), Reply.media_part(), keyword(), keyword()) ::
          send_result()
  def send_media(platform, destination, part, send_opts \\ [], opts \\ [])
      when is_binary(platform) and is_binary(destination) and is_map(part) and
             is_list(send_opts) and is_list(opts) do
    opts = Keyword.put(opts, :dispatch, :send_media)

    case resolve_adapter(platform, opts) do
      {:ok, adapter} -> run_send(adapter, destination, part, send_opts, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Runs `fun` in a linked, monitored process, killing it after `timeout_ms`.

  Returns `fun`'s result, `{:error, :delivery_timeout}` on expiry, or
  `{:error, {:delivery_crashed, reason}}` if it raises, throws or exits. A
  `timeout_ms` of `0` or below runs `fun` inline (no watchdog).

  The send never outlives its caller, except in the few instructions between
  the watchdog's unlink and its kill: if the caller dies mid-send, the link
  takes the send process down with it. A crash inside `fun` is reported (logged
  and returned), never propagated to the caller, and nothing of the send is left
  in the caller's mailbox, even for a caller that traps exits. A `fun` that
  links processes of its own exposes its caller to them: a linked helper's
  crash kills the send process, and through the link a caller that does not
  trap exits.
  """
  @spec with_timeout(integer(), (-> result)) ::
          result | {:error, :delivery_timeout | {:delivery_crashed, term()}}
        when result: term()
  def with_timeout(timeout_ms, fun)
      when is_integer(timeout_ms) and is_function(fun, 0) do
    if timeout_ms > 0 do
      monitored_call(timeout_ms, fun)
    else
      fun.()
    end
  end

  @doc """
  Resolves the channel adapter for `platform` from an explicit `:adapter` opt or
  the configured channels map. A missing/invalid adapter fails loud.
  """
  @spec resolve_adapter(String.t(), keyword()) :: {:ok, module()} | {:error, term()}
  def resolve_adapter(platform, opts \\ []) when is_binary(platform) and is_list(opts) do
    dispatch = Keyword.get(opts, :dispatch, :send_message)

    case Keyword.get(opts, :adapter) do
      adapter when is_atom(adapter) and not is_nil(adapter) -> ensure_adapter(adapter, dispatch)
      _nil -> configured_adapter(platform, opts, dispatch)
    end
  end

  # --- Send loop ----------------------------------------------------------

  defp run_send(adapter, destination, payload, send_opts, opts) do
    max_attempts = Keyword.get(opts, :delivery_max_attempts, @default_delivery_attempts)
    backoff_ms = Keyword.get(opts, :delivery_backoff_ms, @default_delivery_backoff_ms)
    dispatch = Keyword.get(opts, :dispatch, :send_message)

    # Retry only the transient connection-unavailable error (the request never
    # obtained a connection, so a retry cannot duplicate a sent message). Every
    # other error fails fast. Each attempt waits out the shared pool-checkout
    # budget in `HttpClient`, so a small ceiling is a wide-enough floor.
    Enum.reduce_while(1..max_attempts, {:error, :not_attempted}, fn attempt, _acc ->
      adapter
      |> send_with_rescue(destination, payload, send_opts, dispatch)
      |> decide_delivery_attempt(attempt, max_attempts, backoff_ms)
    end)
  end

  # Some send paths surface the Finch pool-checkout timeout as a raised
  # RuntimeError rather than an {:error, _} tuple (mirrors `HttpClient.run/2`).
  # Unwrapped, that raise crashes the caller and silently drops the message.
  # Convert it to the {:error, exception} the retry loop already classifies, so
  # a transient pool timeout is retried, not lost. Only RuntimeError is rescued
  # — a programming error (ArgumentError, …) still crashes loud. Log before
  # returning so a genuine non-transient RuntimeError leaves a trace instead of
  # being silently surfaced as a plain delivery failure.
  defp send_with_rescue(adapter, destination, text, opts, :send_message) do
    adapter.send_message(destination, text, opts)
  rescue
    exception in [RuntimeError] ->
      Logger.warning("Delivery send raised: #{Exception.message(exception)}")
      {:error, exception}
  end

  # Media dispatch: the same rescue and retry classification as text, with the
  # media part handed to the adapter verbatim. Adapter resolution already proved
  # `send_media/3` is exported.
  defp send_with_rescue(adapter, destination, part, opts, :send_media) do
    adapter.send_media(destination, part, opts)
  rescue
    exception in [RuntimeError] ->
      Logger.warning("Delivery send raised: #{Exception.message(exception)}")
      {:error, exception}
  end

  # Proposal dispatch: the adapter builds its own two-button affordance from
  # the bare token (the send_approval convention); resolution already proved
  # `send_proposal/3` is exported.
  defp send_with_rescue(adapter, destination, text, _opts, {:send_proposal, token})
       when is_binary(token) do
    adapter.send_proposal(%{chat_id: destination}, text, token)
  rescue
    exception in [RuntimeError] ->
      Logger.warning("Delivery send raised: #{Exception.message(exception)}")
      {:error, exception}
  end

  defp decide_delivery_attempt(:ok, _attempt, _max_attempts, _backoff_ms) do
    {:halt, :ok}
  end

  defp decide_delivery_attempt({:error, reason}, attempt, max_attempts, backoff_ms)
       when attempt < max_attempts do
    if HttpClient.connection_unavailable?(reason) do
      Process.sleep(backoff_ms * attempt)
      {:cont, {:error, reason}}
    else
      {:halt, {:error, reason}}
    end
  end

  defp decide_delivery_attempt({:error, reason}, _attempt, _max_attempts, _backoff_ms) do
    {:halt, {:error, reason}}
  end

  defp decide_delivery_attempt(other, _attempt, _max_attempts, _backoff_ms) do
    {:halt, {:error, {:unexpected_delivery_result, other}}}
  end

  # --- Timeout watchdog ---------------------------------------------------

  # The send process is spawned linked AND monitored in one atomic call, so it
  # never exists unlinked while its caller waits on it: a caller that dies
  # mid-send (a supervisor shutdown, a `:rest_for_one` restart) takes its send
  # with it. The link must carry only that direction, so `report/1` turns every
  # failure of `fun` into a value and the send process always exits `:normal`.
  defp monitored_call(timeout_ms, fun) do
    parent = self()
    result_ref = make_ref()

    {pid, monitor_ref} =
      Process.spawn(fn -> Kernel.send(parent, {result_ref, report(fun)}) end, [:link, :monitor])

    receive do
      {^result_ref, {:returned, result}} ->
        release(pid, monitor_ref)
        result

      {^result_ref, {:crashed, reason}} ->
        release(pid, monitor_ref)
        {:error, {:delivery_crashed, reason}}

      {:DOWN, ^monitor_ref, :process, _pid, reason} ->
        release(pid, monitor_ref)
        {:error, {:delivery_crashed, reason}}
    after
      timeout_ms -> kill_and_drain(pid, monitor_ref, result_ref)
    end
  end

  # Runs inside the send process. A raise, throw or exit in `fun` is reported
  # as a value rather than propagated, so the send exits `:normal` and its link
  # never takes the caller down. That exit leaves no crash report, so the crash
  # is logged here, bounded because a crash can carry a token or a response
  # body.
  defp report(fun) do
    {:returned, fun.()}
  catch
    kind, reason ->
      Logger.error("Channel send crashed: " <> bounded_crash(kind, reason, __STACKTRACE__))
      {:crashed, reason}
  end

  defp bounded_crash(kind, reason, stacktrace) do
    kind |> Exception.format(reason, stacktrace) |> String.slice(0, @crash_log_max)
  end

  # The send has answered or died, so drop its link and monitor. Once
  # `Process.unlink/1` returns the link has no further effect, but a caller that
  # traps exits may already hold the link's `{:EXIT, pid, _}` message, so it is
  # flushed too (the unlink idiom of the `erlang:unlink/1` docs).
  defp release(pid, monitor_ref) do
    Process.unlink(pid)
    flush_exit(pid)
    Process.demonitor(monitor_ref, [:flush])
    :ok
  end

  # The watchdog expiry. Unlink first so the kill cannot reach the caller, then
  # kill and wait for the send's `:DOWN`. The wait has no `after`: `:kill` cannot
  # be trapped, so the `:DOWN` always arrives (`Task.shutdown(task, :brutal_kill)`
  # waits the same way; `Jobs.Runner.kill_loop/2` also kills and then awaits the
  # `:DOWN`, but with a 100 ms bound). Signals from one process arrive in order,
  # so a result the send posted before it died is already queued ahead of that
  # `:DOWN`; the final zero-timeout receive drops it and nothing of the send is
  # left in the caller's mailbox. That late result is discarded: the caller
  # already gave up on it.
  #
  # Residual: a caller killed in the few instructions between the unlink and the
  # kill leaves its send unlinked, bounded only by the send's own client
  # timeouts. Closing it would need the caller to trap exits.
  defp kill_and_drain(pid, monitor_ref, result_ref) do
    Process.unlink(pid)
    flush_exit(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^monitor_ref, :process, ^pid, _reason} -> :ok
    end

    receive do
      {^result_ref, _discarded} -> :ok
    after
      0 -> :ok
    end

    {:error, :delivery_timeout}
  end

  defp flush_exit(pid) do
    receive do
      {:EXIT, ^pid, _reason} -> :ok
    after
      0 -> :ok
    end
  end

  # --- Adapter resolution -------------------------------------------------

  defp configured_adapter(platform, opts, dispatch) do
    channels = Keyword.get(opts, :channels, default_channels())

    channels
    |> fetch_channel(platform)
    |> case do
      nil -> {:error, {:unsupported_delivery_platform, platform}}
      adapter -> ensure_adapter(adapter, dispatch)
    end
  end

  defp fetch_channel(channels, platform) when is_map(channels) do
    Map.get(channels, platform) || Map.get(channels, platform_atom(platform))
  end

  defp fetch_channel(channels, platform) when is_list(channels) do
    Keyword.get(channels, platform_atom(platform)) || Keyword.get(channels, platform)
  end

  defp fetch_channel(_channels, _platform), do: nil

  defp platform_atom("telegram"), do: :telegram
  defp platform_atom("slack"), do: :slack
  defp platform_atom("discord"), do: :discord
  defp platform_atom("signal"), do: :signal
  defp platform_atom("whatsapp"), do: :whatsapp
  defp platform_atom("cli"), do: :cli
  defp platform_atom(_platform), do: nil

  defp ensure_adapter(adapter, dispatch) when is_atom(adapter) do
    if Code.ensure_loaded?(adapter) and
         function_exported?(adapter, dispatch_callback(dispatch), 3) do
      {:ok, adapter}
    else
      {:error, {:invalid_delivery_adapter, adapter}}
    end
  end

  defp ensure_adapter(adapter, _dispatch), do: {:error, {:invalid_delivery_adapter, adapter}}

  defp dispatch_callback(:send_message), do: :send_message
  defp dispatch_callback(:send_media), do: :send_media
  defp dispatch_callback({:send_proposal, _token}), do: :send_proposal

  defp default_channels do
    :fermix_core
    |> Application.get_env(:jobs, [])
    |> Keyword.get(:delivery_channels, %{})
  end
end
