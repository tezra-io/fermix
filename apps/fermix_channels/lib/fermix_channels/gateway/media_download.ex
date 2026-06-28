defmodule FermixChannels.Gateway.MediaDownload do
  @moduledoc """
  Shared helpers for channel `download_attachment/2` implementations: a declared
  size preflight, a post-receive byte cap, and a temp-file write with a
  mime-derived extension. Used by the channels added in M14 (Discord, Slack,
  Signal). WhatsApp and Telegram predate this module and keep their own private
  copies; a future cleanup may migrate them here.
  """

  require Logger

  @doc "Reject before any fetch when the attachment's declared size exceeds `max`."
  @spec preflight_cap(map(), pos_integer()) :: :ok | {:error, term()}
  def preflight_cap(attachment, max) when is_map(attachment) and is_integer(max) do
    case value(attachment, :size_bytes) do
      size when is_integer(size) and size > max ->
        {:error, {:byte_cap_exceeded, size, max}}

      _ ->
        :ok
    end
  end

  @doc """
  Hard cap on the received body — backstops a missing or lying declared size
  (the streamed-collector path is rejected by Req's test plug, so this
  post-receive guard is the floor; pair it with `preflight_cap/2`).
  """
  @spec enforce_cap(binary(), pos_integer()) :: {:ok, binary()} | {:error, term()}
  def enforce_cap(body, max) when is_binary(body) and byte_size(body) > max do
    Logger.error("Inbound media exceeded #{max}-byte cap; refusing payload")
    {:error, {:byte_cap_exceeded, byte_size(body), max}}
  end

  def enforce_cap(body, _max) when is_binary(body), do: {:ok, body}

  @doc "Write the body to a unique sandboxed temp path, named by channel + mime."
  @spec write_temp(binary(), String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def write_temp(body, channel_tag, attachment)
      when is_binary(body) and is_binary(channel_tag) and is_map(attachment) do
    path =
      Path.join(
        System.tmp_dir!(),
        "fermix-#{channel_tag}-#{System.unique_integer([:positive])}#{extension(attachment)}"
      )

    case File.write(path, body) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Read an attachment field by atom or string key."
  @spec value(map(), atom()) :: term()
  def value(attachment, key) when is_map(attachment) and is_atom(key) do
    Map.get(attachment, key) || Map.get(attachment, Atom.to_string(key))
  end

  defp extension(attachment) do
    attachment
    |> value(:mime_type)
    |> normalize_extension()
  end

  defp normalize_extension(nil), do: ".bin"

  defp normalize_extension(mime_type) when is_binary(mime_type) do
    mime_type
    |> String.split(";", parts: 2)
    |> hd()
    |> String.split("/", parts: 2)
    |> case do
      [_type, subtype] when subtype != "" ->
        "." <> String.replace(subtype, ~r/[^a-zA-Z0-9]+/, "_")

      _ ->
        ".bin"
    end
  end
end
