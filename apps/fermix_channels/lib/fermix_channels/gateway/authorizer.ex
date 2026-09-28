defmodule FermixChannels.Gateway.Authorizer do
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
  - Channels the registry marks `trust: :local_operator` (`cli`,
    `daemon`) are operator-equivalent — same-user local paths the
    human owner is sitting at. That check runs FIRST, so such a
    channel authorizes whether or not it carries a config key or a
    sender id.
  - A paired device (the phone's transport proof) is the operator
    while the mobile trust store still holds it, so work a revoked
    device already submitted is refused when it reaches ingest.
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

  require Logger

  alias FermixChannels.Gateway.Authorization
  alias FermixChannels.Gateway.ChannelRegistry
  alias FermixChannels.Gateway.Source
  alias FermixChannels.Mobile.DeviceStore
  alias FermixCore.Config

  @spec resolve(Source.t()) ::
          {:ok, Authorization.t()} | {:error, :unauthorized | :unknown_channel}
  def resolve(%Source{channel: channel} = source) when is_binary(channel) do
    case ChannelRegistry.trust(channel) do
      :local_operator -> {:ok, %Authorization{role: :operator, trust: :operator}}
      nil -> resolve_registered_ingress(source, ChannelRegistry.ingress_auth(channel))
    end
  end

  defp resolve_registered_ingress(source, :paired_device), do: resolve_paired_device(source)
  defp resolve_registered_ingress(source, nil), do: resolve_sender(source)

  defp resolve_paired_device(%Source{transport_auth: {:mobile_device, device_id}})
       when is_binary(device_id) and device_id != "" do
    case paired_device(device_id) do
      {:ok, _device} ->
        {:ok, %Authorization{role: :operator, trust: :operator}}

      {:error, reason} ->
        Logger.warning("mobile device #{device_id} is not paired: #{inspect(reason)}")
        {:error, :unauthorized}
    end
  end

  defp resolve_paired_device(%Source{}), do: {:error, :unauthorized}

  # The trust store runs with the mobile subtree; without it no device can be
  # confirmed, and none is authorized.
  defp paired_device(device_id) do
    case Process.whereis(DeviceStore) do
      nil -> {:error, :device_store_not_running}
      store -> DeviceStore.fetch(store, device_id)
    end
  end

  defp resolve_sender(%Source{channel_key: nil}), do: {:error, :unknown_channel}

  defp resolve_sender(%Source{channel_key: key, sender_id: sender_id}) when is_atom(key) do
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
