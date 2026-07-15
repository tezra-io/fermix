defmodule FermixChannels.Gateway.ApprovalButton do
  @moduledoc """
  Shared one-tap approval-button plumbing for channel adapters
  (SANDBOX_ACCESS_APPROVAL_FLOW).

  A channel that renders an "Approve" affordance carries the single-use sandbox
  confirmation token in the button payload, namespaced with `grant:` so a future
  non-grant button can never be mistaken for a confirmation. Telegram
  (`callback_data`) and Discord (component `custom_id`) both build the payload
  with `payload/1`, strip it back to the bare token with `parse_payload/1`, and
  synthesize the inbound `/confirm` message with `confirm_message/1`.

  This module ONLY builds the message that funnels a tap into the confirm path;
  the confirm itself stays solely in the unchanged `Commands.Sandbox` (peek →
  validate → take, operator-only, same-origin, auto-resume).
  """

  alias FermixChannels.Gateway.Message

  @prefix "grant:"

  @doc "Namespaced button payload for a confirmation token."
  @spec payload(String.t()) :: String.t()
  def payload(token) when is_binary(token) and token != "", do: @prefix <> token

  @doc """
  Strip the `grant:` namespace back to the bare token. A payload without the
  prefix (or an empty/non-binary payload) is `:ignore` — it is not a
  confirmation tap and must never be treated as one.
  """
  @spec parse_payload(term()) :: {:ok, String.t()} | :ignore
  def parse_payload(@prefix <> token) when token != "", do: {:ok, token}
  def parse_payload(_other), do: :ignore

  @doc """
  Build the synthesized `/confirm <token>` inbound message a tap stands in for.
  Both adapters map their native fields (Telegram callback / Discord interaction)
  into the same five origin inputs so the tap funnels through the exact typed
  `/confirm` path. `user_id` is the platform-authenticated tapper id; `id` and
  `sender` are the adapter's native identifiers.
  """
  @spec confirm_message(%{
          required(:id) => String.t(),
          required(:sender) => String.t(),
          required(:channel) => String.t(),
          required(:chat_id) => String.t(),
          required(:thread_ts) => term(),
          required(:user_id) => term(),
          required(:token) => String.t()
        }) :: Message.t()
  def confirm_message(%{
        id: id,
        sender: sender,
        channel: channel,
        chat_id: chat_id,
        thread_ts: thread_ts,
        user_id: user_id,
        token: token
      })
      when is_binary(id) and is_binary(sender) and is_binary(channel) and is_binary(chat_id) and
             is_binary(token) do
    Message.new!(%{
      id: id,
      content: "/confirm #{token}",
      sender: sender,
      channel: channel,
      chat_id: chat_id,
      reply_target: chat_id,
      thread_ts: thread_ts,
      metadata: %{user_id: to_string(user_id)}
    })
  end
end
