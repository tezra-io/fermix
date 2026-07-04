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

  @type outbound :: {:text, String.t()} | {:media, media_part()} | {:react, String.t()}
  @type reply_fn :: (outbound() -> :ok | {:error, term()})

  @doc """
  Human-readable rendering of a `{:error, reason}` returned by a channel's
  media/text delivery. Shared by `send_attachment` and `Tools.Media.Output`
  so both surface the same wording for the channel egress error tuples
  (byte/text caps, rate limits).
  """
  @spec format_delivery_error(term()) :: String.t()
  def format_delivery_error({:byte_cap_exceeded, actual, allowed}) do
    "attachment is #{format_bytes(actual)}; limit is #{format_bytes(allowed)}"
  end

  def format_delivery_error({:rate_limited, retry_after_ms}) do
    "channel is rate limited; retry after #{format_duration(retry_after_ms)}"
  end

  def format_delivery_error({:text_cap_exceeded, actual, allowed}) do
    "reply text is #{actual} characters; limit is #{allowed} characters"
  end

  def format_delivery_error(reason), do: inspect(reason)

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
