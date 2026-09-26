defmodule FermixCore.Companion.Protocol do
  @moduledoc """
  Newline-delimited JSON protocol for the local companion chat socket, and the
  one owner of the chat vocabulary.

  This module is the single source of truth for the wire contract between the
  daemon and a native companion (the Mac app first). Its machine-readable export
  lives under `priv/companion/` (`PROTOCOL.md`, `protocol.schema.json`, and the
  golden `fixtures/*.jsonl`); `protocol_contract_test.exs` asserts the export
  never drifts from the values below, and a downstream consumer vendors those
  files pinned by checksum instead of hand-copying the shapes.

  The chat events are transport-neutral payload maps. This socket frames each
  one as a JSON object with a `type` discriminator on its own line; the mobile
  wire frames the same payloads inside its `{v, t, seq}` envelope and delegates
  their validation here (`shared_client_events/0`, `shared_server_events/0`).

  ## Versioning

  A connection opens with a mandatory handshake, exactly as the Realtime socket
  does it: the client sends `client_hello` carrying its `protocol_version`; the
  daemon replies `server_hello` with the inclusive `{min_version, max_version}`
  range it supports (an N/N-1 window derived from one constant). See
  `PROTOCOL.md` for the state machine and the rollout order.
  """

  # Bumped in lockstep with any wire-shape change. The supported range is an
  # N/N-1 window derived from this single constant.
  @protocol_version 1
  @min_supported_version max(1, @protocol_version - 1)

  # The inbound line cap, the same as the Realtime socket's.
  @max_line_bytes 65_536
  @max_u64 18_446_744_073_709_551_615
  @max_history_limit 200
  @max_search_limit 50
  @max_query_length 256
  @max_approval_command_length 1_024

  @client_events ~w(client_hello msg command cancel history_pull history_search read_state)
  @server_events ~w(
    server_hello accepted turn_started text_delta tool_event text_done turn_error approval
    approval_resolved read_state history_page search_results error
  )

  # The chat events whose payload the mobile wire carries verbatim. `history_pull`
  # and `history_page` are not among them: this wire's version 1 adds the
  # backward cursor (`before_seq`, `next_before_seq`) the mobile wire lacks.
  @shared_client_events ~w(msg command read_state)
  @shared_server_events ~w(
    accepted turn_started text_delta tool_event text_done turn_error approval approval_resolved
    read_state
  )

  @client_required %{
    "msg" => ~w(client_msg_id profile_id text attach_ids),
    "command" => ~w(client_msg_id profile_id name),
    "cancel" => ~w(profile_id client_msg_id),
    "history_pull" => ~w(profile_id limit),
    "history_search" => ~w(profile_id query limit),
    "read_state" => ~w(profile_id read_up_to_seq)
  }

  @server_required %{
    "server_hello" => ~w(min_version max_version),
    "accepted" => ~w(client_msg_id duplicate),
    "turn_started" => ~w(profile_id turn_id in_reply_to),
    "text_delta" => ~w(turn_id text),
    "tool_event" => ~w(turn_id tool phase),
    "text_done" => ~w(turn_id server_seq text),
    "turn_error" => ~w(turn_id code message),
    "approval" => ~w(approval_id kind text token ttl_s approve_command deny_command),
    "approval_resolved" => ~w(approval_id outcome),
    "read_state" => ~w(profile_id read_up_to_seq),
    "history_page" => ~w(profile_id messages history_head_seq),
    "search_results" => ~w(profile_id query hits),
    "error" => ~w(reason)
  }

  @type event :: %{type: String.t(), payload: map()}

  @doc "The daemon's current companion wire-protocol version."
  @spec protocol_version() :: pos_integer()
  def protocol_version, do: @protocol_version

  @doc "Inclusive `{min, max}` protocol versions the daemon accepts (an N/N-1 window)."
  @spec supported_version_range() :: {pos_integer(), pos_integer()}
  def supported_version_range, do: {@min_supported_version, @protocol_version}

  @doc "Ordered client event catalog."
  @spec client_events() :: [String.t()]
  def client_events, do: @client_events

  @doc "Ordered server event catalog."
  @spec server_events() :: [String.t()]
  def server_events, do: @server_events

  @doc "The client chat events whose payload the mobile wire shares verbatim."
  @spec shared_client_events() :: [String.t()]
  def shared_client_events, do: @shared_client_events

  @doc "The server chat events whose payload the mobile wire shares verbatim."
  @spec shared_server_events() :: [String.t()]
  def shared_server_events, do: @shared_server_events

  @doc "Maximum bytes of one inbound line, newline excluded."
  @spec max_line_bytes() :: pos_integer()
  def max_line_bytes, do: @max_line_bytes

  @doc "Largest `limit` a `history_pull` may ask for."
  @spec max_history_limit() :: pos_integer()
  def max_history_limit, do: @max_history_limit

  @doc "Largest `limit` a `history_search` may ask for."
  @spec max_search_limit() :: pos_integer()
  def max_search_limit, do: @max_search_limit

  @doc "Longest `history_search` query, in Unicode scalar values."
  @spec max_query_length() :: pos_integer()
  def max_query_length, do: @max_query_length

  @doc """
  Negotiate a client's `protocol_version` against the daemon's supported range.

  `{:error, :client_too_old}` means the client must update, and
  `{:error, :client_too_new}` means the daemon must update.
  """
  @spec negotiate(integer()) :: :ok | {:error, :client_too_old | :client_too_new}
  def negotiate(client_version) when is_integer(client_version) do
    {min, max} = supported_version_range()

    cond do
      client_version < min -> {:error, :client_too_old}
      client_version > max -> {:error, :client_too_new}
      true -> :ok
    end
  end

  @doc "Decode and validate one client line (the newline already removed)."
  @spec decode_client_event(binary()) :: {:ok, event()} | {:error, term()}
  def decode_client_event(line) when is_binary(line) do
    with {:ok, decoded} <- decode_json(line),
         {:ok, type} <- fetch_type(decoded),
         :ok <- known_type(type, @client_events),
         payload = Map.delete(decoded, "type"),
         :ok <- validate_client_event(type, payload) do
      {:ok, %{type: type, payload: payload}}
    end
  end

  @doc "Encode and validate one server event as a newline-terminated line."
  @spec encode_server_event(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def encode_server_event(type, payload) when is_binary(type) and is_map(payload) do
    with :ok <- known_type(type, @server_events),
         {:ok, payload} <- stringify_top_level(payload),
         :ok <- reject_reserved(payload),
         :ok <- validate_server_payload(type, payload),
         {:ok, json} <- encode_json(Map.put(payload, "type", type)) do
      {:ok, json <> "\n"}
    end
  end

  @doc """
  Validate one client chat payload (envelope fields removed): its required
  fields first, in catalog order, then each field's constraint.
  """
  @spec validate_client_payload(String.t(), map()) :: :ok | {:error, term()}
  def validate_client_payload(type, payload) when is_binary(type) and is_map(payload) do
    with {:ok, required} <- fetch_required(@client_required, type),
         :ok <- require_fields(required, payload) do
      validate_client(type, payload)
    end
  end

  @doc """
  Validate one server chat payload (envelope fields removed): its required
  fields first, in catalog order, then each field's constraint.
  """
  @spec validate_server_payload(String.t(), map()) :: :ok | {:error, term()}
  def validate_server_payload(type, payload) when is_binary(type) and is_map(payload) do
    with {:ok, required} <- fetch_required(@server_required, type),
         :ok <- require_fields(required, payload) do
      validate_server(type, payload)
    end
  end

  # `client_hello` is transport, not chat: it has no payload rules beyond the
  # version, and its two errors are the Realtime socket's, verbatim.
  defp validate_client_event("client_hello", payload) do
    case Map.get(payload, "protocol_version") do
      version when is_integer(version) and version > 0 -> :ok
      nil -> {:error, :missing_protocol_version}
      _other -> {:error, :invalid_protocol_version}
    end
  end

  # Attachments ride on the mobile wire's media transfer, which this wire does
  # not carry in version 1: an `attach_ids` entry could only name a blob this
  # client has no way to have uploaded.
  defp validate_client_event("msg", payload) do
    with :ok <- validate_client_payload("msg", payload) do
      if payload["attach_ids"] == [], do: :ok, else: {:error, :attachments_unsupported}
    end
  end

  defp validate_client_event(type, payload), do: validate_client_payload(type, payload)

  defp validate_client("msg", payload) do
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

  defp validate_client("command", payload) do
    with :ok <- nonempty(payload, "client_msg_id"),
         :ok <- nonempty(payload, "profile_id"),
         :ok <- nonempty(payload, "name") do
      optional_binary(payload, "args")
    end
  end

  defp validate_client("cancel", payload), do: strings(payload, ~w(profile_id client_msg_id))

  defp validate_client("history_pull", payload) do
    with :ok <- nonempty(payload, "profile_id"),
         :ok <- history_cursor(payload) do
      integer_range(payload, "limit", 1, @max_history_limit)
    end
  end

  defp validate_client("history_search", payload) do
    with :ok <- nonempty(payload, "profile_id"),
         :ok <- bounded_nonempty(payload, "query", @max_query_length),
         :ok <- integer_range(payload, "limit", 1, @max_search_limit) do
      optional_positive_u64(payload, "before_seq")
    end
  end

  defp validate_client("read_state", payload), do: validate_read_state(payload)

  # Exactly one cursor: `after_seq` pages forward (the catch-up read), and
  # `before_seq` pages backward from it (scroll to the top).
  defp history_cursor(%{"after_seq" => _after, "before_seq" => _before}),
    do: {:error, {:invalid_field, "before_seq"}}

  defp history_cursor(%{"before_seq" => _before} = payload),
    do: integer_range(payload, "before_seq", 1, @max_u64)

  defp history_cursor(%{"after_seq" => _after} = payload),
    do: nonnegative_u64(payload, "after_seq")

  defp history_cursor(_payload), do: {:error, {:missing_field, "after_seq"}}

  defp validate_server("server_hello", payload) do
    with :ok <- positive_u64(payload, "min_version"),
         :ok <- positive_u64(payload, "max_version") do
      valid_version_range(payload)
    end
  end

  defp validate_server("accepted", payload) do
    with :ok <- nonempty(payload, "client_msg_id"),
         :ok <- boolean_field(payload, "duplicate") do
      optional_positive_u64(payload, "server_seq")
    end
  end

  defp validate_server("turn_started", payload),
    do: strings(payload, ~w(profile_id turn_id in_reply_to))

  defp validate_server("text_delta", payload), do: text_event(payload)

  defp validate_server("tool_event", payload) do
    with :ok <- nonempty(payload, "turn_id"),
         :ok <- nonempty(payload, "tool"),
         :ok <- enum(payload, "phase", ~w(start stop)) do
      optional_binary(payload, "detail")
    end
  end

  defp validate_server("text_done", payload) do
    with :ok <- text_event(payload) do
      positive_u64(payload, "server_seq")
    end
  end

  defp validate_server("turn_error", payload), do: strings(payload, ~w(turn_id code message))

  defp validate_server("approval", payload) do
    with :ok <- strings(payload, ~w(approval_id kind text token)),
         :ok <- positive_u64(payload, "ttl_s"),
         :ok <- bounded_nonempty(payload, "approve_command", @max_approval_command_length),
         :ok <- bounded_nonempty(payload, "deny_command", @max_approval_command_length) do
      optional_binary(payload, "detail")
    end
  end

  defp validate_server("approval_resolved", payload) do
    with :ok <- nonempty(payload, "approval_id") do
      enum(payload, "outcome", ~w(approved denied expired))
    end
  end

  defp validate_server("read_state", payload), do: validate_read_state(payload)

  defp validate_server("history_page", payload) do
    with :ok <- nonempty(payload, "profile_id"),
         :ok <- list_field(payload, "messages"),
         :ok <- nonnegative_u64(payload, "history_head_seq"),
         :ok <- optional_nonnegative_u64(payload, "next_after_seq") do
      optional_positive_u64(payload, "next_before_seq")
    end
  end

  defp validate_server("search_results", payload) do
    with :ok <- nonempty(payload, "profile_id"),
         :ok <- binary_field(payload, "query"),
         :ok <- list_field(payload, "hits") do
      optional_positive_u64(payload, "next_before_seq")
    end
  end

  defp validate_server("error", payload), do: nonempty(payload, "reason")

  defp validate_read_state(payload) do
    with :ok <- nonempty(payload, "profile_id") do
      nonnegative_u64(payload, "read_up_to_seq")
    end
  end

  defp text_event(payload) do
    with :ok <- nonempty(payload, "turn_id") do
      binary_field(payload, "text")
    end
  end

  defp valid_version_range(%{
         "min_version" => @min_supported_version,
         "max_version" => @protocol_version
       }),
       do: :ok

  defp valid_version_range(_payload), do: {:error, {:invalid_field, "version_range"}}

  defp decode_json(line) do
    case Jason.decode(line) do
      {:ok, %{} = decoded} -> {:ok, decoded}
      {:ok, _other} -> {:error, :invalid_event}
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  defp encode_json(map) do
    case Jason.encode(map) do
      {:ok, json} -> {:ok, json}
      {:error, reason} -> {:error, {:invalid_payload, reason}}
    end
  end

  defp fetch_type(%{"type" => type}) when is_binary(type) and type != "", do: {:ok, type}
  defp fetch_type(_decoded), do: {:error, :missing_type}

  defp known_type(type, known) do
    if type in known, do: :ok, else: {:error, {:unknown_event, type}}
  end

  defp fetch_required(required, type) do
    case Map.fetch(required, type) do
      {:ok, fields} -> {:ok, fields}
      :error -> {:error, {:unknown_event, type}}
    end
  end

  defp require_fields(required, payload) do
    missing = Enum.find(required, &(not Map.has_key?(payload, &1)))
    if is_nil(missing), do: :ok, else: {:error, {:missing_field, missing}}
  end

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

  # An absent optional field is an absent key on this wire, never an explicit
  # null, and `type` is the discriminator this module writes itself.
  defp reject_reserved(%{"type" => _type}), do: {:error, {:reserved_field, "type"}}

  defp reject_reserved(payload) do
    case Enum.find(payload, fn {_field, value} -> is_nil(value) end) do
      nil -> :ok
      {field, nil} -> {:error, {:null_field, field}}
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

  defp bounded_nonempty(payload, field, max_length) do
    with :ok <- nonempty(payload, field) do
      if bounded_utf8?(payload[field], max_length),
        do: :ok,
        else: {:error, {:invalid_field, field}}
    end
  end

  defp bounded_utf8?(value, max_length) do
    byte_size(value) <= max_length * 4 and
      String.valid?(value) and
      length(String.codepoints(value)) <= max_length
  end

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

  defp boolean_field(payload, field) do
    if is_boolean(Map.get(payload, field)), do: :ok, else: {:error, {:invalid_field, field}}
  end

  defp positive_u64(payload, field), do: integer_range(payload, field, 1, @max_u64)
  defp nonnegative_u64(payload, field), do: integer_range(payload, field, 0, @max_u64)

  defp optional_positive_u64(payload, field) do
    if Map.has_key?(payload, field), do: positive_u64(payload, field), else: :ok
  end

  defp optional_nonnegative_u64(payload, field) do
    if Map.has_key?(payload, field), do: nonnegative_u64(payload, field), else: :ok
  end

  defp integer_range(payload, field, min, max) do
    case Map.get(payload, field) do
      value when is_integer(value) and value >= min and value <= max -> :ok
      _value -> {:error, {:invalid_field, field}}
    end
  end

  defp enum(payload, field, values) do
    if Map.get(payload, field) in values, do: :ok, else: {:error, {:invalid_field, field}}
  end
end
