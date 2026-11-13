defmodule FermixChannels.Mobile.WebPush do
  @moduledoc """
  One Web Push (RFC 8030) to one phone: seal the plaintext to the phone's key
  (`WebPush.Encryption`), sign the request with the home's key
  (`WebPush.Vapid`, `WebPush.Key`) and POST it to the phone's push service.

  **Where it goes.** A phone hands over a service name and a token, never an
  address: the address is built from a fixed table (`services/0`, today only
  `"fcm"`, `https://fcm.googleapis.com/fcm/send/<token>`), and the token must
  match `[A-Za-z0-9_:-]{1,4096}`, so a phone can never point the engine at
  another host or path. Redirects are not followed.

  **The request.** `TTL: <ttl_s>`, `Urgency: high`, `Content-Encoding:
  aes128gcm`, `Content-Type: application/octet-stream`, the VAPID
  `Authorization`, and a body of `Encryption.body_size/0` bytes, through the
  shared HTTP client (`FermixCore.Net.HttpClient`, which routes it through the
  configured egress). At most 1 KiB of a response body is read.

  **Google's answers.** Any 2xx is delivered. 404 and 410 are `:gone` and 401
  and 403 `:sender_refused`: the subscription, or this home's key, is no
  longer good, and the caller drops it. Every other status is
  `{:refused, status, excerpt}`, not tried again, the excerpt being at most
  200 bytes of the service's own words, printable ASCII only. 429, 5xx and
  transport errors are tried again.

  **Trying again.** At most three attempts, and no attempt starts 60 seconds
  or more after the first one did. Between attempts it waits the response's
  `Retry-After` (in seconds) when there is one, otherwise 2 s and then 10 s;
  when that wait would reach the 60 s mark it stops instead, and it never
  waits after the last attempt. Each attempt waits at most 15 s for an answer.
  When it stops it answers `{:unavailable, last}`, `last` being the last
  attempt's `{:http, status}` or `{:transport, reason}`. A `Retry-After` given
  as a date rather than seconds is not read, and the fixed waits apply.

  **Logs and reasons.** Each failed attempt is logged once as a warning with
  the service name, the attempt, the status or transport reason, the excerpt
  and what happens next. No log line or reason carries the token, a key, the
  address or the plaintext; a token the service repeats is replaced in the
  excerpt. A subscription, plaintext or key this module cannot use is refused
  before any request as `{:invalid, reason}`.

  `send/4` blocks for as long as its attempts and waits take. Options:
  `:key` (required, the home's `WebPush.Key`); and, for tests, `:req_options`
  (merged into the request, e.g. a `Req.Test` plug), `:now_ms` (a monotonic
  clock in milliseconds), `:now_unix` (wall-clock seconds for the token's
  expiry) and `:sleep`.
  """

  require Logger

  alias FermixChannels.Mobile.WebPush.Encryption
  alias FermixChannels.Mobile.WebPush.Vapid
  alias FermixCore.Net.HttpClient
  alias FermixCore.Net.TimeoutPolicy

  @services %{"fcm" => "https://fcm.googleapis.com/fcm/send/"}
  @token_format ~r/\A[A-Za-z0-9_:\-]{1,4096}\z/
  @max_attempts 3
  @budget_ms 60_000
  @max_body_bytes 1_024
  @excerpt_bytes 200
  @label "Web Push send"
  @options [:key, :req_options, :now_ms, :now_unix, :sleep]

  @type subscription :: %{
          service: String.t(),
          token: String.t(),
          p256dh: <<_::520>>,
          auth: <<_::128>>
        }

  @type last_failure :: {:http, pos_integer()} | {:transport, atom()}

  @type reason ::
          :gone
          | :sender_refused
          | {:refused, pos_integer(), String.t()}
          | {:unavailable, last_failure()}
          | {:invalid, term()}

  @doc "The push services a subscription may name."
  @spec services() :: [String.t()]
  def services, do: @services |> Map.keys() |> Enum.sort()

  @doc "The push address for a token at a known service, or why there is none."
  @spec endpoint(service :: String.t(), token :: String.t()) ::
          {:ok, String.t()} | {:error, :unknown_service | :invalid_token}
  def endpoint(service, token) when is_binary(service) and is_binary(token) do
    with {:ok, base} <- service_base(service),
         :ok <- valid_token(token) do
      {:ok, base <> token}
    end
  end

  @doc "Sends `plaintext` to one phone, trying again as the module doc says."
  @spec send(subscription(), plaintext :: binary(), ttl_s :: pos_integer(), keyword()) ::
          :ok | {:error, reason()}
  # The fields' types are asserted where they are read: `endpoint/2` and
  # `Encryption.encrypt/4` take binaries only.
  def send(
        %{service: _service, token: _token, p256dh: _p256dh, auth: _auth} = subscription,
        plaintext,
        ttl_s,
        opts
      )
      when is_binary(plaintext) and is_integer(ttl_s) and ttl_s > 0 and is_list(opts) do
    case prepare(subscription, plaintext, ttl_s, opts) do
      {:ok, push} -> deliver(push, 1)
      {:error, reason} -> {:error, {:invalid, reason}}
    end
  end

  defp service_base(service) do
    case Map.fetch(@services, service) do
      {:ok, base} -> {:ok, base}
      :error -> {:error, :unknown_service}
    end
  end

  defp valid_token(token) do
    if Regex.match?(@token_format, token), do: :ok, else: {:error, :invalid_token}
  end

  # -- before the first attempt ------------------------------------------------

  defp prepare(subscription, plaintext, ttl_s, opts) do
    %{private: private, public: public} = Keyword.fetch!(opts, :key)
    now_unix = Keyword.get(opts, :now_unix, fn -> System.os_time(:second) end)

    with :ok <- known_options(opts),
         {:ok, url} <- endpoint(subscription.service, subscription.token),
         {:ok, audience} <- Vapid.audience(url),
         {:ok, authorization} <- Vapid.authorization(private, public, audience, now_unix.()),
         {:ok, body} <- Encryption.encrypt(plaintext, subscription.p256dh, subscription.auth) do
      {:ok, push(subscription, request(url, body, ttl_s, authorization, opts), opts)}
    end
  end

  defp known_options(opts) do
    case Keyword.keys(opts) -- @options do
      [] -> :ok
      unknown -> {:error, {:unknown_options, unknown}}
    end
  end

  defp request(url, body, ttl_s, authorization, opts) do
    Req.new(
      method: :post,
      url: url,
      headers: [
        {"ttl", Integer.to_string(ttl_s)},
        {"urgency", "high"},
        {"content-encoding", "aes128gcm"},
        {"content-type", "application/octet-stream"},
        {"authorization", authorization}
      ],
      body: body,
      redirect: false,
      retry: false,
      compressed: false,
      decode_body: false,
      receive_timeout: TimeoutPolicy.receive_timeout_for(:web_push),
      into: &collect_body/2
    )
    |> Req.merge(Keyword.get(opts, :req_options, []))
  end

  defp push(subscription, request, opts) do
    now_ms = Keyword.get(opts, :now_ms, fn -> System.monotonic_time(:millisecond) end)

    %{
      request: request,
      service: subscription.service,
      token: subscription.token,
      now_ms: now_ms,
      sleep: Keyword.get(opts, :sleep, &Process.sleep/1),
      started_ms: now_ms.()
    }
  end

  # Keeps the first `@max_body_bytes` of a response and stops reading there.
  defp collect_body({:data, data}, {request, %Req.Response{body: body} = response})
       when is_binary(body) do
    kept = body <> data

    if byte_size(kept) > @max_body_bytes,
      do: {:halt, {request, %{response | body: binary_part(kept, 0, @max_body_bytes)}}},
      else: {:cont, {request, %{response | body: kept}}}
  end

  # -- attempts ----------------------------------------------------------------

  # Bounded by `@max_attempts`: `next_step/3` stops at the last one.
  defp deliver(push, attempt) do
    push.request
    |> HttpClient.request(@label)
    |> classify(push.token)
    |> settle(push, attempt)
  end

  defp classify({:ok, %Req.Response{status: status}}, _token) when status in 200..299,
    do: :delivered

  defp classify({:ok, %Req.Response{status: status} = response}, token) do
    excerpt = excerpt(response.body, token)
    said = if excerpt == "", do: "HTTP #{status}", else: "HTTP #{status} #{inspect(excerpt)}"

    cond do
      status in [404, 410] ->
        {:stop, :gone, said}

      status in [401, 403] ->
        {:stop, :sender_refused, said}

      status == 429 or status in 500..599 ->
        {:again, {:http, status}, said, retry_after(response)}

      true ->
        {:stop, {:refused, status, excerpt}, said}
    end
  end

  defp classify({:error, exception}, _token) do
    reason = transport_reason(exception)
    {:again, {:transport, reason}, "transport #{reason}", nil}
  end

  defp settle(:delivered, _push, _attempt), do: :ok

  defp settle({:stop, reason, said}, push, attempt) do
    warn(push, attempt, said, "not tried again")
    {:error, reason}
  end

  defp settle({:again, last, said, retry_after_ms}, push, attempt) do
    case next_step(push, attempt, retry_after_ms) do
      {:wait, wait_ms} ->
        warn(push, attempt, said, "trying again in #{wait_ms} ms")
        push.sleep.(wait_ms)
        deliver(push, attempt + 1)

      {:stop, why} ->
        warn(push, attempt, said, why)
        {:error, {:unavailable, last}}
    end
  end

  defp next_step(_push, attempt, _retry_after_ms) when attempt >= @max_attempts,
    do: {:stop, "no attempts left"}

  defp next_step(push, attempt, retry_after_ms) do
    wait_ms = retry_after_ms || default_wait_ms(attempt)
    elapsed_ms = push.now_ms.() - push.started_ms

    if elapsed_ms + wait_ms >= @budget_ms,
      do: {:stop, "waiting #{wait_ms} ms would pass #{div(@budget_ms, 1_000)} s, giving up"},
      else: {:wait, wait_ms}
  end

  defp default_wait_ms(1), do: 2_000
  defp default_wait_ms(2), do: 10_000

  defp warn(push, attempt, said, next) do
    Logger.warning(
      "Web Push to #{push.service} failed (attempt #{attempt} of #{@max_attempts}): " <>
        "#{said}; #{next}"
    )
  end

  # -- what a response says ------------------------------------------------------

  defp retry_after(response) do
    case Req.Response.get_header(response, "retry-after") do
      [value | _rest] -> retry_after_seconds(String.trim(value))
      [] -> nil
    end
  end

  defp retry_after_seconds(value) do
    case Integer.parse(value) do
      {seconds, ""} when seconds >= 0 -> seconds * 1_000
      _not_seconds -> nil
    end
  end

  # Printable ASCII only, runs of anything else one space, the token never.
  defp excerpt(body, token) when is_binary(body) do
    words =
      body
      |> printable()
      |> String.replace(token, "[token]")
      |> String.replace(~r/ {2,}/, " ")
      |> String.trim()

    binary_part(words, 0, min(byte_size(words), @excerpt_bytes))
  end

  defp printable(body), do: for(<<byte <- body>>, into: "", do: printable_byte(byte))

  defp printable_byte(byte) when byte in 0x20..0x7E, do: <<byte>>
  defp printable_byte(_byte), do: " "

  defp transport_reason(%Req.TransportError{reason: reason}) when is_atom(reason), do: reason

  defp transport_reason(%Req.TransportError{reason: reason})
       when is_tuple(reason) and is_atom(elem(reason, 0)),
       do: elem(reason, 0)

  defp transport_reason(%Req.HTTPError{}), do: :protocol_error

  defp transport_reason(exception) do
    if HttpClient.connection_unavailable?(exception),
      do: :connection_unavailable,
      else: :request_failed
  end
end
