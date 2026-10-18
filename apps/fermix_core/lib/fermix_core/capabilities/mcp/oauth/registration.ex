defmodule FermixCore.Capabilities.MCP.OAuth.Registration do
  @moduledoc """
  Which client signs in to an MCP server's authorization server (M74 §3, E5,
  D6), in the order the MCP authorization specification gives:

    1. **The owner's client**: the server's `oauth_client_id`, with
       `mcp:<name>/client_secret` when one is stored, sent the way the
       authorization server's `token_endpoint_auth_methods_supported` allows
       (`client_secret_basic`, then `client_secret_post`, then `none`).
    2. **Fermix's Client ID Metadata Document**, where the metadata says
       `client_id_metadata_document_supported`: the `client_id` is the HTTPS
       URL that serves it (`@client_id`), and its bytes are
       `priv/oauth/mcp-client.json`, which the site serves.
    3. **Dynamic Client Registration** (RFC 7591) at `registration_endpoint`,
       with `application_type: "native"` and the document's own metadata. The
       client it issues is kept with the server's grant, under the issuer, and
       the next sign-in to that issuer uses it again.

  Every client is public to the authorization server unless it holds a
  secret: the document and a registration ask for `none`, and a loopback
  redirect whose port the listener chooses (RFC 8252 §7.3).
  """

  alias FermixCore.Capabilities.MCP.OAuth.Http
  alias FermixCore.Capabilities.MCP.Secrets, as: McpSecrets

  require Logger

  @client_id "https://fermix.ai/oauth/mcp-client.json"
  @redirect_host "127.0.0.1"
  @redirect_path "/callback"
  # What Fermix says of itself, in the document and in every registration.
  @metadata %{
    "client_name" => "Fermix",
    "client_uri" => "https://fermix.ai",
    "redirect_uris" => ["http://#{@redirect_host}#{@redirect_path}"],
    "grant_types" => ["authorization_code", "refresh_token"],
    "response_types" => ["code"],
    "token_endpoint_auth_method" => "none",
    "application_type" => "native"
  }
  @secret_methods ["client_secret_basic", "client_secret_post"]
  @max_client_id_bytes 1_024

  @type kind :: :owner | :metadata_document | :registered
  @type client :: %{
          id: String.t(),
          secret: String.t() | nil,
          auth: String.t(),
          kind: kind()
        }

  @doc "The `client_id` of Fermix's Client ID Metadata Document: the URL that serves it."
  @spec client_id() :: String.t()
  def client_id, do: @client_id

  @doc "The Client ID Metadata Document, as the site serves it."
  @spec document() :: map()
  def document, do: Map.put(@metadata, "client_id", @client_id)

  @doc "The loopback host and path every redirect names; the listener picks the port."
  @spec redirect() :: {String.t(), String.t()}
  def redirect, do: {@redirect_host, @redirect_path}

  @doc """
  The client for a sign-in to `server` at the authorization server `metadata`
  describes. `registered` is the client an earlier registration with the same
  issuer issued, or `nil`.
  """
  @spec client(map(), map(), client() | nil, integer(), keyword()) ::
          {:ok, client()} | {:error, term()}
  def client(server, metadata, registered, deadline, opts \\ []) do
    cond do
      is_binary(server.oauth_client_id) ->
        owner_client(server, metadata)

      metadata.client_id_metadata_document? ->
        {:ok, public(@client_id, :metadata_document)}

      registered != nil ->
        {:ok, registered}

      is_binary(metadata.registration_endpoint) ->
        register(metadata.registration_endpoint, deadline, opts)

      true ->
        {:error, :no_client_registration}
    end
  end

  @doc "The client secret a refresh sends: the owner's from the secret store, or the one registration issued."
  @spec secret(String.t(), client()) :: String.t() | nil
  def secret(server_name, %{kind: :owner}), do: owner_secret(server_name)
  def secret(_server_name, %{secret: secret}), do: secret

  defp owner_client(server, metadata) do
    secret = owner_secret(server.name)

    case auth_method(secret, metadata.token_auth_methods) do
      nil -> {:error, :unsupported_client_auth}
      auth -> {:ok, %{id: server.oauth_client_id, secret: secret, auth: auth, kind: :owner}}
    end
  end

  defp owner_secret(name) do
    case McpSecrets.fetch(name, :client_secret) do
      {:ok, secret} -> secret
      {:error, _absent} -> nil
    end
  end

  defp auth_method(nil, _methods), do: "none"
  defp auth_method(_secret, methods), do: Enum.find(@secret_methods ++ ["none"], &(&1 in methods))

  defp public(id, kind), do: %{id: id, secret: nil, auth: "none", kind: kind}

  defp register(endpoint, deadline, opts) do
    headers = [{"content-type", "application/json"}, {"accept", "application/json"}]
    body = Jason.encode!(@metadata)

    case Http.request("POST", endpoint, headers, body, deadline, opts) do
      {:ok, %{status: status} = response} when status in 200..299 ->
        registered(Http.document(response))

      {:ok, response} ->
        refused(response)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # RFC 7591 §3.2.1: the server answers what it registered. A method it chose
  # over `none` is followed, with the secret it issued for it.
  defp registered(%{"client_id" => id} = answer)
       when is_binary(id) and byte_size(id) in 1..@max_client_id_bytes do
    auth = Map.get(answer, "token_endpoint_auth_method", "none")
    secret = answer["client_secret"]

    cond do
      auth == "none" ->
        {:ok, public(id, :registered)}

      auth in @secret_methods and is_binary(secret) ->
        {:ok, %{id: id, secret: secret, auth: auth, kind: :registered}}

      true ->
        {:error, :unsupported_client_auth}
    end
  end

  defp registered(_answer), do: {:error, {:client_registration_refused, :invalid_answer}}

  defp refused(response) do
    code = response.body |> Http.object() |> error_code()

    Logger.warning(
      "MCP sign-in: the client registration was refused (#{response.status}, #{code})"
    )

    {:error, {:client_registration_refused, response.status}}
  end

  defp error_code(%{"error" => code}) when is_binary(code) do
    if Regex.match?(~r/\A[a-z0-9_.]{1,64}\z/, code), do: code, else: "unknown"
  end

  defp error_code(_answer), do: "none"
end
