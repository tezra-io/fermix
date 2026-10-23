defmodule FermixCore.Cues.Door.Router do
  @moduledoc """
  The door's only routes (M60 §6.5–§6.7): `POST /cues/v1/:ref` (local push)
  and `POST /cues/hooks/:ref/:random` (webhooks). Everything else is 404. No
  debugger, no session, no parsers: the body is read here, under the door's
  own bounds.

  Local push, in order:

    1. Before the body: the content type (415), `Content-Length` of at most
       1,000,000 bytes and no `Transfer-Encoding` (413, 411), the source is a
       configured, enabled local-push source with a stored token (else 401,
       like a bad token; one waiting for its token is refused here), no
       `Tailscale-Funnel-Request` header (401), and a bearer token (401).
    2. The token, compared in constant time against the fingerprint of the
       source's stored token (401). A token needs no body to check, so this
       comes before the read (the design's §6.7 reads first): a client without
       the token never holds one of the read slots.
    3. The body, read within 5 s while at most 16 bodies are read at once and
       4 for one source (503 past either).
    4. Decoding, duplicate keys refused (400).
    5. Rate: one authenticated request per source and four in all (429), and
       the source's and the daemon's buckets (429).
    6. `Cues.Ingest.accept/3`, answered `200` with a result per event.

  Webhooks (`Cues.Webhook`), in order:

    1. Before the body: the source is a configured, enabled webhook source
       that is not waiting for its signing secret and has a URL, and the
       path's random part matches its `path_secret`,
       compared in constant time against its fingerprint (else 404, like any
       unknown path: the path is the first secret); a JSON content type (415);
       `Content-Length` as for local push (413, 411); the method's signature
       headers, and for Standard Webhooks a timestamp within 5 minutes (401).
       A Funnel request is welcome: Funnel is one way a webhook arrives.
    2. The body, under local push's read bounds (503, 408).
    3. In the source's one authenticated slot (429 past it), so whoever holds
       the URL cannot make the door read the secret store in parallel: the
       signature over the raw body with the source's signing key (HMAC or
       Standard Webhooks; the key kept a minute by `Buckets.hook_key/2`), or
       the shared secret against its fingerprint (401).
    4. Rate as for local push (429); the body decoded, duplicate keys refused
       (400), into one item; `Cues.Ingest.accept/3`, answered `200` with its
       result.

  A refusal writes nothing except a coalesced count in `Cues.Buckets`, and only
  for a configured source. Options (copied to `conn.assigns.door`): `:ingest`,
  `:clock` (monotonic milliseconds), `:now` (the receipt `DateTime`), both
  zero-arity functions, and `:load_secret` (`(ref, field) -> {:ok, secret}`).
  """

  use Plug.Router, copy_opts_to_assign: :door

  import Plug.Conn

  alias FermixCore.Cues.Buckets
  alias FermixCore.Cues.CloudEvents
  alias FermixCore.Cues.Config
  alias FermixCore.Cues.Ingest
  alias FermixCore.Cues.Item
  alias FermixCore.Cues.Webhook
  alias FermixCore.Setup.AccessToken

  require Logger

  @max_body_bytes 1_000_000
  @body_deadline_ms 5_000
  @read_chunk_bytes 64_000
  # Enough reads for the largest body at the chunk size, and a cap if a read
  # ever returns nothing.
  @max_body_reads div(@max_body_bytes, @read_chunk_bytes) + 2
  @funnel_header "tailscale-funnel-request"

  @unauthorized "This request is not authorized for that source."
  @busy "The door is busy; try again shortly."
  @rate_limited "This source is over its rate limit; try again shortly."

  plug(:match)
  plug(:dispatch)

  post "/cues/v1/:ref" do
    local_push(conn, ref)
  end

  post "/cues/hooks/:ref/:random" do
    webhook(conn, ref, random)
  end

  match _ do
    send_json(conn, 404, %{"error" => "Not found."})
  end

  # --- local push ------------------------------------------------------------

  defp local_push(conn, ref) do
    opts = conn.assigns.door
    known = Config.source(ref)

    case handle_push(conn, ref, known, opts) do
      {:respond, conn, status, body} ->
        send_json(conn, status, body)

      {:refuse, status, reason, message} ->
        count_refusal(known, ref, reason)
        send_json(conn, status, %{"error" => message})
    end
  end

  defp handle_push(conn, ref, known, opts) do
    with {:ok, mode} <- media_mode(conn),
         {:ok, length} <- content_length(conn),
         {:ok, source} <- local_push_source(known),
         :ok <- not_funnel(conn),
         {:ok, presented} <- bearer(conn),
         :ok <- verify(ref, presented, opts),
         {:ok, body, conn} <-
           with_slot(:read, ref, fn -> read_body_within(conn, length, opts) end) do
      with_slot(:auth, ref, fn -> accept(conn, source, mode, body, opts) end)
    end
  end

  defp media_mode(conn) do
    case CloudEvents.media_mode(single_header(conn, "content-type")) do
      {:ok, mode} ->
        {:ok, mode}

      :error ->
        {:refuse, 415, :unsupported_media_type,
         "Send application/cloudevents+json or application/cloudevents-batch+json."}
    end
  end

  defp content_length(conn) do
    case {get_req_header(conn, "transfer-encoding"), get_req_header(conn, "content-length")} do
      {[], [value]} -> parse_length(value)
      {_encoding, _length} -> {:refuse, 411, :malformed, "Send the body with one Content-Length."}
    end
  end

  defp parse_length(value) do
    case Integer.parse(value) do
      {length, ""} when length in 0..@max_body_bytes ->
        {:ok, length}

      {length, ""} when length > @max_body_bytes ->
        {:refuse, 413, :too_large, "The body is larger than 1,000,000 bytes."}

      _not_a_length ->
        {:refuse, 400, :malformed, "The Content-Length is not a number of bytes."}
    end
  end

  defp local_push_source(
         {:ok, %{kind: :local_push, enabled?: true, missing_secret: nil} = source}
       ),
       do: {:ok, source}

  defp local_push_source(_unknown_disabled_waiting_or_other), do: unauthorized()

  defp not_funnel(conn) do
    case get_req_header(conn, @funnel_header) do
      [] -> :ok
      _funnel -> unauthorized()
    end
  end

  defp bearer(conn) do
    with [value] <- get_req_header(conn, "authorization"),
         [scheme, token] <- String.split(value, " ", parts: 2),
         "bearer" <- String.downcase(scheme),
         token when token != "" <- String.trim(token) do
      {:ok, token}
    else
      _missing -> unauthorized()
    end
  end

  defp unauthorized, do: {:refuse, 401, :unauthorized, @unauthorized}

  # --- slots ---------------------------------------------------------------

  # The slot is released in `after`, so a raise while reading (a body read
  # timeout raises inside the adapter) gives it back too.
  defp with_slot(kind, ref, fun) do
    case Buckets.acquire(kind, ref) do
      {:ok, token} ->
        try do
          fun.()
        after
          Buckets.release(token)
        end

      {:error, :busy} when kind == :read ->
        {:refuse, 503, :busy, @busy}

      {:error, :busy} ->
        {:refuse, 429, :rate_limited, @rate_limited}
    end
  end

  # --- body ------------------------------------------------------------------

  defp read_body_within(conn, length, opts) do
    clock = clock(opts)
    read_chunks(conn, length, [], clock.() + @body_deadline_ms, clock, @max_body_reads)
  end

  defp read_chunks(conn, 0, acc, _deadline, _clock, _reads_left),
    do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary(), conn}

  defp read_chunks(_conn, _remaining, _acc, _deadline, _clock, 0),
    do: {:refuse, 400, :malformed, "The body did not arrive as its Content-Length says."}

  defp read_chunks(conn, remaining, acc, deadline, clock, reads_left) do
    left_ms = deadline - clock.()
    chunk = min(remaining, @read_chunk_bytes)

    if left_ms <= 0 do
      {:refuse, 408, :timeout, "The body took longer than 5 seconds to arrive."}
    else
      conn
      |> read_body(length: chunk, read_length: chunk, read_timeout: left_ms)
      |> next_chunk(remaining, acc, deadline, clock, reads_left)
    end
  end

  defp next_chunk({:ok, data, conn}, remaining, acc, _deadline, _clock, _reads_left)
       when byte_size(data) == remaining,
       do: {:ok, [data | acc] |> Enum.reverse() |> IO.iodata_to_binary(), conn}

  defp next_chunk({:more, data, conn}, remaining, acc, deadline, clock, reads_left)
       when byte_size(data) < remaining,
       do:
         read_chunks(
           conn,
           remaining - byte_size(data),
           [data | acc],
           deadline,
           clock,
           reads_left - 1
         )

  defp next_chunk({:error, :timeout}, _remaining, _acc, _deadline, _clock, _reads_left),
    do: {:refuse, 408, :timeout, "The body took longer than 5 seconds to arrive."}

  defp next_chunk(_short_or_failed, _remaining, _acc, _deadline, _clock, _reads_left),
    do: {:refuse, 400, :malformed, "The body did not arrive as its Content-Length says."}

  # --- verification ----------------------------------------------------------

  defp verify(ref, presented, opts) do
    load = fn -> load_token(ref, opts) end

    case Buckets.fingerprint({ref, :token}, now_ms: clock(opts).(), load: load) do
      {:ok, digest} ->
        if AccessToken.secure_equal?(:crypto.hash(:sha256, presented), digest),
          do: :ok,
          else: unauthorized()

      {:error, _reason} ->
        {:refuse, 503, :unavailable, "This source's token cannot be read right now."}
    end
  end

  # Logged where the keyring is actually read: a failure is then remembered
  # for a minute by `Buckets.fingerprint/2`, so this logs once a minute at most.
  defp load_token(ref, opts) do
    load_secret = Keyword.get(opts, :load_secret, &Config.secret/2)

    case load_secret.(ref, :token) do
      {:ok, token} ->
        {:ok, token}

      {:error, reason} ->
        Logger.warning("cue source #{ref}: its token cannot be read (#{inspect(reason)})")
        {:error, reason}
    end
  end

  # --- acceptance ------------------------------------------------------------

  defp accept(conn, source, mode, body, opts) do
    now = Keyword.get(opts, :now, &DateTime.utc_now/0).()

    with {:ok, decoded} <- decode(mode, body),
         entries = Enum.map(decoded, &entry(&1, now)),
         :ok <- rate(source.ref, entries, opts) do
      ingest(conn, source, decoded, entries, now, opts)
    end
  end

  defp decode(mode, body) do
    case CloudEvents.decode(mode, body) do
      {:ok, decoded} ->
        {:ok, decoded}

      {:error, :too_many_events} ->
        {:refuse, 413, :too_large, "A batch holds at most 1,000 events."}

      {:error, reason} ->
        {:refuse, 400, :malformed, decode_sentence(reason)}
    end
  end

  defp decode_sentence(:invalid_json), do: "The body is not valid JSON."
  defp decode_sentence(:duplicate_object_key), do: "The body repeats a key in one object."
  defp decode_sentence(:not_an_event), do: "A structured event must be one JSON object."
  defp decode_sentence(:not_a_batch), do: "A batch must be a JSON array of events."
  defp decode_sentence(_other), do: "The body is not CloudEvents JSON."

  # What `Cues.Ingest.accept/3` takes per event: the item, or why it is not one.
  defp entry(%{result: {:ok, fields}}, now) do
    case Item.new(fields, now) do
      {:ok, item} -> item
      {:error, reason} -> {:error, reason}
    end
  end

  defp entry(%{result: {:error, message}}, _now), do: {:error, {:invalid, message}}

  # Spending happens in `Cues.Ingest` through the `:admit` function; the door
  # refuses the whole request only when the source has nothing left at all.
  defp rate(ref, entries, opts) do
    if Enum.any?(entries, &match?(%Item{}, &1)) and Buckets.tokens(ref, clock(opts).()) == 0 do
      {:refuse, 429, :rate_limited, @rate_limited}
    else
      :ok
    end
  end

  defp ingest(conn, source, decoded, entries, now, opts) do
    clock = clock(opts)
    ingest = Keyword.get(opts, :ingest, &Ingest.accept/3)

    ingest_opts = [
      now: now,
      received_mono: clock.(),
      admit: fn wanted -> Buckets.admit(source.ref, wanted, clock.()) end
    ]

    case ingest.(%{ref: source.ref, daily_budget: source.daily_budget}, entries, ingest_opts) do
      {:ok, results} -> respond(conn, decoded, results)
      {:error, reason} -> unknown_outcome(source.ref, reason)
    end
  end

  # A failure after verification is an unknown outcome: the transaction may
  # still commit, so a retry with the same ids answers duplicate.
  defp unknown_outcome(ref, reason) do
    Logger.error("cue source #{ref}: accepting pushed events failed (#{inspect(reason)})")
    {:refuse, 503, :unavailable, "The events could not be accepted; retry with the same ids."}
  end

  # Results are positional. A request none of whose events got past the rate
  # or the daily budget answers 429, with the same rows.
  defp respond(conn, decoded, results) when length(decoded) == length(results) do
    rows =
      [decoded, results, Stream.iterate(0, &(&1 + 1))]
      |> Enum.zip_with(fn [%{id: id}, result, index] -> row(index, id, result) end)

    held = Enum.filter(results, &(&1 in [:rate_limited, :over_budget]))
    status = if results != [] and held == results, do: 429, else: 200
    {:respond, conn, status, %{"results" => rows}}
  end

  defp row(index, id, {:invalid, message}),
    do: %{"index" => index, "id" => id, "status" => "invalid", "reason" => message}

  defp row(index, id, status) when is_atom(status),
    do: %{"index" => index, "id" => id, "status" => Atom.to_string(status)}

  # --- webhooks --------------------------------------------------------------

  defp webhook(conn, ref, random) do
    opts = conn.assigns.door
    known = Config.source(ref)

    case handle_hook(conn, ref, random, known, opts) do
      {:respond, conn, status, body} ->
        send_json(conn, status, body)

      {:refuse, status, reason, message} ->
        count_refusal(known, ref, reason)
        send_json(conn, status, %{"error" => message})
    end
  end

  defp handle_hook(conn, ref, random, known, opts) do
    now = Keyword.get(opts, :now, &DateTime.utc_now/0).()

    with {:ok, source} <- hook_source(known),
         :ok <- hook_path(source, random, opts),
         :ok <- json_media(conn),
         {:ok, length} <- content_length(conn),
         {:ok, presented} <- presented(source, conn, now),
         {:ok, body, conn} <-
           with_slot(:read, ref, fn -> read_body_within(conn, length, opts) end) do
      with_slot(:auth, ref, fn -> verified_hook(conn, source, presented, body, now, opts) end)
    end
  end

  # Inside the authenticated slot: the signature, then the request.
  defp verified_hook(conn, source, presented, body, now, opts) do
    with :ok <- verify_hook(source, presented, body, opts) do
      accept_hook(conn, source, body, now, opts)
    end
  end

  defp hook_source({:ok, %{kind: :webhook, enabled?: true, missing_secret: nil} = source}),
    do: {:ok, source}

  defp hook_source(_unknown_disabled_waiting_or_other), do: not_found()

  # A source whose URL was never made has no path to match.
  defp hook_path(%{ref: ref, secrets: %{path_secret: _store}}, random, opts),
    do: verify_digest(ref, :path_secret, random, opts, not_found())

  defp hook_path(_source, _random, _opts), do: not_found()

  defp not_found, do: {:refuse, 404, :unauthorized, "Not found."}

  defp json_media(conn) do
    if json_media_type?(single_header(conn, "content-type")),
      do: :ok,
      else: {:refuse, 415, :unsupported_media_type, "Send the webhook as application/json."}
  end

  defp json_media_type?(nil), do: false

  defp json_media_type?(content_type) do
    type =
      content_type |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase()

    type == "application/json" or
      (String.starts_with?(type, "application/") and String.ends_with?(type, "+json"))
  end

  defp presented(source, conn, now) do
    case Webhook.presented(source, conn.req_headers, now) do
      {:ok, presented} ->
        {:ok, presented}

      {:error, :missing_signature} ->
        unauthorized()

      {:error, :outside_window} ->
        {:refuse, 401, :unauthorized, "The webhook's timestamp is more than 5 minutes from now."}
    end
  end

  defp verify_hook(%{verify: :shared_secret, ref: ref}, presented, _body, opts),
    do: verify_digest(ref, :secret, presented, opts, unauthorized())

  # An HMAC needs the key itself, not its digest: `Buckets.hook_key/2` keeps it
  # a minute, so the store is read once a minute at most, inside the slot.
  defp verify_hook(%{ref: ref} = source, presented, body, opts) do
    load = fn -> load_hook_secret(ref, :secret, opts) end

    case Buckets.hook_key({ref, :secret}, now_ms: clock(opts).(), load: load) do
      {:ok, secret} -> signature_result(ref, Webhook.verify(source, presented, body, secret))
      {:error, _reason} -> unusable_secret()
    end
  end

  defp signature_result(_ref, :ok), do: :ok
  defp signature_result(_ref, {:error, :bad_signature}), do: unauthorized()

  defp signature_result(ref, {:error, :bad_secret}) do
    Logger.warning(
      "cue source #{ref}: its secret is not a Standard Webhooks secret (whsec_ and base64)"
    )

    unusable_secret()
  end

  # The digest is kept a minute by `Buckets.fingerprint/2`, failures included,
  # so a stream of wrong paths or wrong shared secrets reads the store at most
  # once a minute.
  defp verify_digest(ref, field, presented, opts, refusal) do
    load = fn -> load_hook_secret(ref, field, opts) end

    case Buckets.fingerprint({ref, field}, now_ms: clock(opts).(), load: load) do
      {:ok, digest} ->
        if AccessToken.secure_equal?(:crypto.hash(:sha256, presented), digest),
          do: :ok,
          else: refusal

      {:error, _reason} ->
        unusable_secret()
    end
  end

  defp load_hook_secret(ref, field, opts) do
    load_secret = Keyword.get(opts, :load_secret, &Config.secret/2)

    case load_secret.(ref, field) do
      {:ok, secret} ->
        {:ok, secret}

      {:error, reason} ->
        Logger.warning("cue source #{ref}: its #{field} cannot be read (#{inspect(reason)})")
        {:error, reason}
    end
  end

  defp unusable_secret,
    do: {:refuse, 503, :unavailable, "This source's secret cannot be used right now."}

  defp accept_hook(conn, source, body, now, opts) do
    case Webhook.entry(source, conn.req_headers, body, now) do
      {:ok, %{id: id, entry: entry}} ->
        with :ok <- rate(source.ref, [entry], opts) do
          ingest(conn, source, [%{id: id}], [entry], now, opts)
        end

      {:error, :duplicate_object_key} ->
        {:refuse, 400, :malformed, decode_sentence(:duplicate_object_key)}

      {:error, _not_json} ->
        {:refuse, 400, :malformed, decode_sentence(:invalid_json)}
    end
  end

  # --- helpers ---------------------------------------------------------------

  defp count_refusal({:ok, _source}, ref, reason), do: Buckets.record_reject(ref, reason)
  defp count_refusal(:error, _ref, _reason), do: :ok

  defp single_header(conn, name) do
    case get_req_header(conn, name) do
      [value] -> value
      _none_or_many -> nil
    end
  end

  defp clock(opts),
    do: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end)

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
