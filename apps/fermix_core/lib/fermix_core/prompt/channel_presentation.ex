defmodule FermixCore.Prompt.ChannelPresentation do
  @moduledoc """
  Builds the per-turn "presentation posture" system note for the delivering
  channel (`CHANNEL_LONGFORM_PRESENTATION.md` §7).

  Same seam and same reason as `FermixCore.Prompt.CurrentDate`: the composed
  system prompt and the generated runtime section are cached per *trust profile*
  in `FermixCore.Agents.RuntimeContext`, and a profile is shared across every
  channel — so channel-varying text cannot live there. `TurnRunner` injects this
  note fresh on every turn instead.

  Unlike the date note this one never churns. It is a pure function of the
  channel and the chat type, both of which are `ConversationKey`-stable, so the
  block is byte-identical for the whole life of a conversation and adds nothing
  to the provider's prompt-cache invalidation (`TurnRunner` splices it *before*
  the date note, so the date's once-a-day change stays the only change).

  Only chat surfaces get a note. `nil` for `acp`, `cli`, an unknown channel, or
  no channel at all is the correct answer rather than an error: those are
  machine and terminal surfaces (an editor client, a terminal, a scheduled run)
  where a phone-width bubble posture is simply false — a terminal renders tables
  fine and has no message-size rhythm. A missing note means "no presentation
  posture applies", which is a real state, not a failure to classify.

  The note stays thin because rendering already adapts per channel (§3.1): the
  model writes one house style and is told what kind of surface will carry it.
  """

  # OWNER AUTHORS THE FINAL TEXT. Per design §9.6, S3 ships these principles as
  # a reviewed DRAFT placement: the seam, the keying, and the byte-stability are
  # the engineering; the wording is expected to be rewritten by the operator
  # before it is considered settled. Keep them failure-class principles (name the
  # mistake to avoid), never worked examples.
  @core_lines [
    "Presentation: your reply is delivered on a phone-width chat surface, not a document page.",
    "- Lead with the answer. Preamble, method, and caveats come after it.",
    "- Keep sections short and self-contained; a long answer may arrive as several separate messages.",
    "- No markdown tables and no horizontal rules — no chat client renders them.",
    "- Keep heading depth shallow; a bold lead-in beats a stack of heading levels.",
    "- Put each link inline on the claim it supports rather than collecting them at the end.",
    "- Deep optional detail belongs in a quote block, so the main line stays readable.",
    "- Match depth to the ask: a small question gets a small answer."
  ]

  # Chat surfaces, each mapped to the one extra line that channel actually earns
  # (nil where the shared core already says everything true of it). Membership in
  # this map is what makes a channel "a chat surface" at all.
  @channel_lines %{
    "telegram" =>
      "- Telegram renders a quote block collapsed until it is tapped, so long optional detail costs the reader nothing.",
    "discord" =>
      "- Discord caps a single message near 2,000 characters; keep sections tighter here.",
    "slack" => nil,
    "signal" => nil,
    "whatsapp" => nil
  }

  # Chat types the channels report for a shared room (telegram: group/supergroup/
  # channel, slack: channel/group/mpim, discord: guild). Listed positively so an
  # unknown or absent chat type omits the line instead of guessing "group" —
  # every channel already reports "private"/"im" for a DM.
  @group_chat_types ["group", "supergroup", "channel", "guild", "mpim"]

  @doc """
  The presentation note for `channel`, or `nil` when the surface carries no
  presentation posture (machine and terminal surfaces, unknown channels).

  `chat_type` is the gateway-resolved chat context already carried on the
  inbound message metadata; a group value appends one addressing line, and an
  absent or unrecognised value simply omits it.
  """
  @spec note(String.t() | nil, String.t() | nil) :: String.t() | nil
  def note(channel, chat_type)
      when (is_binary(channel) or is_nil(channel)) and
             (is_binary(chat_type) or is_nil(chat_type)) do
    case Map.fetch(@channel_lines, channel) do
      {:ok, channel_line} -> compose(channel_line, chat_type)
      :error -> nil
    end
  end

  defp compose(channel_line, chat_type) do
    (@core_lines ++ [channel_line, group_line(chat_type)])
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp group_line(chat_type) when chat_type in @group_chat_types do
    "- This is a shared chat: answer the person who asked, briefly addressing them, without lecturing the room."
  end

  defp group_line(_dm_or_unknown), do: nil
end
