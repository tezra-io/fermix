defmodule FermixCore.PhoneCalls.OpenAILive do
  @moduledoc """
  The GPT-Live SIP session adapter: the one request that places an outbound
  call, and the hangup control that ends one. The sideband, its events and the
  in-call controls are `OpenAILive.Sideband`, `OpenAILive.Events` and
  `OpenAILive.Controls`.

  Every wire shape here is from OpenAI's pages: *Telephony and SIP*, the
  *Create Live session* reference, *Usage and graceful close*, *Server-side
  controls* and the *Sideband WebSocket* reference.

  ## Creating the call

  `create_session/2` sends one `POST /v1/live/sessions` through
  `Net.HttpClient.request_once/3`, which never retries, never follows a
  redirect and says whether the request provably never left. Each SIP create
  places a new call and the vendor documents no idempotency key, so nothing in
  this path ever sends it twice. The body is the session (`model`,
  `instructions`, `input`, `audio.output.voice`, `delegation: client`,
  `store: false`) and the SIP transport (`destination` and the trunk's
  `provider_url`, digest `auth` and `caller_number`). There is no
  `audio.format`: SIP negotiates it.

  Its result is one of four, and they are the only ones:

    * `{:ok, %{session_id: id, http_status: 200 | 201, transport_type: type}}`
      — a documented success status carrying a session id, the id returned
      exactly as sent. The *Telephony and SIP* guide shows `200`, the create
      reference `201`; both are accepted. Success means the session exists and
      a call is being placed, never that anyone answered.
    * `{:error, {:rejected, status, vendor}}` — the vendor refused the request:
      a 4xx (429 included) or a 5xx other than 504. `vendor` is
      `%{message, code, type}` in the vendor's own words.
    * `{:error, {:not_sent, reason}}` — the request provably never left: an
      argument that fails the documented shape (`{:invalid, field}`, never the
      value), a sideband route the proxy would carry
      (`:proxy_unsupported_transport`, refused before dialing because the call
      could not be controlled), a refused connection, a name that does not
      resolve, or no pooled connection.
    * `{:error, {:unknown, reason}}` — anything else: a timeout, a closed
      connection, a 504 (documented as an initialization timeout), a success
      status without a session id, an unexpected status. The call may exist.

  ## Ending the call

  `hangup/2` sends `POST /v1/live/sessions/{id}/hangup` with no body, once.
  The vendor documents `200 OK` with an empty body as success and documents
  nothing about a second hangup or a hangup of an ended session; see
  `hangup/2` for how those are read.

  ## Credentials

  The create body carries the trunk's password and the headers the API key.
  Nothing in this adapter logs a body or a header, and vendor text returned to
  the caller has both secrets scrubbed from it. `redact/1` is the one function
  that makes a create body or a header list safe to log, trace or capture.
  """

  alias FermixCore.Net.Egress
  alias FermixCore.Net.HttpClient
  alias FermixCore.PhoneCalls.OpenAILive.Sideband

  @api_base_url "https://api.openai.com"
  @sessions_path "/v1/live/sessions"
  # Create answers once the session initializes and before anyone answers; the
  # vendor's own initialization timeout (its 504) is undocumented in length.
  # Past this the call may exist, so it is generous.
  @create_receive_timeout_ms 60_000
  @hangup_receive_timeout_ms 15_000
  @vendor_text_limit 1_000
  @redacted "[REDACTED]"

  @e164 ~r/\A\+[1-9][0-9]{1,14}\z/
  # `sips:host[:port][;transport=tcp]`: no userinfo, path, headers or other
  # parameters (create reference).
  @provider_url ~r/\Asips:[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?(?::\d{1,5})?(?:;transport=tcp)?\z/
  @max_username_bytes 256
  @max_password_bytes 4_096
  @max_input_items 128
  @max_session_id_bytes 512

  @type trunk :: %{
          provider_url: String.t(),
          username: String.t(),
          password: String.t(),
          caller_number: String.t()
        }

  @type create_request :: %{
          api_key: String.t(),
          model: String.t(),
          instructions: String.t(),
          input: [map()],
          voice: String.t(),
          destination: String.t(),
          trunk: trunk()
        }

  @type vendor :: %{
          message: String.t() | nil,
          code: String.t() | nil,
          type: String.t() | nil
        }

  @type created :: %{
          session_id: String.t(),
          http_status: 200 | 201,
          transport_type: String.t() | nil
        }

  @type create_result ::
          {:ok, created()}
          | {:error, {:rejected, pos_integer(), vendor()}}
          | {:error, {:not_sent, term()}}
          | {:error, {:unknown, term()}}

  @type hangup_result ::
          {:ok, :accepted}
          | {:ok, {:already_ended, pos_integer(), vendor()}}
          | {:error, {:rejected, pos_integer(), vendor()}}
          | {:error, {:not_sent, term()}}
          | {:error, {:unknown, term()}}

  @doc "The production API origin."
  @spec api_base_url() :: String.t()
  def api_base_url, do: @api_base_url

  @doc """
  Places one outbound call: creates the Live session with the SIP transport.

  `request` is every input, explicit (see `t:create_request/0`); nothing is
  read from configuration. `opts`:

    * `:base_url` — the API origin, default `api_base_url/0`.
    * `:ws_base_url` — the sideband origin, default `Sideband.ws_base_url/0`,
      checked against the egress route before anything is sent.
    * `:egress` — default `Egress.active/0`.

  See the module doc for the four results. There is no retry anywhere in this
  path, and no result here means the call was answered.
  """
  @spec create_session(create_request(), keyword()) :: create_result()
  def create_session(%{} = request, opts) when is_list(opts) do
    egress = egress(opts)

    with :ok <- validate_request(request),
         :ok <- sideband_route(ws_base_url(opts), egress) do
      request
      |> create_req(Keyword.get(opts, :base_url, @api_base_url))
      |> HttpClient.request_once("openai_live_sip_create", egress)
      |> classify_create(secrets(request))
    end
  end

  @doc """
  The create body for `request`, as JSON-ready maps. Pure. It carries the trunk
  password: pass it through `redact/1` before it goes anywhere but the wire.
  """
  @spec create_body(create_request()) :: map()
  def create_body(%{trunk: %{} = trunk} = request) do
    session = %{
      "model" => request.model,
      "instructions" => request.instructions,
      "audio" => %{"output" => %{"voice" => request.voice}},
      "delegation" => %{"type" => "client"},
      "store" => false
    }

    %{
      "session" => put_input(session, request.input),
      "transport" => %{
        "type" => "sip",
        "destination" => request.destination,
        "trunk" => %{
          "provider_url" => trunk.provider_url,
          "auth" => %{
            "type" => "digest",
            "username" => trunk.username,
            "password" => trunk.password
          },
          "caller_number" => trunk.caller_number
        }
      }
    }
  end

  @doc """
  Reads one `request_once/3` result for a create. Pure; `secrets` are scrubbed
  from any vendor text kept. Public so every branch has a fixture.
  """
  @spec classify_create(
          {:ok, Req.Response.t()} | {:error, {:not_sent | :unknown, Exception.t()}},
          [String.t()]
        ) :: create_result()
  def classify_create({:ok, %Req.Response{status: status} = response}, secrets)
      when status in [200, 201] and is_list(secrets) do
    case decode(response.body) do
      {:ok, %{"session" => %{"id" => id}} = body} when is_binary(id) and id != "" ->
        {:ok, %{session_id: id, http_status: status, transport_type: transport_type(body)}}

      _no_id ->
        {:error, {:unknown, {:success_without_session_id, status}}}
    end
  end

  def classify_create({:ok, %Req.Response{status: 504} = response}, secrets)
      when is_list(secrets),
      do: {:error, {:unknown, {:http_status, 504, vendor(response, secrets)}}}

  def classify_create({:ok, %Req.Response{status: status} = response}, secrets)
      when status in 400..599 and is_list(secrets),
      do: {:error, {:rejected, status, vendor(response, secrets)}}

  def classify_create({:ok, %Req.Response{status: status}}, secrets) when is_list(secrets),
    do: {:error, {:unknown, {:unexpected_status, status}}}

  def classify_create({:error, {:not_sent, error}}, secrets) when is_list(secrets),
    do: {:error, {:not_sent, transport_reason(error)}}

  def classify_create({:error, {:unknown, error}}, secrets) when is_list(secrets),
    do: {:error, {:unknown, transport_reason(error)}}

  @doc """
  Ends the call through the documented hangup control: one
  `POST /v1/live/sessions/{session_id}/hangup` with no body, never retried.

  `opts`: `:api_key` (required), `:base_url` (default `api_base_url/0`),
  `:egress` (default `Egress.active/0`).

    * `{:ok, :accepted}` — a 2xx; the vendor documents `200` with an empty body.
    * `{:ok, {:already_ended, status, vendor}}` — a 404, 409 or 410: the vendor
      says there is nothing to hang up. Not a documented contract: OpenAI
      documents neither a second hangup nor a hangup of an ended session, so
      this reading is an assumption for the live proof, and it is not evidence
      that the call ended.
    * `{:error, {:rejected, status, vendor}}` — any other 4xx or 5xx but 504.
    * `{:error, {:not_sent, reason}}` / `{:error, {:unknown, reason}}` — as for
      create; a 504 is unknown.
  """
  @spec hangup(String.t(), keyword()) :: hangup_result()
  def hangup(session_id, opts) when is_binary(session_id) and is_list(opts) do
    api_key = Keyword.fetch!(opts, :api_key)

    with :ok <- check(valid_session_id?(session_id), :session_id),
         :ok <- check(present?(api_key), :api_key) do
      opts
      |> Keyword.get(:base_url, @api_base_url)
      |> hangup_req(session_id, api_key)
      |> HttpClient.request_once("openai_live_sip_hangup", egress(opts))
      |> classify_hangup([api_key])
    end
  end

  @doc "Reads one `request_once/3` result for a hangup. Pure; see `hangup/2`."
  @spec classify_hangup(
          {:ok, Req.Response.t()} | {:error, {:not_sent | :unknown, Exception.t()}},
          [String.t()]
        ) :: hangup_result()
  def classify_hangup({:ok, %Req.Response{status: status}}, secrets)
      when status in 200..299 and is_list(secrets),
      do: {:ok, :accepted}

  def classify_hangup({:ok, %Req.Response{status: status} = response}, secrets)
      when status in [404, 409, 410] and is_list(secrets),
      do: {:ok, {:already_ended, status, vendor(response, secrets)}}

  def classify_hangup({:ok, %Req.Response{status: 504} = response}, secrets)
      when is_list(secrets),
      do: {:error, {:unknown, {:http_status, 504, vendor(response, secrets)}}}

  def classify_hangup({:ok, %Req.Response{status: status} = response}, secrets)
      when status in 400..599 and is_list(secrets),
      do: {:error, {:rejected, status, vendor(response, secrets)}}

  def classify_hangup({:ok, %Req.Response{status: status}}, secrets) when is_list(secrets),
    do: {:error, {:unknown, {:unexpected_status, status}}}

  def classify_hangup({:error, {kind, error}}, secrets)
      when kind in [:not_sent, :unknown] and is_list(secrets),
      do: {:error, {kind, transport_reason(error)}}

  @doc """
  A create body, or headers (a list of pairs or a map, as Req keeps them),
  with its credentials replaced by `"[REDACTED]"`: the trunk's `auth.password`
  (string or atom keys) and the value of any `authorization` header, whatever
  its case. Everything else is kept, so a redacted
  body still shows what was asked for. The destination and caller numbers are
  not credentials and stay; whether they may be logged is the content policy's
  call, not this function's.
  """
  @spec redact(map() | [{String.t() | atom(), term()}]) :: map() | [{String.t() | atom(), term()}]
  def redact(headers) when is_list(headers), do: Enum.map(headers, &redact_pair/1)

  def redact(%{} = body), do: Map.new(body, &redact_pair/1)

  defp redact_pair({key, %{} = value}) when key in ["transport", :transport, "trunk", :trunk],
    do: {key, redact(value)}

  defp redact_pair({key, %{} = auth}) when key in ["auth", :auth],
    do: {key, Map.new(auth, &redact_password/1)}

  defp redact_pair({key, value}) do
    if String.downcase(to_string(key)) == "authorization",
      do: {key, @redacted},
      else: {key, value}
  end

  defp redact_password({key, _password}) when key in ["password", :password],
    do: {key, @redacted}

  defp redact_password(pair), do: pair

  defp put_input(session, []), do: session
  defp put_input(session, input), do: Map.put(session, "input", input)

  defp create_req(request, base_url) do
    Req.new(
      method: :post,
      url: String.trim_trailing(base_url, "/") <> @sessions_path,
      headers: [{"authorization", "Bearer " <> request.api_key}],
      json: create_body(request),
      decode_body: false,
      receive_timeout: @create_receive_timeout_ms
    )
  end

  defp hangup_req(base_url, session_id, api_key) do
    encoded = URI.encode(session_id, &URI.char_unreserved?/1)

    Req.new(
      method: :post,
      url: String.trim_trailing(base_url, "/") <> "#{@sessions_path}/#{encoded}/hangup",
      headers: [{"authorization", "Bearer " <> api_key}],
      body: "",
      decode_body: false,
      receive_timeout: @hangup_receive_timeout_ms
    )
  end

  # The sideband cannot tunnel through a proxy. A call it could not attach to
  # could not be controlled, so the create is refused before it is sent.
  defp sideband_route(ws_base_url, egress) do
    case Egress.ensure_direct(ws_base_url, egress) do
      :ok ->
        :ok

      {:error, :proxy_unsupported_transport} ->
        {:error, {:not_sent, :proxy_unsupported_transport}}
    end
  end

  defp validate_request(request) do
    trunk = Map.get(request, :trunk)

    with :ok <- check(present?(request[:api_key]), :api_key),
         :ok <- check(present?(request[:model]), :model),
         :ok <- check(present?(request[:instructions]), :instructions),
         :ok <- check(valid_input?(request[:input]), :input),
         :ok <- check(present?(request[:voice]), :voice),
         :ok <- check(e164?(request[:destination]), :destination) do
      validate_trunk(trunk)
    end
  end

  defp validate_trunk(%{} = trunk) do
    with :ok <- check(provider_url?(trunk[:provider_url]), :provider_url),
         :ok <- check(credential?(trunk[:username], @max_username_bytes), :username),
         :ok <- check(credential?(trunk[:password], @max_password_bytes), :password) do
      check(e164?(trunk[:caller_number]), :caller_number)
    end
  end

  defp validate_trunk(_trunk), do: {:error, {:not_sent, {:invalid, :trunk}}}

  defp check(true, _field), do: :ok
  defp check(false, field), do: {:error, {:not_sent, {:invalid, field}}}

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp valid_input?(input),
    do: is_list(input) and length(input) <= @max_input_items and Enum.all?(input, &is_map/1)

  defp e164?(value), do: is_binary(value) and Regex.match?(@e164, value)
  defp provider_url?(value), do: is_binary(value) and Regex.match?(@provider_url, value)

  # 1..max bytes, none of CR, LF or NUL (create reference).
  defp credential?(value, max_bytes) do
    is_binary(value) and byte_size(value) in 1..max_bytes and
      not String.contains?(value, ["\r", "\n", <<0>>])
  end

  defp valid_session_id?(id), do: id != "" and byte_size(id) <= @max_session_id_bytes

  defp secrets(%{api_key: api_key, trunk: %{password: password}}), do: [api_key, password]

  defp ws_base_url(opts), do: Keyword.get(opts, :ws_base_url, Sideband.ws_base_url())
  defp egress(opts), do: Keyword.get_lazy(opts, :egress, &Egress.active/0)

  defp transport_type(%{"transport" => %{"type" => type}}) when is_binary(type), do: type
  defp transport_type(_body), do: nil

  defp decode(body) when is_binary(body) and body != "", do: Jason.decode(body)
  defp decode(_body), do: {:error, :empty}

  # The vendor's own words: `error.message`/`code`/`type` from its JSON error
  # envelope, or the start of a non-JSON body as `message`.
  defp vendor(%Req.Response{body: body}, secrets) do
    case decode(body) do
      {:ok, %{"error" => %{} = error}} ->
        %{
          message: vendor_text(error["message"], secrets),
          code: vendor_text(error["code"], secrets),
          type: vendor_text(error["type"], secrets)
        }

      _not_an_envelope ->
        %{message: vendor_text(body, secrets), code: nil, type: nil}
    end
  end

  defp vendor_text(text, secrets) when is_binary(text) and text != "" do
    secrets
    |> Enum.filter(&present?/1)
    |> Enum.reduce(text, &String.replace(&2, &1, @redacted))
    |> String.slice(0, @vendor_text_limit)
  end

  defp vendor_text(_text, _secrets), do: nil

  defp transport_reason(%Req.TransportError{reason: reason}), do: {:transport, reason}

  defp transport_reason(error) when is_exception(error) do
    if HttpClient.connection_unavailable?(error),
      do: :connection_unavailable,
      else: {:exception, error.__struct__, Exception.message(error)}
  end
end
