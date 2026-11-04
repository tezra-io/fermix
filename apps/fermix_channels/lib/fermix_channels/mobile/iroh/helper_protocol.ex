defmodule FermixChannels.Mobile.Iroh.HelperProtocol do
  @moduledoc """
  The codec of the `fermix-iroh` helper protocol: the control channel's ops and
  events (NDJSON over the helper's stdin and stdout) and the bridge preamble.
  Protocol 3 adds the endpoint that only dials (`start_dial_only/2`) and the
  `dial` op with its `dialed`, `dial_failed` and `dial_closed` events (M75).

  This module is the protocol's source of truth;
  `fermix_core/priv/iroh_helper/PROTOCOL.md` and its fixtures are its export,
  and the contract test holds them together. The `tezra-io/fermix-iroh`
  repository vendors that export. Pure: `Mobile.Iroh.Helper` owns the helper
  process.
  """

  @protocol_version 3
  @max_line_bytes 65_536
  @max_text_bytes 512
  @alpn "fermix/mobile/1"
  @preamble_magic "FXB1"
  @preamble_bytes 37
  @error_codes ~w(bad_request key_unreadable key_invalid bind_failed internal)
  @refusal_reasons %{
    "busy" => :busy,
    "alpn" => :alpn,
    "bridge_unreachable" => :bridge_unreachable
  }
  @path_kinds %{"relay" => :relay, "direct" => :direct}
  @log_levels %{"info" => :info, "warn" => :warn}
  @dial_failures %{
    "unreachable" => :unreachable,
    "timeout" => :timeout,
    "refused" => :refused,
    "bridge_unreachable" => :bridge_unreachable,
    "busy" => :busy
  }
  @max_dials 8
  @dial_deadline_ms 20_000
  @max_relays 8
  @max_dial_addrs 8

  @typedoc "Why a dial made no stream, as the helper says it."
  @type dial_failure :: :unreachable | :timeout | :refused | :bridge_unreachable | :busy

  @typedoc "One event the helper sent, decoded and checked."
  @type event ::
          %{
            event: :hello,
            protocol_version: pos_integer(),
            helper_version: String.t(),
            iroh_version: String.t()
          }
          | %{event: :ready, endpoint_id: String.t()}
          | %{
              event: :relay,
              home_relay: String.t() | nil,
              connected: boolean(),
              error: String.t() | nil
            }
          | %{
              event: :path,
              endpoint_id: String.t(),
              kind: :relay | :direct,
              relay: String.t() | nil
            }
          | %{event: :closed, endpoint_id: String.t()}
          | %{
              event: :refused,
              reason: :busy | :alpn | :bridge_unreachable,
              endpoint_id: String.t() | nil
            }
          | %{event: :log, level: :info | :warn, message: String.t()}
          | %{event: :error, code: String.t(), message: String.t()}
          | %{
              event: :dialed,
              dial_id: String.t(),
              kind: :relay | :direct,
              relay: String.t() | nil
            }
          | %{event: :dial_failed, dial_id: String.t(), reason: dial_failure()}
          | %{event: :dial_closed, dial_id: String.t()}

  @typedoc "The helper's limits, as `start` sends them."
  @type limits :: %{
          max_connections: 1..1_024,
          max_streams_per_connection: 1..16,
          stream_receive_window: pos_integer(),
          connection_receive_window: pos_integer(),
          send_window: pos_integer()
        }

  @doc "The control channel's `protocol_version`."
  @spec protocol_version() :: pos_integer()
  def protocol_version, do: @protocol_version

  @doc "The longest control line, newline excluded."
  @spec max_line_bytes() :: pos_integer()
  def max_line_bytes, do: @max_line_bytes

  @doc "The one application protocol the helper's endpoint accepts."
  @spec alpn() :: String.t()
  def alpn, do: @alpn

  @doc "The bridge preamble's length."
  @spec preamble_bytes() :: pos_integer()
  def preamble_bytes, do: @preamble_bytes

  @doc "The most dials the helper runs at once; it answers one more `busy`."
  @spec max_dials() :: pos_integer()
  def max_dials, do: @max_dials

  @doc "How long the helper gives a dial before it answers `timeout`."
  @spec dial_deadline_ms() :: pos_integer()
  def dial_deadline_ms, do: @dial_deadline_ms

  @doc "The `start` op."
  @spec start(Path.t(), Path.t(), [map()], limits()) :: map()
  def start(secret_key_path, bridge_socket, relays, limits)
      when is_binary(secret_key_path) and is_binary(bridge_socket) and is_list(relays) and
             relays != [] and is_map(limits) do
    %{
      "op" => "start",
      "secret_key_path" => secret_key_path,
      "bridge_socket" => bridge_socket,
      "alpn" => @alpn,
      "relays" => relays,
      "limits" => Map.new(limits, fn {key, value} -> {Atom.to_string(key), value} end)
    }
  end

  @doc """
  The `start` op of an endpoint that only dials: no key and no bridge socket,
  so the helper binds with a fresh key it holds in memory and accepts nothing.
  """
  @spec start_dial_only([map()], limits()) :: map()
  def start_dial_only(relays, limits)
      when is_list(relays) and relays != [] and is_map(limits) do
    %{
      "op" => "start",
      "alpn" => @alpn,
      "relays" => relays,
      "limits" => Map.new(limits, fn {key, value} -> {Atom.to_string(key), value} end)
    }
  end

  @doc """
  The `dial` op: dial `endpoint_id` through `relays` (and `addrs`, direct
  `ip:port` addresses, which only a test that knows where the peer listens
  names), open one stream and copy it to `socket`. Anything outside the
  contract fails loud: the helper would refuse it and end.
  """
  @spec dial(String.t(), String.t(), [map()], Path.t(), [String.t()]) :: map()
  def dial(dial_id, endpoint_id, relays, socket, addrs \\ [])
      when is_binary(dial_id) and is_binary(endpoint_id) and is_list(relays) and
             is_binary(socket) and is_list(addrs) do
    with :ok <- dial_id(dial_id),
         :ok <- endpoint_id(endpoint_id),
         :ok <- dial_relays(relays),
         :ok <- absolute(socket),
         :ok <- dial_addrs(addrs) do
      %{
        "op" => "dial",
        "dial_id" => dial_id,
        "endpoint_id" => endpoint_id,
        "relays" => relays,
        "socket" => socket
      }
      |> put_addrs(addrs)
    else
      {:error, reason} -> raise ArgumentError, "not a dial: #{inspect(reason)}"
    end
  end

  defp put_addrs(op, []), do: op
  defp put_addrs(op, addrs), do: Map.put(op, "addrs", addrs)

  defp dial_relays(relays) when length(relays) in 1..@max_relays do
    if Enum.all?(relays, &wire_relay?/1), do: :ok, else: {:error, :invalid_relays}
  end

  defp dial_relays(_relays), do: {:error, :invalid_relays}

  defp wire_relay?(%{"url" => "https://" <> _host, "quic_port" => port})
       when port in 1..65_535,
       do: true

  defp wire_relay?(_relay), do: false

  defp absolute(path) do
    if Path.type(path) == :absolute, do: :ok, else: {:error, :socket_not_absolute}
  end

  defp dial_addrs(addrs) when length(addrs) <= @max_dial_addrs do
    if Enum.all?(addrs, &is_binary/1), do: :ok, else: {:error, :invalid_addrs}
  end

  defp dial_addrs(_addrs), do: {:error, :invalid_addrs}

  @doc "The `set_relays` op."
  @spec set_relays([map()]) :: map()
  def set_relays(relays) when is_list(relays) and relays != [],
    do: %{"op" => "set_relays", "relays" => relays}

  @doc """
  The `close` op: the helper closes the peer's connections once their streams
  have ended. The id is the lowercase hex a preamble names; any other fails loud.
  """
  @spec close(String.t()) :: map()
  def close(id) when is_binary(id) do
    case endpoint_id(id) do
      :ok -> %{"op" => "close", "endpoint_id" => id}
      {:error, :invalid_endpoint_id} -> raise ArgumentError, "not an endpoint id: #{inspect(id)}"
    end
  end

  @doc "The `shutdown` op."
  @spec shutdown() :: map()
  def shutdown, do: %{"op" => "shutdown"}

  @doc "One op as the line the helper reads."
  @spec encode(map()) :: iodata()
  def encode(%{"op" => op} = frame) when is_binary(op), do: [Jason.encode_to_iodata!(frame), "\n"]

  @doc "Decodes and checks one line the helper wrote, newline excluded."
  @spec decode_event(binary()) :: {:ok, event()} | {:error, term()}
  def decode_event(line) when is_binary(line) and byte_size(line) > @max_line_bytes,
    do: {:error, :line_too_long}

  def decode_event(line) when is_binary(line) do
    case Jason.decode(line) do
      {:ok, %{"event" => name} = frame} when is_binary(name) -> event(name, frame)
      {:ok, _other} -> {:error, :not_an_event}
      {:error, _reason} -> {:error, :malformed_json}
    end
  end

  defp event("hello", %{
         "protocol_version" => version,
         "helper_version" => helper,
         "iroh_version" => iroh
       })
       when is_integer(version) and is_binary(helper) and is_binary(iroh),
       do:
         {:ok,
          %{event: :hello, protocol_version: version, helper_version: helper, iroh_version: iroh}}

  defp event("ready", %{"endpoint_id" => id}) do
    with :ok <- endpoint_id(id), do: {:ok, %{event: :ready, endpoint_id: id}}
  end

  defp event("relay", %{"home_relay" => relay, "connected" => connected} = frame)
       when (is_binary(relay) or is_nil(relay)) and is_boolean(connected) do
    with {:ok, error} <- optional_text(Map.get(frame, "error")) do
      {:ok, %{event: :relay, home_relay: relay, connected: connected, error: error}}
    end
  end

  defp event("path", %{"endpoint_id" => id, "kind" => kind, "relay" => relay})
       when is_map_key(@path_kinds, kind) and (is_binary(relay) or is_nil(relay)) do
    with :ok <- endpoint_id(id),
         :ok <- path_relay(kind, relay) do
      {:ok, %{event: :path, endpoint_id: id, kind: Map.fetch!(@path_kinds, kind), relay: relay}}
    end
  end

  defp event("closed", %{"endpoint_id" => id}) do
    with :ok <- endpoint_id(id), do: {:ok, %{event: :closed, endpoint_id: id}}
  end

  defp event("refused", %{"reason" => reason, "endpoint_id" => id})
       when is_map_key(@refusal_reasons, reason) do
    with :ok <- optional_endpoint_id(id) do
      {:ok, %{event: :refused, reason: Map.fetch!(@refusal_reasons, reason), endpoint_id: id}}
    end
  end

  defp event("log", %{"level" => level, "message" => message})
       when is_map_key(@log_levels, level) and is_binary(message) do
    with {:ok, message} <- optional_text(message) do
      {:ok, %{event: :log, level: Map.fetch!(@log_levels, level), message: message}}
    end
  end

  defp event("error", %{"code" => code, "message" => message})
       when code in @error_codes and is_binary(message) do
    with {:ok, message} <- optional_text(message),
         do: {:ok, %{event: :error, code: code, message: message}}
  end

  defp event("dialed", %{"dial_id" => id, "kind" => kind, "relay" => relay})
       when is_map_key(@path_kinds, kind) and (is_binary(relay) or is_nil(relay)) do
    with :ok <- dial_id(id),
         :ok <- path_relay(kind, relay) do
      {:ok, %{event: :dialed, dial_id: id, kind: Map.fetch!(@path_kinds, kind), relay: relay}}
    end
  end

  defp event("dial_failed", %{"dial_id" => id, "reason" => reason})
       when is_map_key(@dial_failures, reason) do
    with :ok <- dial_id(id),
         do:
           {:ok, %{event: :dial_failed, dial_id: id, reason: Map.fetch!(@dial_failures, reason)}}
  end

  defp event("dial_closed", %{"dial_id" => id}) do
    with :ok <- dial_id(id), do: {:ok, %{event: :dial_closed, dial_id: id}}
  end

  defp event(name, _frame), do: {:error, {:invalid_event, name}}

  defp endpoint_id(id) when is_binary(id) do
    if Regex.match?(~r/\A[0-9a-f]{64}\z/, id), do: :ok, else: {:error, :invalid_endpoint_id}
  end

  defp endpoint_id(_id), do: {:error, :invalid_endpoint_id}

  defp optional_endpoint_id(nil), do: :ok
  defp optional_endpoint_id(id), do: endpoint_id(id)

  defp dial_id(id) when is_binary(id) do
    if Regex.match?(~r/\A[a-z0-9_-]{1,64}\z/, id), do: :ok, else: {:error, :invalid_dial_id}
  end

  defp dial_id(_id), do: {:error, :invalid_dial_id}

  defp path_relay("relay", relay) when is_binary(relay), do: :ok
  defp path_relay("direct", nil), do: :ok
  defp path_relay(_kind, _relay), do: {:error, :invalid_path}

  defp optional_text(nil), do: {:ok, nil}

  defp optional_text(text) when is_binary(text) and byte_size(text) <= @max_text_bytes,
    do: {:ok, text}

  defp optional_text(_text), do: {:error, :text_too_long}

  @doc """
  Reads a bridge connection's preamble: the peer's kind and its endpoint id as
  lowercase hex. A peer is a phone, the only kind the protocol knows.
  """
  @spec decode_preamble(binary()) :: {:ok, :phone, String.t()} | {:error, :invalid_preamble}
  def decode_preamble(<<@preamble_magic, 1, id::binary-size(32)>>),
    do: {:ok, :phone, Base.encode16(id, case: :lower)}

  def decode_preamble(_bytes), do: {:error, :invalid_preamble}
end
