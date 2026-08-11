defmodule FermixCore.Reply do
  @moduledoc """
  Outbound reply contract: the text/media/reaction reply shape that core
  produces (agent turns, the `send_attachment`, `react`, and media-generation
  tools) and the channel layer delivers.
  """

  @type media_kind :: :image | :document | :audio | :video | :voice

  @type media_part :: %{
          required(:kind) => media_kind(),
          required(:path) => String.t(),
          optional(:caption) => String.t(),
          optional(:filename) => String.t(),
          optional(:mime_type) => String.t()
        }

  @typedoc """
  An abstract owner-approval prompt (SANDBOX_ACCESS_APPROVAL_FLOW): the prompt
  text plus the confirmation `token`. A channel that renders one-tap approval
  attaches it (Telegram: an inline "Approve" button whose callback carries the
  token); every other channel delivers the text alone — the text already carries
  the tap-to-copy `/confirm <token>` command, so no button is a full fallback,
  not a degraded state.
  """
  @type approval_prompt :: {:approval_prompt, text :: String.t(), token :: String.t()}

  @type outbound ::
          {:text, String.t()} | {:media, media_part()} | {:react, String.t()} | approval_prompt()
  @type reply_fn :: (outbound() -> :ok | {:error, term()})

  @doc """
  Human-readable rendering of a `{:error, reason}` returned by a channel's
  media/text delivery. Shared by `send_attachment` and `Tools.Media.Output`
  so both surface the same wording for the channel egress error tuples
  (byte/text caps, rate limits) and by every reason in the closed delivery
  vocabulary `FermixCore.Delivery.Error.t/0` (M30 §11.3).
  """
  @spec format_delivery_error(term()) :: String.t()
  def format_delivery_error({:byte_cap_exceeded, actual, allowed}) do
    "attachment is #{format_bytes(actual)}; limit is #{format_bytes(allowed)}"
  end

  def format_delivery_error({:rate_limited, retry_after_ms}) do
    "channel is rate limited; retry after #{format_duration(retry_after_ms)}"
  end

  def format_delivery_error({:http_status, status}) do
    "channel rejected the message with HTTP #{status}"
  end

  def format_delivery_error({:permanent, :authentication}) do
    "channel credentials were rejected; re-check that channel's token in your Fermix config"
  end

  def format_delivery_error({:permanent, :authorization}) do
    "channel refused the destination; the bot needs access to that conversation"
  end

  def format_delivery_error({:permanent, :invalid_destination}) do
    "destination no longer exists on that channel; re-check the configured chat or channel id"
  end

  def format_delivery_error({:permanent, :malformed_request}) do
    "channel rejected the request as malformed"
  end

  def format_delivery_error({:permanent, :remote_rejected}) do
    "channel rejected the message; the platform's own words are in the daemon log"
  end

  def format_delivery_error({:permanent, :adapter_unavailable}) do
    "channel client is unavailable; check that this channel is configured and installed"
  end

  def format_delivery_error({:transport, :pool_unavailable}) do
    "no outbound connection was available before the checkout budget ran out"
  end

  def format_delivery_error({:transport, :closed}) do
    "connection closed before the channel answered"
  end

  def format_delivery_error({:transport, :connection_refused}) do
    "channel host refused the connection"
  end

  def format_delivery_error({:transport, :connection_reset}) do
    "channel host reset the connection mid-request"
  end

  def format_delivery_error({:transport, :network_unreachable}) do
    "channel host was unreachable from this network"
  end

  def format_delivery_error({:transport, :timeout}) do
    "channel did not answer before the request timed out"
  end

  def format_delivery_error(:delivery_timeout) do
    "delivery timed out and was cancelled by its watchdog"
  end

  def format_delivery_error({:delivery_crashed, :worker_crash}) do
    "delivery crashed before the channel answered; see the daemon log"
  end

  def format_delivery_error({:unsupported_delivery_platform, platform}) do
    "no channel is configured for the #{format_value(platform)} platform"
  end

  def format_delivery_error({:invalid_delivery_adapter, adapter}) do
    "channel adapter #{format_value(adapter)} is missing or cannot send messages"
  end

  def format_delivery_error({:unexpected_delivery_result, :invalid_contract}) do
    "channel returned an unrecognized result; the raw shape is in the daemon log"
  end

  def format_delivery_error(reason), do: inspect(reason)

  defp format_value(value) when is_binary(value), do: value
  defp format_value(value), do: inspect(value)

  defp format_bytes(bytes) when is_integer(bytes) and bytes >= 1_048_576 do
    "#{Float.round(bytes / 1_048_576, 1)} MiB"
  end

  defp format_bytes(bytes) when is_integer(bytes) and bytes >= 1_024 do
    "#{Float.round(bytes / 1_024, 1)} KiB"
  end

  defp format_bytes(bytes) when is_integer(bytes), do: "#{bytes} bytes"
  defp format_bytes(value), do: inspect(value)

  defp format_duration(ms) when is_integer(ms) and ms >= 1_000 and rem(ms, 1_000) == 0 do
    "#{div(ms, 1_000)}s"
  end

  defp format_duration(ms) when is_integer(ms) and ms >= 0, do: "#{ms}ms"
  defp format_duration(value), do: inspect(value)
end
