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
    * `{:error, {:rejected, status, vendor}}` — the answer itself proves the
      provider decided not to place the call: any 4xx (429 included), or a 5xx
      other than 504 that carries the API's own error envelope (a JSON
      `error` object with a `message`), which is the origin saying the request
      failed; the SIP guide's transport-setup failure (502) is one. `vendor` is
      `%{message, code, type}` in the vendor's own words, except that a
      refused key's message, which quotes the key, is replaced by the
      engine's sentence.
    * `{:error, {:not_sent, reason}}` — the request provably never left: an
      argument that fails the documented shape (`{:invalid, field}`, never the
      value), a sideband route the proxy would carry
      (`:proxy_unsupported_transport`, refused before dialing because the call
      could not be controlled), a refused connection, a name that does not
      resolve, or no pooled connection.
    * `{:error, {:unknown, reason}}` — anything else: a timeout, a closed
      connection, a 504 (documented as an initialization timeout), any other
      5xx without the vendor's envelope (`{:http_status, status, vendor}`: an
      empty or unreadable body, or a gateway's page standing in for a lost
      origin answer), a success status without a session id, an unexpected
      status. The call may exist.

  ## Ending the call

  `hangup/2` sends `POST /v1/live/sessions/{id}/hangup` with no body, once.
  The vendor documents `200 OK` with an empty body as success and documents
  nothing about a second hangup or a hangup of an ended session; see
  `hangup/2` for how those are read.

  ## Where requests go

  To the origins the caller names (`:base_url`, `:ws_base_url`), else the
  vendor's, `api_base_url/0` and `Sideband.ws_base_url/0`. Nothing here reads
  the process environment or configuration: which origins a build's calls go
  to is the composition root's decision (`FermixCore.Application`, which
  wires a development build's eval fixture origin and refuses every call in a
  test build), handed down through `PhoneCalls.CallTransport`.

  ## Credentials

  The create body carries the trunk's password and the headers the API key.
  Nothing in this adapter logs, traces or returns a body or a header, and
  nothing downstream does either: the worker keeps the request only inside the
  task that sends it. What does leave is the reason, which becomes a call's
  failure words in the owner's chat, the ledger and telemetry. So every reason
  of every shape is free of both secrets: vendor words and exception messages
  are scrubbed of each secret as stored, trimmed, as `inspect/1` prints it and
  as JSON escapes it, a refused key's message (which quotes the key, masked)
  is withheld, and a key no request could carry is refused before it is sent
  (`sendable_api_key?/1`). The same scrub, as a function (`scrubber/1`), is
  what `OpenAILive.Sideband` passes every message it hands the worker through,
  so what the vendor says during a call is free of both secrets too.
  """

  alias FermixCore.Net.Egress
  alias FermixCore.Net.HttpClient
  alias FermixCore.PhoneCalls.Limits
  alias FermixCore.PhoneCalls.OpenAILive.Sideband
  alias FermixCore.PhoneCalls.UsNumbers

  @api_base_url "https://api.openai.com"
  @sessions_path "/v1/live/sessions"
  @vendor_text_limit 1_000
  @redacted "[REDACTED]"
  # How deep `scrubber/1` reads a term: a vendor event nests a few levels.
  # Reached: the part below is replaced whole, never passed on unread.
  @scrub_depth 32
  # The vendor's `error.code` and `error.type` are fixed identifiers.
  @identifier ~r/\A[a-z0-9_.]{1,64}\z/
  # A bearer token is printable ASCII with no space: the only bytes an HTTP/1
  # header value, and the sideband's unchecked upgrade request, can carry.
  @api_key_shape ~r/\A[\x21-\x7E]+\z/

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
    origins = origins(opts)

    with :ok <- validate_request(request),
         :ok <- sideband_route(origins.ws, egress) do
      request
      |> create_req(origins.http)
      |> HttpClient.request_once("openai_live_sip_create", egress)
      |> classify_create(secrets(request))
    end
  end

  @doc """
  The create body for `request`, as JSON-ready maps. Pure. It carries the trunk
  password, so it goes nowhere but the wire.
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

  def classify_create({:ok, %Req.Response{status: status} = response}, secrets)
      when status in 400..499 and is_list(secrets),
      do: {:error, {:rejected, status, vendor(response, secrets)}}

  def classify_create({:ok, %Req.Response{status: status} = response}, secrets)
      when status in 500..599 and is_list(secrets),
      do: server_error(response, secrets)

  def classify_create({:ok, %Req.Response{status: status}}, secrets) when is_list(secrets),
    do: {:error, {:unknown, {:unexpected_status, status}}}

  def classify_create({:error, {kind, error}}, secrets)
      when kind in [:not_sent, :unknown] and is_list(secrets),
      do: {:error, {kind, transport_reason(error, secrets)}}

  @doc """
  Ends the call through the documented hangup control: one
  `POST /v1/live/sessions/{session_id}/hangup` with no body, never retried.

  `opts`: `:api_key` (required), `:base_url` (default `api_base_url/0`),
  `:egress` (default `Egress.active/0`).

    * `{:ok, :accepted}` — a 2xx; the vendor documents `200` with an empty body.
    * `{:ok, {:already_ended, status, vendor}}` — a 404, 409 or 410 in the
      API's own error envelope: the origin says there is nothing to hang up.
      Not a documented contract: OpenAI documents neither a second hangup nor
      a hangup of an ended session, so this reading is an assumption for the
      live proof, and it is not evidence that the call ended. The same
      statuses without the envelope (an edge's page) are a refusal to act,
      not an ended session.
    * `{:error, {:rejected, status, vendor}}` — any other 4xx, or a 5xx but 504
      in the vendor's envelope: the hangup was not performed.
    * `{:error, {:not_sent, reason}}` / `{:error, {:unknown, reason}}` — as for
      create: a 504, or a 5xx without the envelope, is unknown.
  """
  @spec hangup(String.t(), keyword()) :: hangup_result()
  def hangup(session_id, opts) when is_binary(session_id) and is_list(opts) do
    api_key = Keyword.fetch!(opts, :api_key)

    with :ok <- check(valid_session_id?(session_id), :session_id),
         :ok <- check(sendable_api_key?(api_key), :api_key) do
      origins(opts).http
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
      when status in [404, 409, 410] and is_list(secrets) do
    case read_answer(response, secrets) do
      {:envelope, vendor} -> {:ok, {:already_ended, status, vendor}}
      {:other, vendor} -> {:error, {:rejected, status, vendor}}
    end
  end

  def classify_hangup({:ok, %Req.Response{status: status} = response}, secrets)
      when status in 400..499 and is_list(secrets),
      do: {:error, {:rejected, status, vendor(response, secrets)}}

  def classify_hangup({:ok, %Req.Response{status: status} = response}, secrets)
      when status in 500..599 and is_list(secrets),
      do: server_error(response, secrets)

  def classify_hangup({:ok, %Req.Response{status: status}}, secrets) when is_list(secrets),
    do: {:error, {:unknown, {:unexpected_status, status}}}

  def classify_hangup({:error, {kind, error}}, secrets)
      when kind in [:not_sent, :unknown] and is_list(secrets),
      do: {:error, {kind, transport_reason(error, secrets)}}

  defp put_input(session, []), do: session
  defp put_input(session, input), do: Map.put(session, "input", input)

  defp create_req(request, base_url) do
    Req.new(
      method: :post,
      url: String.trim_trailing(base_url, "/") <> @sessions_path,
      headers: [{"authorization", "Bearer " <> request.api_key}],
      json: create_body(request),
      decode_body: false,
      receive_timeout: Limits.create_response_wait_ms()
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
      receive_timeout: Limits.hangup_response_wait_ms()
    )
  end

  @doc """
  The create reference's rule for a trunk credential: 1 to
  #{@max_username_bytes} bytes for the `username`, 1 to #{@max_password_bytes}
  for the `password`, none of CR, LF or NUL. `:ok`, or why not: `:empty`,
  `:too_long`, `:control_characters`, `:not_a_string`. Pure and explicit, so
  the settings' check (`PhoneCalls.Config`) and this request's are one rule.
  """
  @spec check_credential(:username | :password, term()) ::
          :ok | {:error, :empty | :too_long | :control_characters | :not_a_string}
  def check_credential(kind, value) when kind in [:username, :password] do
    max = if kind == :username, do: @max_username_bytes, else: @max_password_bytes

    cond do
      not is_binary(value) -> {:error, :not_a_string}
      value == "" -> {:error, :empty}
      byte_size(value) > max -> {:error, :too_long}
      String.contains?(value, ["\r", "\n", <<0>>]) -> {:error, :control_characters}
      true -> :ok
    end
  end

  @doc """
  Whether `key` can be sent as a bearer token at all: printable ASCII with no
  space. A stored key with a trailing line break is the common failure; it is
  refused before any request (`{:not_sent, {:invalid, :api_key}}`) rather than
  raised inside the HTTP client, whose error would quote it back.
  `Sideband.start_link/1` refuses the same keys.
  """
  @spec sendable_api_key?(term()) :: boolean()
  def sendable_api_key?(key), do: is_binary(key) and Regex.match?(@api_key_shape, key)

  @doc """
  Whether a call placed now could be controlled: `:ok` when its sideband
  origin is dialed directly, `{:error, {:not_sent, :proxy_unsupported_transport}}`
  when the network proxy would carry it. The very test `create_session/2`
  makes before it sends, over the same origins and egress (`opts` as there),
  so `PhoneCalls.Readiness` can tell the owner before a call is asked for.
  """
  @spec control_route(keyword()) :: :ok | {:error, {:not_sent, :proxy_unsupported_transport}}
  def control_route(opts \\ []) when is_list(opts),
    do: sideband_route(origins(opts).ws, egress(opts))

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

    with :ok <- check(sendable_api_key?(request[:api_key]), :api_key),
         :ok <- check(present?(request[:model]), :model),
         :ok <- check(present?(request[:instructions]), :instructions),
         :ok <- check(valid_input?(request[:input]), :input),
         :ok <- check(present?(request[:voice]), :voice),
         :ok <- check(UsNumbers.e164?(request[:destination]), :destination) do
      validate_trunk(trunk)
    end
  end

  defp validate_trunk(%{} = trunk) do
    with :ok <- check(provider_url?(trunk[:provider_url]), :provider_url),
         :ok <- check(check_credential(:username, trunk[:username]) == :ok, :username),
         :ok <- check(check_credential(:password, trunk[:password]) == :ok, :password) do
      check(UsNumbers.e164?(trunk[:caller_number]), :caller_number)
    end
  end

  defp validate_trunk(_trunk), do: {:error, {:not_sent, {:invalid, :trunk}}}

  defp check(true, _field), do: :ok
  defp check(false, field), do: {:error, {:not_sent, {:invalid, field}}}

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp valid_input?(input),
    do: is_list(input) and length(input) <= @max_input_items and Enum.all?(input, &is_map/1)

  defp provider_url?(value), do: is_binary(value) and Regex.match?(@provider_url, value)

  defp valid_session_id?(id), do: id != "" and byte_size(id) <= @max_session_id_bytes

  defp secrets(%{api_key: api_key, trunk: %{password: password}}), do: [api_key, password]

  # What the caller named, else the vendor's.
  defp origins(opts) do
    %{
      http: Keyword.get(opts, :base_url, @api_base_url),
      ws: Keyword.get(opts, :ws_base_url, Sideband.ws_base_url())
    }
  end

  defp egress(opts), do: Keyword.get_lazy(opts, :egress, &Egress.active/0)

  defp transport_type(%{"transport" => %{"type" => type}}) when is_binary(type), do: type
  defp transport_type(_body), do: nil

  defp decode(body) when is_binary(body) and body != "", do: Jason.decode(body)
  defp decode(_body), do: {:error, :empty}

  # A 5xx is the origin's refusal only when it says so in its own error
  # envelope. A gateway's page, an empty or unreadable body, or the documented
  # initialization timeout (504, with or without the envelope) can stand for an
  # answer lost after the call was placed, so they are unknown.
  defp server_error(%Req.Response{status: status} = response, secrets) do
    case {status, read_answer(response, secrets)} do
      {504, {_kind, vendor}} -> {:error, {:unknown, {:http_status, 504, vendor}}}
      {_status, {:envelope, vendor}} -> {:error, {:rejected, status, vendor}}
      {_status, {:other, vendor}} -> {:error, {:unknown, {:http_status, status, vendor}}}
    end
  end

  defp vendor(response, secrets), do: response |> read_answer(secrets) |> elem(1)

  # `{:envelope, vendor}` when the body is the API's own error envelope (a JSON
  # object whose `error` is an object with a `message`), `{:other, vendor}` for
  # any other body, kept as its words. `code` and `type` are kept only when
  # they read as the fixed identifiers they are.
  defp read_answer(%Req.Response{status: status, body: body}, secrets) do
    case decode(body) do
      {:ok, %{"error" => %{"message" => message} = error}} when is_binary(message) ->
        code = identifier(error["code"])

        {:envelope,
         %{
           message: words(status, code, message, secrets),
           code: code,
           type: identifier(error["type"])
         }}

      _not_an_envelope ->
        {:other, %{message: words(status, nil, body, secrets), code: nil, type: nil}}
    end
  end

  # OpenAI's refused-key message quotes the key back, masked but with its last
  # characters, which no exact-match scrub can see. The engine's own sentence
  # stands in for it, as `Realtime.SessionServer` does for the same refusal.
  defp words(status, code, _text, _secrets) when status == 401 or code == "invalid_api_key",
    do: refused_key(code)

  defp words(_status, _code, text, secrets), do: vendor_text(text, secrets)

  defp refused_key(nil), do: "OpenAI did not accept the API key."
  defp refused_key(code), do: "OpenAI did not accept the API key (#{code})."

  defp identifier(value) when is_binary(value) do
    if Regex.match?(@identifier, value), do: value, else: nil
  end

  defp identifier(_value), do: nil

  defp vendor_text(text, secrets) when is_binary(text) and text != "" do
    text
    |> scrub(secrets)
    |> String.slice(0, @vendor_text_limit)
  end

  defp vendor_text(_text, _secrets), do: nil

  # Every reason is built here, so this is where secrets leave it: an
  # exception's message (the HTTP/1 client quotes a header value it refuses)
  # and a transport reason whose printed form holds one.
  defp transport_reason(%Req.TransportError{reason: reason}, secrets),
    do: {:transport, scrub_term(reason, secrets)}

  defp transport_reason(error, secrets) when is_exception(error) do
    if HttpClient.connection_unavailable?(error),
      do: :connection_unavailable,
      else: {:exception, error.__struct__, vendor_text(Exception.message(error), secrets)}
  end

  # The term as it is, unless its printed form holds a secret: then that
  # printed form, scrubbed and bounded.
  defp scrub_term(term, secrets) do
    printed = inspect(term, limit: :infinity, printable_limit: :infinity)
    scrubbed = scrub(printed, secrets)

    if scrubbed == printed, do: term, else: String.slice(scrubbed, 0, @vendor_text_limit)
  end

  defp scrub(text, secrets), do: replace_forms(text, secret_forms(secrets))

  defp replace_forms(text, forms),
    do: Enum.reduce(forms, text, &String.replace(&2, &1, @redacted))

  @doc """
  The scrub every vendor word leaves this adapter through, as a function of
  the call's `secrets` (its API key and trunk password): it answers its term
  with every string inside it, map keys included, scrubbed as the create's
  and hangup's answers are (each secret as stored, trimmed, as `inspect/1`
  prints it and as JSON escapes it). Structure is kept; a part nested deeper
  than #{@scrub_depth} levels is replaced whole by `#{@redacted}`. The
  function closes over the secrets, so whoever holds it (the sideband, for the
  life of a call) holds no credential it could print.
  """
  @spec scrubber([String.t()]) :: (term() -> term())
  def scrubber(secrets) when is_list(secrets) do
    forms = secret_forms(secrets)
    fn term -> scrub_all(term, forms, @scrub_depth) end
  end

  defp scrub_all(_term, _forms, 0), do: @redacted
  defp scrub_all(text, forms, _depth) when is_binary(text), do: replace_forms(text, forms)

  defp scrub_all(list, forms, depth) when is_list(list),
    do: Enum.map(list, &scrub_all(&1, forms, depth - 1))

  defp scrub_all(tuple, forms, depth) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> scrub_all(forms, depth) |> List.to_tuple()

  defp scrub_all(%{__struct__: _module} = struct, forms, depth),
    do: :maps.map(fn _field, value -> scrub_all(value, forms, depth - 1) end, struct)

  defp scrub_all(%{} = map, forms, depth),
    do:
      Map.new(map, fn {key, value} ->
        {scrub_all(key, forms, depth - 1), scrub_all(value, forms, depth - 1)}
      end)

  defp scrub_all(other, _forms, _depth), do: other

  # A secret as it can appear inside a message: as stored, trimmed, and as
  # `inspect/1` prints or JSON escapes either, longest first so no form is left
  # half replaced.
  defp secret_forms(secrets) do
    secrets
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.flat_map(&[&1, String.trim(&1)])
    |> Enum.flat_map(&[&1, inspected(&1) | json_escaped(&1)])
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort_by(&byte_size/1, :desc)
  end

  defp inspected(form), do: form |> inspect() |> String.slice(1..-2//1)

  # As a JSON encoder writes it inside a string: plainly, with every
  # non-ASCII character as `\uXXXX`, and with `/`, `<`, `>` and `&` escaped too.
  defp json_escaped(form) do
    for escape <- [:json, :unicode_safe, :html_safe],
        {:ok, encoded} <- [Jason.encode(form, escape: escape)],
        do: String.slice(encoded, 1..-2//1)
  end
end
