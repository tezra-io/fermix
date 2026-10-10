defmodule FermixChannels.Mobile.Protocol do
  @moduledoc """
  Pure codec for the encrypted mobile channel's plaintext frames.

  A frame is a 32-bit unsigned big-endian JSON-header length, the JSON header,
  then optional raw bytes. The enclosing Noise transport supplies secrecy,
  authentication, and message boundaries. This module performs no I/O and owns
  no connection state; `Mobile.SocketHandler` owns hello-first and sequence
  ordering checks.

  The canonical cross-repository export lives under `fermix_core/priv/mobile/`.
  A phone app vendors those files pinned by checksum.

  The chat events this wire shares verbatim with the companion socket
  (`FermixCore.Companion.Protocol.shared_client_events/0` and
  `shared_server_events/0`) are validated by that module, the chat
  vocabulary's one owner; this module validates the mobile transport's own
  events (hello, pairing, attachments and media, push, ack, keepalive) and the
  `history_pull`/`history_page` pair, whose mobile page always carries
  `next_after_seq` and names its backward cursor `prev_before_seq`.

  A logical server event whose header would exceed the 4 KiB cap travels as one
  contiguous run of `event_part` frames: each raw tail is a slice of the
  event's JSON object (with `t`, without `v` and `seq`), and the client
  concatenates them in index order. `event_part` is server-only.
  """

  alias FermixCore.Companion.Protocol, as: ChatProtocol
  alias FermixCore.Text

  @protocol_version 2
  # Protocol 1 shipped in daemons but never had a client, so the window is the
  # current version alone (M51 D1), not N/N-1.
  @min_supported_version 2
  @max_header_bytes 4_096
  @max_raw_chunk_bytes 60 * 1_024
  @max_plaintext_bytes 65_535 - 16
  @max_event_bytes 1_048_576
  @max_event_parts div(@max_event_bytes + @max_raw_chunk_bytes - 1, @max_raw_chunk_bytes)
  @max_u64 18_446_744_073_709_551_615
  @default_max_media_bytes 20 * 1_024 * 1_024
  @platforms ~w(ios android)
  @attestation_kinds ~w(android_keymint apple_app_attest)
  @max_attestation_certs 6
  @max_attestation_chain_bytes 16 * 1_024
  @max_status_requests 32
  @request_states ~w(accepted running completed failed)

  @client_events ~w(
    hello msg attach_begin attach_chunk attach_end command cancel history_pull media_fetch
    push_register ack read_state request_status pair_request unpair ping
  )
  @server_events ~w(
    hello_ack accepted attach_status turn_started text_delta tool_event text_done turn_done
    media_begin media_chunk media_end turn_error row reaction approval approval_resolved
    link_preview read_state history_page request_status_page notice pair_approved pair_denied
    error pong event_part
  )
  @raw_client_events ~w(attach_chunk pair_request)
  @raw_server_events ~w(media_chunk event_part)

  @client_required %{
    "hello" => ~w(device_id app_version last_server_seq protocol_v),
    "attach_begin" => ~w(attach_id kind mime size_bytes sha256),
    "attach_chunk" => ~w(attach_id index),
    "attach_end" => ~w(attach_id sha256),
    "history_pull" => ~w(profile_id limit),
    "media_fetch" => ~w(ref),
    "push_register" => ~w(apns_token environment),
    "ack" => ~w(server_seq),
    "request_status" => ~w(client_msg_ids),
    "pair_request" => ~w(device_name model app_version platform attestation),
    "unpair" => [],
    "ping" => []
  }

  @server_required %{
    "hello_ack" =>
      ~w(session_id min_version max_version profiles candidates history_head_seq read_up_to_seq caps),
    "attach_status" => ~w(attach_id status),
    "turn_done" => ~w(turn_id),
    "media_begin" => ~w(ref server_seq kind mime size_bytes sha256),
    "media_chunk" => ~w(ref index),
    "media_end" => ~w(ref sha256),
    "reaction" => ~w(in_reply_to emoji),
    "link_preview" => ~w(in_reply_to url site title),
    "history_page" => ~w(profile_id messages next_after_seq history_head_seq),
    "request_status_page" => ~w(requests),
    "notice" => ~w(kind text),
    "pair_approved" => ~w(device_id candidates profiles push_salt),
    "pair_denied" => ~w(reason),
    "error" => ~w(code message),
    "pong" => [],
    "event_part" => ~w(index count)
  }

  @type decoded_event :: %{
          version: pos_integer(),
          type: String.t(),
          seq: pos_integer(),
          payload: map(),
          bytes: binary()
        }

  @doc "The daemon's current mobile wire-protocol version."
  @spec protocol_version() :: pos_integer()
  def protocol_version, do: @protocol_version

  @doc "Inclusive `{min, max}` protocol versions accepted by this daemon."
  @spec supported_version_range() :: {pos_integer(), pos_integer()}
  def supported_version_range, do: {@min_supported_version, @protocol_version}

  @doc "Ordered client event catalog."
  @spec client_events() :: [String.t()]
  def client_events, do: @client_events

  @doc "Ordered server event catalog."
  @spec server_events() :: [String.t()]
  def server_events, do: @server_events

  @doc "Maximum JSON header size accepted by the codec."
  @spec max_header_bytes() :: pos_integer()
  def max_header_bytes, do: @max_header_bytes

  @doc "Maximum raw-byte tail on an attachment or media chunk (60 KiB)."
  @spec max_raw_chunk_bytes() :: pos_integer()
  def max_raw_chunk_bytes, do: @max_raw_chunk_bytes

  @doc "Maximum plaintext that fits in one Noise message with its 16-byte tag."
  @spec max_plaintext_bytes() :: pos_integer()
  def max_plaintext_bytes, do: @max_plaintext_bytes

  @doc "Maximum size of the attestation chain a `pair_request` carries as its raw tail (16 KiB)."
  @spec max_attestation_chain_bytes() :: pos_integer()
  def max_attestation_chain_bytes, do: @max_attestation_chain_bytes

  @doc "Maximum JSON size of one logical server event carried as `event_part` frames (1 MiB)."
  @spec max_event_bytes() :: pos_integer()
  def max_event_bytes, do: @max_event_bytes

  @doc "Negotiate a client version against the daemon's inclusive window."
  @spec negotiate(integer()) :: :ok | {:error, :client_too_old | :client_too_new}
  def negotiate(version) when is_integer(version) do
    {min, max} = supported_version_range()

    cond do
      version < min -> {:error, :client_too_old}
      version > max -> {:error, :client_too_new}
      true -> :ok
    end
  end

  @doc "Decode and validate one client plaintext frame."
  @spec decode_client_frame(binary(), keyword()) :: {:ok, decoded_event()} | {:error, term()}
  def decode_client_frame(frame, opts \\ []) when is_binary(frame) and is_list(opts) do
    max_media_bytes = Keyword.get(opts, :max_media_bytes, @default_max_media_bytes)

    with :ok <- validate_media_cap(max_media_bytes),
         {:ok, header, bytes} <- split_frame(frame),
         {:ok, envelope} <- decode_envelope(header, @client_events),
         :ok <- validate_client_event(envelope, max_media_bytes),
         :ok <- validate_binary(envelope.type, bytes, @raw_client_events),
         :ok <- validate_attestation_chain(envelope, bytes) do
      {:ok, Map.put(envelope, :bytes, bytes)}
    end
  end

  @doc "Encode and validate one server plaintext frame."
  @spec encode_server_frame(String.t(), map(), pos_integer(), binary()) ::
          {:ok, binary()} | {:error, term()}
  def encode_server_frame(type, payload, seq, bytes \\ <<>>)
      when is_binary(type) and is_map(payload) and is_integer(seq) and is_binary(bytes) do
    encode_server_frame(type, payload, seq, bytes, [])
  end

  @doc "Encode one server frame using the protocol version pinned to this session."
  @spec encode_server_frame(String.t(), map(), pos_integer(), binary(), keyword()) ::
          {:ok, binary()} | {:error, term()}
  def encode_server_frame(type, payload, seq, bytes, opts)
      when is_binary(type) and is_map(payload) and is_integer(seq) and is_binary(bytes) and
             is_list(opts) do
    version = Keyword.get(opts, :version, @protocol_version)

    with {:ok, payload} <- validate_server_frame(type, payload, seq, bytes, version) do
      encode_frame(type, payload, seq, bytes, version)
    end
  end

  @doc """
  Encode one logical server event as the frames it needs, sequenced from
  `seq`: one frame, or, when its header would exceed the 4 KiB cap, a run of
  two or more `event_part` frames. A `text_done` or `row` text, or the content
  of a one-row `history_page`, that would push the event past 1 MiB is cut on a
  UTF-8 boundary and marked `"truncated": true`; any other event that large
  is refused.
  """
  @spec encode_server_event(String.t(), map(), pos_integer(), binary(), keyword()) ::
          {:ok, [binary(), ...]} | {:error, term()}
  def encode_server_event(type, payload, seq, bytes, opts)
      when is_binary(type) and is_map(payload) and is_integer(seq) and is_binary(bytes) and
             is_list(opts) do
    version = Keyword.get(opts, :version, @protocol_version)

    with :ok <- logical_type(type),
         {:ok, payload} <- validate_server_frame(type, payload, seq, bytes, version) do
      event_frames(type, payload, seq, bytes, version)
    end
  end

  defp validate_server_frame(type, payload, seq, bytes, version) do
    with :ok <- known_type(type, @server_events),
         :ok <- negotiate(version),
         :ok <- valid_seq(seq),
         {:ok, payload} <- stringify_top_level(payload),
         :ok <- reject_reserved(payload),
         :ok <- validate_server_event(type, payload),
         :ok <- validate_binary(type, bytes, @raw_server_events) do
      {:ok, payload}
    end
  end

  defp logical_type("event_part"), do: {:error, :nested_event_part}
  defp logical_type(_type), do: :ok

  defp validate_client_event(%{type: type, payload: payload, version: version}, max_media_bytes) do
    if type in ChatProtocol.shared_client_events() do
      ChatProtocol.validate_client_payload(type, payload)
    else
      with :ok <- require_fields(type, payload, @client_required),
           :ok <- validate_envelope_payload(type, payload, version) do
        validate_client_payload(type, payload, max_media_bytes)
      end
    end
  end

  defp validate_server_event(type, payload) do
    if type in ChatProtocol.shared_server_events() do
      ChatProtocol.validate_server_payload(type, payload)
    else
      with :ok <- require_fields(type, payload, @server_required) do
        validate_server_payload(type, payload)
      end
    end
  end

  defp split_frame(frame) when byte_size(frame) > @max_plaintext_bytes,
    do: {:error, {:frame_too_large, byte_size(frame), @max_plaintext_bytes}}

  defp split_frame(<<header_size::unsigned-big-32, rest::binary>>) do
    cond do
      header_size > @max_header_bytes ->
        {:error, {:header_too_large, header_size, @max_header_bytes}}

      byte_size(rest) < header_size ->
        {:error, :truncated_frame}

      true ->
        <<header::binary-size(header_size), bytes::binary>> = rest
        {:ok, header, bytes}
    end
  end

  defp split_frame(_frame), do: {:error, :truncated_frame}

  defp decode_envelope(header, known_events) do
    with {:ok, decoded} <- decode_json_object(header),
         {:ok, version} <- fetch_integer(decoded, "v"),
         :ok <- supported_version(version),
         {:ok, type} <- fetch_nonempty(decoded, "t"),
         :ok <- known_type(type, known_events),
         {:ok, seq} <- fetch_integer(decoded, "seq"),
         :ok <- valid_seq(seq) do
      {:ok,
       %{
         version: version,
         type: type,
         seq: seq,
         payload: Map.drop(decoded, ~w(v t seq))
       }}
    end
  end

  # A client outside the window must learn which side has to update, so the
  # refusal carries the direction and the version it sent.
  defp supported_version(version) do
    case negotiate(version) do
      :ok -> :ok
      {:error, direction} -> {:error, {:unsupported_protocol_version, direction, version}}
    end
  end

  defp decode_json_object(header) do
    case Jason.decode(header) do
      {:ok, %{} = decoded} -> {:ok, decoded}
      {:ok, _other} -> {:error, :invalid_event}
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  defp encode_frame(type, payload, seq, bytes, version) do
    header = Map.merge(payload, %{"v" => version, "t" => type, "seq" => seq})

    with {:ok, json} <- encode_json(header) do
      pack_frame(json, bytes)
    end
  end

  # Only an event without a raw tail is ever split: `media_chunk` bounds its
  # own header, and its bytes already fill a frame.
  defp event_frames(type, payload, seq, <<>>, version) do
    header = Map.merge(payload, %{"v" => version, "t" => type, "seq" => seq})

    with {:ok, json} <- encode_json(header) do
      header_frames(json, Map.put(payload, "t", type), seq, version)
    end
  end

  defp event_frames(type, payload, seq, bytes, version) do
    with {:ok, frame} <- encode_frame(type, payload, seq, bytes, version), do: {:ok, [frame]}
  end

  defp header_frames(json, _logical, _seq, _version) when byte_size(json) <= @max_header_bytes,
    do: {:ok, [<<byte_size(json)::unsigned-big-32, json::binary>>]}

  defp header_frames(_json, logical, seq, version), do: event_parts(logical, seq, version)

  defp event_parts(logical, seq, version) do
    with {:ok, json} <- encode_json(logical),
         {:ok, json} <- fit_event(logical, json),
         slices = event_slices(json),
         :ok <- valid_seq(seq + length(slices) - 1) do
      encode_parts(slices, seq, version)
    end
  end

  defp encode_parts(slices, seq, version) do
    count = length(slices)

    slices
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {slice, index}, {:ok, frames} ->
      part = %{"index" => index, "count" => count}

      case encode_frame("event_part", part, seq + index, slice, version) do
        {:ok, frame} -> {:cont, {:ok, [frame | frames]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, frames} -> {:ok, Enum.reverse(frames)}
      {:error, _reason} = error -> error
    end)
  end

  # Equal slices, the last possibly shorter, never fewer than two: an event
  # that fits one frame is sent as one. Bounded by the 1 MiB event cap.
  defp event_slices(json) do
    size = byte_size(json)
    count = max(2, div(size + @max_raw_chunk_bytes - 1, @max_raw_chunk_bytes))
    slices(json, div(size + count - 1, count), [])
  end

  defp slices(json, slice_bytes, acc) when byte_size(json) <= slice_bytes,
    do: Enum.reverse([json | acc])

  defp slices(json, slice_bytes, acc) do
    <<slice::binary-size(slice_bytes), rest::binary>> = json
    slices(rest, slice_bytes, [slice | acc])
  end

  # A reply, an announced row, or the one row of a history page, too long for
  # one logical event ships cut and marked; the stored row stays whole. Nothing
  # else is cut.
  defp fit_event(_logical, json) when byte_size(json) <= @max_event_bytes, do: {:ok, json}

  defp fit_event(%{"t" => type, "text" => text} = event, _json)
       when type in ["text_done", "row"] and is_binary(text) do
    cut_text(text, &(event |> Map.put("text", &1) |> Map.put("truncated", true)))
  end

  defp fit_event(
         %{"t" => "history_page", "messages" => [%{"content" => content} = row]} = event,
         _json
       )
       when is_binary(content) do
    cut_text(content, fn cut ->
      Map.put(event, "messages", [row |> Map.put("content", cut) |> Map.put("truncated", true)])
    end)
  end

  defp fit_event(_logical, json), do: within_event_cap(json)

  # `rebuild` puts a cut of the text back into its event.
  defp cut_text(text, rebuild) do
    with {:ok, skeleton} <- encode_json(rebuild.("")),
         cut = escaped_prefix(text, max(@max_event_bytes - byte_size(skeleton), 0)),
         {:ok, json} <- encode_json(rebuild.(cut)) do
      within_event_cap(json)
    end
  end

  # JSON escaping only ever lengthens text, so one cut to the budget and one
  # more by whatever escaping added always lands within it.
  defp escaped_prefix(text, budget) do
    first = Text.truncate_utf8(text, budget)
    excess = escaped_bytes(first) - budget

    if excess > 0,
      do: Text.truncate_utf8(first, max(byte_size(first) - excess, 0)),
      else: first
  end

  # The whole event already encoded, so this text is valid UTF-8.
  defp escaped_bytes(text), do: byte_size(Jason.encode!(text)) - 2

  defp within_event_cap(json) when byte_size(json) <= @max_event_bytes, do: {:ok, json}

  defp within_event_cap(json),
    do: {:error, {:event_too_large, byte_size(json), @max_event_bytes}}

  defp encode_json(value) do
    case Jason.encode(value) do
      {:ok, json} -> {:ok, json}
      {:error, reason} -> {:error, {:invalid_payload, reason}}
    end
  end

  defp pack_frame(json, _bytes) when byte_size(json) > @max_header_bytes,
    do: {:error, {:header_too_large, byte_size(json), @max_header_bytes}}

  defp pack_frame(json, bytes)
       when byte_size(json) + byte_size(bytes) + 4 > @max_plaintext_bytes do
    size = byte_size(json) + byte_size(bytes) + 4
    {:error, {:frame_too_large, size, @max_plaintext_bytes}}
  end

  defp pack_frame(json, bytes),
    do: {:ok, <<byte_size(json)::unsigned-big-32, json::binary, bytes::binary>>}

  defp stringify_top_level(payload) do
    Enum.reduce_while(payload, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      with {:ok, key} <- stringify_key(key),
           false <- Map.has_key?(acc, key) do
        {:cont, {:ok, Map.put(acc, key, value)}}
      else
        true -> {:halt, {:error, {:duplicate_field, to_string(key)}}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp stringify_key(key) when is_binary(key), do: {:ok, key}
  defp stringify_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp stringify_key(key), do: {:error, {:invalid_field_name, key}}

  # The envelope fields are this module's to write, and an absent optional
  # field is an absent key, never an explicit null, as on the companion wire.
  defp reject_reserved(payload) do
    case Enum.find(~w(v t seq), &Map.has_key?(payload, &1)) do
      nil -> reject_null(payload)
      field -> {:error, {:reserved_field, field}}
    end
  end

  defp reject_null(payload) do
    case Enum.find(payload, fn {_field, value} -> is_nil(value) end) do
      nil -> :ok
      {field, nil} -> {:error, {:null_field, field}}
    end
  end

  defp require_fields(type, payload, required) do
    missing = Enum.find(Map.fetch!(required, type), &(not Map.has_key?(payload, &1)))
    if is_nil(missing), do: :ok, else: {:error, {:missing_field, missing}}
  end

  defp validate_client_payload("hello", payload, _max), do: validate_hello(payload)

  defp validate_client_payload("attach_begin", payload, max),
    do: validate_transfer_begin(payload, max)

  defp validate_client_payload("attach_chunk", payload, _max), do: validate_chunk(payload)
  defp validate_client_payload("attach_end", payload, _max), do: validate_transfer_end(payload)
  defp validate_client_payload("history_pull", payload, _max), do: validate_history_pull(payload)
  defp validate_client_payload("media_fetch", payload, _max), do: nonempty(payload, "ref")
  defp validate_client_payload("push_register", payload, _max), do: validate_push(payload)
  defp validate_client_payload("ack", payload, _max), do: nonnegative_u64(payload, "server_seq")

  defp validate_client_payload("request_status", payload, _max),
    do: validate_request_status(payload)

  defp validate_client_payload("pair_request", payload, _max), do: validate_pair_request(payload)
  defp validate_client_payload(type, _payload, _max) when type in ~w(unpair ping), do: :ok

  defp validate_hello(payload) do
    with :ok <- nonempty(payload, "device_id"),
         :ok <- nonempty(payload, "app_version"),
         :ok <- nonnegative_u64(payload, "last_server_seq"),
         :ok <- positive_integer(payload, "protocol_v") do
      :ok
    end
  end

  defp validate_transfer_begin(payload, max) do
    with :ok <- nonempty(payload, "attach_id"),
         :ok <- nonempty(payload, "kind"),
         :ok <- nonempty(payload, "mime"),
         :ok <- bounded_size(payload, "size_bytes", max),
         :ok <- sha256(payload, "sha256") do
      optional_nonempty(payload, "name")
    end
  end

  defp validate_chunk(payload) do
    with :ok <- nonempty(payload, "attach_id") do
      nonnegative_u64(payload, "index")
    end
  end

  defp validate_transfer_end(payload) do
    with :ok <- nonempty(payload, "attach_id") do
      sha256(payload, "sha256")
    end
  end

  defp validate_history_pull(payload) do
    with :ok <- nonempty(payload, "profile_id"),
         :ok <- history_cursor(payload) do
      integer_range(payload, "limit", 1, 200)
    end
  end

  # Exactly one cursor: `after_seq` pages forward (the catch-up read), and
  # `before_seq` pages backward from it (a fresh phone's newest page, then
  # older ones).
  defp history_cursor(%{"after_seq" => _after, "before_seq" => _before}),
    do: {:error, {:invalid_field, "before_seq"}}

  defp history_cursor(%{"before_seq" => _before} = payload),
    do: positive_u64(payload, "before_seq")

  defp history_cursor(%{"after_seq" => _after} = payload),
    do: nonnegative_u64(payload, "after_seq")

  defp history_cursor(_payload), do: {:error, {:missing_field, "after_seq"}}

  # How requests stand, asked after a reconnect: 1 to 32 client message ids.
  defp validate_request_status(%{"client_msg_ids" => ids})
       when is_list(ids) and length(ids) in 1..@max_status_requests do
    if Enum.all?(ids, &(is_binary(&1) and &1 != "")),
      do: :ok,
      else: {:error, {:invalid_field, "client_msg_ids"}}
  end

  defp validate_request_status(_payload), do: {:error, {:invalid_field, "client_msg_ids"}}

  defp validate_push(payload) do
    with :ok <- nonempty(payload, "apns_token") do
      enum(payload, "environment", ~w(development production))
    end
  end

  defp validate_pair_request(payload) do
    with :ok <- nonempty(payload, "device_name"),
         :ok <- nonempty(payload, "model"),
         :ok <- nonempty(payload, "app_version"),
         :ok <- enum(payload, "platform", @platforms) do
      validate_attestation(payload["attestation"])
    end
  end

  # A pairing presents its secure-hardware attestation: the kind, and the
  # length of each DER certificate of the chain its raw tail carries, leaf
  # first. The chain is checked for shape here and not verified (M51 D3).
  defp validate_attestation(%{"kind" => kind, "cert_lengths" => lengths}) do
    cond do
      kind not in @attestation_kinds -> {:error, {:invalid_field, "attestation.kind"}}
      not cert_lengths?(lengths) -> {:error, {:invalid_field, "attestation.cert_lengths"}}
      true -> :ok
    end
  end

  defp validate_attestation(_attestation), do: {:error, {:invalid_field, "attestation"}}

  defp cert_lengths?(lengths)
       when is_list(lengths) and length(lengths) in 1..@max_attestation_certs,
       do: Enum.all?(lengths, &(is_integer(&1) and &1 > 0))

  defp cert_lengths?(_lengths), do: false

  # The certificates, cut by their lengths, are the whole tail.
  defp validate_attestation_chain(%{type: "pair_request", payload: payload}, bytes) do
    size = byte_size(bytes)

    cond do
      size > @max_attestation_chain_bytes ->
        {:error, {:attestation_chain_too_large, size, @max_attestation_chain_bytes}}

      Enum.sum(payload["attestation"]["cert_lengths"]) != size ->
        {:error, {:invalid_field, "attestation.cert_lengths"}}

      true ->
        :ok
    end
  end

  defp validate_attestation_chain(_envelope, _bytes), do: :ok

  defp validate_server_payload("hello_ack", payload), do: validate_hello_ack(payload)
  defp validate_server_payload("attach_status", payload), do: validate_attach_status(payload)
  # This wire's own: the companion's `turn_done` is a version 2 event of that
  # wire, so the shared chat vocabulary does not carry it.
  defp validate_server_payload("turn_done", payload), do: nonempty(payload, "turn_id")

  defp validate_server_payload("media_begin", payload), do: validate_media_begin(payload)
  defp validate_server_payload("media_chunk", payload), do: validate_media_chunk(payload)
  defp validate_server_payload("media_end", payload), do: validate_media_end(payload)

  defp validate_server_payload("reaction", payload), do: strings(payload, ~w(in_reply_to emoji))
  defp validate_server_payload("link_preview", payload), do: validate_link_preview(payload)
  defp validate_server_payload("history_page", payload), do: validate_history_page(payload)

  defp validate_server_payload("request_status_page", payload),
    do: validate_request_status_page(payload)

  defp validate_server_payload("notice", payload), do: strings(payload, ~w(kind text))
  defp validate_server_payload("pair_approved", payload), do: validate_pair_approved(payload)
  defp validate_server_payload("pair_denied", payload), do: nonempty(payload, "reason")
  # A request's failure names the request it ends (`client_msg_id`).
  defp validate_server_payload("error", payload) do
    with :ok <- strings(payload, ~w(code message)) do
      optional_nonempty(payload, "client_msg_id")
    end
  end

  defp validate_server_payload("pong", _payload), do: :ok
  defp validate_server_payload("event_part", payload), do: validate_event_part(payload)

  defp validate_hello_ack(payload) do
    with :ok <- nonempty(payload, "session_id"),
         :ok <- positive_integer(payload, "min_version"),
         :ok <- positive_integer(payload, "max_version"),
         :ok <- valid_version_range(payload),
         :ok <- list_field(payload, "profiles"),
         :ok <- list_field(payload, "candidates"),
         :ok <- nonnegative_u64(payload, "history_head_seq"),
         :ok <- nonnegative_u64(payload, "read_up_to_seq") do
      map_field(payload, "caps")
    end
  end

  defp valid_version_range(%{
         "min_version" => @min_supported_version,
         "max_version" => @protocol_version
       }),
       do: :ok

  defp valid_version_range(_payload), do: {:error, {:invalid_field, "version_range"}}

  defp validate_attach_status(payload) do
    with :ok <- nonempty(payload, "attach_id") do
      enum(payload, "status", ~w(upload present))
    end
  end

  defp validate_media_begin(payload) do
    with :ok <- strings(payload, ~w(ref kind mime)),
         :ok <- positive_u64(payload, "server_seq"),
         :ok <- nonnegative_u64(payload, "size_bytes"),
         :ok <- sha256(payload, "sha256"),
         :ok <- optional_nonempty(payload, "filename"),
         :ok <- optional_nonempty(payload, "caption") do
      :ok
    end
  end

  defp validate_media_chunk(payload) do
    with :ok <- nonempty(payload, "ref") do
      nonnegative_u64(payload, "index")
    end
  end

  defp validate_media_end(payload) do
    with :ok <- nonempty(payload, "ref") do
      sha256(payload, "sha256")
    end
  end

  defp validate_link_preview(payload) do
    with :ok <- nonnegative_u64(payload, "in_reply_to"),
         :ok <- strings(payload, ~w(url site title)),
         :ok <- optional_binary(payload, "description") do
      optional_nonempty(payload, "image_ref")
    end
  end

  defp validate_history_page(payload) do
    with :ok <- nonempty(payload, "profile_id"),
         :ok <- list_field(payload, "messages"),
         :ok <- nonnegative_u64(payload, "next_after_seq"),
         :ok <- nonnegative_u64(payload, "history_head_seq") do
      optional_positive_u64(payload, "prev_before_seq")
    end
  end

  defp validate_request_status_page(%{"requests" => requests})
       when is_list(requests) and length(requests) <= @max_status_requests do
    if Enum.all?(requests, &request_outcome?/1),
      do: :ok,
      else: {:error, {:invalid_field, "requests"}}
  end

  defp validate_request_status_page(_payload), do: {:error, {:invalid_field, "requests"}}

  defp request_outcome?(%{"client_msg_id" => id, "status" => status} = outcome)
       when is_binary(id) and id != "" and status in @request_states do
    Enum.all?(
      [
        optional_nonempty(outcome, "turn_id"),
        optional_positive_u64(outcome, "result_server_seq"),
        optional_nonempty(outcome, "error")
      ],
      &(&1 == :ok)
    )
  end

  defp request_outcome?(_outcome), do: false

  defp validate_pair_approved(payload) do
    with :ok <- nonempty(payload, "device_id"),
         :ok <- list_field(payload, "candidates"),
         :ok <- list_field(payload, "profiles") do
      base64_bytes(payload, "push_salt", 32)
    end
  end

  defp validate_event_part(payload) do
    with :ok <- integer_range(payload, "count", 2, @max_event_parts) do
      integer_range(payload, "index", 0, payload["count"] - 1)
    end
  end

  defp validate_binary(type, bytes, raw_types) do
    if type in raw_types, do: validate_raw_tail(bytes), else: validate_no_tail(type, bytes)
  end

  defp validate_raw_tail(bytes) do
    size = byte_size(bytes)

    cond do
      size == 0 -> {:error, {:missing_field, "bytes"}}
      size > @max_raw_chunk_bytes -> {:error, {:raw_chunk_too_large, size, @max_raw_chunk_bytes}}
      true -> :ok
    end
  end

  defp validate_no_tail(_type, <<>>), do: :ok
  defp validate_no_tail(type, _bytes), do: {:error, {:unexpected_binary, type}}

  defp validate_envelope_payload("hello", %{"protocol_v" => version}, version), do: :ok

  defp validate_envelope_payload("hello", _payload, _version),
    do: {:error, :protocol_version_mismatch}

  defp validate_envelope_payload(_type, _payload, _version), do: :ok

  defp known_type(type, known) do
    if type in known, do: :ok, else: {:error, {:unknown_event, type}}
  end

  defp valid_seq(value) when is_integer(value) and value >= 1 and value <= @max_u64, do: :ok
  defp valid_seq(_value), do: {:error, :invalid_seq}

  defp fetch_integer(map, field) do
    case Map.get(map, field) do
      value when is_integer(value) -> {:ok, value}
      _value -> {:error, {:invalid_field, field}}
    end
  end

  defp fetch_nonempty(map, field) do
    case Map.get(map, field) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, {:invalid_field, field}}
    end
  end

  defp strings(payload, fields) do
    Enum.reduce_while(fields, :ok, fn field, :ok ->
      case nonempty(payload, field) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp nonempty(payload, field) do
    case Map.get(payload, field) do
      value when is_binary(value) and value != "" -> :ok
      _value -> {:error, {:invalid_field, field}}
    end
  end

  defp optional_nonempty(payload, field) do
    case Map.get(payload, field) do
      nil -> :ok
      value when is_binary(value) and value != "" -> :ok
      _value -> {:error, {:invalid_field, field}}
    end
  end

  defp optional_binary(payload, field) do
    value = Map.get(payload, field)
    if is_nil(value) or is_binary(value), do: :ok, else: {:error, {:invalid_field, field}}
  end

  defp list_field(payload, field) do
    if is_list(Map.get(payload, field)), do: :ok, else: {:error, {:invalid_field, field}}
  end

  defp map_field(payload, field) do
    if is_map(Map.get(payload, field)), do: :ok, else: {:error, {:invalid_field, field}}
  end

  defp positive_integer(payload, field), do: integer_range(payload, field, 1, @max_u64)
  defp positive_u64(payload, field), do: integer_range(payload, field, 1, @max_u64)
  defp nonnegative_u64(payload, field), do: integer_range(payload, field, 0, @max_u64)

  defp optional_positive_u64(payload, field) do
    if Map.has_key?(payload, field), do: positive_u64(payload, field), else: :ok
  end

  defp integer_range(payload, field, min, max) do
    case Map.get(payload, field) do
      value when is_integer(value) and value >= min and value <= max -> :ok
      _value -> {:error, {:invalid_field, field}}
    end
  end

  defp bounded_size(payload, field, max), do: integer_range(payload, field, 0, max)

  defp enum(payload, field, values) do
    if Map.get(payload, field) in values, do: :ok, else: {:error, {:invalid_field, field}}
  end

  defp sha256(payload, field) do
    case Map.get(payload, field) do
      <<value::binary-size(64)>> ->
        if String.match?(value, ~r/\A[0-9a-fA-F]{64}\z/),
          do: :ok,
          else: {:error, {:invalid_field, field}}

      _value ->
        {:error, {:invalid_field, field}}
    end
  end

  defp base64_bytes(payload, field, size) do
    with value when is_binary(value) <- Map.get(payload, field),
         {:ok, decoded} when byte_size(decoded) == size <- Base.decode64(value) do
      :ok
    else
      _invalid -> {:error, {:invalid_field, field}}
    end
  end

  defp validate_media_cap(value) when is_integer(value) and value > 0, do: :ok
  defp validate_media_cap(_value), do: {:error, :invalid_max_media_bytes}
end
