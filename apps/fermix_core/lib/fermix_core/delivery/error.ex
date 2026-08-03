defmodule FermixCore.Delivery.Error do
  @moduledoc """
  The closed delivery-error vocabulary for proactive channel sends
  (`docs/design/MILESTONE_30_TEMPORAL_EVENTS_AND_PROACTIVE_REMINDERS.md` §11.3
  and §11.4).

  `normalize/1` takes the result of an *entire* `Delivery.ChannelSend.with_timeout/2`
  call — adapter result, watchdog expiry, or watchdog crash alike — and returns
  `:ok` or `{:error, reason}` where `reason` is one of the nine shapes in `t/0`
  and nothing else. Anything outside the vocabulary is an implementation
  contract violation: it is logged with a bounded inspect of the raw shape and
  reduced to the terminal `{:unexpected_delivery_result, :invalid_contract}`.

  Division of labor (§11.3): the channel adapters own platform knowledge —
  HTTP status and rate-limit forms, Slack's `ok: false` rejection codes, and
  Signal's CLI exit mapping. Raw transport errors keep passing through the
  adapters untouched and are mapped here, in one place, so no adapter has to
  reimplement the `%Req.TransportError{}` table. `:pool_unavailable` reuses
  `HttpClient.connection_unavailable?/1` — an inherited substring predicate on
  the Finch pool-checkout exception, and the one deliberate exception to the
  no-string-matching rule.

  Raw crash reasons, response bodies, CLI output, and exception messages never
  become classifier input or a persisted reminder error; they reach bounded
  local diagnostics only.

  `retryable?/1` is the §11.4 positive allowlist: only structured transient
  failures are retried. A `{:delivery_crashed, _}` is terminal on purpose — a
  crash inside one send is a bug, not weather.
  """

  require Logger

  alias FermixCore.Net.HttpClient

  # Bounded inspect ceiling for local diagnostics — the same 500-byte bound the
  # persisted `last_error` column uses (§7.1).
  @raw_shape_max 500

  @transport_kinds [
    :pool_unavailable,
    :closed,
    :connection_refused,
    :connection_reset,
    :network_unreachable,
    :timeout
  ]

  @permanent_kinds [
    :authentication,
    :authorization,
    :invalid_destination,
    :malformed_request,
    :remote_rejected,
    :adapter_unavailable
  ]

  # Every `%Req.TransportError{}` reason with a place in the closed vocabulary.
  # An unlisted reason is a contract violation, not a guessed sub-reason.
  # `:nxdomain` counts as network-unreachable: failed DNS resolution is the
  # commonest symptom of an offline/captive-portal host, exactly the transient
  # window §11.1's durable retry exists for.
  @transport_reasons %{
    closed: :closed,
    econnrefused: :connection_refused,
    econnreset: :connection_reset,
    ehostunreach: :network_unreachable,
    enetunreach: :network_unreachable,
    nxdomain: :network_unreachable,
    timeout: :timeout
  }

  # HTTP statuses below 500 that are still worth another claim cycle (§11.4).
  @retryable_statuses [408, 425, 429]

  @type transport_kind ::
          :pool_unavailable
          | :closed
          | :connection_refused
          | :connection_reset
          | :network_unreachable
          | :timeout

  @type permanent_kind ::
          :authentication
          | :authorization
          | :invalid_destination
          | :malformed_request
          | :remote_rejected
          | :adapter_unavailable

  @type t ::
          :delivery_timeout
          | {:rate_limited, non_neg_integer()}
          | {:http_status, 100..599}
          | {:transport, transport_kind()}
          | {:permanent, permanent_kind()}
          | {:unsupported_delivery_platform, term()}
          | {:invalid_delivery_adapter, term()}
          | {:delivery_crashed, :worker_crash}
          | {:unexpected_delivery_result, :invalid_contract}

  @doc """
  Reduces a whole `ChannelSend.with_timeout/2` result to `:ok` or a single
  reason from `t/0`.
  """
  @spec normalize(term()) :: :ok | {:error, t()}
  def normalize(:ok), do: :ok

  def normalize({:error, {:rate_limited, retry_after_ms}})
      when is_integer(retry_after_ms) and retry_after_ms >= 0 do
    {:error, {:rate_limited, retry_after_ms}}
  end

  def normalize({:error, {:http_status, status}})
      when is_integer(status) and status in 100..599 do
    {:error, {:http_status, status}}
  end

  def normalize({:error, {:permanent, kind}}) when kind in @permanent_kinds do
    {:error, {:permanent, kind}}
  end

  def normalize({:error, {:transport, kind}}) when kind in @transport_kinds do
    {:error, {:transport, kind}}
  end

  def normalize({:error, {:unsupported_delivery_platform, platform}}) do
    {:error, {:unsupported_delivery_platform, platform}}
  end

  def normalize({:error, {:invalid_delivery_adapter, adapter}}) do
    {:error, {:invalid_delivery_adapter, adapter}}
  end

  def normalize({:error, :delivery_timeout}), do: {:error, :delivery_timeout}

  # An adapter whose own runner contract is open (Signal's CLI) closes it at its
  # boundary and returns this reason already classified and already logged.
  # Re-reporting it as "outside the closed vocabulary" would make the trace say
  # the opposite of what happened.
  def normalize({:error, {:unexpected_delivery_result, :invalid_contract}}) do
    {:error, {:unexpected_delivery_result, :invalid_contract}}
  end

  # A watchdog child can die of anything: an exception with a token in its
  # message, an exit tuple carrying a stacktrace, a plain `:killed`. None of
  # that may reach the classifier or SQLite, so every crash collapses to one
  # fixed reason and the raw payload is dropped here.
  def normalize({:error, {:delivery_crashed, _reason}}) do
    {:error, {:delivery_crashed, :worker_crash}}
  end

  def normalize({:error, %Req.TransportError{reason: reason}} = raw) do
    case Map.fetch(@transport_reasons, reason) do
      {:ok, kind} -> {:error, {:transport, kind}}
      :error -> invalid_contract(raw)
    end
  end

  def normalize({:error, reason} = raw) do
    if HttpClient.connection_unavailable?(reason) do
      {:error, {:transport, :pool_unavailable}}
    else
      invalid_contract(raw)
    end
  end

  def normalize(raw), do: invalid_contract(raw)

  @doc """
  True only for the §11.4 allowlist of structured transient failures.

  Authentication failures, invalid destinations, unsupported adapters,
  malformed requests, other 4xx responses, worker crashes, and contract
  violations are terminal on the first attempt.
  """
  @spec retryable?(t()) :: boolean()
  def retryable?({:transport, kind}) when kind in @transport_kinds, do: true
  def retryable?(:delivery_timeout), do: true

  def retryable?({:rate_limited, retry_after_ms})
      when is_integer(retry_after_ms) and retry_after_ms >= 0,
      do: true

  def retryable?({:http_status, status}) when status in @retryable_statuses, do: true
  def retryable?({:http_status, status}) when is_integer(status) and status >= 500, do: true
  def retryable?({:http_status, status}) when is_integer(status), do: false
  def retryable?({:permanent, kind}) when kind in @permanent_kinds, do: false
  def retryable?({:unsupported_delivery_platform, _platform}), do: false
  def retryable?({:invalid_delivery_adapter, _adapter}), do: false
  def retryable?({:delivery_crashed, :worker_crash}), do: false
  def retryable?({:unexpected_delivery_result, :invalid_contract}), do: false

  # Reachable only if a caller invents a reason outside `normalize/1`'s output.
  # Say so loudly, then treat it the way §11.3 treats every unclassified error.
  def retryable?(reason) do
    Logger.error(
      "Channel delivery reason outside the closed vocabulary, treating as terminal: " <>
        bounded(reason)
    )

    false
  end

  @doc """
  The server-provided retry delay carried by a rate-limit reason, if any.
  """
  @spec retry_after_hint(t()) :: {:ok, non_neg_integer()} | :error
  def retry_after_hint({:rate_limited, retry_after_ms})
      when is_integer(retry_after_ms) and retry_after_ms >= 0,
      do: {:ok, retry_after_ms}

  def retry_after_hint(_reason), do: :error

  defp invalid_contract(raw) do
    Logger.error(
      "Channel delivery returned a result outside the closed error vocabulary: " <> bounded(raw)
    )

    {:error, {:unexpected_delivery_result, :invalid_contract}}
  end

  defp bounded(raw), do: raw |> inspect() |> String.slice(0, @raw_shape_max)
end
