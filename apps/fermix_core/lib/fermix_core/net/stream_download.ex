defmodule FermixCore.Net.StreamDownload do
  @moduledoc """
  Streaming file download + streaming SHA-256 verification.

  Lifted out of `Fermix.CLI.Upgrade.Swapper` so the binary-upgrade path and the
  plugin-distribution fetcher share one implementation: download a URL straight
  to disk via `Req`'s `into: File.stream!` (never buffering the whole artifact
  in memory), and verify a file's SHA-256 by streaming it in 64 KB chunks. Both
  are deterministic and fail loud — a non-200 status or a hash mismatch returns
  an error tuple, never a partial success.
  """

  @chunk_bytes 64 * 1024
  # Idle cap: fail a stalled/dead connection rather than holding the plugin
  # store lock (and an open socket) indefinitely. Bounds *idle* time between
  # received bytes, so a slow-but-progressing download is not killed.
  # `req_options` can override it.
  @receive_timeout_ms 60_000

  @doc """
  Stream a URL to `path`. `req_options` are merged into (and override) the
  `Req.get/2` call (tests pass `plug:` for in-process stubbing). Only HTTP 200
  is success.
  """
  @spec download(String.t(), Path.t(), keyword()) :: :ok | {:error, term()}
  def download(url, path, req_options \\ [])
      when is_binary(url) and is_binary(path) and is_list(req_options) do
    base = [raw: true, into: File.stream!(path), receive_timeout: @receive_timeout_ms]

    case Req.get(url, base ++ req_options) do
      {:ok, %Req.Response{status: 200}} -> :ok
      {:ok, %Req.Response{status: status}} -> {:error, {:download_status, status, url}}
      {:error, reason} -> {:error, {:download_failed, reason, url}}
    end
  end

  @doc """
  Stream `path` in #{div(@chunk_bytes, 1024)} KB chunks and compare its
  lowercase-hex SHA-256 against `expected_hex` (case-insensitive).
  """
  @spec check_sha256(Path.t(), String.t()) :: :ok | {:error, term()}
  def check_sha256(path, expected_hex) when is_binary(path) and is_binary(expected_hex) do
    actual =
      path |> File.stream!([], @chunk_bytes) |> hash_stream() |> Base.encode16(case: :lower)

    if actual == String.downcase(expected_hex) do
      :ok
    else
      {:error, {:sha256_mismatch, expected: expected_hex, actual: actual}}
    end
  end

  defp hash_stream(stream) do
    stream
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
  end
end
