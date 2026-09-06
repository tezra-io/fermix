defmodule FermixChannels.Gateway.ApprovalButton do
  @moduledoc """
  Shared approval-button plumbing for channel adapters
  (SANDBOX_ACCESS_APPROVAL_FLOW).

  Approve and deny affordances carry a single-use token in distinct `grant:` and
  `deny:` namespaces. Telegram (`callback_data`) and Discord (component
  `custom_id`) parse the action and synthesize the same `/confirm` or `/deny`
  command an owner could type.

  This module only builds the message. Token validation and consumption stay in
  `Commands.Sandbox` (peek → validate → take, operator-only, same-origin).
  """

  alias FermixChannels.Gateway.Message

  @approve_prefix "grant:"
  @deny_prefix "deny:"

  @doc "Namespaced button payload for a confirmation token."
  @spec payload(String.t()) :: String.t()
  def payload(token) when is_binary(token) and token != "", do: approve_payload(token)

  @doc "Namespaced Approve-button payload."
  @spec approve_payload(String.t()) :: String.t()
  def approve_payload(token) when is_binary(token) and token != "", do: @approve_prefix <> token

  @doc "Namespaced Deny-button payload."
  @spec deny_payload(String.t()) :: String.t()
  def deny_payload(token) when is_binary(token) and token != "", do: @deny_prefix <> token

  @doc """
  Strip the `grant:` namespace back to the bare token. A payload without the
  prefix (or an empty/non-binary payload) is `:ignore` — it is not a
  confirmation tap and must never be treated as one.
  """
  @spec parse_payload(term()) :: {:ok, String.t()} | :ignore
  def parse_payload(@approve_prefix <> token) when token != "", do: {:ok, token}
  def parse_payload(_other), do: :ignore

  @doc "Parse an Approve or Deny payload without treating unknown namespaces as actions."
  @spec parse_action(term()) :: {:ok, :approve | :deny, String.t()} | :ignore
  def parse_action(@approve_prefix <> token) when token != "", do: {:ok, :approve, token}
  def parse_action(@deny_prefix <> token) when token != "", do: {:ok, :deny, token}
  def parse_action(_other), do: :ignore

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
             is_binary(token),
      do:
        action_message(%{
          id: id,
          sender: sender,
          channel: channel,
          chat_id: chat_id,
          thread_ts: thread_ts,
          user_id: user_id,
          action: :approve,
          token: token
        })

  @doc "Build the synthesized command message for an approval action."
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
             action in [:approve, :deny] and is_binary(token) and token != "" do
    Message.new!(%{
      id: id,
      content: "/#{action_command(action)} #{token}",
      sender: sender,
      channel: channel,
      chat_id: chat_id,
      reply_target: chat_id,
      thread_ts: thread_ts,
      metadata: %{user_id: to_string(user_id)}
    })
  end

  defp action_command(:approve), do: "confirm"
  defp action_command(:deny), do: "deny"
end
