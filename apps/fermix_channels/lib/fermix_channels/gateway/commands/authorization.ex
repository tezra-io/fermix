defmodule FermixChannels.Gateway.Commands.Authorization do
  @moduledoc """
  Authorization helpers for channel commands.

  Owner-only commands consume the resolved ingress decision
  (`context.authorization`) produced by `FermixChannels.Gateway.Authorizer`
  rather than re-reading channel config per command. Two outcomes are
  authorised:

  - `role: :operator` — the gateway already classified this sender as
    the configured channel owner (or a local CLI/daemon caller), so
    owner-only commands run unconditionally.
  - `role: :guest` + sender listed in `command_allowlist` — a non-owner
    who is allowed to chat *and* explicitly opted in to run owner-only
    slash commands (e.g. a trusted collaborator who can run `/new` or
    `/compact` without operator-grade tool access).

  Any other context (missing authorization, missing user id, no
  matching channel) fails loud as `{:error, :unauthorized}`.

  For operator-grade actions (e.g. sandbox directory grants) use
  `operator_only/3`, which admits *only* `role: :operator` and never
  the `command_allowlist` guest branch: a trusted collaborator allowed
  to run `/new` must not thereby gain sandbox-mutation authority.

  The approval family also asks who sent the message, through
  `in_person/1`. A local socket's transport trust makes every same-user
  peer an operator, so the daemon reads the peer instead
  (`FermixCore.SocketPeer`) and the CLI and companion channels stamp it as
  `metadata.caller`. A process the daemon started (the agent's own shell
  command, a coding run) or one no terminal is attached to is not the
  owner in person, so an approval-family command refuses it as
  `{:error, :unattended}` (SIDE-V1): otherwise the agent could answer its
  own `/confirm` prompt or approve a change it proposed itself. Every
  other owner command answers by role alone, for any caller.

  This is `MESSAGE_GATEWAY_ARCHITECTURE.md` stage 4: command
  authorization and agent tool trust now share one decision.
  """

  alias FermixChannels.Gateway.Authorization

  @typedoc "Why a gate refused: not the owner, or not a person at all."
  @type refusal :: :unauthorized | :unattended

  # The `SocketPeer` callers no person is behind.
  @unattended_callers [:daemon_descendant, :detached]

  @doc """
  Whether a person sent this message. The approval family calls it before
  its role gate: `/confirm`, `/deny`, `/grant`, `/revoke` and the rest of
  `/sandbox`, `/soul` and `/skills`, which answer the owner's approval
  prompts or approve a change the agent itself proposed. Refuses a caller
  no person is behind; a message with no caller was not read off a local
  socket (a remote chat, an in-process call) and passes.
  """
  @spec in_person(map()) :: :ok | {:error, :unattended}
  def in_person(%{caller: caller}) when caller in @unattended_callers, do: {:error, :unattended}
  def in_person(metadata) when is_map(metadata), do: :ok

  @spec owner_only(FermixChannels.Gateway.Message.t(), map(), map()) ::
          :ok | {:error, :unauthorized}
  def owner_only(_message, _metadata, %{authorization: %Authorization{role: :operator}}), do: :ok

  def owner_only(%{channel: channel}, metadata, %{authorization: %Authorization{role: :guest}}) do
    with {:ok, key} <- channel_key(channel),
         user_id when is_binary(user_id) <- stable_user_id(metadata),
         true <- in_command_allowlist?(key, user_id) do
      :ok
    else
      _other -> {:error, :unauthorized}
    end
  end

  def owner_only(_message, _metadata, _context), do: {:error, :unauthorized}

  @doc """
  Strict operator gate. Authorises only when the gateway classified the
  sender as the configured owner (`role: :operator`). Unlike `owner_only/3`
  it never consults `command_allowlist`, so a guest can never reach an
  operator-grade action even if allowed to run other slash commands.
  """
  @spec operator_only(FermixChannels.Gateway.Message.t(), map(), map()) ::
          :ok | {:error, :unauthorized}
  def operator_only(_message, _metadata, %{authorization: %Authorization{role: :operator}}),
    do: :ok

  def operator_only(_message, _metadata, _context), do: {:error, :unauthorized}

  defp stable_user_id(metadata) when is_map(metadata) do
    case Map.get(metadata, :user_id) || Map.get(metadata, "user_id") do
      value when is_binary(value) -> value
      value when is_integer(value) -> Integer.to_string(value)
      _other -> nil
    end
  end

  defp stable_user_id(_metadata), do: nil

  defp in_command_allowlist?(channel_key, user_id) do
    user_id in Enum.map(FermixCore.Config.channel_command_allowlist(channel_key), &to_string/1)
  end

  defp channel_key("telegram"), do: {:ok, :telegram}
  defp channel_key("whatsapp"), do: {:ok, :whatsapp}
  defp channel_key("discord"), do: {:ok, :discord}
  defp channel_key("slack"), do: {:ok, :slack}
  defp channel_key("signal"), do: {:ok, :signal}
  defp channel_key("imessage"), do: {:ok, :imessage}
  defp channel_key(_channel), do: :error
end
