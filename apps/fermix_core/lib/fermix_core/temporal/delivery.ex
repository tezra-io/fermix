defmodule FermixCore.Temporal.Delivery do
  @moduledoc """
  One bounded channel attempt for a claimed reminder, plus the retry arithmetic
  the outbox persists (M30 §11.2, §11.4).

  `attempt/3` renders nothing and decides nothing about state: it derives the
  platform-specific thread option from the row's snapshotted
  `delivery_thread_scope`, makes exactly ONE `ChannelSend.send/5` call
  (`delivery_max_attempts: 1`, so no second durable backoff loop can stack) under
  the validity-clamped watchdog, and passes the *whole* watchdog result through
  `FermixCore.Delivery.Error.normalize/1`. The adapter module and its credentials
  are resolved live by `ChannelSend` at send time; nothing about the live channel
  account is ever snapshotted on a reminder row (§11.1).

  Thread normalization is the closed §11.1 table — Telegram's decimal
  `message_thread_id`, Slack's `thread_ts`, and nothing for the platforms whose
  destination already *is* the thread. A scope that contradicts its platform is a
  data-integrity break, so it fails terminally and loudly rather than being
  dropped and delivered to the wrong place.
  """

  require Logger

  alias FermixCore.Delivery.ChannelSend
  alias FermixCore.Delivery.Error

  # §11.4: four bounded delays behind five durable claim cycles, each measured
  # from the previous failed attempt. Indexed by the attempt the claim consumed.
  @retry_delays_ms %{1 => 60_000, 2 => 300_000, 3 => 900_000, 4 => 3_600_000}
  @last_retry_delay_ms 3_600_000

  # Persisted `last_error` ceiling (§7.1). The reason is already a closed atom
  # shape; the bound is belt and braces against a term-carrying variant.
  @error_text_max 500

  @doc """
  Makes one bounded send attempt for `row` with the already-rendered `text`.

  `timeout_ms` is the validity-clamped watchdog computed by the caller;
  `opts` are passed to `ChannelSend` (the `:adapter`/`:channels` seams).
  """
  @spec attempt(map(), String.t(), non_neg_integer(), keyword()) :: :ok | {:error, Error.t()}
  def attempt(row, text, timeout_ms, opts \\ [])
      when is_map(row) and is_binary(text) and is_integer(timeout_ms) and timeout_ms > 0 and
             is_list(opts) do
    case thread_opts(row) do
      {:ok, send_opts} -> send_once(row, text, send_opts, timeout_ms, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  defp send_once(row, text, send_opts, timeout_ms, opts) do
    timeout_ms
    |> ChannelSend.with_timeout(fn ->
      ChannelSend.send(
        row.delivery_platform,
        row.delivery_destination,
        text,
        send_opts,
        Keyword.put(opts, :delivery_max_attempts, 1)
      )
    end)
    |> Error.normalize()
  end

  @doc """
  The §11.1 send option for a row's snapshotted thread scope.

  `root` is no option at all. Telegram stores a decimal string and sends an
  integer; Slack stores and sends its `thread_ts` verbatim; every other
  reminder-capable platform must be `root`.
  """
  @spec thread_opts(map()) :: {:ok, keyword()} | {:error, Error.t()}
  def thread_opts(%{delivery_thread_scope: "root"}), do: {:ok, []}

  def thread_opts(%{delivery_platform: "telegram", delivery_thread_scope: scope})
      when is_binary(scope) do
    case Integer.parse(scope) do
      {thread_id, ""} when thread_id > 0 -> {:ok, [message_thread_id: thread_id]}
      _invalid -> malformed("telegram", "message_thread_id is not a positive decimal")
    end
  end

  def thread_opts(%{delivery_platform: "slack", delivery_thread_scope: scope})
      when is_binary(scope) and scope != "" do
    {:ok, [thread_ts: scope]}
  end

  def thread_opts(%{delivery_platform: platform}) when is_binary(platform) do
    malformed(platform, "platform has no thread option but the row is not root")
  end

  def thread_opts(_row), do: malformed("unknown", "row carries no delivery platform")

  defp malformed(platform, detail) do
    Logger.error("Reminder delivery target is malformed for #{platform}: #{detail}")
    {:error, {:permanent, :malformed_request}}
  end

  @doc """
  The delay before the next durable claim, given the attempt this claim consumed
  and any server-provided rate-limit hint (§11.4: the larger of the two wins).
  """
  @spec retry_delay_ms(pos_integer(), Error.t()) :: pos_integer()
  def retry_delay_ms(attempt_count, reason)
      when is_integer(attempt_count) and attempt_count > 0 do
    planned = Map.get(@retry_delays_ms, attempt_count, @last_retry_delay_ms)

    case Error.retry_after_hint(reason) do
      {:ok, hint} -> max(planned, hint)
      :error -> planned
    end
  end

  @doc """
  A compact, bounded rendering of a normalized reason for the persisted
  `last_error` column. Raw bodies, CLI output, and crash payloads never reach
  here — `Delivery.Error` already collapsed them.
  """
  @spec error_text(Error.t()) :: String.t()
  def error_text(:delivery_timeout), do: "delivery_timeout"
  def error_text({:rate_limited, ms}), do: "rate_limited:#{ms}"
  def error_text({:http_status, status}), do: "http_status:#{status}"
  def error_text({:transport, kind}), do: "transport:#{kind}"
  def error_text({:permanent, kind}), do: "permanent:#{kind}"
  def error_text({:delivery_crashed, kind}), do: "delivery_crashed:#{kind}"
  def error_text({:unexpected_delivery_result, kind}), do: "unexpected_delivery_result:#{kind}"

  def error_text({tag, value})
      when tag in [:unsupported_delivery_platform, :invalid_delivery_adapter] do
    bounded("#{tag}:#{inspect(value)}")
  end

  def error_text(reason), do: bounded(inspect(reason))

  defp bounded(text) when byte_size(text) <= @error_text_max, do: text

  # A UTF-8 character is at most four bytes, so dropping at most three trailing
  # bytes always lands the cut on a character boundary.
  defp bounded(text) do
    Enum.reduce_while(0..3, "", fn drop, _acc ->
      chunk = binary_part(text, 0, @error_text_max - drop)
      if String.valid?(chunk), do: {:halt, chunk}, else: {:cont, ""}
    end)
  end
end
