defmodule FermixCore.NativeHost.Protocol do
  @moduledoc """
  Newline-delimited JSON protocol of `native_host.sock`, the local wire over
  which the daemon asks the Fermix app for this Mac's own services (M76 §4.4),
  and the one owner of its vocabulary.

  This module is the single source of truth for the wire. Its machine-readable
  export lives under `priv/native_host/` (`PROTOCOL.md`, `protocol.schema.json`,
  and the golden `fixtures/*.jsonl`); `protocol_contract_test.exs` asserts the
  export never drifts from the values below, and the Mac app vendors those
  files pinned by checksum.

  The grammar is the browser host's (`FermixCore.BrowserHost.Protocol`), for
  another concept: the same transport, line cap and trust, one host at a time,
  the same handshake and the same daemon error table, and no tasks or tabs.
  The app opens the socket (`client_hello`, answered `server_hello`), attaches
  (`attached`), and reports its grants (`capabilities`) at attach and on every
  change. Then the daemon asks, one grant question or one post per request,
  each carrying an `id` and answered `{id, ok: true, result}` or `{id, ok:
  false, error: {reason, message}}`. The app's own news (`capabilities`, a
  press on a notification's action, its quit) arrives
  as events, which carry a `type` and no `id`.

  ## Versioning

  One integer, `protocol_version`, on an N/N-1 window derived from it: the
  first version, so the window is 1 to 1.
  """

  @protocol_version 1
  @min_supported_version max(1, @protocol_version - 1)

  # The browser host's cap, so one transport rule holds on both of the app's
  # wires; nothing this wire carries comes near it.
  @max_line_bytes 4_194_304
  @max_message_chars 500
  @max_id_chars 64
  # Above the 240 an event's title may hold (`Temporal.Registry`), and the
  # 1,800 bytes a reminder's text may (`Temporal.Renderer`).
  @max_title_chars 256
  @max_body_chars 1_800
  @max_action_title_chars 64
  @max_actions 2
  @max_u64 18_446_744_073_709_551_615

  @requests ~w(notifications.authorize notifications.post host.status host.stop_ack)
  @events ~w(attached capabilities notification.action host_stopping)

  # The reasons the app may answer a request with.
  @host_errors ~w(not_authorized post_failed invalid_request host_unavailable)

  # The reasons of the daemon's own `error` frame, each followed by the close.
  @daemon_errors ~w(
    invalid_json invalid_frame missing_type unknown_event missing_field invalid_field
    line_too_large handshake_required unexpected_client_hello attach_required unexpected_attached
    unsupported_protocol_version host_already_attached untrusted_host
  )

  @grant_states ~w(granted not_granted not_asked)
  # The actions a reminder's notification carries, each its button title and
  # what a press does: one table, so the button, the codec and the press agree.
  @reminder_actions %{"snooze_10m" => %{title: "Snooze 10 minutes", snooze_minutes: 10}}
  @action_ids @reminder_actions |> Map.keys() |> Enum.sort()

  @request_required %{
    "notifications.authorize" => [],
    "notifications.post" => ~w(title body sound actions),
    "host.status" => [],
    "host.stop_ack" => []
  }

  @request_optional %{"notifications.post" => ~w(reminder_id)}

  @result_required %{
    "notifications.authorize" => ~w(state),
    "notifications.post" => ~w(notification_id),
    "host.status" => ~w(host_version notifications),
    "host.stop_ack" => []
  }

  @event_required %{
    "attached" => ~w(host_version),
    "capabilities" => ~w(notifications),
    "notification.action" => ~w(reminder_id action),
    "host_stopping" => []
  }

  @typedoc "One frame the app sent, decoded."
  @type host_frame ::
          {:hello, pos_integer()}
          | {:event, String.t(), map()}
          | {:response, pos_integer(), {:ok, map()} | {:error, map()}}

  @doc "The daemon's current native host wire version."
  @spec protocol_version() :: pos_integer()
  def protocol_version, do: @protocol_version

  @doc "Inclusive `{min, max}` protocol versions the daemon accepts (an N/N-1 window)."
  @spec supported_version_range() :: {pos_integer(), pos_integer()}
  def supported_version_range, do: {@min_supported_version, @protocol_version}

  @doc "Ordered request catalog (daemon to app)."
  @spec requests() :: [String.t()]
  def requests, do: @requests

  @doc "Ordered event catalog (app to daemon)."
  @spec events() :: [String.t()]
  def events, do: @events

  @doc "Every `error.reason` the app may answer a request with."
  @spec host_errors() :: [String.t()]
  def host_errors, do: @host_errors

  @doc "Every `reason` of the daemon's own `error` frame."
  @spec daemon_errors() :: [String.t()]
  def daemon_errors, do: @daemon_errors

  @doc "The notification grant states the app reports: `granted`, `not_granted`, `not_asked`."
  @spec grant_states() :: [String.t()]
  def grant_states, do: @grant_states

  @doc "The action ids a notification may offer; a press comes back as `notification.action`."
  @spec action_ids() :: [String.t()]
  def action_ids, do: @action_ids

  @doc "The buttons a reminder's notification carries, as `notifications.post` sends them."
  @spec reminder_actions() :: [%{String.t() => String.t()}]
  def reminder_actions do
    Enum.map(@action_ids, &%{"id" => &1, "title" => @reminder_actions[&1].title})
  end

  @doc "How many minutes a press on `action` snoozes its reminder."
  @spec snooze_minutes(String.t()) :: pos_integer()
  def snooze_minutes(action) when is_map_key(@reminder_actions, action),
    do: @reminder_actions[action].snooze_minutes

  @doc "Maximum bytes of one inbound line, newline excluded."
  @spec max_line_bytes() :: pos_integer()
  def max_line_bytes, do: @max_line_bytes

  @doc "Longest `error.message` the app may send, in Unicode scalar values."
  @spec max_message_chars() :: pos_integer()
  def max_message_chars, do: @max_message_chars

  @doc "Longest notification title, in Unicode scalar values."
  @spec max_title_chars() :: pos_integer()
  def max_title_chars, do: @max_title_chars

  @doc "Longest notification body, in Unicode scalar values."
  @spec max_body_chars() :: pos_integer()
  def max_body_chars, do: @max_body_chars

  @doc "Most actions one notification may offer."
  @spec max_actions() :: pos_integer()
  def max_actions, do: @max_actions

  @doc """
  Negotiate the app's `protocol_version` against the daemon's supported range.

  `{:error, :client_too_old}` means the app must update, and
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

  @doc """
  Decode and validate one line from the app (the newline already removed): the
  handshake, an event, or an answer to a request. An answer's `result` is
  checked against the request it answers by `validate_result/2`, because only
  the daemon knows which request an `id` was.
  """
  @spec decode_host_frame(binary()) :: {:ok, host_frame()} | {:error, term()}
  def decode_host_frame(line) when is_binary(line) do
    with {:ok, decoded} <- decode_json(line) do
      classify(decoded)
    end
  end

  @doc "Encode and validate one daemon request as a newline-terminated line."
  @spec encode_request(pos_integer(), String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def encode_request(id, type, payload)
      when is_integer(id) and id > 0 and is_binary(type) and is_map(payload) do
    with :ok <- known(type, @requests, :unknown_request),
         {:ok, payload} <- stringify_top_level(payload),
         :ok <- reject_reserved(payload, ["id", "type"]),
         :ok <- validate_request(type, payload) do
      encode_line(payload |> Map.put("id", id) |> Map.put("type", type))
    end
  end

  @doc """
  Encode and validate one of the daemon's two unsolicited frames, `server_hello`
  and `error`, as a newline-terminated line.
  """
  @spec encode_daemon_frame(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def encode_daemon_frame(type, payload) when type in ["server_hello", "error"] do
    with {:ok, payload} <- stringify_top_level(payload),
         :ok <- reject_reserved(payload, ["id", "type"]),
         :ok <- validate_daemon_frame(type, payload) do
      encode_line(Map.put(payload, "type", type))
    end
  end

  @doc """
  Validate one request payload (`id` and `type` removed): its required fields in
  catalog order, no field the request does not carry, then each field.
  """
  @spec validate_request(String.t(), map()) :: :ok | {:error, term()}
  def validate_request(type, payload) when is_binary(type) and is_map(payload) do
    with {:ok, required} <- fetch(@request_required, type, :unknown_request),
         :ok <- require_fields(required, payload),
         :ok <- only_fields(required ++ Map.get(@request_optional, type, []), payload) do
      request_fields(type, payload)
    end
  end

  @doc "Validate an answer's `result` against the request type it answers."
  @spec validate_result(String.t(), map()) :: :ok | {:error, term()}
  def validate_result(type, result) when is_binary(type) and is_map(result) do
    with {:ok, required} <- fetch(@result_required, type, :unknown_request),
         :ok <- require_fields(required, result) do
      result_fields(type, result)
    end
  end

  @doc "Validate one event payload (`type` removed): required fields, then each field."
  @spec validate_event(String.t(), map()) :: :ok | {:error, term()}
  def validate_event(type, payload) when is_binary(type) and is_map(payload) do
    with {:ok, required} <- fetch(@event_required, type, :unknown_event),
         :ok <- require_fields(required, payload) do
      event_fields(type, payload)
    end
  end

  # ── decoding the app's frames ──────────────────────────────────────────────

  defp classify(%{"id" => _id} = frame), do: response(frame)
  defp classify(%{"type" => "client_hello"} = frame), do: hello(frame)

  defp classify(%{"type" => type} = frame) when is_binary(type) and type != "" do
    with :ok <- known(type, @events, :unknown_event),
         payload = Map.delete(frame, "type"),
         :ok <- validate_event(type, payload) do
      {:ok, {:event, type, payload}}
    end
  end

  defp classify(_frame), do: {:error, :missing_type}

  defp hello(frame) do
    case Map.get(frame, "protocol_version") do
      version when is_integer(version) and version > 0 -> {:ok, {:hello, version}}
      nil -> {:error, {:missing_field, "protocol_version"}}
      _other -> {:error, {:invalid_field, "protocol_version"}}
    end
  end

  # An answer carries no `type`: which request it answers is its `id`.
  defp response(%{"type" => _type}), do: {:error, :invalid_frame}

  defp response(frame) do
    with :ok <- integer_range(frame, "id", 1, @max_u64),
         :ok <- boolean_field(frame, "ok") do
      outcome(frame)
    end
  end

  defp outcome(%{"id" => id, "ok" => true, "result" => result} = frame)
       when is_map(result) and not is_map_key(frame, "error"),
       do: {:ok, {:response, id, {:ok, result}}}

  defp outcome(%{"id" => id, "ok" => false, "error" => error} = frame)
       when is_map(error) and not is_map_key(frame, "result") do
    with :ok <- enum(error, "reason", @host_errors),
         :ok <- bounded_nonempty(error, "message", @max_message_chars) do
      {:ok, {:response, id, {:error, Map.take(error, ["reason", "message"])}}}
    end
  end

  defp outcome(%{"ok" => true}), do: {:error, {:invalid_field, "result"}}
  defp outcome(_frame), do: {:error, {:invalid_field, "error"}}

  # ── requests ───────────────────────────────────────────────────────────────

  defp request_fields("notifications.post", payload) do
    with :ok <- bounded_nonempty(payload, "title", @max_title_chars),
         :ok <- bounded_nonempty(payload, "body", @max_body_chars),
         :ok <- boolean_field(payload, "sound"),
         :ok <- optional(payload, "reminder_id", &id_string/2) do
      actions(payload)
    end
  end

  defp request_fields(type, _payload)
       when type in ["notifications.authorize", "host.status", "host.stop_ack"],
       do: :ok

  # A press on an action comes back naming the reminder it acts on, so a post
  # that offers one carries that reminder's id.
  defp actions(%{"actions" => []}), do: :ok

  defp actions(%{"actions" => actions} = payload) when is_list(actions) do
    cond do
      length(actions) > @max_actions or not Enum.all?(actions, &action?/1) ->
        {:error, {:invalid_field, "actions"}}

      not Map.has_key?(payload, "reminder_id") ->
        {:error, {:missing_field, "reminder_id"}}

      true ->
        :ok
    end
  end

  defp actions(_payload), do: {:error, {:invalid_field, "actions"}}

  defp action?(%{"id" => id, "title" => title} = action)
       when id in @action_ids and is_binary(title) and map_size(action) == 2,
       do:
         title != "" and String.valid?(title) and String.length(title) <= @max_action_title_chars

  defp action?(_action), do: false

  # ── results ────────────────────────────────────────────────────────────────

  defp result_fields("notifications.authorize", result), do: enum(result, "state", @grant_states)
  defp result_fields("notifications.post", result), do: id_string(result, "notification_id")

  defp result_fields("host.status", result) do
    with :ok <- id_string(result, "host_version") do
      enum(result, "notifications", @grant_states)
    end
  end

  defp result_fields("host.stop_ack", _result), do: :ok

  # ── events ─────────────────────────────────────────────────────────────────

  defp event_fields("attached", payload), do: id_string(payload, "host_version")
  defp event_fields("capabilities", payload), do: enum(payload, "notifications", @grant_states)

  defp event_fields("notification.action", payload) do
    with :ok <- id_string(payload, "reminder_id") do
      enum(payload, "action", @action_ids)
    end
  end

  defp event_fields("host_stopping", _payload), do: :ok

  # ── the daemon's unsolicited frames ────────────────────────────────────────

  defp validate_daemon_frame("server_hello", payload) do
    {min, max} = supported_version_range()

    if payload == %{"min_version" => min, "max_version" => max},
      do: :ok,
      else: {:error, {:invalid_field, "version_range"}}
  end

  defp validate_daemon_frame("error", payload) do
    with :ok <- enum(payload, "reason", @daemon_errors) do
      optional(payload, "message", &bounded_nonempty(&1, &2, @max_message_chars))
    end
  end

  # ── field checks ───────────────────────────────────────────────────────────

  defp decode_json(line) do
    case Jason.decode(line) do
      {:ok, %{} = decoded} -> {:ok, decoded}
      {:ok, _other} -> {:error, :invalid_frame}
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  defp encode_line(map) do
    case Jason.encode(map) do
      {:ok, json} -> {:ok, json <> "\n"}
      {:error, reason} -> {:error, {:invalid_payload, reason}}
    end
  end

  defp known(type, catalog, error) do
    if type in catalog, do: :ok, else: {:error, {error, type}}
  end

  defp fetch(table, type, error) do
    case Map.fetch(table, type) do
      {:ok, fields} -> {:ok, fields}
      :error -> {:error, {error, type}}
    end
  end

  defp require_fields(required, payload) do
    case Enum.find(required, &(not Map.has_key?(payload, &1))) do
      nil -> :ok
      missing -> {:error, {:missing_field, missing}}
    end
  end

  defp only_fields(allowed, payload) do
    case Enum.find(Map.keys(payload), &(&1 not in allowed)) do
      nil -> :ok
      extra -> {:error, {:invalid_field, extra}}
    end
  end

  defp stringify_top_level(payload) do
    Enum.reduce_while(payload, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case stringify_key(key) do
        {:ok, key} when not is_map_key(acc, key) -> {:cont, {:ok, Map.put(acc, key, value)}}
        {:ok, key} -> {:halt, {:error, {:duplicate_field, key}}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp stringify_key(key) when is_binary(key), do: {:ok, key}
  defp stringify_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp stringify_key(key), do: {:error, {:invalid_field_name, key}}

  # An absent optional field is an absent key on this wire, never an explicit
  # null, and the envelope's own keys are this module's to write.
  defp reject_reserved(payload, reserved) do
    cond do
      reserved_key = Enum.find(reserved, &Map.has_key?(payload, &1)) ->
        {:error, {:reserved_field, reserved_key}}

      nil_key = Enum.find_value(payload, fn {key, value} -> is_nil(value) && key end) ->
        {:error, {:null_field, nil_key}}

      true ->
        :ok
    end
  end

  defp optional(payload, field, check) do
    if Map.has_key?(payload, field), do: check.(payload, field), else: :ok
  end

  defp id_string(payload, field), do: bounded_nonempty(payload, field, @max_id_chars)

  # A conditionally-required field has no earlier `require_fields/2` pass to
  # catch its absence, so this is the one place that tells "never sent" from
  # "sent empty or invalid".
  defp bounded_nonempty(payload, field, max) do
    cond do
      not Map.has_key?(payload, field) -> {:error, {:missing_field, field}}
      Map.get(payload, field) == "" -> {:error, {:invalid_field, field}}
      true -> bounded_binary(payload, field, max)
    end
  end

  defp bounded_binary(payload, field, max) do
    case Map.get(payload, field) do
      value when is_binary(value) ->
        if String.valid?(value) and String.length(value) <= max,
          do: :ok,
          else: {:error, {:invalid_field, field}}

      _value ->
        {:error, {:invalid_field, field}}
    end
  end

  defp boolean_field(payload, field) do
    if is_boolean(Map.get(payload, field)), do: :ok, else: {:error, {:invalid_field, field}}
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
