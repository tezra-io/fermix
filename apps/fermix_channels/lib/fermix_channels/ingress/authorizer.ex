defmodule FermixChannels.Ingress.Authorizer do
  @moduledoc """
  Resolves the inbound source's authorization and trust.

  Two-tier model:

  - The configured `owner_user_id` on a remote channel resolves to
    `{role: :operator, trust: :operator}` — full registry surface.
  - Any other sender in `allowed_user_ids` resolves to
    `{role: :guest, trust: :guest}` — read-only surface. Adding a
    friend to the allow-list lets them chat with the bot but does
    not silently grant them skills, MCP tools, exec, network, or
    external API capabilities.
  - Local channels (`cli`, `daemon`) are operator-equivalent —
    loopback paths the human owner is sitting at.
  - Missing sender id, unknown sender, or unknown channel string:
    denied.

  Owner detection uses `Config.channel_explicit_owner_user_id/1`
  (strict — does not promote a sole allow-list entry to owner). The
  command-side accessor `Config.channel_command_owner_user_id/1`
  keeps its single-allow-list shortcut for slash-command UX, but it
  is not the trust source.

  Centralising this here means `MainAgent` does not look up channel
  owner config per message, and channel adapters do not duplicate
  trust rules. See `docs/MESSAGE_GATEWAY_ARCHITECTURE.md` §4 and §9.2.
  """

  alias FermixChannels.Ingress.Authorization
  alias FermixChannels.Ingress.Source
  alias FermixCore.Config

  @local_channels ~w(cli daemon)

  @spec resolve(Source.t()) ::
          {:ok, Authorization.t()} | {:error, :unauthorized | :unknown_channel}
  def resolve(%Source{channel: channel}) when channel in @local_channels do
    {:ok, %Authorization{role: :operator, trust: :operator}}
  end

  def resolve(%Source{channel_key: nil}), do: {:error, :unknown_channel}

  def resolve(%Source{channel_key: key, sender_id: sender_id}) when is_atom(key) do
    cond do
      is_nil(sender_id) ->
        {:error, :unauthorized}

      owner?(key, sender_id) ->
        {:ok, %Authorization{role: :operator, trust: :operator}}

      allowed?(key, sender_id) ->
        {:ok, %Authorization{role: :guest, trust: :guest}}

      true ->
        {:error, :unauthorized}
    end
  end

  defp owner?(channel_key, sender_id) do
    case Config.channel_explicit_owner_user_id(channel_key) do
      owner when is_binary(owner) -> owner == sender_id
      _other -> false
    end
  end

  defp allowed?(channel_key, sender_id) do
    channel_key
    |> Config.channel_ingress_user_ids()
    |> Enum.map(&to_string/1)
    |> Enum.member?(sender_id)
  end
end
