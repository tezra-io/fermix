defmodule FermixCore.Auth.ChatGPT.IdToken do
  @moduledoc """
  Verifies the ID token a ChatGPT sign-in returns (M57 §4.1), with OTP's
  `:public_key` and `:crypto` only.

  The signature is RS256 against OpenAI's published JWKS, fetched for each
  verification: a sign-in verifies one token, so there is no cache to keep
  fresh. The claims must say `iss` exactly `https://auth.openai.com`; `aud` the
  issued client id (or a list holding it, with `azp` naming it); `azp`, when
  present, the client id; `exp`, `iat` and `sub` present, with 5 s of clock
  skew; and the attempt's `nonce`.

  Two failures, kept apart because they mean different things to the person:
  `:identity_verification_unavailable` (the keys could not be fetched; nothing
  is wrong with the account, try again) and `:invalid_id_token` (the token
  itself failed a check). Each is logged with what failed, never the token.
  """

  alias FermixCore.Auth.Redaction
  alias FermixCore.Auth.RefreshClient
  alias FermixCore.Net.Egress

  require Logger

  @issuer "https://auth.openai.com"
  @jwks_url "https://auth.openai.com/.well-known/jwks.json"
  @skew_s 5

  @type claims :: %{optional(String.t()) => term()}
  @type error :: :invalid_id_token | :identity_verification_unavailable

  @doc """
  Verifies `token` for `client_id`. Options: `:nonce` (the attempt's; required
  on a code exchange), `:req_options` (merged into the JWKS request), `:now`
  (Unix seconds; a test seam).
  """
  @spec verify(String.t(), String.t(), keyword()) :: {:ok, claims()} | {:error, error()}
  def verify(token, client_id, opts)
      when is_binary(token) and is_binary(client_id) and is_list(opts) do
    now = Keyword.get_lazy(opts, :now, fn -> System.system_time(:second) end)

    with {:ok, header, claims, signed, signature} <- decode(token),
         :ok <- check(header["alg"] == "RS256", :unsupported_alg),
         {:ok, keys} <- fetch_keys(Keyword.get(opts, :req_options, [])),
         {:ok, key} <- signing_key(keys, header["kid"]),
         :ok <- check(:public_key.verify(signed, :sha256, signature, key), :bad_signature),
         :ok <- check_claims(claims, client_id, Keyword.get(opts, :nonce), now) do
      {:ok, claims}
    end
  end

  @doc """
  The `sub` an ID token names, read without verifying it. Only for a refresh:
  the token arrives straight from the token endpoint over TLS, and a refresh
  holds the profile lock, whose bound has no room for a JWKS fetch. A sign-in
  always uses `verify/3`.
  """
  @spec subject(String.t()) :: {:ok, String.t()} | {:error, :invalid_id_token}
  def subject(token) when is_binary(token) do
    case decode(token) do
      {:ok, _header, %{"sub" => sub}, _signed, _signature} when is_binary(sub) and sub != "" ->
        {:ok, sub}

      _unreadable ->
        invalid(:unreadable_subject)
    end
  end

  defp decode(token) do
    with [header64, claims64, signature64] <- String.split(token, "."),
         {:ok, header} <- decode_json(header64),
         {:ok, claims} <- decode_json(claims64),
         {:ok, signature} <- Base.url_decode64(signature64, padding: false) do
      {:ok, header, claims, header64 <> "." <> claims64, signature}
    else
      _malformed -> invalid(:malformed)
    end
  end

  defp decode_json(part) do
    with {:ok, json} <- Base.url_decode64(part, padding: false) do
      case Jason.decode(json) do
        {:ok, %{} = map} -> {:ok, map}
        _not_an_object -> :error
      end
    end
  end

  defp fetch_keys(req_options) do
    request =
      Req.new(
        [url: @jwks_url, method: :get, headers: [{"accept", "application/json"}]] ++
          RefreshClient.request_bounds()
      )

    case request |> Req.merge(req_options) |> Egress.attach(:direct) |> Req.request() do
      {:ok, %{status: 200, body: %{"keys" => keys}}} when is_list(keys) ->
        {:ok, keys}

      {:ok, %{status: status}} ->
        unavailable("JWKS answered HTTP #{status}")

      {:error, reason} ->
        unavailable("JWKS unreachable: #{Redaction.format(reason)}")
    end
  end

  # The key the token names. A kid the fresh key set does not hold is the
  # token's fault: the set was fetched for this verification.
  defp signing_key(keys, kid) when is_binary(kid) do
    case Enum.find(keys, &(is_map(&1) and &1["kid"] == kid)) do
      nil -> invalid(:unknown_kid)
      jwk -> rsa_key(jwk)
    end
  end

  defp signing_key(_keys, _kid), do: invalid(:missing_kid)

  defp rsa_key(%{"kty" => "RSA", "n" => n, "e" => e} = jwk) when is_binary(n) and is_binary(e) do
    # A modulus under 2048 bits, or an empty exponent, is no key OpenAI
    # publishes; `:public_key` is never handed one.
    with true <- Map.get(jwk, "use", "sig") == "sig",
         {:ok, modulus} when byte_size(modulus) >= 256 <- Base.url_decode64(n, padding: false),
         {:ok, exponent} when exponent != "" <- Base.url_decode64(e, padding: false) do
      {:ok, {:RSAPublicKey, :binary.decode_unsigned(modulus), :binary.decode_unsigned(exponent)}}
    else
      _unusable -> unavailable("JWKS key #{jwk["kid"]} is unusable")
    end
  end

  defp rsa_key(_jwk), do: invalid(:not_an_rsa_key)

  defp check_claims(claims, client_id, nonce, now) do
    with :ok <- check(claims["iss"] == @issuer, :wrong_issuer),
         :ok <- check(audience?(claims, client_id), audience_failure(claims, client_id)),
         :ok <- check(azp?(claims, client_id), :wrong_azp),
         :ok <- check(subject?(claims["sub"]), :missing_subject),
         :ok <- check(unexpired?(claims["exp"], now), :expired),
         :ok <- check(issued?(claims["iat"], now), :bad_iat) do
      check(nonce?(claims["nonce"], nonce), :nonce_mismatch)
    end
  end

  defp audience?(%{"aud" => client_id}, client_id), do: true

  # OpenAI sends a single audience as a one-element list. Only a list that names
  # other parties too needs `azp` to say which of them the token is for (OIDC
  # Core 3.1.3.7).
  defp audience?(%{"aud" => [client_id]}, client_id), do: true

  defp audience?(%{"aud" => audiences, "azp" => client_id}, client_id) when is_list(audiences),
    do: client_id in audiences

  defp audience?(_claims, _client_id), do: false

  # Client ids are public, so a refusal names what the token said and what was
  # expected: an audience mismatch is otherwise undiagnosable from the log.
  defp audience_failure(claims, client_id),
    do:
      "wrong_audience: aud #{inspect(claims["aud"])}, azp #{inspect(claims["azp"])}, " <>
        "expected #{inspect(client_id)}"

  defp azp?(%{"azp" => azp}, client_id), do: azp == client_id
  defp azp?(_claims, _client_id), do: true

  defp subject?(sub), do: is_binary(sub) and sub != ""

  defp unexpired?(exp, now), do: is_integer(exp) and now <= exp + @skew_s
  defp issued?(iat, now), do: is_integer(iat) and iat <= now + @skew_s

  defp nonce?(_claimed, nil), do: true

  defp nonce?(claimed, nonce) when is_binary(claimed),
    do: byte_size(claimed) == byte_size(nonce) and :crypto.hash_equals(claimed, nonce)

  defp nonce?(_claimed, _nonce), do: false

  defp check(true, _failure), do: :ok
  defp check(_false, failure), do: invalid(failure)

  defp invalid(failure) do
    Logger.warning("ChatGPT.IdToken: invalid_id_token (#{failure})")
    {:error, :invalid_id_token}
  end

  defp unavailable(why) do
    Logger.warning("ChatGPT.IdToken: identity_verification_unavailable (#{why})")
    {:error, :identity_verification_unavailable}
  end
end
