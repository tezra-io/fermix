defmodule FermixCore.Delivery.ChannelSend do
  @moduledoc """
  The generic channel-send primitive shared by every outbound delivery path.

  This is the single place that turns a resolved `{platform, destination}` pair
  into an adapter `send_message/3` call: it resolves the adapter (from an
  injected `:adapter` or the configured `[:fermix_core, :jobs, :delivery_channels]`
  map), runs the bounded transient-retry loop (only the connection-unavailable
  pool-checkout error is retried — every other error fails fast), rescues the
  RuntimeError that some send paths raise instead of returning, and offers a
  spawn-monitor `with_timeout/2` watchdog so a slow send can never wedge the
  caller.

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

  @default_delivery_attempts 3
  @default_delivery_backoff_ms 1_000

  @type send_result :: :ok | {:error, term()}

  @doc """
  Sends `text` to `destination` on `platform` through the resolved channel
  adapter, retrying only the transient connection-unavailable error.

  `send_opts` is passed verbatim to `adapter.send_message/3`. `opts` may carry:

    * `:adapter` — an explicit adapter module (bypasses channel resolution);
    * `:channels` — the channels map (defaults to the configured jobs map);
    * `:delivery_max_attempts` — retry ceiling (default 3; pass `1` for a single
      attempt owned by an outer retry loop);
    * `:delivery_backoff_ms` — linear backoff base between transient retries.
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
  Runs `fun` in a monitored process, killing it after `timeout_ms`.

  Returns `fun`'s result, `{:error, :delivery_timeout}` on expiry, or
  `{:error, {:delivery_crashed, reason}}` if it crashes. A `timeout_ms` of `0`
  or below runs `fun` inline (no watchdog).
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
    case Keyword.get(opts, :adapter) do
      adapter when is_atom(adapter) and not is_nil(adapter) -> ensure_adapter(adapter)
      _nil -> configured_adapter(platform, opts)
    end
  end

  # --- Send loop ----------------------------------------------------------

  defp run_send(adapter, destination, text, send_opts, opts) do
    max_attempts = Keyword.get(opts, :delivery_max_attempts, @default_delivery_attempts)
    backoff_ms = Keyword.get(opts, :delivery_backoff_ms, @default_delivery_backoff_ms)

    # Retry only the transient connection-unavailable error (the request never
    # obtained a connection, so a retry cannot duplicate a sent message). Every
    # other error fails fast. Each attempt waits out the shared pool-checkout
    # budget in `HttpClient`, so a small ceiling is a wide-enough floor.
    Enum.reduce_while(1..max_attempts, {:error, :not_attempted}, fn attempt, _acc ->
      adapter
      |> send_with_rescue(destination, text, send_opts)
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
  defp send_with_rescue(adapter, destination, text, opts) do
    adapter.send_message(destination, text, opts)
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

  defp monitored_call(timeout_ms, fun) do
    parent = self()
    result_ref = make_ref()

    {pid, monitor_ref} =
      spawn_monitor(fn -> Kernel.send(parent, {result_ref, fun.()}) end)

    receive do
      {^result_ref, result} ->
        Process.demonitor(monitor_ref, [:flush])
        result

      {:DOWN, ^monitor_ref, :process, _pid, reason} ->
        {:error, {:delivery_crashed, reason}}
    after
      timeout_ms ->
        Process.exit(pid, :kill)
        flush_call_messages(monitor_ref, result_ref)
        {:error, :delivery_timeout}
    end
  end

  defp flush_call_messages(monitor_ref, result_ref) do
    receive do
      {:DOWN, ^monitor_ref, :process, _pid, _reason} ->
        flush_call_messages(monitor_ref, result_ref)

      {^result_ref, _result} ->
        flush_call_messages(monitor_ref, result_ref)
    after
      0 ->
        :ok
    end
  end

  # --- Adapter resolution -------------------------------------------------

  defp configured_adapter(platform, opts) do
    channels = Keyword.get(opts, :channels, default_channels())

    channels
    |> fetch_channel(platform)
    |> case do
      nil -> {:error, {:unsupported_delivery_platform, platform}}
      adapter -> ensure_adapter(adapter)
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

  defp ensure_adapter(adapter) when is_atom(adapter) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :send_message, 3) do
      {:ok, adapter}
    else
      {:error, {:invalid_delivery_adapter, adapter}}
    end
  end

  defp ensure_adapter(adapter), do: {:error, {:invalid_delivery_adapter, adapter}}

  defp default_channels do
    :fermix_core
    |> Application.get_env(:jobs, [])
    |> Keyword.get(:delivery_channels, %{})
  end
end
