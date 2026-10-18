defmodule FermixCore.Capabilities.MCP.OAuth.Http do
  @moduledoc """
  One request of an MCP server's sign-in (M74 E5), on the remote rail.

  Every address a sign-in reaches (the server itself, its protected resource
  metadata, its authorization server's metadata, registration and token
  endpoints, and its userinfo endpoint) is one the server named, so each
  goes through the rule the server's own URL went through: `Endpoint.operator/1`
  (`https`, or `http` only to this machine) and `Net.Guard`'s owner policy,
  dialled pinned by `Remote.Connection`. No redirect is followed, as on the
  rest of the rail: a 3xx answers `{:remote_security_blocked,
  {:redirect_refused, status}}`. TLS verification is the rail's.

  Each answer is bounded in bytes while it streams (`@max_body_bytes`: these
  are small documents) and in time by the caller's `deadline`, a monotonic
  millisecond instant every request of one step shares, each request taking
  at most `@max_request_ms` of it.
  """

  alias FermixCore.Capabilities.MCP.Remote.Connection
  alias FermixCore.Capabilities.MCP.Remote.Endpoint
  alias FermixCore.Capabilities.MCP.Remote.Json

  @max_body_bytes 256 * 1024
  @max_request_ms 10_000
  @max_json_depth 16

  @type response :: %{
          status: non_neg_integer(),
          headers: [{String.t(), String.t()}],
          body: binary()
        }

  @doc "A deadline `budget_ms` from now, for the requests of one step."
  @spec deadline(pos_integer()) :: integer()
  def deadline(budget_ms) when is_integer(budget_ms) and budget_ms > 0,
    do: System.monotonic_time(:millisecond) + budget_ms

  @doc """
  Sends one request to `url` and reads its answer. `:stop` is the
  connection's (`:first_event` for a request whose answer may be a stream
  that never ends). `opts` may carry `:connect_opts` for the connection.
  """
  @spec request(
          String.t(),
          String.t(),
          [{String.t(), String.t()}],
          binary() | nil,
          integer(),
          keyword()
        ) ::
          {:ok, response()} | {:error, term()}
  def request(method, url, headers, body, deadline, opts \\ []) when is_binary(url) do
    with {:ok, endpoint} <- endpoint(url),
         {:ok, budget} <- budget(deadline),
         {:ok, connection} <- Connection.open(endpoint, connect_opts(opts, budget)) do
      exchange(connection, method, headers, body, budget, opts)
    end
  end

  @doc "GETs a JSON document: `{:ok, status, document}`, the document `nil` unless a 2xx answered one."
  @spec get_json(String.t(), [{String.t(), String.t()}], integer(), keyword()) ::
          {:ok, non_neg_integer(), map() | nil} | {:error, term()}
  def get_json(url, headers, deadline, opts \\ []) do
    with {:ok, response} <-
           request("GET", url, [{"accept", "application/json"} | headers], nil, deadline, opts) do
      {:ok, response.status, document(response)}
    end
  end

  @doc "The JSON object a 2xx answer carries, or `nil`."
  @spec document(response()) :: map() | nil
  def document(%{status: status, body: body}) when status in 200..299, do: object(body)
  def document(_response), do: nil

  @doc "The JSON object an answer's body holds, whatever its status, or `nil`."
  @spec object(binary()) :: map() | nil
  def object(body) when is_binary(body) do
    case Json.decode(body, max_bytes: @max_body_bytes, max_depth: @max_json_depth) do
      {:ok, %{} = object} -> object
      _other -> nil
    end
  end

  @doc "Whether `url` passes the rule every address of a sign-in passes."
  @spec allowed_url?(term()) :: boolean()
  def allowed_url?(url) when is_binary(url), do: match?({:ok, _endpoint}, Endpoint.operator(url))
  def allowed_url?(_url), do: false

  defp endpoint(url) do
    case Endpoint.operator(url) do
      {:ok, endpoint} -> {:ok, endpoint}
      {:error, reason} -> {:error, {:invalid_remote_config, reason}}
    end
  end

  defp budget(deadline) do
    case deadline - System.monotonic_time(:millisecond) do
      left when left > 0 -> {:ok, min(left, @max_request_ms)}
      _spent -> {:error, {:remote_unreachable, :sign_in_deadline}}
    end
  end

  defp connect_opts(opts, budget),
    do: Keyword.put(Keyword.get(opts, :connect_opts, []), :connect_timeout_ms, budget)

  defp exchange(connection, method, headers, body, budget, opts) do
    request_opts = [stop: Keyword.get(opts, :stop, :done), max_bytes: @max_body_bytes]

    case Connection.request(connection, method, headers, body, budget, request_opts) do
      {:ok, connection, response} ->
        Connection.close(connection)
        {:ok, %{status: response.status, headers: response.headers, body: raw(response.body)}}

      {:error, connection, reason} ->
        Connection.close(connection)
        {:error, reason}
    end
  end

  defp raw({:json, raw}), do: raw
  defp raw({:empty, raw}), do: raw
  defp raw({:sse, _events}), do: ""
end
