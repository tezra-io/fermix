defmodule FermixCore.Auth.ChatGPT.IdTokenTest do
  # A local RSA key stands in for OpenAI's; the JWKS request is answered by a
  # Req plug, so nothing leaves the machine.
  use ExUnit.Case, async: true

  alias FermixCore.Auth.ChatGPT.IdToken

  @client "oaiapp_A1"
  @now 1_790_032_532

  setup_all do
    %{key: :public_key.generate_key({:rsa, 2048, 65_537})}
  end

  defp claims(overrides \\ %{}) do
    Map.merge(
      %{
        "iss" => "https://auth.openai.com",
        "aud" => @client,
        "sub" => "user-sub-1",
        "email" => "ada@example.test",
        "iat" => @now,
        "exp" => @now + 3_600,
        "nonce" => "nonce-1"
      },
      overrides
    )
  end

  defp verify(token, key, opts \\ []) do
    IdToken.verify(
      token,
      @client,
      Keyword.merge([nonce: "nonce-1", now: @now, req_options: [plug: jwks_plug(key)]], opts)
    )
  end

  test "a token signed by a published key, for this client, verifies", %{key: key} do
    assert {:ok, %{"sub" => "user-sub-1", "email" => "ada@example.test"}} =
             verify(sign(claims(), key), key)
  end

  test "a list audience holding the client verifies only with a matching azp", %{key: key} do
    listed = claims(%{"aud" => [@client, "other"], "azp" => @client})
    assert {:ok, _claims} = verify(sign(listed, key), key)

    no_azp = claims(%{"aud" => [@client, "other"]})
    assert {:error, :invalid_id_token} = verify(sign(no_azp, key), key)
  end

  for {name, override} <- [
        {"another issuer", %{"iss" => "https://auth.openai.com/"}},
        {"another audience", %{"aud" => "oaiapp_OTHER"}},
        {"a mismatched azp", %{"azp" => "oaiapp_OTHER"}},
        {"an expired token", %{"exp" => @now - 6}},
        {"a token issued in the future", %{"iat" => @now + 6}},
        {"a missing subject", %{"sub" => nil}},
        {"another attempt's nonce", %{"nonce" => "nonce-2"}},
        {"no nonce", %{"nonce" => nil}}
      ] do
    test "#{name} is an invalid id token", %{key: key} do
      token = sign(claims(unquote(Macro.escape(override))), key)
      assert {:error, :invalid_id_token} = verify(token, key)
    end
  end

  test "five seconds of clock skew are allowed", %{key: key} do
    assert {:ok, _claims} =
             verify(sign(claims(%{"exp" => @now - 5, "iat" => @now + 5}), key), key)
  end

  test "a signature by another key is an invalid id token", %{key: key} do
    other = :public_key.generate_key({:rsa, 2048, 65_537})
    assert {:error, :invalid_id_token} = verify(sign(claims(), other), key)
  end

  test "a kid the fresh key set does not hold is an invalid id token", %{key: key} do
    token = sign(claims(), key, %{"kid" => "rotated-away"})
    assert {:error, :invalid_id_token} = verify(token, key)
  end

  test "a token that is not RS256 is refused before any key is fetched", %{key: key} do
    token = sign(claims(), key, %{"alg" => "none"})
    plug = fn _conn -> flunk("no key fetch for an unsupported algorithm") end

    assert {:error, :invalid_id_token} = verify(token, key, req_options: [plug: plug])
  end

  test "a malformed token is an invalid id token", %{key: key} do
    for token <- ["", "a.b", "a.b.c", "not.base64!.x"] do
      assert {:error, :invalid_id_token} = verify(token, key)
    end
  end

  test "keys that cannot be fetched are a verification outage, not a bad token", %{key: key} do
    token = sign(claims(), key)

    down = fn conn -> Plug.Conn.send_resp(conn, 503, "unavailable") end

    assert {:error, :identity_verification_unavailable} =
             verify(token, key, req_options: [plug: down])

    unreachable = fn conn -> Req.Test.transport_error(conn, :econnrefused) end

    assert {:error, :identity_verification_unavailable} =
             verify(token, key, req_options: [plug: unreachable])
  end

  test "subject/1 reads the sub without verifying", %{key: key} do
    assert {:ok, "user-sub-1"} = IdToken.subject(sign(claims(), key))
    assert {:error, :invalid_id_token} = IdToken.subject("garbage")
  end

  defp jwks_plug(key) do
    fn conn ->
      assert conn.method == "GET"
      assert conn.host == "auth.openai.com"
      assert conn.request_path == "/.well-known/jwks.json"
      Req.Test.json(conn, jwks(key))
    end
  end

  defp jwks(key) do
    %{
      "keys" => [
        %{"kty" => "RSA", "kid" => "other-kid", "use" => "sig", "n" => "AQAB", "e" => "AQAB"},
        %{
          "kty" => "RSA",
          "kid" => "kid-1",
          "use" => "sig",
          "alg" => "RS256",
          "n" => b64(:binary.encode_unsigned(elem(key, 2))),
          "e" => b64(:binary.encode_unsigned(elem(key, 3)))
        }
      ]
    }
  end

  defp sign(claims, key, header \\ %{}) do
    header = Map.merge(%{"alg" => "RS256", "typ" => "JWT", "kid" => "kid-1"}, header)
    claims = claims |> Enum.reject(fn {_name, value} -> is_nil(value) end) |> Map.new()
    signed = b64(Jason.encode!(header)) <> "." <> b64(Jason.encode!(claims))
    signed <> "." <> b64(:public_key.sign(signed, :sha256, key))
  end

  defp b64(bytes), do: Base.url_encode64(bytes, padding: false)
end
