defmodule FermixCore.Memory.Scope do
  @moduledoc """
  Shared helpers for durable memory scope identifiers.
  """

  @type thread_scope :: :root | String.t() | integer()

  @spec normalize_thread_scope(thread_scope()) :: String.t()
  def normalize_thread_scope(:root), do: "root"
  def normalize_thread_scope(value) when is_binary(value), do: value
  def normalize_thread_scope(value) when is_integer(value), do: Integer.to_string(value)

  @spec conversation_scope_id(String.t(), String.t(), thread_scope()) :: String.t()
  def conversation_scope_id(channel, chat_id, thread_scope)
      when is_binary(channel) and is_binary(chat_id) do
    Enum.join([channel, chat_id, normalize_thread_scope(thread_scope)], ":")
  end

  @spec legacy_scope_id(String.t(), String.t()) :: String.t()
  def legacy_scope_id(channel, chat_id) when is_binary(channel) and is_binary(chat_id) do
    "legacy:#{channel}:#{chat_id}"
  end
end
