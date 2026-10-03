defmodule FermixCore.Tools.SendToChannel do
  @moduledoc """
  Send a text to the owner's own inbox on a channel they name (M56 §4.7):
  "send it to my Telegram", from a typed turn or from a voice call's task.

  Three rules, each one place:

    * **The owner's inbox only.** The destination is
      `Delivery.OwnerInbox.on_platform/2`'s, never a chat id the model gives:
      the owner DM a remote platform's owner id derives (or the configured
      target on that platform), and the chat a transport only the owner
      reaches names for itself (the Mac's chat, the phones while their channel
      runs). A channel that is no delivery channel, or has no inbox of the
      owner's now, is refused with its reason, and nothing is sent to another
      channel in its place.
    * **One bounded send.** `Delivery.ChannelSend` makes one attempt under a
      watchdog, keyed by a proactive key derived from the turn and the text.
      A timeline channel (companion, mobile) writes one row per key, so a
      retry in the turn answers the row already written, and sends nothing
      more. A remote platform has no idempotency key of its own: there the
      send is one attempt, never repeated by the send path.
    * **Not for replying.** The current conversation gets the turn's reply;
      this is for the owner's other channels.

  Category `:delivery`, which no voice call excludes
  (`Agents.VoiceCall.excluded_categories/1`), so a task asked aloud gets it
  as a typed turn does. Offered only while some delivery channel has an inbox
  of the owner's, with exactly those channels as the `channel` enum.

  Telemetry through `Tools.Telemetry.exec/5` with the channel, the text's
  size and the outcome; the text, which may have been said aloud, reaches no
  field.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Delivery.ChannelSend
  alias FermixCore.Delivery.Error
  alias FermixCore.Delivery.OwnerInbox
  alias FermixCore.Reply
  alias FermixCore.Tools.Telemetry, as: ToolTelemetry

  @name "send_to_channel"
  @text_max_bytes 4_096
  @channel_max_bytes 64
  # The bound on one send, watchdog included: a turn (a call's task among
  # them) waits on it.
  @send_timeout_ms 30_000

  @impl true
  @spec name() :: String.t()
  def name, do: @name

  @doc "The bound on the text one send carries, in bytes."
  @spec text_max_bytes() :: pos_integer()
  def text_max_bytes, do: @text_max_bytes

  @impl true
  @spec description() :: String.t()
  def description do
    "Send a text to the owner's own inbox on a channel they name (\"send it to my " <>
      "Telegram\"). It reaches only the owner's inbox on that channel, never another chat; " <>
      "not for replying in this conversation."
  end

  @impl true
  @spec parameters() :: map()
  def parameters, do: parameters_with(channel_schema(nil))

  @doc """
  Per-turn schema: `channel` is an enum of exactly the delivery channels with
  an inbox of the owner's now (`OwnerInbox.reachable_platforms/1`).
  """
  @spec dynamic_parameters(map()) :: map()
  def dynamic_parameters(context) when is_map(context),
    do: parameters_with(channel_schema(OwnerInbox.reachable_platforms(inbox_opts(context))))

  @doc "Offered only while some delivery channel has an inbox of the owner's."
  @spec advertise?(map()) :: boolean()
  def advertise?(context) when is_map(context),
    do: OwnerInbox.reachable_platforms(inbox_opts(context)) != []

  @impl true
  def when_to_use do
    ~s|When the owner asks for something to be sent to one of their own channels | <>
      ~s|("send it to my Telegram", "put that in my chat"), from a typed message or a | <>
      ~s|voice call: send it, then say where it went. It is not for replying here, which | <>
      ~s|needs no tool.|
  end

  @impl true
  def examples do
    [
      %{
        args: %{"channel" => "telegram", "text" => "The lease renews on 1 November."},
        note: "send a result to the owner's Telegram"
      }
    ]
  end

  @impl true
  def failure_modes do
    [
      %{tag: "not_a_delivery_channel", description: "the channel named is not configured"},
      %{
        tag: "no_owner_inbox",
        description: "the channel has no inbox of the owner's (no owner id, or it cannot deliver)"
      },
      %{tag: "text_too_long", description: "the text is over 4 KB"},
      %{tag: "delivery_failed", description: "the channel refused the send; its reason is given"}
    ]
  end

  @impl true
  def requires_setup, do: nil

  @impl true
  def category, do: :delivery

  @impl true
  @spec execute(map(), Tool.context()) :: {:ok, Tool.tool_result()}
  def execute(args, context) when is_map(args) and is_map(context) do
    start = System.monotonic_time(:millisecond)
    {outcome, result} = run(args, context)
    duration = System.monotonic_time(:millisecond) - start

    ToolTelemetry.exec(@name, context, outcome == "sent", duration,
      metadata: telemetry_metadata(args, outcome),
      result: result
    )

    result
  end

  defp run(args, context) do
    opts = inbox_opts(context)

    with {:ok, platform} <- channel_arg(args),
         {:ok, text} <- text_arg(args),
         {:ok, session_id} <- session_id(context),
         {:ok, inbox} <- on_platform(platform, opts),
         :ok <- deliver(inbox, text, proactive_key(session_id, platform, text), opts) do
      {"sent", {:ok, Tool.success("Sent to the owner's inbox on #{platform}.")}}
    else
      {:error, reason} -> refusal(reason, Map.get(args, "channel"), opts)
    end
  end

  # --- arguments -----------------------------------------------------------

  defp channel_arg(%{"channel" => channel})
       when is_binary(channel) and channel != "" and byte_size(channel) <= @channel_max_bytes,
       do: {:ok, channel}

  defp channel_arg(_args), do: {:error, {:invalid_param, "channel"}}

  defp text_arg(%{"text" => text}) when is_binary(text) and byte_size(text) > @text_max_bytes,
    do: {:error, {:text_too_long, byte_size(text)}}

  defp text_arg(%{"text" => text}) when is_binary(text) and text != "", do: {:ok, text}
  defp text_arg(_args), do: {:error, {:invalid_param, "text"}}

  defp session_id(%{session_id: session_id}) when is_binary(session_id) and session_id != "",
    do: {:ok, session_id}

  defp session_id(_context), do: {:error, :missing_session}

  # --- resolution and the send ---------------------------------------------

  defp on_platform(platform, opts) do
    case OwnerInbox.on_platform(platform, opts) do
      {:ok, inbox} -> {:ok, inbox}
      {:error, reason} -> {:error, {:no_inbox, platform, reason}}
    end
  end

  # One attempt under the watchdog, reduced to the closed delivery vocabulary
  # (`Delivery.Error`), whose every reason has its sentence.
  defp deliver(inbox, text, key, opts) do
    @send_timeout_ms
    |> ChannelSend.with_timeout(fn ->
      ChannelSend.send(inbox.platform, inbox.destination, text, [proactive_key: key],
        channels: delivery_channels(opts),
        delivery_max_attempts: 1
      )
    end)
    |> Error.normalize()
    |> case do
      :ok -> :ok
      {:error, reason} -> {:error, {:delivery_failed, inbox.platform, reason}}
    end
  end

  # The turn's session id is unique only within one run of the VM, and a
  # timeline's key is durable, so the daemon's OS process is part of the
  # turn's identity: a later run's turn that sends the same text is a new
  # send, never a row already written.
  defp proactive_key(session_id, platform, text) do
    digest =
      :sha256
      |> :crypto.hash([System.pid(), 0, session_id, 0, platform, 0, text])
      |> Base.encode16(case: :lower)
      |> binary_part(0, 32)

    "send_to_channel:" <> digest
  end

  # --- refusals ------------------------------------------------------------

  defp refusal({:invalid_param, key}, _channel, _opts),
    do: {"invalid_args", error("Missing or invalid parameter: #{key}.")}

  defp refusal({:text_too_long, bytes}, _channel, _opts) do
    {"text_too_long",
     error(
       "Not sent: the text is #{bytes} bytes and the limit is #{@text_max_bytes}. Send a " <>
         "shorter text, such as the gist and where the rest is."
     )}
  end

  defp refusal(:missing_session, _channel, _opts),
    do: {"invalid_args", error("Not sent: this turn has no session id to key the send by.")}

  defp refusal({:no_inbox, platform, :no_owner_inbox}, _channel, opts) do
    {"no_owner_inbox",
     error(
       "Not sent: #{platform} has no inbox of the owner's now (no owner id is set for it, " <>
         "or it cannot deliver). " <> reachable_line(opts)
     )}
  end

  defp refusal({:no_inbox, _platform, {kind, _detail} = reason}, _channel, opts) do
    {Atom.to_string(kind),
     error("Not sent: " <> Reply.format_delivery_error(reason) <> ". " <> reachable_line(opts))}
  end

  defp refusal({:delivery_failed, platform, reason}, _channel, _opts) do
    {"delivery_failed",
     error("Not sent to #{platform}: " <> Reply.format_delivery_error(reason) <> ".")}
  end

  # Where the owner can be reached instead, for the model to say or ask about;
  # nothing is ever sent there in this one's place.
  defp reachable_line(opts) do
    case OwnerInbox.reachable_platforms(opts) do
      [] -> "No channel has an inbox of the owner's now."
      platforms -> "Channels with an inbox of the owner's now: #{Enum.join(platforms, ", ")}."
    end
  end

  defp error(sentence), do: {:ok, Tool.error(sentence)}

  # --- shared --------------------------------------------------------------

  defp parameters_with(channel) do
    %{
      type: "object",
      required: ["channel", "text"],
      properties: %{
        channel: channel,
        text: %{
          type: "string",
          maxLength: @text_max_bytes,
          description:
            "What to send, as it should read there: the result itself, at most 4 KB, not " <>
              "a reference to this conversation."
        }
      }
    }
  end

  defp channel_schema(nil) do
    %{type: "string", description: "The channel to send to, by name (telegram, companion, ...)."}
  end

  defp channel_schema(platforms) when is_list(platforms) do
    %{
      type: "string",
      enum: platforms,
      description:
        "The channel to send to: companion is the owner's chat in the Fermix app, mobile " <>
          "their phone."
    }
  end

  # The delivery path's own seams, read from the turn's context when a test
  # names them: the jobs config (its `delivery_channels` and default target)
  # and the configured owners.
  defp inbox_opts(context) do
    context
    |> Map.take([:jobs_config, :configured_owners])
    |> Map.to_list()
  end

  defp delivery_channels(opts) do
    opts
    |> Keyword.get_lazy(:jobs_config, fn -> Application.get_env(:fermix_core, :jobs, []) end)
    |> Keyword.get(:delivery_channels, %{})
  end

  defp telemetry_metadata(args, outcome) do
    %{outcome: outcome}
    |> put_string(:channel, Map.get(args, "channel"), @channel_max_bytes)
    |> put_size(Map.get(args, "text"))
  end

  defp put_string(metadata, key, value, max)
       when is_binary(value) and byte_size(value) <= max,
       do: Map.put(metadata, key, value)

  defp put_string(metadata, _key, _value, _max), do: metadata

  defp put_size(metadata, text) when is_binary(text),
    do: Map.put(metadata, :text_bytes, byte_size(text))

  defp put_size(metadata, _text), do: metadata
end
