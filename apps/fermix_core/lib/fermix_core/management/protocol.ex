defmodule FermixCore.Management.Protocol do
  @moduledoc """
  Versioned request and response envelopes for the local management socket.

  The socket transport remains owned by `Fermix.CLI.Daemon`. This module is
  pure: it classifies v0 compatibility requests, validates v1 envelopes, and
  constructs bounded v1 responses without exposing internal terms.

  This module is the source of truth for the wire; the canonical contract lives
  beside it under `priv/management/` (`PROTOCOL.md`, `protocol.schema.json`, and
  golden `fixtures/`), which `protocol_contract_test.exs` pins to it. The macOS
  application vendors that export by checksum rather than hand-copying shapes.
  """

  @protocol_version 2
  @min_supported_version max(1, @protocol_version - 1)
  @request_id_pattern ~r/^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/
  @method_pattern ~r/^[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)*$/
  @request_fields ~w(request_id protocol_version method params)
  # The transport's frame ceiling, published so the schema and every client
  # build against one number instead of three copies of the same literal.
  @max_frame_bytes 4_194_304
  @max_params_bytes 65_536
  @max_result_bytes 1_048_576
  @max_error_details_bytes 4_096
  @max_json_depth 6
  # The widest collection the contract publishes is a 500-entry `logs.query`
  # page (M34 §5) and the 500 log entries `diagnostics.build` carries (§6). A
  # ceiling below that rejects a legal result at the responder and answers
  # `internal_error`, so this bound tracks the largest published collection
  # rather than a round number.
  @max_json_collection_items 500

  # Ordered, and the single source for the catalog, the published minimum-version
  # table, and the schema's method enum. The integer is the method's
  # `min_protocol_version`: the lowest negotiated version that may call it. A
  # v1-declared request for a v2 method is refused rather than served, so the
  # wire's meaning never depends on the client's honesty about what it speaks.
  @method_minimums [
    {"hello", 1},
    {"overview.get", 1},
    {"setup.session.create", 1},
    {"doctor.start", 1},
    {"doctor.get", 1},
    {"doctor.cancel", 1},
    {"logs.query", 1},
    {"lifecycle.prepare", 1},
    {"lifecycle.commit", 1},
    {"lifecycle.cancel", 1},
    {"diagnostics.build", 1},
    {"setup.state.get", 2},
    {"setup.detect", 2},
    {"settings.sections", 2},
    {"settings.get", 2},
    {"settings.apply", 2},
    {"settings.reload", 2},
    {"secret.set", 2},
    {"secret.clear", 2},
    {"providers.set_primary", 2},
    {"providers.models.list", 2},
    {"providers.probe.start", 2},
    {"job.get", 2},
    {"job.cancel", 2},
    {"job.list", 2},
    {"auth.start", 2},
    {"auth.import.start", 2},
    {"auth.logout", 2},
    {"plugins.list", 2},
    {"plugins.install.start", 2},
    {"plugins.check.start", 2},
    {"plugins.workspaces.discover.start", 2},
    {"plugins.workspace.select.start", 2},
    {"plugins.enable", 2},
    {"plugins.disable", 2},
    {"plugins.disconnect", 2},
    {"plugins.oauth_client.set", 2},
    {"plugins.setting.set", 2},
    {"capabilities.install.start", 2},
    {"meetings.signin.start", 2},
    {"computer_use.grant.start", 2},
    {"computer_use.permissions.get", 2}
  ]
  @methods Enum.map(@method_minimums, fn {method, _minimum} -> method end)
  @method_minimum_versions Map.new(@method_minimums)

  # Ordered, and the single source for both the catalog and the messages. A
  # keyword list keeps publication order without a second hand-maintained list
  # to filter through — a code present in one list and absent from the other is
  # emittable by `respond/2` yet missing from the schema enum, `PROTOCOL.md`,
  # and the client's accept-list, which reads to the operator as "this daemon
  # does not speak v1".
  @errors [
    invalid_request: "The management request is invalid.",
    invalid_params: "Request parameters are invalid.",
    method_not_found: "The requested management method is not available.",
    client_too_old: "The client management protocol is too old.",
    daemon_too_old: "The daemon management protocol is too old.",
    internal_error: "The management request could not be completed.",
    unavailable: "The requested management capability is unavailable.",
    busy: "Another management operation of this kind is already running.",
    lease_expired: "The lifecycle lease expired and the daemon resumed.",
    unknown_lease: "The lifecycle lease is not held by this daemon.",
    unknown_session: "The Doctor session is not retained by this daemon.",
    cursor_expired: "The log cursor predates a rotation and cannot be resumed.",
    secret_store_failed: "The secret could not be stored.",
    unknown_job: "The job is not retained by this daemon.",
    external_change: "The settings file changed outside Fermix.",
    config_unreadable: "The settings file could not be read."
  ]
  @error_messages Map.new(@errors)

  @type request :: %{
          request_id: String.t(),
          protocol_version: pos_integer(),
          method: String.t(),
          params: map()
        }
  @type response :: map()
  @type route_result :: {:ok, map()} | {:error, atom(), map()}

  @doc "The daemon's current management protocol version."
  @spec protocol_version() :: pos_integer()
  def protocol_version, do: @protocol_version

  @doc "Inclusive management protocol versions accepted by this daemon."
  @spec supported_version_range() :: {pos_integer(), pos_integer()}
  def supported_version_range, do: {@min_supported_version, @protocol_version}

  @doc "Ordered management method catalog for every version in the window."
  @spec methods() :: [String.t()]
  def methods, do: @methods

  @doc """
  The lowest negotiated protocol version each published method may be called at.

  Published whole rather than per method: a client that decodes a partial table
  cannot tell "this method needs a newer engine" from "this daemon does not
  serve it", and those are two different states with two different remedies.
  """
  @spec method_minimum_versions() :: %{String.t() => pos_integer()}
  def method_minimum_versions, do: @method_minimum_versions

  @doc "The minimum negotiated version for one method, or `:error` when unknown."
  @spec minimum_version(term()) :: {:ok, pos_integer()} | :error
  def minimum_version(method) when is_binary(method),
    do: Map.fetch(@method_minimum_versions, method)

  def minimum_version(_method), do: :error

  @doc """
  Every bound this protocol publishes, in bytes or items.

  `protocol.schema.json` pins `x-limits` to this map, so a bound that changes
  here fails the contract test rather than silently leaving the app validating
  against a wider or narrower wire than the daemon enforces.
  """
  @spec limits() :: map()
  def limits do
    %{
      max_frame_bytes: @max_frame_bytes,
      max_params_bytes: @max_params_bytes,
      max_result_bytes: @max_result_bytes,
      max_error_details_bytes: @max_error_details_bytes,
      max_json_depth: @max_json_depth,
      max_json_collection_items: @max_json_collection_items
    }
  end

  @doc "Ordered stable public error-code catalog."
  @spec error_codes() :: [String.t()]
  def error_codes, do: Enum.map(@errors, fn {code, _message} -> Atom.to_string(code) end)

  @doc "The public sentence each error code carries, keyed by code."
  @spec error_messages() :: %{atom() => String.t()}
  def error_messages, do: @error_messages

  @doc "Negotiates a client version against the daemon's inclusive window."
  @spec negotiate(integer()) :: :ok | {:error, :client_too_old | :daemon_too_old}
  def negotiate(version) when is_integer(version) do
    {minimum, maximum} = supported_version_range()

    cond do
      version < minimum -> {:error, :client_too_old}
      version > maximum -> {:error, :daemon_too_old}
      true -> :ok
    end
  end

  @doc "Decodes one JSON frame as a v0 compatibility request or strict v1 request."
  @spec decode_request(binary()) ::
          {:ok, {:v0, map()} | {:v1, request()}}
          | {:error, :invalid_v0_request | {:v1, response()}}
  def decode_request(frame) when is_binary(frame) do
    case Jason.decode(String.trim(frame)) do
      {:ok, %{} = decoded} -> classify_request(decoded)
      {:ok, _other} -> {:error, :invalid_v0_request}
      {:error, _reason} -> {:error, :invalid_v0_request}
    end
  end

  @doc "Builds one bounded v1 response containing exactly one result or error."
  @spec respond(String.t() | nil, route_result()) :: {:ok, response()} | {:error, term()}
  def respond(request_id, {:ok, result}) when is_binary(request_id) and is_map(result) do
    with :ok <- validate_request_id(request_id),
         :ok <- validate_json_map(result, :invalid_result),
         :ok <- within_encoded_size(result, @max_result_bytes, :result_too_large) do
      {:ok, %{"request_id" => request_id, "result" => result}}
    end
  end

  def respond(request_id, {:error, code, details}) when is_map(details) do
    with :ok <- validate_response_request_id(request_id),
         {:ok, message} <- error_message(code),
         :ok <- validate_json_map(details, :invalid_error_details),
         :ok <- within_error_details_size(details) do
      {:ok, error_envelope(request_id, code, message, details)}
    end
  end

  def respond(_request_id, {:ok, _result}), do: {:error, :invalid_result}
  def respond(_request_id, {:error, _code, _details}), do: {:error, :invalid_error_details}

  defp classify_request(request) do
    if attempted_v1?(request) do
      validate_v1_request(request)
    else
      validate_v0_request(request)
    end
  end

  defp attempted_v1?(request) do
    Map.has_key?(request, "request_id") or Map.has_key?(request, "protocol_version")
  end

  defp validate_v0_request(%{"method" => method} = request) when is_binary(method),
    do: {:ok, {:v0, request}}

  defp validate_v0_request(_request), do: {:error, :invalid_v0_request}

  defp validate_v1_request(request) do
    request_id = valid_request_id_or_nil(Map.get(request, "request_id"))

    with :ok <- require_valid_request_id(request_id),
         {:ok, version} <- fetch_version(request, request_id),
         :ok <- negotiate_request(version, request_id),
         {:ok, method} <- fetch_method(request, request_id),
         {:ok, params} <- fetch_params(request, request_id),
         :ok <- reject_unknown_fields(request, request_id) do
      {:ok,
       {:v1,
        %{
          request_id: request_id,
          protocol_version: version,
          method: method,
          params: params
        }}}
    end
  end

  defp require_valid_request_id(nil),
    do: v1_error(nil, :invalid_request, %{"field" => "request_id"})

  defp require_valid_request_id(_request_id), do: :ok

  defp fetch_version(request, request_id) do
    case Map.get(request, "protocol_version") do
      version when is_integer(version) -> {:ok, version}
      _invalid -> v1_error(request_id, :invalid_request, %{"field" => "protocol_version"})
    end
  end

  defp negotiate_request(version, request_id) do
    case negotiate(version) do
      :ok -> :ok
      {:error, code} -> v1_error(request_id, code, version_details())
    end
  end

  defp fetch_method(request, request_id) do
    method = Map.get(request, "method")

    if valid_method?(method) do
      {:ok, method}
    else
      v1_error(request_id, :invalid_request, %{"field" => "method"})
    end
  end

  defp fetch_params(request, request_id) do
    case Map.get(request, "params", %{}) do
      params when is_map(params) -> validate_params(params, request_id)
      _invalid -> v1_error(request_id, :invalid_params, %{"field" => "params"})
    end
  end

  defp validate_params(params, request_id) do
    with :ok <- validate_json_map(params, :invalid_params),
         :ok <- within_encoded_size(params, @max_params_bytes, :params_too_large) do
      {:ok, params}
    else
      {:error, {:params_too_large, _size, maximum}} -> params_too_large(request_id, maximum)
      {:error, _reason} -> v1_error(request_id, :invalid_params, %{"field" => "params"})
    end
  end

  defp params_too_large(request_id, maximum) do
    v1_error(request_id, :invalid_params, %{
      "field" => "params",
      "maximum_bytes" => maximum
    })
  end

  defp reject_unknown_fields(request, request_id) do
    case Enum.find(Map.keys(request), &(&1 not in @request_fields)) do
      nil -> :ok
      field -> v1_error(request_id, :invalid_request, %{"field" => field})
    end
  end

  defp valid_request_id_or_nil(request_id) do
    if validate_request_id(request_id) == :ok, do: request_id, else: nil
  end

  defp validate_request_id(request_id) when is_binary(request_id) do
    if Regex.match?(@request_id_pattern, request_id), do: :ok, else: {:error, :invalid_request_id}
  end

  defp validate_request_id(_request_id), do: {:error, :invalid_request_id}
  defp validate_response_request_id(nil), do: :ok
  defp validate_response_request_id(request_id), do: validate_request_id(request_id)

  defp valid_method?(method) when is_binary(method) and byte_size(method) <= 128,
    do: Regex.match?(@method_pattern, method)

  defp valid_method?(_method), do: false

  defp within_error_details_size(details) do
    case within_encoded_size(details, @max_error_details_bytes, :error_details_too_large) do
      :ok ->
        :ok

      {:error, {:error_details_too_large, size, maximum}} ->
        {:error, {:error_details_too_large, size, maximum}}

      {:error, _reason} ->
        {:error, :invalid_error_details}
    end
  end

  defp within_encoded_size(value, maximum, error_kind) do
    case Jason.encode(value) do
      {:ok, encoded} when byte_size(encoded) <= maximum -> :ok
      {:ok, encoded} -> {:error, {error_kind, byte_size(encoded), maximum}}
      {:error, _reason} -> {:error, :invalid_json_value}
    end
  end

  defp validate_json_map(value, error) when is_map(value) and is_atom(error) do
    if json_value?(value, 0), do: :ok, else: {:error, error}
  end

  defp json_value?(_value, depth) when depth > @max_json_depth, do: false
  defp json_value?(value, _depth) when is_nil(value) or is_boolean(value), do: true
  defp json_value?(value, _depth) when is_integer(value) or is_float(value), do: true
  defp json_value?(value, _depth) when is_binary(value), do: true

  defp json_value?(value, depth) when is_list(value) do
    length(value) <= @max_json_collection_items and
      Enum.all?(value, &json_value?(&1, depth + 1))
  end

  defp json_value?(value, depth) when is_map(value) do
    map_size(value) <= @max_json_collection_items and
      Enum.all?(value, fn {key, item} -> is_binary(key) and json_value?(item, depth + 1) end)
  end

  defp json_value?(_value, _depth), do: false

  defp error_message(code) when is_atom(code) do
    case Map.fetch(@error_messages, code) do
      {:ok, message} -> {:ok, message}
      :error -> {:error, :unknown_error_code}
    end
  end

  defp error_message(_code), do: {:error, :unknown_error_code}

  defp error_envelope(request_id, code, message, details) do
    %{
      "request_id" => request_id,
      "error" => %{
        "code" => Atom.to_string(code),
        "message" => message,
        "details" => details
      }
    }
  end

  defp v1_error(request_id, code, details) do
    {:ok, message} = error_message(code)
    {:error, {:v1, error_envelope(request_id, code, message, details)}}
  end

  defp version_details do
    {minimum, maximum} = supported_version_range()
    %{"minimum_version" => minimum, "maximum_version" => maximum}
  end
end
