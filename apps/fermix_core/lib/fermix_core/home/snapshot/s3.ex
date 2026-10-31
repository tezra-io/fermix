defmodule FermixCore.Home.Snapshot.S3 do
  @moduledoc """
  The S3 target (M75 §8, B8): one `PutObject` per snapshot, to
  `<prefix>/<profile>/<UTC>-e<epoch>.fxsnap` in `s3_bucket`.

  **The request.** SigV4 (`S3.SigV4`), signing `host`, `content-length`,
  `x-amz-content-sha256` (the file's SHA-256, which the snapshot writer
  already computed) and `x-amz-checksum-sha256` (the same digest, base64). The
  body streams from the encrypted file a mebibyte at a time and is never held
  in memory. AWS is addressed virtual-hosted
  (`https://<bucket>.s3.<region>.amazonaws.com`), except a bucket named with
  dots, which S3's wildcard certificate does not cover there and which is
  addressed path-style (`https://s3.<region>.amazonaws.com/<bucket>/<key>`); an
  S3-compatible host named by `s3_endpoint` path-style
  (`<endpoint>/<bucket>/<key>`). The call goes
  through `FermixCore.Net.HttpClient`, so it rides the shared pool and the
  egress proxy (`Net.Egress`) like every other engine call.

  **Verified** means S3 accepted the checksum: a `200` to a request that
  carried it, since S3 refuses a body whose digest differs (`BadDigest`), and,
  when the answer echoes `x-amz-checksum-sha256`, the echo is ours. The
  target never lists, reads or deletes, so an access key that may only
  `PutObject` is enough.

  **One `PUT`.** A single `PutObject` carries up to 5 GiB. A larger snapshot is
  refused by name (`{:too_large, size, max}`) rather than split: multipart
  upload needs three more calls and a second permission story, and a home that
  size is not one this target serves yet.

  **Failures** keep the vendor's own words: a refusal carries S3's `Code` and
  `Message` (`{:refused, status, code, message}`), a transport failure its
  reason, and `sentence/1` puts them into the status sentence.
  """

  @behaviour FermixCore.Home.Snapshot.Target

  alias FermixCore.Home.Snapshot.Config
  alias FermixCore.Home.Snapshot.S3.Credentials
  alias FermixCore.Home.Snapshot.S3.SigV4
  alias FermixCore.Net.HttpClient

  @max_put_bytes 5_368_709_120
  @read_bytes 1_048_576
  @receive_timeout_ms 120_000
  @max_vendor_bytes 300

  @impl true
  def id, do: "s3"

  @impl true
  def label, do: "S3"

  @impl true
  def configured(config) when is_list(config), do: Config.s3(config)

  @impl true
  def destination(settings, opts),
    do: "s3://#{settings.bucket}/#{settings.prefix}/#{profile(opts)}/"

  @doc "The most bytes one `PutObject` carries, and so one snapshot this target stores."
  @spec max_put_bytes() :: pos_integer()
  def max_put_bytes, do: @max_put_bytes

  @doc "The address the `PUT` of the object `key` goes to."
  @spec url(map(), String.t()) :: String.t()
  def url(settings, key) when is_map(settings) and is_binary(key) do
    {base, raw_path} = address(settings, key)
    base <> SigV4.encode_path(raw_path)
  end

  @doc "The object key a snapshot named `name` is stored under."
  @spec key(map(), String.t(), keyword()) :: String.t()
  def key(settings, name, opts), do: "#{settings.prefix}/#{profile(opts)}/#{name}"

  @impl true
  def store(%{path: path, size: size, sha256: sha256, name: name}, settings, opts)
      when is_binary(path) and is_list(opts) do
    with :ok <- within_one_put(size),
         {:ok, credentials} <- Credentials.resolve(settings) do
      key = key(settings, name, opts)

      request =
        request(settings, key, %{path: path, size: size, sha256: sha256}, credentials, opts)

      case HttpClient.request(request, "snapshot S3 upload") do
        {:ok, response} -> answer(response, settings, key, sha256)
        {:error, exception} -> {:error, {:unreachable, Exception.message(exception)}}
      end
    end
  end

  @impl true
  def sentence({:too_large, size, max}),
    do: "The snapshot is #{size} bytes, more than the #{max} one S3 upload carries."

  def sentence({:refused, status, code, message}) do
    said = if String.ends_with?(message, [".", "?", "!"]), do: message, else: message <> "."
    "S3 refused the snapshot (#{status} #{code}): #{said}"
  end

  def sentence({:unreachable, reason}), do: "S3 could not be reached: #{reason}."

  def sentence({:checksum_mismatch, _echoed}),
    do: "S3 answered with another checksum than the snapshot's, so it is not counted as stored."

  def sentence({:keys_missing, key}),
    do: "The S3 access keys are not stored: set `#{key}` and try again."

  def sentence({:secret_unreadable, key, :missing_secret}),
    do: "Nothing is stored as `#{key}`: set it and try again."

  def sentence({:secret_unreadable, key, _reason}),
    do: "The stored `#{key}` could not be read from the secret store; Fermix's log says why."

  def sentence(reason), do: "The S3 upload failed: #{describe(reason)}."

  defp within_one_put(size) when size <= @max_put_bytes, do: :ok
  defp within_one_put(size), do: {:error, {:too_large, size, @max_put_bytes}}

  defp request(settings, key, file, credentials, opts) do
    {base, raw_path} = address(settings, key)
    uri = URI.parse(base)
    checksum = file.sha256 |> Base.decode16!(case: :lower) |> Base.encode64()

    headers = [
      {"host", host(uri)},
      {"content-length", Integer.to_string(file.size)},
      {"x-amz-content-sha256", file.sha256},
      {"x-amz-checksum-sha256", checksum}
    ]

    signed =
      SigV4.sign(
        %{
          method: "PUT",
          path: raw_path,
          query: [],
          headers: headers,
          payload_sha256: file.sha256
        },
        credentials,
        %{region: settings.region, service: "s3", now: now(opts)}
      )

    Req.new(
      method: :put,
      url: base <> SigV4.encode_path(raw_path),
      headers: headers ++ signed,
      body: File.stream!(file.path, @read_bytes),
      retry: false,
      redirect: false,
      decode_body: false,
      compressed: false,
      receive_timeout: @receive_timeout_ms
    )
  end

  # Path-style on an S3-compatible host, virtual-hosted on AWS, and path-style
  # on AWS for a dotted bucket name: `a.b.s3.<region>.amazonaws.com` is not
  # covered by `*.s3.<region>.amazonaws.com`, so TLS would refuse it.
  defp address(%{endpoint: endpoint, bucket: bucket}, key) when is_binary(endpoint),
    do: {endpoint, "/#{bucket}/#{key}"}

  defp address(%{bucket: bucket, region: region}, key) do
    if String.contains?(bucket, "."),
      do: {"https://s3.#{region}.amazonaws.com", "/#{bucket}/#{key}"},
      else: {"https://#{bucket}.s3.#{region}.amazonaws.com", "/#{key}"}
  end

  defp host(%URI{host: host, port: port, scheme: scheme}) do
    if {scheme, port} in [{"https", 443}, {"http", 80}], do: host, else: "#{host}:#{port}"
  end

  defp answer(%Req.Response{status: 200} = response, settings, key, sha256) do
    ours = sha256 |> Base.decode16!(case: :lower) |> Base.encode64()

    case Req.Response.get_header(response, "x-amz-checksum-sha256") do
      [] -> {:ok, %{location: "s3://#{settings.bucket}/#{key}"}}
      [^ours | _rest] -> {:ok, %{location: "s3://#{settings.bucket}/#{key}"}}
      [echoed | _rest] -> {:error, {:checksum_mismatch, echoed}}
    end
  end

  defp answer(%Req.Response{status: status, body: body}, _settings, _key, _sha256) do
    {:error,
     {:refused, status, xml_field(body, "Code") || "no code", vendor_message(body, status)}}
  end

  defp vendor_message(body, status) do
    case xml_field(body, "Message") do
      nil -> "it answered HTTP #{status} with no message."
      message -> message
    end
  end

  # S3 answers an error as a small XML document; its `Code` and `Message` are
  # the vendor's own words, bounded and unescaped, and nothing else is read.
  defp xml_field(body, tag) when is_binary(body) do
    case Regex.run(~r/<#{tag}>([^<]{1,2048})<\/#{tag}>/, body, capture: :all_but_first) do
      [value] -> value |> unescape() |> String.trim() |> bounded()
      nil -> nil
    end
  end

  defp xml_field(_body, _tag), do: nil

  defp unescape(text) do
    text
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&apos;", "'")
    |> then(
      &Regex.replace(~r/&#(x[0-9A-Fa-f]{1,6}|[0-9]{1,7});/, &1, fn _all, code ->
        character(code)
      end)
    )
    |> String.replace("&amp;", "&")
  end

  # A numeric character reference (MinIO writes `&#39;`); one that names no
  # printable character is dropped.
  defp character("x" <> hex), do: hex |> String.to_integer(16) |> printable()
  defp character(decimal), do: decimal |> String.to_integer() |> printable()

  defp printable(code)
       when code in 0x20..0x7E or code in 0xA0..0xD7FF or code in 0xE000..0x10FFFF,
       do: <<code::utf8>>

  defp printable(_code), do: ""

  defp bounded(text) when byte_size(text) <= @max_vendor_bytes, do: text
  defp bounded(text), do: String.slice(text, 0, @max_vendor_bytes) <> "…"

  defp profile(opts), do: Keyword.get_lazy(opts, :profile, &current_profile/0)

  defp current_profile do
    case Application.get_env(:fermix_core, :profile) do
      profile when is_binary(profile) and profile != "" -> profile
      _unset -> "general"
    end
  end

  defp now(opts), do: Keyword.get(opts, :now, &DateTime.utc_now/0).()

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason) when is_atom(reason), do: posix(reason, :file.format_error(reason))
  defp describe(reason), do: inspect(reason)

  # A POSIX code reads as its words; any other atom is a literal, backticked.
  defp posix(reason, ~c"unknown POSIX error" ++ _rest), do: "`#{reason}`"
  defp posix(_reason, words), do: List.to_string(words)
end
