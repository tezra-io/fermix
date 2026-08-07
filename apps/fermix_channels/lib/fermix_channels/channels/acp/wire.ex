defmodule FermixChannels.Channels.Acp.Wire.Error do
  @moduledoc """
  A JSON-RPC 2.0 error value — `code`, `message`, and optional `data`.

  Built by the constructors on `FermixChannels.Channels.Acp.Wire` (never by
  hand, so the code and its default message never drift apart) and rendered onto
  the wire by `FermixChannels.Channels.Acp.Wire.encode_error/2`.
  """

  @enforce_keys [:code, :message]
  defstruct [:code, :message, :data]

  @type t :: %__MODULE__{code: integer(), message: String.t(), data: term()}
end

defmodule FermixChannels.Channels.Acp.Wire do
  @moduledoc """
  Pure codec for the Agent Client Protocol (ACP) wire: newline-delimited
  JSON-RPC 2.0, wire protocol version 1, schema release `schema-v1.20.0`.

  This module has no processes and does no IO — it turns one line of bytes into
  a classified message and turns a message back into one line of bytes. The
  socket owner (`Channels.Acp.Peer`) does the reading, writing, line splitting,
  size enforcement, and id bookkeeping.

  ## Framing

  Every encoder returns **one complete UTF-8 line with its trailing newline**,
  ready to write. JSON string escaping means a payload containing a raw newline
  can never split a frame. `decode_line/1` accepts a line with or without its
  trailing newline.

  `max_line_bytes/0` is the protocol's 10 MiB line cap — a constant published
  here for the socket owner to enforce while reading; this module never sees a
  partial line.

  ## Classification

  `decode_line/1` returns a map whose `:type` is one of:

  - `:request` — a `method` **and** an `id` (the id is what a response is keyed to)
  - `:notification` — a `method` with no id (or an explicit `null` id); no reply
  - `:response` — no `method`, carrying `result` or `error` (an answer to a
    request this side sent)

  It refuses, with the JSON-RPC code the refusal maps to: unparseable JSON
  (`-32700`); a frame that is not a JSON object, a missing or non-`"2.0"`
  `jsonrpc`, an id that is neither string nor number, a non-string or empty
  `method`, or a method-less frame carrying neither `result` nor `error`
  (`-32600`); `params` that are not an object (`-32602` — ACP never uses
  positional params, and coercing them to an empty map would hand the dispatcher
  a silently empty request).

  ## Version negotiation

  `negotiate/1` always answers with the latest version this agent supports. That
  is the spec's rule, not a lenient one: an agent that does not support the
  client's version replies with the latest version it does support, and the
  *client* decides whether to disconnect. So version `0` gets `1` back rather
  than an error, and a client announcing `2` gets `1` back and proceeds on v1.

  The vendored upstream contract lives in `priv/acp/` (`schema.json`,
  `meta.json`, `PROVENANCE.md`); `contract_test.exs` pins `known_methods/0` and
  `schema_version/0` against it.
  """

  alias FermixChannels.Channels.Acp.Wire.Error

  @protocol_version 1
  @schema_version "schema-v1.20.0"
  @max_line_bytes 10_485_760

  # The client -> agent methods the ACP surface dispatches on. Every entry is
  # pinned against the vendored `meta.json` by `contract_test.exs`; methods the
  # agent *sends* (`session/update`, `session/request_permission`, `fs/*`,
  # `terminal/*`) are deliberately absent.
  @known_methods MapSet.new(~w(
                   initialize
                   authenticate
                   session/new
                   session/load
                   session/list
                   session/resume
                   session/close
                   session/delete
                   session/set_mode
                   session/set_config_option
                   logout
                   session/prompt
                   session/cancel
                   $/cancel_request
                 ))

  @type id :: String.t() | number()

  @type message :: %{
          type: :request | :notification | :response,
          id: id() | nil,
          method: String.t() | nil,
          params: map(),
          result: term(),
          error: term()
        }

  @doc "The ACP wire protocol version this agent speaks."
  @spec protocol_version() :: pos_integer()
  def protocol_version, do: @protocol_version

  @doc "The upstream schema release vendored under `priv/acp/`."
  @spec schema_version() :: String.t()
  def schema_version, do: @schema_version

  @doc "The protocol's maximum line size in bytes. Enforced by the socket owner, not here."
  @spec max_line_bytes() :: pos_integer()
  def max_line_bytes, do: @max_line_bytes

  @doc "The client -> agent methods this surface dispatches on."
  @spec known_methods() :: MapSet.t(String.t())
  def known_methods, do: @known_methods

  @doc """
  Answer a client's announced protocol version with the latest version we speak.

  Always `protocol_version/0` — see the module doc: replying with our latest and
  letting the client decide is the spec's negotiation rule.
  """
  @spec negotiate(integer()) :: pos_integer()
  def negotiate(client_version) when is_integer(client_version), do: @protocol_version

  @doc """
  Decode one NDJSON line into a classified message.

  Returns `{:error, Error.t()}` with the JSON-RPC code the refusal maps to; the
  caller answers requests with `encode_error/2` and drops bad notifications.
  """
  @spec decode_line(binary()) :: {:ok, message()} | {:error, Error.t()}
  def decode_line(line) when is_binary(line) do
    with {:ok, frame} <- parse_object(line),
         :ok <- validate_jsonrpc(frame),
         {:ok, id} <- validate_id(frame),
         {:ok, params} <- validate_params(frame) do
      classify(frame, id, params)
    end
  end

  @doc "Encode a successful response to `id`. Returns one newline-terminated line."
  @spec encode_response(id(), map()) :: binary()
  def encode_response(id, result) when (is_binary(id) or is_number(id)) and is_map(result) do
    encode(%{"jsonrpc" => "2.0", "id" => id, "result" => result})
  end

  @doc """
  Encode an error response to `id`. Returns one newline-terminated line.

  `id` is `nil` only when the request it answers could not be parsed far enough
  to have one — JSON-RPC's null-id case.
  """
  @spec encode_error(id() | nil, Error.t()) :: binary()
  def encode_error(id, %Error{} = error) when is_binary(id) or is_number(id) or is_nil(id) do
    encode(%{"jsonrpc" => "2.0", "id" => id, "error" => error_body(error)})
  end

  @doc "Encode a notification (no id, no reply expected). Returns one newline-terminated line."
  @spec encode_notification(String.t(), map()) :: binary()
  def encode_notification(method, params) when is_binary(method) and is_map(params) do
    encode(%{"jsonrpc" => "2.0", "method" => method, "params" => params})
  end

  @doc "JSON-RPC parse error (-32700): the line was not valid JSON."
  @spec parse_error(String.t() | nil, term()) :: Error.t()
  def parse_error(message \\ nil, data \\ nil), do: build(-32_700, "Parse error", message, data)

  @doc "JSON-RPC invalid request (-32600): the frame is not a well-formed JSON-RPC message."
  @spec invalid_request(String.t() | nil, term()) :: Error.t()
  def invalid_request(message \\ nil, data \\ nil),
    do: build(-32_600, "Invalid Request", message, data)

  @doc "JSON-RPC method not found (-32601): the method is unknown or the capability is not advertised."
  @spec method_not_found(String.t() | nil, term()) :: Error.t()
  def method_not_found(message \\ nil, data \\ nil),
    do: build(-32_601, "Method not found", message, data)

  @doc "JSON-RPC invalid params (-32602): the method's parameters are missing or unusable."
  @spec invalid_params(String.t() | nil, term()) :: Error.t()
  def invalid_params(message \\ nil, data \\ nil),
    do: build(-32_602, "Invalid params", message, data)

  @doc "JSON-RPC internal error (-32603): the agent failed to complete the request."
  @spec internal_error(String.t() | nil, term()) :: Error.t()
  def internal_error(message \\ nil, data \\ nil),
    do: build(-32_603, "Internal error", message, data)

  @doc "ACP auth required (-32000): the client must authenticate before this request."
  @spec auth_required(String.t() | nil, term()) :: Error.t()
  def auth_required(message \\ nil, data \\ nil),
    do: build(-32_000, "Authentication required", message, data)

  @doc "ACP request cancelled (-32800): the request was cancelled via `$/cancel_request`."
  @spec request_cancelled(String.t() | nil, term()) :: Error.t()
  def request_cancelled(message \\ nil, data \\ nil),
    do: build(-32_800, "Request cancelled", message, data)

  defp build(code, default_message, message, data) when is_nil(message) or is_binary(message) do
    %Error{code: code, message: message || default_message, data: data}
  end

  defp parse_object(line) do
    case Jason.decode(line) do
      {:ok, %{} = frame} -> {:ok, frame}
      {:ok, _other} -> {:error, invalid_request("a JSON-RPC frame must be a JSON object")}
      {:error, _reason} -> {:error, parse_error()}
    end
  end

  defp validate_jsonrpc(%{"jsonrpc" => "2.0"}), do: :ok
  defp validate_jsonrpc(_frame), do: {:error, invalid_request(~s(jsonrpc must be "2.0"))}

  defp validate_id(frame) do
    case Map.get(frame, "id") do
      nil -> {:ok, nil}
      id when is_binary(id) or is_number(id) -> {:ok, id}
      _other -> {:error, invalid_request("id must be a string or a number")}
    end
  end

  defp validate_params(frame) do
    case Map.get(frame, "params") do
      nil -> {:ok, %{}}
      %{} = params -> {:ok, params}
      _other -> {:error, invalid_params("params must be an object")}
    end
  end

  defp classify(frame, id, params) do
    case Map.fetch(frame, "method") do
      {:ok, method} when is_binary(method) and method != "" -> {:ok, call(method, id, params)}
      {:ok, _invalid} -> {:error, invalid_request("method must be a non-empty string")}
      :error -> response(frame, id)
    end
  end

  defp call(method, id, params) do
    type = if is_nil(id), do: :notification, else: :request

    %{type: type, id: id, method: method, params: params, result: nil, error: nil}
  end

  defp response(frame, id) do
    if Map.has_key?(frame, "result") or Map.has_key?(frame, "error") do
      {:ok,
       %{
         type: :response,
         id: id,
         method: nil,
         params: %{},
         result: Map.get(frame, "result"),
         error: Map.get(frame, "error")
       }}
    else
      {:error, invalid_request("a frame without a method must carry result or error")}
    end
  end

  defp error_body(%Error{data: nil} = error),
    do: %{"code" => error.code, "message" => error.message}

  defp error_body(%Error{} = error) do
    %{"code" => error.code, "message" => error.message, "data" => error.data}
  end

  defp encode(frame), do: Jason.encode!(frame) <> "\n"
end
