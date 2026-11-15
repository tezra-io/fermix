defmodule FermixChannels.Mobile.PushRelay do
  @moduledoc """
  One push to one Android phone through Tezra's push relay (M99 §14): seal
  the plaintext to the phone's key (`WebPush.Encryption`, RFC 8291) and POST
  it to the relay, which passes it to Google. The home holds no key, no
  credential and no setting of its own.

  **Where it goes.** Always `https://push.fermix.ai/v1/push`, a constant: a
  phone hands over a service name and its address at Google (its Firebase
  Installation ID), never a URL, so a phone can never point the engine at
  another server. The address travels in the body, never in the URL, so no
  access log can hold it. Redirects are not followed.

  **The request.** `Content-Type: application/json` and the body
  `{"service":"fcm","address":"…","ttl":<seconds>,"body":"…"}`, `body` being
  the sealed message (always `Encryption.body_size/0` bytes) in base64url
  without padding, through the shared HTTP client
  (`FermixCore.Net.HttpClient`, which routes it through the configured
  egress). No credential. At most 1 KiB of a response is read.

  **The relay's answers.** `204` is delivered. Any other answer is read by
  the relay's error word when its body is `{"error": word}` with a word the
  relay has: `gone` is `:gone` (Google no longer knows the address, and the
  caller drops it); `busy`, `unavailable` and `permission` are tried again;
  every other word (`malformed`, `service`, `address`, `ttl`, `body`,
  `too_large`, `refused`, `not_found`) is a bug in this Fermix or the relay,
  `{:rejected, word}`, logged once as an error and never tried again. An
  answer with no relay word (the API gateway's own, or anything unexpected)
  goes by its status: `429` and any `5xx` are tried again, any other is
  `{:refused, status}`, logged as an error and not tried again. Transport
  errors are tried again.

  **Trying again.** At most three attempts, and no attempt starts 60 seconds
  or more after the first one did. Between attempts it waits the answer's
  `Retry-After` (in seconds) when there is one, otherwise 2 s and then 10 s;
  when that wait would reach the 60 s mark it stops instead, and it never
  waits after the last attempt. Each attempt waits at most 15 s for an answer
  (`Net.TimeoutPolicy`, `:push_relay`). When it stops it answers
  `{:unavailable, last}`, `last` being the last attempt's `{:relay, word}`,
  `{:http, status}` or `{:transport, reason}`.

  **Logs and reasons.** Each failed attempt is logged once, with the service
  name, the attempt, the status and the relay's word when it is one the relay
  has, or the transport reason, and what happens next. No log line or reason
  carries the address, a key, the sealed body or the plaintext, and none
  echoes a response body: the relay's known error words are the only words of
  an answer that are ever logged. A subscription or plaintext this module
  cannot send is refused before any request as `{:invalid, reason}`.

  `send/4` blocks for as long as its attempts and waits take. Options, for
  tests: `:req_options` (merged into the request, e.g. a `Req.Test` plug),
  `:now_ms` (a monotonic clock in milliseconds) and `:sleep`.
  """

  require Logger

  alias FermixChannels.Mobile.WebPush.Encryption
  alias FermixCore.Net.HttpClient
  alias FermixCore.Net.TimeoutPolicy

  @url "https://push.fermix.ai/v1/push"
  @services ["fcm"]
  @address_format ~r/\A[A-Za-z0-9_-]{1,256}\z/
  @max_attempts 3
  @budget_ms 60_000
  @max_body_bytes 1_024
  @label "push relay send"
  @options [:req_options, :now_ms, :sleep]
  # The relay's error words (fermix-push, M99 §14), each as the atom a reason
  # carries: the three it asks to be tried again, and the ones that name a bug.
  @retried_words %{"busy" => :busy, "unavailable" => :unavailable, "permission" => :permission}
  @bug_words %{
    "malformed" => :malformed,
    "service" => :service,
    "address" => :address,
    "ttl" => :ttl,
    "body" => :body,
    "too_large" => :too_large,
    "refused" => :refused,
    "not_found" => :not_found
  }

  @type subscription :: %{
          service: String.t(),
          address: String.t(),
          p256dh: <<_::520>>,
          auth: <<_::128>>
        }

  @type retried_word :: :busy | :unavailable | :permission
  @type bug_word ::
          :malformed
          | :service
          | :address
          | :ttl
          | :body
          | :too_large
          | :refused
          | :not_found

  @type last_failure ::
          {:relay, retried_word()} | {:http, pos_integer()} | {:transport, atom()}

  @type reason ::
          :gone
          | {:rejected, bug_word()}
          | {:refused, pos_integer()}
          | {:unavailable, last_failure()}
          | {:invalid, term()}

  @doc "The push services a subscription may name."
  @spec services() :: [String.t()]
  def services, do: @services

  @doc """
  Whether `address` is one the relay takes: letters, digits, `_` and `-`
  only, 1 to 256 characters.
  """
  @spec valid_address?(term()) :: boolean()
  def valid_address?(address) when is_binary(address), do: Regex.match?(@address_format, address)
  def valid_address?(_address), do: false

  @doc "Sends `plaintext` to one phone, trying again as the module doc says."
  @spec send(subscription(), plaintext :: binary(), ttl_s :: pos_integer(), keyword()) ::
          :ok | {:error, reason()}
  # The fields' types are asserted where they are read: `valid_address?/1` and
  # `Encryption.encrypt/4` take binaries only.
  def send(
        %{service: _service, address: _address, p256dh: _p256dh, auth: _auth} = subscription,
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

  # -- before the first attempt ------------------------------------------------

  defp prepare(subscription, plaintext, ttl_s, opts) do
    with :ok <- known_options(opts),
         :ok <- known_service(subscription.service),
         :ok <- sendable_address(subscription.address),
         {:ok, sealed} <- Encryption.encrypt(plaintext, subscription.p256dh, subscription.auth) do
      body = request_body(subscription, ttl_s, sealed)
      {:ok, push(subscription, request(body, opts), opts)}
    end
  end

  defp known_options(opts) do
    case Keyword.keys(opts) -- @options do
      [] -> :ok
      unknown -> {:error, {:unknown_options, unknown}}
    end
  end

  defp known_service(service) when service in @services, do: :ok
  defp known_service(_service), do: {:error, :unknown_service}

  defp sendable_address(address),
    do: if(valid_address?(address), do: :ok, else: {:error, :invalid_address})

  # The keys in the contract's order (M99 §14).
  defp request_body(subscription, ttl_s, sealed) do
    Jason.encode!(
      Jason.OrderedObject.new([
        {"service", subscription.service},
        {"address", subscription.address},
        {"ttl", ttl_s},
        {"body", Base.url_encode64(sealed, padding: false)}
      ])
    )
  end

  defp request(body, opts) do
    Req.new(
      method: :post,
      url: @url,
      headers: [{"content-type", "application/json"}],
      body: body,
      redirect: false,
      retry: false,
      compressed: false,
      decode_body: false,
      receive_timeout: TimeoutPolicy.receive_timeout_for(:push_relay),
      into: &collect_body/2
    )
    |> Req.merge(Keyword.get(opts, :req_options, []))
  end

  defp push(subscription, request, opts) do
    now_ms = Keyword.get(opts, :now_ms, fn -> System.monotonic_time(:millisecond) end)

    %{
      request: request,
      service: subscription.service,
      now_ms: now_ms,
      sleep: Keyword.get(opts, :sleep, &Process.sleep/1),
      started_ms: now_ms.()
    }
  end

  # Keeps the first `@max_body_bytes` of an answer and stops reading there.
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
    |> classify()
    |> settle(push, attempt)
  end

  defp classify({:ok, %Req.Response{status: 204}}), do: :delivered

  defp classify({:ok, %Req.Response{status: status} = response}),
    do: classify_answer(status, relay_word(response.body), response)

  defp classify({:error, exception}) do
    reason = transport_reason(exception)
    {:again, {:transport, reason}, "transport #{reason}", nil}
  end

  defp classify_answer(status, "gone" = word, _response), do: {:gone, said(status, word)}

  defp classify_answer(status, word, response) when is_map_key(@retried_words, word),
    do: {:again, {:relay, @retried_words[word]}, said(status, word), retry_after(response)}

  defp classify_answer(status, word, _response) when is_map_key(@bug_words, word),
    do: {:bug, {:rejected, @bug_words[word]}, said(status, word)}

  defp classify_answer(status, nil, response) when status == 429 or status in 500..599,
    do: {:again, {:http, status}, said(status, nil), retry_after(response)}

  defp classify_answer(status, nil, _response),
    do: {:bug, {:refused, status}, said(status, nil)}

  defp said(status, nil), do: "HTTP #{status}"
  defp said(status, word), do: "HTTP #{status} #{word}"

  defp settle(:delivered, _push, _attempt), do: :ok

  defp settle({:gone, said}, push, attempt) do
    log(:warning, push, attempt, said, "the relay says Google no longer knows the address")
    {:error, :gone}
  end

  defp settle({:bug, reason, said}, push, attempt) do
    log(:error, push, attempt, said, "a fault in this Fermix or the relay; not tried again")
    {:error, reason}
  end

  defp settle({:again, last, said, retry_after_ms}, push, attempt) do
    case next_step(push, attempt, retry_after_ms) do
      {:wait, wait_ms} ->
        log(:warning, push, attempt, said, "trying again in #{wait_ms} ms")
        push.sleep.(wait_ms)
        deliver(push, attempt + 1)

      {:stop, why} ->
        log(:warning, push, attempt, said, why)
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

  defp log(level, push, attempt, said, next) do
    Logger.log(
      level,
      "mobile push relay (#{push.service}) failed (attempt #{attempt} of #{@max_attempts}): " <>
        "#{said}; #{next}"
    )
  end

  # -- what an answer says -------------------------------------------------------

  # The relay's word, only when it is one the relay has: anything else in a
  # body is never read further, and never logged.
  defp relay_word(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => word}} when is_binary(word) -> known_word(word)
      _not_the_relays -> nil
    end
  end

  defp known_word(word) do
    if word == "gone" or is_map_key(@retried_words, word) or is_map_key(@bug_words, word),
      do: word,
      else: nil
  end

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
