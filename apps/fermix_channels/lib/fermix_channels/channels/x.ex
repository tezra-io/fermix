defmodule FermixChannels.Channels.X do
  @moduledoc """
  The shared X handle's inbound channel (MILESTONE_63_SHARED_X_HANDLE).

  Fermix Connect watches the shared account's mentions and hands this
  installation the ones its owner's linked X identity made, as signed
  assignments over a socket this machine dials (`X.Client`). `X.Pump` verifies
  and stores each one, asks Connect for a start, and ingests it here as one
  guest turn; this adapter shapes the turn and takes back its one result.

  Its hard rules are code, never settings:

    * **Final-only.** The turn's reply text is staged on its assignment row
      (the last text wins) and its outcome seals the row, which `X.Pump` sends
      to Connect as the one result. Nothing streams: the adapter declares no
      stream tier and owns its terminal result, which the gateway reads as
      final-only. There is no typing, reaction, draft, approval or proposal
      callback, and slash commands are off for the channel (the registry).
    * **Nothing sends to X.** `send_message/3` and `send_media/3` refuse;
      `Delivery.ChannelSend` has no `"x"` clause, so jobs, reminders and
      `send_to_channel` never reach it. Connect alone publishes, from its own
      record of the interaction.
    * **A guest turn.** The authorization comes from the stored assignment
      (`Gateway.Authorizer`), never from anything the message carries; its
      metadata is informational.

  Each requester has their own conversation, per X conversation and per link
  generation: `{"x", "<tenant>:<requester>:<generation>", <conversation_id>}`,
  built here from the verified claims and never from a payload's own key.
  """

  @behaviour FermixChannels.Gateway.Channel

  alias FermixChannels.Gateway.Channel
  alias FermixChannels.Gateway.Message
  alias FermixChannels.X.Assignment
  alias FermixChannels.X.Pump
  alias FermixCore.Capabilities.UntrustedContent

  @channel "x"
  # The untrusted frame's source: the public posts Connect read around the
  # mention, which anyone on X could have written.
  @context_source "x_thread"
  @public_reply_chars 280

  @type decision :: {:public_reply, String.t()} | :no_reply | :failed

  @spec channel() :: String.t()
  def channel, do: @channel

  # --- Transport -------------------------------------------------------------

  @impl true
  @spec parse_webhook(map()) :: {:error, :unsupported_transport}
  def parse_webhook(_params), do: {:error, :unsupported_transport}

  @impl true
  @spec verify_webhook(Plug.Conn.t()) :: {:error, :unsupported_transport}
  def verify_webhook(_conn), do: {:error, :unsupported_transport}

  @impl true
  @spec send_message(String.t(), String.t(), keyword()) :: {:error, :x_is_final_only}
  def send_message(_chat_id, _text, _opts), do: {:error, :x_is_final_only}

  @impl true
  @spec send_media(String.t(), map(), keyword()) :: {:error, :x_is_final_only}
  def send_media(_chat_id, _media, _opts), do: {:error, :x_is_final_only}

  # --- The turn's one result -------------------------------------------------

  @doc "Stages each reply text on the assignment's row; the last one is the result."
  @impl true
  @spec build_text_reply(Message.t()) :: (String.t() -> :ok | {:error, term()})
  def build_text_reply(%Message{channel: @channel, id: assignment_id}) do
    fn text when is_binary(text) -> Pump.stage_reply(assignment_id, text) end
  end

  @impl true
  @spec build_media_reply(Message.t()) :: (map() -> {:error, :x_is_text_only})
  def build_media_reply(%Message{channel: @channel}) do
    fn _media -> {:error, :x_is_text_only} end
  end

  @doc "Seals the assignment's row from the turn's outcome (`decision/2`)."
  @impl true
  @spec build_turn_result(Message.t()) :: (term() -> :ok | {:error, term()})
  def build_turn_result(%Message{channel: @channel, id: assignment_id}) do
    fn outcome -> Pump.turn_result(assignment_id, outcome) end
  end

  @impl true
  @spec terminal_error_capability() :: :turn_result
  def terminal_error_capability, do: :turn_result

  @doc """
  The result a turn's outcome and staged text make: a completed turn's last
  text is its public reply, and one that staged none has no reply; a turn
  that was stopped or failed is `failed`, whatever it staged.
  """
  @spec decision(term(), String.t() | nil) :: decision()
  def decision({:completed}, text) when is_binary(text), do: {:public_reply, text}
  def decision({:completed}, nil), do: :no_reply
  def decision({:cancelled}, _text), do: :failed
  def decision({:failed, _reason}, _text), do: :failed

  @impl true
  @spec health_check(keyword()) :: Channel.health_result()
  def health_check(_opts) do
    case Pump.status() do
      {:ok, %{connection: :connected, pending: pending, running: running}} ->
        {:ok, %{detail: "connected to Fermix Connect (#{running} running, #{pending} waiting)"}}

      {:ok, %{connection: connection}} ->
        {:error, {:not_connected, connection}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- The turn's message ----------------------------------------------------

  @doc """
  The gateway message for a verified assignment. Its conversation is the
  requester's own, per X conversation and link generation; its content is the
  request, then the public posts Connect read, framed as outside content.
  """
  @spec message(Assignment.t()) :: Message.t()
  def message(%Assignment{} = assignment) do
    Message.new!(%{
      id: assignment.assignment_id,
      content: content(assignment),
      sender: sender(assignment),
      channel: @channel,
      chat_id: chat_id(assignment),
      reply_target: assignment.assignment_id,
      thread_ts: assignment.conversation_id,
      metadata: %{
        assignment_id: assignment.assignment_id,
        interaction_id: assignment.interaction_id
      }
    })
  end

  defp chat_id(%Assignment{} = assignment) do
    "#{assignment.tenant_id}:#{assignment.requester_x_user_id}:#{assignment.tenant_generation}"
  end

  defp sender(%Assignment{context: %{posts: posts}} = assignment) do
    case Enum.find(posts, &(&1.role == :invoking and is_binary(&1.author_handle))) do
      %{author_handle: handle} -> handle
      nil -> assignment.requester_x_user_id
    end
  end

  # The verified facts first (who asked, and that the answer is one public
  # post), then the request, then the thread as data.
  defp content(%Assignment{} = assignment) do
    "[A mention on X from #{sender(assignment)}. The answer is published on X as one " <>
      "public reply of at most #{@public_reply_chars} characters.]\n" <>
      assignment.request_text <>
      "\n\n" <> UntrustedContent.frame(@context_source, packet(assignment.context))
  end

  defp packet(%{posts: posts, truncated: truncated}) do
    lines =
      ["Public posts around the mention, as Fermix Connect read them:"] ++
        Enum.map(posts, &post_text/1) ++ truncation(truncated)

    Enum.join(lines, "\n\n")
  end

  defp post_text(%{missing?: true} = post) do
    "[#{post.role}] post #{post.id}: missing (this post could not be read)"
  end

  defp post_text(post) do
    "[#{post.role}] #{post.author_handle} · post #{post.id} · " <>
      "#{DateTime.to_iso8601(post.created_at)}\n#{post.text}"
  end

  defp truncation(true), do: ["The thread was truncated: some posts were left out."]
  defp truncation(false), do: []
end
