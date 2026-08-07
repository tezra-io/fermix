defmodule FermixChannels.Gateway.ProposalButton do
  @moduledoc """
  Two-button skill-curation proposal plumbing for channel adapters
  (MILESTONE_26_SKILL_CURATION §6.6).

  A proposal message carries approve/deny affordances whose payloads are
  namespaced `skillcur:` with an action verb (`skillcur:a:<token>` /
  `skillcur:d:<token>`), so they can never be mistaken for a sandbox `grant:`
  confirmation (whose module's own docs demand exactly this separation). A tap
  synthesizes the typed `/skills approve <token>` or `/skills deny <token>`
  inbound message — the typed command is the single code path; buttons only
  type it for you.
  """

  alias FermixChannels.Gateway.Message

  @approve_prefix "skillcur:a:"
  @deny_prefix "skillcur:d:"

  @doc "Namespaced approve-button payload for a proposal token."
  @spec approve_payload(String.t()) :: String.t()
  def approve_payload(token) when is_binary(token) and token != "", do: @approve_prefix <> token

  @doc "Namespaced deny-button payload for a proposal token."
  @spec deny_payload(String.t()) :: String.t()
  def deny_payload(token) when is_binary(token) and token != "", do: @deny_prefix <> token

  @doc """
  Strip the `skillcur:` namespace back to the action verb and bare token. Any
  other payload is `:ignore` — it is not a proposal tap and must never be
  treated as one.
  """
  @spec parse_payload(term()) :: {:ok, :approve | :deny, String.t()} | :ignore
  def parse_payload(@approve_prefix <> token) when token != "", do: {:ok, :approve, token}
  def parse_payload(@deny_prefix <> token) when token != "", do: {:ok, :deny, token}
  def parse_payload(_other), do: :ignore

  @doc """
  Build the synthesized `/skills approve|deny <token>` inbound message a tap
  stands in for (the `ApprovalButton.confirm_message/1` convention: the same
  five origin inputs, `user_id` platform-authenticated).
  """
  @spec action_message(%{
          required(:id) => String.t(),
          required(:sender) => String.t(),
          required(:channel) => String.t(),
          required(:chat_id) => String.t(),
          required(:thread_ts) => term(),
          required(:user_id) => term(),
          required(:action) => :approve | :deny,
          required(:token) => String.t()
        }) :: Message.t()
  def action_message(%{
        id: id,
        sender: sender,
        channel: channel,
        chat_id: chat_id,
        thread_ts: thread_ts,
        user_id: user_id,
        action: action,
        token: token
      })
      when is_binary(id) and is_binary(sender) and is_binary(channel) and is_binary(chat_id) and
             action in [:approve, :deny] and is_binary(token) do
    Message.new!(%{
      id: id,
      content: "/skills #{action} #{token}",
      sender: sender,
      channel: channel,
      chat_id: chat_id,
      reply_target: chat_id,
      thread_ts: thread_ts,
      metadata: %{user_id: to_string(user_id)}
    })
  end
end
