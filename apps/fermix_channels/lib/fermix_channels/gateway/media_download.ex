defmodule FermixChannels.Gateway.MediaDownload do
  @moduledoc """
  Shared helpers for channel `download_attachment/2` implementations: a declared
  size preflight, a streaming fetch that halts the transfer before it can cross
  a byte cap, and a private temp-file write with a mime-derived extension.

  Every channel that fetches an attachment over HTTP — Telegram, WhatsApp,
  Slack, Discord — goes through `get_capped/3`, and every channel writes through
  `write_temp/3` or `write_temp_bytes/3`. One fetch path, no post-receive copies.

  Signal is the one downloader that does not fetch: signal-cli leaves inbound
  media as a local file, so it reads bytes off disk and measures them with
  `enforce_cap/2`. That is the only remaining caller of `enforce_cap/2`, and it
  is not a second path for the same job — there is no transfer to halt.
  """

  require Logger

  alias FermixCore.Net.HttpClient

  # A chat sender's media lands on a shared /tmp on Linux; owner-only from the
  # moment the file exists.
  @temp_file_mode 0o600

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
  GET `req`, streaming the response body through a collector that halts the
  transfer before the chunk that would cross `max` is ever buffered — the cap
  prevents the allocation instead of measuring it afterwards. `label` names the
  request in transport logs.

  Streaming disables Req's `decompress_body` step and stops Req advertising
  `accept-encoding`, which removes the decompression amplifier outright. A body
  that arrives compressed anyway is refused by name
  (`{:unexpected_content_encoding, encoding}`) rather than handed back as bytes
  no caller can parse. Non-2xx responses return
  `{:error, {:http_status, status, body}}` for the channel to phrase.
  """
  @spec get_capped(Req.Request.t(), pos_integer(), String.t()) ::
          {:ok, binary()} | {:error, term()}
  def get_capped(%Req.Request{method: :get} = req, max, label)
      when is_integer(max) and max > 0 and is_binary(label) do
    req
    |> Req.merge(decode_body: false, into: capped_collector(max))
    |> HttpClient.request(label)
    |> capped_result(max)
  end

  # Bounded collector (mirrors the shipped `Tools.Media.Support.materialize_url/2`):
  # accumulate until the next chunk would cross `max`, then flag and halt. Req's
  # plug adapter honors `{:halt, acc}`; the Finch adapter aborts the real
  # transfer through `Finch.stream_while/5`.
  defp capped_collector(max) do
    fn {:data, data}, {req, response} -> collect_chunk(data, req, response, max) end
  end

  defp collect_chunk(data, req, %{body: body} = response, max)
       when is_binary(data) and is_binary(body) do
    received = byte_size(body) + byte_size(data)

    if received > max do
      {:halt, {req, Req.Response.put_private(response, :fermix_body_cap, received)}}
    else
      {:cont, {req, %{response | body: body <> data}}}
    end
  end

  defp capped_result({:ok, %Req.Response{private: %{fermix_body_cap: received}}}, max) do
    Logger.error(
      "Inbound media exceeded #{max}-byte cap; halted the transfer at #{received} bytes"
    )

    {:error, {:byte_cap_exceeded, received, max}}
  end

  defp capped_result({:ok, %Req.Response{status: status} = response}, _max)
       when status in 200..299 do
    undecompressed_body(response)
  end

  defp capped_result({:ok, %Req.Response{status: status, body: body}}, _max),
    do: {:error, {:http_status, status, body}}

  defp capped_result({:error, reason}, _max), do: {:error, reason}

  defp undecompressed_body(%Req.Response{body: body} = response) when is_binary(body) do
    response
    |> Req.Response.get_header("content-encoding")
    |> Enum.reject(&(&1 == "identity"))
    |> case do
      [] -> {:ok, body}
      [encoding | _rest] -> {:error, {:unexpected_content_encoding, encoding}}
    end
  end

  @doc """
  Size cap for bytes that are already resident because they were never fetched:
  Signal reads inbound media off signal-cli's local disk. There is no transfer
  to halt, so this reports the breach rather than preventing it; pair it with
  `preflight_cap/2`. Anything that fetches over HTTP uses `get_capped/3`.
  """
  @spec enforce_cap(binary(), pos_integer()) :: {:ok, binary()} | {:error, term()}
  def enforce_cap(body, max) when is_binary(body) and byte_size(body) > max do
    Logger.error("Inbound media exceeded #{max}-byte cap; refusing payload")
    {:error, {:byte_cap_exceeded, byte_size(body), max}}
  end

  def enforce_cap(body, _max) when is_binary(body), do: {:ok, body}

  @doc "`write_temp_bytes/3` with the extension derived from the attachment's mime."
  @spec write_temp(binary(), String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def write_temp(body, channel_tag, attachment)
      when is_binary(body) and is_binary(channel_tag) and is_map(attachment) do
    write_temp_bytes(body, channel_tag, extension(attachment))
  end

  @doc """
  Write the body to a unique temp path with a caller-supplied extension
  (Telegram derives its own from the getFile path when the attachment has no
  mime).

  The file is created exclusively — never opening a path that already exists —
  and chmodded to 0600 while still empty, so a sender's media is owner-only for
  its whole life. The handle is closed on every path, errors included, and the
  file this function created is removed again on every path that does not
  return it.
  """
  @spec write_temp_bytes(binary(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def write_temp_bytes(body, channel_tag, extension)
      when is_binary(body) and is_binary(channel_tag) and is_binary(extension) do
    path =
      Path.join(
        System.tmp_dir!(),
        "fermix-#{channel_tag}-#{temp_suffix()}#{extension}"
      )

    case File.open(path, [:write, :binary, :exclusive]) do
      {:ok, io} -> write_private(io, path, body)
      {:error, reason} -> {:error, {:temp_create_failed, reason}}
    end
  end

  # Random, not `System.unique_integer/1`. That counter restarts at the same
  # small values in every fresh BEAM, so with `:exclusive` any leftover
  # `fermix-telegram-1.jpg` in a shared `/tmp` becomes a permanent landmine: the
  # open fails for that name on every boot from then on, and nothing reaps it.
  # Randomness also removes the predictable name a co-resident account could
  # pre-create — which is the attack `:exclusive` exists to refuse in the first
  # place, and it can only refuse a name an attacker can guess.
  defp temp_suffix do
    9 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  defp write_private(io, path, body) do
    written =
      with :ok <- File.chmod(path, @temp_file_mode) do
        IO.binwrite(io, body)
      end

    write_result(written, File.close(io), path)
  end

  # Maps the chmod/write result and the close result onto this module's
  # contract, removing the temp file on every path that does not return it.
  #
  # Code Rule 4 covers the file `write_temp_bytes/3` created, not just the
  # handle: closing the handle on a failed write leaves a zero-byte
  # `fermix-<channel>-<n>.<ext>` behind — one per failed inbound attachment, in
  # the exact condition (a full `/tmp`) that produces the failure — and nothing
  # ever reaps them.
  #
  # Public only so the cleanup can be tested: neither failure it handles is
  # reachable from ExUnit. `IO.binwrite/2` fails on ENOSPC and `File.close/1` on
  # a device error; every filesystem failure a test can produce deterministically
  # lands on `File.open/2` instead, before a file exists. Same `@doc false` seam
  # as `FermixCore.Providers.OpenAI.Codex.receive_timeout_for/1`.
  @doc false
  @spec write_result(:ok | {:error, term()}, :ok | {:error, term()}, String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def write_result(:ok, :ok, path) when is_binary(path), do: {:ok, path}

  def write_result({:error, reason}, _closed, path) when is_binary(path) do
    discard_temp(path)
    {:error, {:temp_write_failed, reason}}
  end

  def write_result(:ok, {:error, reason}, path) when is_binary(path) do
    discard_temp(path)
    {:error, {:temp_close_failed, reason}}
  end

  # The write/close failure stays the reason the caller gets back — it is the
  # one that explains the request. A cleanup that itself fails is logged rather
  # than returned, because replacing the real reason with an rm errno would hide
  # it; it is never dropped silently.
  defp discard_temp(path) do
    case File.rm(path) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Could not remove failed temp media file #{path}: #{inspect(reason)}")
        :ok
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
