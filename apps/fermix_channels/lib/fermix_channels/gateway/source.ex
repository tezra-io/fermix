defmodule FermixChannels.Gateway.Source do
  @moduledoc """
  Normalized inbound identity built from a channel message before
  authorization.

  `channel_key` is the atom form used by `FermixCore.Config` accessors;
  it is `nil` for non-remote channels (`cli`, `daemon`) and for remote
  channels Fermix does not know about. `sender_id` is extracted from the
  message's `metadata` (`:user_id` falling back to `:sender_id`); raw
  string values are trimmed and empty strings collapse to `nil`.

  See `docs/MESSAGE_GATEWAY_ARCHITECTURE.md` §9.1.
  """

  @enforce_keys [:channel]
  defstruct [:channel, :channel_key, :sender_id, :sender_name, :chat_id, :thread_id]

  @type t :: %__MODULE__{
          channel: String.t(),
          channel_key: atom() | nil,
          sender_id: String.t() | nil,
          sender_name: String.t() | nil,
          chat_id: String.t() | nil,
          thread_id: String.t() | nil
        }

  @remote_channel_keys %{
    "telegram" => :telegram,
    "whatsapp" => :whatsapp,
    "slack" => :slack,
    "discord" => :discord,
    "signal" => :signal
  }

  @spec from_message(map()) :: t()
  def from_message(message) when is_map(message) do
    channel = require_binary(message, :channel)
    metadata = Map.get(message, :metadata) || %{}

    %__MODULE__{
      channel: channel,
      channel_key: Map.get(@remote_channel_keys, channel),
      sender_id: sender_id_from_metadata(metadata),
      sender_name: metadata_value(metadata, :sender_name),
      chat_id: optional_binary(message, :chat_id),
      thread_id: optional_binary(message, :thread_ts) || metadata_value(metadata, :thread_id)
    }
  end

  defp sender_id_from_metadata(metadata) do
    case normalize(metadata_value(metadata, :user_id)) do
      nil -> normalize(metadata_value(metadata, :sender_id))
      id -> id
    end
  end

  defp metadata_value(metadata, key) when is_map(metadata) do
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
  end

  defp metadata_value(_metadata, _key), do: nil

  defp normalize(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize(nil), do: nil
  defp normalize(value), do: to_string(value)

  defp require_binary(message, key) do
    case Map.get(message, key) do
      value when is_binary(value) ->
        value

      _other ->
        raise ArgumentError, "Source.from_message/1 requires #{key} to be a binary"
    end
  end

  defp optional_binary(message, key) do
    case Map.get(message, key) do
      value when is_binary(value) -> value
      _other -> nil
    end
  end
end
