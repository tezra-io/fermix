defmodule FermixChannels.Mobile.Protocol do
  @moduledoc """
  Pure codec for the encrypted mobile channel's plaintext frames.

  A frame is a 32-bit unsigned big-endian JSON-header length, the JSON header,
  then optional raw bytes. The enclosing Noise transport supplies secrecy,
  authentication, and message boundaries. This module performs no I/O and owns
  no connection state; `Mobile.SocketHandler` owns hello-first and sequence
  ordering checks.

  The canonical cross-repository export lives under `fermix_core/priv/mobile/`.
  The iOS repository vendors those files pinned by checksum.
  """

  @protocol_version 1
  @min_supported_version max(1, @protocol_version - 1)
  @max_header_bytes 4_096
  @max_raw_chunk_bytes 60 * 1_024
  @max_plaintext_bytes 65_535 - 16
  @max_u64 18_446_744_073_709_551_615
  @default_max_media_bytes 20 * 1_024 * 1_024
  @max_approval_command_length 1_024

  @client_events ~w(
    hello msg attach_begin attach_chunk attach_end command history_pull media_fetch
    push_register ack read_state pair_request unpair ping
  )
  @server_events ~w(
    hello_ack accepted attach_status turn_started text_delta tool_event text_done
    media_begin media_chunk media_end turn_error reaction approval approval_resolved
    link_preview read_state history_page notice pair_approved pair_denied error pong
  )

  @client_required %{
    "hello" => ~w(device_id app_version last_server_seq protocol_v),
    "msg" => ~w(client_msg_id profile_id text attach_ids),
    "attach_begin" => ~w(attach_id kind mime size_bytes sha256),
    "attach_chunk" => ~w(attach_id index),
    "attach_end" => ~w(attach_id sha256),
    "command" => ~w(client_msg_id profile_id name),
    "history_pull" => ~w(profile_id after_seq limit),
    "media_fetch" => ~w(ref),
    "push_register" => ~w(apns_token environment),
    "ack" => ~w(server_seq),
    "read_state" => ~w(profile_id read_up_to_seq),
    "pair_request" => ~w(device_name model app_version),
    "unpair" => [],
    "ping" => []
  }

  @server_required %{
    "hello_ack" =>
      ~w(session_id min_version max_version profiles candidates history_head_seq read_up_to_seq caps),
    "accepted" => ~w(client_msg_id duplicate),
    "attach_status" => ~w(attach_id status),
    "turn_started" => ~w(profile_id turn_id in_reply_to),
    "text_delta" => ~w(turn_id text),
    "tool_event" => ~w(turn_id tool phase),
    "text_done" => ~w(turn_id server_seq text),
    "media_begin" => ~w(ref server_seq kind mime size_bytes sha256),
    "media_chunk" => ~w(ref index),
    "media_end" => ~w(ref sha256),
    "turn_error" => ~w(turn_id code message),
    "reaction" => ~w(in_reply_to emoji),
    "approval" => ~w(approval_id kind text token ttl_s approve_command deny_command),
    "approval_resolved" => ~w(approval_id outcome),
    "link_preview" => ~w(in_reply_to url site title),
    "read_state" => ~w(profile_id read_up_to_seq),
    "history_page" => ~w(profile_id messages),
    "notice" => ~w(kind text),
    "pair_approved" => ~w(device_id candidates profiles),
    "pair_denied" => ~w(reason),
    "error" => ~w(code message),
    "pong" => []
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

  @doc "Inclusive N/N-1 protocol versions accepted by this daemon."
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

  @doc "Negotiate a client version against the daemon's inclusive N/N-1 window."
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
         :ok <- require_fields(envelope.type, envelope.payload, @client_required),
         :ok <- validate_envelope_payload(envelope.type, envelope.payload, envelope.version),
         :ok <- validate_client_payload(envelope.type, envelope.payload, max_media_bytes),
         :ok <- validate_binary(envelope.type, bytes, "attach_chunk") do
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

    with :ok <- known_type(type, @server_events),
         :ok <- negotiate(version),
         :ok <- valid_seq(seq),
         {:ok, payload} <- stringify_top_level(payload),
         :ok <- reject_reserved(payload),
         :ok <- require_fields(type, payload, @server_required),
         :ok <- validate_server_payload(type, payload),
         :ok <- validate_binary(type, bytes, "media_chunk"),
         {:ok, frame} <- encode_frame(type, payload, seq, bytes, version) do
      {:ok, frame}
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
         :ok <- negotiate(version),
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

  defp decode_json_object(header) do
    case Jason.decode(header) do
      {:ok, %{} = decoded} -> {:ok, decoded}
      {:ok, _other} -> {:error, :invalid_event}
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  defp encode_frame(type, payload, seq, bytes, version) do
    header = Map.merge(payload, %{"v" => version, "t" => type, "seq" => seq})

    case Jason.encode(header) do
      {:ok, json} -> pack_frame(json, bytes)
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

  defp reject_reserved(payload) do
    case Enum.find(~w(v t seq), &Map.has_key?(payload, &1)) do
      nil -> :ok
      field -> {:error, {:reserved_field, field}}
    end
  end

  defp require_fields(type, payload, required) do
    missing = Enum.find(Map.fetch!(required, type), &(not Map.has_key?(payload, &1)))
    if is_nil(missing), do: :ok, else: {:error, {:missing_field, missing}}
  end

  defp validate_client_payload("hello", payload, _max), do: validate_hello(payload)
  defp validate_client_payload("msg", payload, _max), do: validate_message(payload)

  defp validate_client_payload("attach_begin", payload, max),
    do: validate_transfer_begin(payload, max)

  defp validate_client_payload("attach_chunk", payload, _max), do: validate_chunk(payload)
  defp validate_client_payload("attach_end", payload, _max), do: validate_transfer_end(payload)
  defp validate_client_payload("command", payload, _max), do: validate_command(payload)
  defp validate_client_payload("history_pull", payload, _max), do: validate_history_pull(payload)
  defp validate_client_payload("media_fetch", payload, _max), do: nonempty(payload, "ref")
  defp validate_client_payload("push_register", payload, _max), do: validate_push(payload)
  defp validate_client_payload("ack", payload, _max), do: nonnegative_u64(payload, "server_seq")
  defp validate_client_payload("read_state", payload, _max), do: validate_read_state(payload)
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

  defp validate_message(payload) do
    with :ok <- nonempty(payload, "client_msg_id"),
         :ok <- nonempty(payload, "profile_id"),
         :ok <- binary_field(payload, "text"),
         :ok <- string_list(payload, "attach_ids") do
      has_text = String.trim(payload["text"]) != ""

      if has_text or payload["attach_ids"] != [],
        do: :ok,
        else: {:error, {:missing_field, "content"}}
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

  defp validate_command(payload) do
    with :ok <- nonempty(payload, "client_msg_id"),
         :ok <- nonempty(payload, "profile_id"),
         :ok <- nonempty(payload, "name") do
      optional_binary(payload, "args")
    end
  end

  defp validate_history_pull(payload) do
    with :ok <- nonempty(payload, "profile_id"),
         :ok <- nonnegative_u64(payload, "after_seq") do
      integer_range(payload, "limit", 1, 200)
    end
  end

  defp validate_push(payload) do
    with :ok <- nonempty(payload, "apns_token") do
      enum(payload, "environment", ~w(development production))
    end
  end

  defp validate_read_state(payload) do
    with :ok <- nonempty(payload, "profile_id") do
      nonnegative_u64(payload, "read_up_to_seq")
    end
  end

  defp validate_pair_request(payload) do
    with :ok <- nonempty(payload, "device_name"),
         :ok <- nonempty(payload, "model") do
      nonempty(payload, "app_version")
    end
  end

  defp validate_server_payload("hello_ack", payload), do: validate_hello_ack(payload)
  defp validate_server_payload("accepted", payload), do: validate_accepted(payload)
  defp validate_server_payload("attach_status", payload), do: validate_attach_status(payload)

  defp validate_server_payload("turn_started", payload),
    do: strings(payload, ~w(profile_id turn_id in_reply_to))

  defp validate_server_payload("text_delta", payload), do: text_event(payload)
  defp validate_server_payload("tool_event", payload), do: validate_tool_event(payload)
  defp validate_server_payload("text_done", payload), do: validate_text_done(payload)
  defp validate_server_payload("media_begin", payload), do: validate_media_begin(payload)
  defp validate_server_payload("media_chunk", payload), do: validate_media_chunk(payload)
  defp validate_server_payload("media_end", payload), do: validate_media_end(payload)

  defp validate_server_payload("turn_error", payload),
    do: strings(payload, ~w(turn_id code message))

  defp validate_server_payload("reaction", payload), do: strings(payload, ~w(in_reply_to emoji))
  defp validate_server_payload("approval", payload), do: validate_approval(payload)
  defp validate_server_payload("approval_resolved", payload), do: validate_resolution(payload)
  defp validate_server_payload("link_preview", payload), do: validate_link_preview(payload)
  defp validate_server_payload("read_state", payload), do: validate_read_state(payload)
  defp validate_server_payload("history_page", payload), do: validate_history_page(payload)
  defp validate_server_payload("notice", payload), do: strings(payload, ~w(kind text))
  defp validate_server_payload("pair_approved", payload), do: validate_pair_approved(payload)
  defp validate_server_payload("pair_denied", payload), do: nonempty(payload, "reason")
  defp validate_server_payload("error", payload), do: strings(payload, ~w(code message))
  defp validate_server_payload("pong", _payload), do: :ok

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

  defp validate_accepted(payload) do
    with :ok <- nonempty(payload, "client_msg_id") do
      boolean_field(payload, "duplicate")
    end
  end

  defp validate_attach_status(payload) do
    with :ok <- nonempty(payload, "attach_id") do
      enum(payload, "status", ~w(upload present))
    end
  end

  defp text_event(payload) do
    with :ok <- nonempty(payload, "turn_id") do
      binary_field(payload, "text")
    end
  end

  defp validate_tool_event(payload) do
    with :ok <- nonempty(payload, "turn_id"),
         :ok <- nonempty(payload, "tool") do
      enum(payload, "phase", ~w(start stop))
    end
  end

  defp validate_text_done(payload) do
    with :ok <- text_event(payload) do
      positive_u64(payload, "server_seq")
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

  defp validate_approval(payload) do
    with :ok <- strings(payload, ~w(approval_id kind text token)),
         :ok <- positive_integer(payload, "ttl_s"),
         :ok <- bounded_nonempty(payload, "approve_command", @max_approval_command_length),
         :ok <- bounded_nonempty(payload, "deny_command", @max_approval_command_length) do
      optional_binary(payload, "detail")
    end
  end

  defp validate_resolution(payload) do
    with :ok <- nonempty(payload, "approval_id") do
      enum(payload, "outcome", ~w(approved denied expired))
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
         :ok <- list_field(payload, "messages") do
      optional_nonnegative_u64(payload, "next_after_seq")
    end
  end

  defp validate_pair_approved(payload) do
    with :ok <- nonempty(payload, "device_id"),
         :ok <- list_field(payload, "candidates") do
      list_field(payload, "profiles")
    end
  end

  defp validate_binary(type, bytes, allowed_type) when type == allowed_type do
    size = byte_size(bytes)

    cond do
      size == 0 -> {:error, {:missing_field, "bytes"}}
      size > @max_raw_chunk_bytes -> {:error, {:raw_chunk_too_large, size, @max_raw_chunk_bytes}}
      true -> :ok
    end
  end

  defp validate_binary(_type, <<>>, _allowed_type), do: :ok
  defp validate_binary(type, _bytes, _allowed_type), do: {:error, {:unexpected_binary, type}}

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

  defp bounded_nonempty(payload, field, max_length) do
    case Map.get(payload, field) do
      value when is_binary(value) and value != "" ->
        if bounded_utf8?(value, max_length),
          do: :ok,
          else: {:error, {:invalid_field, field}}

      _value ->
        {:error, {:invalid_field, field}}
    end
  end

  defp bounded_utf8?(value, max_length) do
    byte_size(value) <= max_length * 4 and
      String.valid?(value) and
      codepoint_length(value) <= max_length
  end

  defp codepoint_length(value), do: value |> String.codepoints() |> length()

  defp binary_field(payload, field) do
    if is_binary(Map.get(payload, field)), do: :ok, else: {:error, {:invalid_field, field}}
  end

  defp optional_binary(payload, field) do
    value = Map.get(payload, field)
    if is_nil(value) or is_binary(value), do: :ok, else: {:error, {:invalid_field, field}}
  end

  defp string_list(payload, field) do
    case Map.get(payload, field) do
      values when is_list(values) ->
        if Enum.all?(values, &(is_binary(&1) and &1 != "")),
          do: :ok,
          else: {:error, {:invalid_field, field}}

      _value ->
        {:error, {:invalid_field, field}}
    end
  end

  defp list_field(payload, field) do
    if is_list(Map.get(payload, field)), do: :ok, else: {:error, {:invalid_field, field}}
  end

  defp map_field(payload, field) do
    if is_map(Map.get(payload, field)), do: :ok, else: {:error, {:invalid_field, field}}
  end

  defp boolean_field(payload, field) do
    if is_boolean(Map.get(payload, field)), do: :ok, else: {:error, {:invalid_field, field}}
  end

  defp positive_integer(payload, field), do: integer_range(payload, field, 1, @max_u64)
  defp positive_u64(payload, field), do: integer_range(payload, field, 1, @max_u64)
  defp nonnegative_u64(payload, field), do: integer_range(payload, field, 0, @max_u64)

  defp optional_nonnegative_u64(payload, field) do
    if Map.has_key?(payload, field), do: nonnegative_u64(payload, field), else: :ok
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

  defp validate_media_cap(value) when is_integer(value) and value > 0, do: :ok
  defp validate_media_cap(_value), do: {:error, :invalid_max_media_bytes}
end
