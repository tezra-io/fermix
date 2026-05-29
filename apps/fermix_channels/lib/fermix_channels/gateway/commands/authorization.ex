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

  This is `MESSAGE_GATEWAY_ARCHITECTURE.md` stage 4: command
  authorization and agent tool trust now share one decision.
  """

  alias FermixChannels.Gateway.Authorization

  @spec owner_only(FermixChannels.Gateway.Message.t(), map(), map()) :: :ok | {:error, :unauthorized}
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
  defp channel_key(_channel), do: :error
end
