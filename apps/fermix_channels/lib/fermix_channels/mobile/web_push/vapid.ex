defmodule FermixChannels.Mobile.WebPush.Vapid do
  @moduledoc """
  The home's signature on a Web Push request (VAPID, RFC 8292). Pure.

  `authorization/4` returns the `Authorization` header value

      vapid t=<JWT>, k=<the public key, base64url without padding>

  The JWT's header is `{"typ":"JWT","alg":"ES256"}` and its claims, in this
  order, are `aud` (the push service's origin, `audience/1`), `exp` (twelve
  hours after the time given; RFC 8292 allows at most 24) and `sub`
  (`https://fermix.ai`). The signature is ECDSA P-256 over SHA-256 in the JWS
  form: `r || s`, 32 bytes each, base64url without padding.

  The key pair is checked before signing: a public key that is not the
  private key's would have every request refused with 401 or 403, and a
  refused sender is a reason to drop a phone's subscription.
  """

  @lifetime_s 12 * 60 * 60
  @subject "https://fermix.ai"
  @jwt_header ~s({"typ":"JWT","alg":"ES256"})

  # P-256's group order: a private scalar is 1..n-1.
  @n 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551
  @host_name ~r/\A[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*\z/

  @type error :: :invalid_private_key | :key_mismatch | :invalid_audience | :invalid_time

  @doc "The `Authorization` header value for a request to `audience` at `now_unix`."
  @spec authorization(
          private :: <<_::256>>,
          public :: <<_::520>>,
          audience :: String.t(),
          now_unix :: integer()
        ) :: {:ok, String.t()} | {:error, error()}
  def authorization(private, public, audience, now_unix)
      when is_binary(private) and is_binary(public) and is_binary(audience) and
             is_integer(now_unix) do
    with {:ok, ^public} <- matching_public(private, public),
         :ok <- valid_audience(audience),
         :ok <- valid_time(now_unix) do
      token = sign(private, claims(audience, now_unix))
      {:ok, "vapid t=#{token}, k=#{base64url(public)}"}
    end
  end

  @doc """
  The uncompressed P-256 point (65 bytes) of a 32-byte private scalar, or
  `:invalid_private_key` for one outside 1..n-1.
  """
  @spec public_key(binary()) :: {:ok, <<_::520>>} | {:error, :invalid_private_key}
  def public_key(<<scalar::256>> = private) when scalar >= 1 and scalar < @n do
    {<<4, _point::binary-64>> = public, _private} =
      :crypto.generate_key(:ecdh, :secp256r1, private)

    {:ok, public}
  end

  def public_key(private) when is_binary(private), do: {:error, :invalid_private_key}

  @doc """
  The origin a JWT's `aud` names for a push endpoint: `https://` and the host,
  with the port only when it is not 443. Only an https URL with a host name
  and no user part is accepted.
  """
  @spec audience(url :: String.t()) :: {:ok, String.t()} | {:error, :invalid_endpoint}
  def audience(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: "https", userinfo: nil, host: host, port: port}} when is_binary(host) ->
        origin(String.downcase(host), port)

      _other ->
        {:error, :invalid_endpoint}
    end
  end

  defp origin(host, port) do
    cond do
      not Regex.match?(@host_name, host) -> {:error, :invalid_endpoint}
      port == 443 -> {:ok, "https://" <> host}
      true -> {:ok, "https://#{host}:#{port}"}
    end
  end

  defp matching_public(private, public) do
    case public_key(private) do
      {:ok, ^public} -> {:ok, public}
      {:ok, _other} -> {:error, :key_mismatch}
      {:error, _reason} = error -> error
    end
  end

  # The audience is accepted only as `audience/1` would write it.
  defp valid_audience(audience) do
    case audience(audience) do
      {:ok, ^audience} -> :ok
      _other -> {:error, :invalid_audience}
    end
  end

  defp valid_time(now_unix) when now_unix >= 0, do: :ok
  defp valid_time(_now_unix), do: {:error, :invalid_time}

  defp claims(audience, now_unix) do
    Jason.encode!(
      Jason.OrderedObject.new([
        {"aud", audience},
        {"exp", now_unix + @lifetime_s},
        {"sub", @subject}
      ])
    )
  end

  defp sign(private, claims) do
    signing_input = base64url(@jwt_header) <> "." <> base64url(claims)
    der = :crypto.sign(:ecdsa, :sha256, signing_input, [private, :secp256r1])
    {:"ECDSA-Sig-Value", r, s} = :public_key.der_decode(:"ECDSA-Sig-Value", der)
    signing_input <> "." <> base64url(<<r::256, s::256>>)
  end

  defp base64url(bytes), do: Base.url_encode64(bytes, padding: false)
end
