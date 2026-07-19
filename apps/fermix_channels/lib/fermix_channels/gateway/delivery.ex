defmodule FermixChannels.Gateway.Delivery do
  @moduledoc """
  Renders and sends an outbound reply to a channel.

  `build_deliver/1` turns a `ReplyContext` into the delivery closure the rest of
  the gateway uses — for the final turn reply, mid-turn channel-tool sends
  (`send_attachment`), and system (slash-command) replies. The closure delegates
  to the adapter's `build_text_reply`/`build_media_reply` (which own text
  splitting, media byte caps, and platform retry hints) and wraps each send in
  `[:fermix, :channel, :reply]` telemetry.

  This is the single channel-delivery path: core turn execution returns a
  response and never calls a reply closure itself; the gateway delivers.
  """

  require Logger

  alias FermixChannels.Gateway.Message
  alias FermixChannels.Gateway.ReplyContext
  alias FermixCore.Reply
  alias FermixCore.Telemetry

  @doc "Build the delivery closure for a destination."
  @spec build_deliver(ReplyContext.t()) :: Reply.reply_fn()
  def build_deliver(%ReplyContext{channel: channel, message: message}) do
    text_reply = channel.build_text_reply(message)
    media_reply = channel.build_media_reply(message)

    fn
      {:text, text} when is_binary(text) ->
        observe_reply(fn -> text_reply.(text) end, :text, nil, message)

      {:media, %{kind: kind} = media_part} ->
        observe_reply(fn -> media_reply.(media_part) end, :media, kind, message)

      {:react, emoji} when is_binary(emoji) ->
        deliver_reaction(channel, message, emoji)

      {:approval_prompt, text, token} when is_binary(text) and is_binary(token) ->
        deliver_approval(channel, message, text_reply, text, token)

      other ->
        {:error, {:invalid_reply_part, other}}
    end
  end

  # One-tap approval is a per-channel capability, not a runtime degrade: a channel
  # that renders an approve affordance implements `send_approval/3`; every other
  # channel delivers the same prompt text (which carries the tap-to-copy
  # `/confirm <token>` command) through the text closure already built above.
  defp deliver_approval(channel, message, text_reply, text, token) do
    if function_exported?(channel, :send_approval, 3) do
      observe_reply(fn -> channel.send_approval(message, text, token) end, :text, nil, message)
    else
      observe_reply(fn -> text_reply.(text) end, :text, nil, message)
    end
  end

  # `message` is closed over by build_deliver, so the platform reaction target is
  # available with no new plumbing. Defense-in-depth gate: a non-reaction channel
  # is never advertised the `react` tool, but if a `{:react,_}` ever reaches one,
  # fail loud instead of dispatching to an undefined callback.
  defp deliver_reaction(channel, message, emoji) do
    if function_exported?(channel, :react, 2) do
      observe_reply(fn -> channel.react(message, emoji) end, :reaction, nil, message)
    else
      {:error, :reaction_unsupported}
    end
  end

  @doc """
  Build the delivery closure, honoring an explicit `reply_fn` override (e.g. the
  CLI sync path captures the reply instead of sending it through the adapter).
  """
  @spec build_deliver(ReplyContext.t(), Reply.reply_fn() | nil) :: Reply.reply_fn()
  def build_deliver(%ReplyContext{message: message}, override) when is_function(override, 1) do
    fn part -> observe_reply(fn -> override.(part) end, :override, nil, message) end
  end

  def build_deliver(%ReplyContext{} = reply_context, nil), do: build_deliver(reply_context)

  @doc "One-shot delivery of a single outbound part (used for system replies)."
  @spec deliver(ReplyContext.t(), Reply.outbound()) :: :ok | {:error, term()}
  def deliver(%ReplyContext{} = reply_context, outbound) do
    build_deliver(reply_context).(outbound)
  end

  @spec observe_reply(
          (-> term()),
          :override | :text | :media | :reaction,
          Reply.media_kind() | nil,
          Message.t()
        ) :: :ok | {:error, term()}
  defp observe_reply(fun, reply_type, media_kind, message) when is_function(fun, 0) do
    {result, duration_us} = Telemetry.timed_us(fun)
    emit_channel_reply_telemetry(message, result, reply_type, media_kind, duration_us)
    observe_reply_result(result, reply_type, media_kind)
  end

  defp observe_reply_result(:ok, _reply_type, _media_kind), do: :ok

  defp observe_reply_result({:error, reason} = error, reply_type, media_kind) do
    Logger.error("Channel reply delivery failed: #{inspect(reason)}")

    if reply_type == :media do
      :telemetry.execute(
        [:fermix, :channel, :media_send_error],
        %{count: 1},
        %{kind: media_kind, reason: reason}
      )
    end

    error
  end

  defp observe_reply_result(_other, _reply_type, _media_kind), do: :ok

  defp emit_channel_reply_telemetry(message, result, reply_type, media_kind, duration_us) do
    metadata =
      %{
        channel: message.channel,
        reply_type: reply_type,
        status: result_status(result)
      }
      |> maybe_put_metadata(:media_kind, media_kind)

    :telemetry.execute(
      [:fermix, :channel, :reply],
      %{duration_us: duration_us},
      metadata
    )
  end

  defp result_status(:ok), do: :ok
  defp result_status({:ok, _value}), do: :ok
  defp result_status({:error, _reason}), do: :error
  defp result_status(_other), do: :ok

  defp maybe_put_metadata(metadata, _key, nil), do: metadata
  defp maybe_put_metadata(metadata, key, value), do: Map.put(metadata, key, value)
end
