defmodule FermixCore.Home.Snapshot.S3.SigV4 do
  @moduledoc """
  AWS Signature Version 4 for one request (the `Authorization` header), as the
  S3 target sends it.

  The canonical request is the method, the path with each segment
  percent-encoded once (S3's rule: every byte but `A-Z a-z 0-9 - _ . ~`, the
  slashes kept), the query sorted by encoded name and value, every header the
  caller passes with its name lowercased and its value trimmed and its inner
  runs of spaces collapsed, sorted by name, the signed header names, and the
  payload's SHA-256 in hex. `x-amz-date`, and `x-amz-security-token` when the
  credentials carry a session token, are added and signed. The key is
  `HMAC("AWS4" <> secret, date)`, then the region, the service and
  `aws4_request`. Pure: the clock is the caller's.
  """

  @algorithm "AWS4-HMAC-SHA256"
  @unreserved ~c"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~"

  @type credentials :: %{
          access_key_id: String.t(),
          secret_access_key: String.t(),
          session_token: String.t() | nil
        }
  @type request :: %{
          method: String.t(),
          path: String.t(),
          query: [{String.t(), String.t()}],
          headers: [{String.t(), String.t()}],
          payload_sha256: String.t()
        }
  @type scope :: %{region: String.t(), service: String.t(), now: DateTime.t()}

  @doc """
  The headers to add to `request` so it is signed: `x-amz-date`,
  `x-amz-security-token` when there is a session token, and `authorization`.
  `request.headers` must already hold every header to be signed, `host`
  included.
  """
  @spec sign(request(), credentials(), scope()) :: [{String.t(), String.t()}]
  def sign(request, credentials, %{now: %DateTime{} = now} = scope) do
    amz_date = Calendar.strftime(DateTime.truncate(now, :second), "%Y%m%dT%H%M%SZ")
    added = [{"x-amz-date", amz_date}] ++ token(credentials)
    headers = canonical_headers(request.headers ++ added)
    signed = Enum.map_join(headers, ";", &elem(&1, 0))
    credential_scope = credential_scope(amz_date, scope)

    signature =
      request
      |> canonical_request(headers, signed)
      |> string_to_sign(amz_date, credential_scope)
      |> signature(credentials.secret_access_key, amz_date, scope)

    authorization =
      "#{@algorithm} Credential=#{credentials.access_key_id}/#{credential_scope}, " <>
        "SignedHeaders=#{signed}, Signature=#{signature}"

    added ++ [{"authorization", authorization}]
  end

  @doc "The canonical request, exposed for the published test vectors."
  @spec canonical_request(request(), [{String.t(), String.t()}], String.t()) :: String.t()
  def canonical_request(request, headers, signed) do
    Enum.join(
      [
        String.upcase(request.method),
        encode_path(request.path),
        canonical_query(request.query),
        Enum.map_join(headers, "", fn {name, value} -> "#{name}:#{value}\n" end),
        signed,
        request.payload_sha256
      ],
      "\n"
    )
  end

  @doc "Percent-encodes a path the S3 way: each segment once, slashes kept."
  @spec encode_path(String.t()) :: String.t()
  def encode_path(""), do: "/"
  def encode_path(path), do: path |> String.split("/") |> Enum.map_join("/", &encode/1)

  @doc "Percent-encodes every byte but the unreserved ones."
  @spec encode(String.t()) :: String.t()
  def encode(value) when is_binary(value),
    do: URI.encode(value, &(&1 in @unreserved))

  defp canonical_query(query) do
    query
    |> Enum.map(fn {name, value} -> {encode(name), encode(value)} end)
    |> Enum.sort()
    |> Enum.map_join("&", fn {name, value} -> "#{name}=#{value}" end)
  end

  defp canonical_headers(headers) do
    headers
    |> Enum.map(fn {name, value} -> {String.downcase(name), trim(value)} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp trim(value), do: value |> String.trim() |> String.replace(~r/ +/, " ")

  defp token(%{session_token: token}) when is_binary(token) and token != "",
    do: [{"x-amz-security-token", token}]

  defp token(_credentials), do: []

  defp credential_scope(amz_date, scope),
    do: "#{binary_part(amz_date, 0, 8)}/#{scope.region}/#{scope.service}/aws4_request"

  defp string_to_sign(canonical, amz_date, credential_scope) do
    Enum.join(
      [@algorithm, amz_date, credential_scope, hex(:crypto.hash(:sha256, canonical))],
      "\n"
    )
  end

  defp signature(string_to_sign, secret, amz_date, scope) do
    ("AWS4" <> secret)
    |> hmac(binary_part(amz_date, 0, 8))
    |> hmac(scope.region)
    |> hmac(scope.service)
    |> hmac("aws4_request")
    |> hmac(string_to_sign)
    |> hex()
  end

  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)
  defp hex(bytes), do: Base.encode16(bytes, case: :lower)
end
