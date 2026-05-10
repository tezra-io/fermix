defmodule FermixChannels.Commands.Authorization do
  @moduledoc """
  Authorization helpers for channel commands.
  """

  @spec owner_only(FermixChannels.Message.t(), map(), map()) :: :ok | {:error, :unauthorized}
  def owner_only(%{channel: "cli"}, _metadata, _context), do: :ok

  def owner_only(%{channel: channel}, metadata, _context) do
    case channel_key(channel) do
      {:ok, key} ->
        authorize_channel(key, stable_user_id(metadata))

      :error ->
        {:error, :unauthorized}
    end
  end

  defp stable_user_id(metadata) when is_map(metadata) do
    Map.get(metadata, :user_id) || Map.get(metadata, "user_id")
  end

  defp stable_user_id(_metadata), do: nil

  defp authorize_channel(key, user_id) do
    owner = FermixCore.Config.channel_command_owner_user_id(key)
    allowlist = FermixCore.Config.channel_command_allowlist(key)

    cond do
      is_nil(owner) -> {:error, :unauthorized}
      is_nil(user_id) -> {:error, :unauthorized}
      to_string(user_id) == to_string(owner) -> :ok
      to_string(user_id) in Enum.map(allowlist, &to_string/1) -> :ok
      true -> {:error, :unauthorized}
    end
  end

  defp channel_key("telegram"), do: {:ok, :telegram}
  defp channel_key("whatsapp"), do: {:ok, :whatsapp}
  defp channel_key("discord"), do: {:ok, :discord}
  defp channel_key("slack"), do: {:ok, :slack}
  defp channel_key("signal"), do: {:ok, :signal}
  defp channel_key(_channel), do: :error
end
