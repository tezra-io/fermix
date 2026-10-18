defmodule FermixCore.Capabilities.MCP.OAuth.Token do
  @moduledoc """
  The token endpoint of an MCP server's authorization server (M74 E5): the
  code exchange and the refresh, each one form `POST` through `OAuth.Http`.

  Both name the `resource` the grant is for (RFC 8707 §2.2), and the client
  authenticates the way its registration chose (RFC 6749 §2.3.1):
  `client_secret_basic` (an HTTP Basic header of the form-encoded id and
  secret), `client_secret_post` (both in the form), or `none` (the id alone).

  An answer the server refused (any `4xx`, or a `200` that is not a bearer
  token) is `{:error, {:token_refused, code}}`, the code being its OAuth
  `error` when that is a short identifier: the grant behind it is spent.
  Anything else (unreachable, a `5xx`) is not a refusal, and the grant
  stands.
  """

  alias FermixCore.Capabilities.MCP.OAuth.Http
  alias FermixCore.Capabilities.MCP.OAuth.Registration

  @vendor_code ~r/\A[a-z0-9_.]{1,64}\z/

  @type tokens :: %{
          access_token: String.t(),
          refresh_token: String.t() | nil,
          id_token: String.t() | nil,
          scope: String.t() | nil,
          expires_at: DateTime.t() | nil
        }

  @doc "Spends an authorization code."
  @spec exchange(String.t(), Registration.client(), map(), integer(), keyword()) ::
          {:ok, tokens()} | {:error, term()}
  def exchange(
        endpoint,
        client,
        %{code: code, verifier: verifier, redirect_uri: redirect_uri, resource: resource},
        deadline,
        opts \\ []
      ) do
    form = %{
      "grant_type" => "authorization_code",
      "code" => code,
      "redirect_uri" => redirect_uri,
      "code_verifier" => verifier,
      "resource" => resource
    }

    post(endpoint, client, form, deadline, opts)
  end

  @doc "Spends a refresh token for a new access token."
  @spec refresh(String.t(), Registration.client(), String.t(), String.t(), integer(), keyword()) ::
          {:ok, tokens()} | {:error, term()}
  def refresh(endpoint, client, refresh_token, resource, deadline, opts \\ []) do
    form = %{
      "grant_type" => "refresh_token",
      "refresh_token" => refresh_token,
      "resource" => resource
    }

    post(endpoint, client, form, deadline, opts)
  end

  defp post(endpoint, client, form, deadline, opts) do
    {headers, form} = authenticate(client, form)

    headers = [
      {"content-type", "application/x-www-form-urlencoded"},
      {"accept", "application/json"} | headers
    ]

    case Http.request("POST", endpoint, headers, URI.encode_query(form), deadline, opts) do
      {:ok, %{status: 200, body: body}} -> parse(Http.object(body))
      {:ok, %{status: status, body: body}} when status in 400..499 -> refused(Http.object(body))
      {:ok, %{status: status}} -> {:error, {:remote_http_error, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp authenticate(%{auth: "client_secret_basic", id: id, secret: secret}, form) do
    credentials = Base.encode64(form_encode(id) <> ":" <> form_encode(secret))
    {[{"authorization", "Basic " <> credentials}], form}
  end

  defp authenticate(%{auth: "client_secret_post", id: id, secret: secret}, form),
    do: {[], Map.merge(form, %{"client_id" => id, "client_secret" => secret})}

  defp authenticate(%{id: id}, form), do: {[], Map.put(form, "client_id", id)}

  defp form_encode(value), do: URI.encode_www_form(value)

  defp parse(%{"access_token" => access} = answer) when is_binary(access) and access != "" do
    if bearer?(answer["token_type"]) do
      {:ok,
       %{
         access_token: access,
         refresh_token: text(answer["refresh_token"]),
         id_token: text(answer["id_token"]),
         scope: text(answer["scope"]),
         expires_at: expires_at(answer["expires_in"])
       }}
    else
      {:error, {:token_refused, "unsupported_token_type"}}
    end
  end

  defp parse(_answer), do: {:error, {:token_refused, "invalid_token_response"}}

  # RFC 6749 §7.1: the type is matched without case. One that is absent is
  # taken for the bearer the request asked for.
  defp bearer?(nil), do: true
  defp bearer?(type) when is_binary(type), do: String.downcase(type) == "bearer"
  defp bearer?(_type), do: false

  defp expires_at(seconds) when is_integer(seconds) and seconds > 0,
    do: DateTime.add(DateTime.utc_now(), seconds, :second)

  defp expires_at(_absent), do: nil

  defp refused(%{"error" => code}) when is_binary(code) do
    {:error, {:token_refused, if(Regex.match?(@vendor_code, code), do: code, else: "unknown")}}
  end

  defp refused(_answer), do: {:error, {:token_refused, "unknown"}}

  defp text(value) when is_binary(value) and value != "", do: value
  defp text(_value), do: nil
end
