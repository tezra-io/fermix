defmodule FermixCore.BrowserHost.Protocol do
  @moduledoc """
  Newline-delimited JSON protocol of `browser_host.sock`, the local wire over
  which the daemon drives the Fermix app's browser pane, and the one owner of
  its vocabulary.

  This module is the single source of truth for the wire. Its machine-readable
  export lives under `priv/browser_host/` (`PROTOCOL.md`,
  `protocol.schema.json`, and the golden `fixtures/*.jsonl`);
  `protocol_contract_test.exs` asserts the export never drifts from the values
  below, and the Mac app vendors those files pinned by checksum.

  The direction is reversed from the other wires. The app is the socket's
  client and opens it with the handshake every local wire uses (`client_hello`,
  answered `server_hello`); after that the daemon is the one asking. It sends
  requests carrying an `id`, and the app answers each with `{id, ok: true,
  result}` or `{id, ok: false, error: {reason, message}}`. The app's own news
  (`attached`, `availability`, a closed tab, a dialog, a download, the
  person's own cancel of a task, its quit) arrives as events, which carry a
  `type` and no `id`.

  ## Versioning

  One integer, `protocol_version`, on an N/N-1 window derived from it: the
  first version, so the window is 1 to 1.
  """

  @protocol_version 1
  @min_supported_version max(1, @protocol_version - 1)

  # A snapshot's node list is the largest frame the app sends. The app bounds it
  # by the request's `max_chars` and `depth`; this caps the line whatever it
  # sends.
  @max_line_bytes 4_194_304
  @max_message_chars 500
  @max_reason_chars 200
  @max_id_chars 64
  @max_url_chars 8_192
  @max_text_chars 65_536
  @max_nodes 50_000
  @max_form_fields 12
  @max_u64 18_446_744_073_709_551_615

  @requests ~w(
    tab.open tab.navigate tab.list tab.focus tab.close task.release page.snapshot page.screenshot
    page.pdf page.act page.upload dialog.resolve cookies.get cookies.clear host.status host.stop_ack
  )
  @events ~w(
    attached availability tab.closed dialog.opened download.began download.progress
    download.finished task.cancel host_stopping
  )

  # The reasons the app may answer a request with. `host_unavailable` is the one
  # that ends a task: the app sends `availability` false before answering it.
  @host_errors ~w(
    tab_not_found cap_reached not_owner navigation_refused act_failed stale_ref dialog_blocked
    no_dialog wait_timeout write_failed upload_failed invalid_request host_unavailable
  )

  # The reasons of the daemon's own `error` frame, each followed by the close.
  @daemon_errors ~w(
    invalid_json invalid_frame missing_type unknown_event missing_field invalid_field
    line_too_large handshake_required unexpected_client_hello attach_required unexpected_attached
    unsupported_protocol_version host_already_attached untrusted_host
  )

  @act_kinds ~w(click fill fill_form type submit press hover get wait click_coords)
  @snapshot_modes ~w(interactive full)
  @wait_modes ~w(text url element load)
  @get_fields ~w(text title html count ready_state rect)
  @ready_states ~w(loading interactive complete)
  @dialog_kinds ~w(alert confirm prompt beforeunload)
  @closed_by ~w(task person page host)
  @download_states ~w(completed failed cancelled)
  @image_types ~w(image/png image/jpeg)
  @cookie_keys ~w(name domain path secure http_only same_site expires session)

  @request_required %{
    "tab.open" => ~w(task_id url observe download_dir task_tab_cap tab_cap),
    "tab.navigate" => ~w(tab_id url observe),
    "tab.list" => ~w(task_id),
    "tab.focus" => ~w(tab_id),
    "tab.close" => ~w(tab_id),
    "task.release" => ~w(task_id),
    "page.snapshot" => ~w(tab_id mode max_chars depth),
    "page.screenshot" => ~w(tab_id full_page path),
    "page.pdf" => ~w(tab_id path),
    "page.act" => ~w(tab_id kind observe),
    "page.upload" => ~w(tab_id ref path),
    "dialog.resolve" => ~w(tab_id accept),
    "cookies.get" => ~w(tab_id),
    "cookies.clear" => ~w(tab_id),
    "host.status" => [],
    "host.stop_ack" => []
  }

  @request_optional %{
    "tab.open" => ~w(snapshot),
    "tab.navigate" => ~w(snapshot),
    "page.act" => ~w(ref x y text key fields field selector wait_until timeout_ms snapshot),
    "dialog.resolve" => ~w(text)
  }

  @result_required %{
    "tab.open" => ~w(tab_id url title),
    "tab.navigate" => ~w(tab_id url title),
    "tab.list" => ~w(tabs),
    "tab.focus" => ~w(tab_id url title),
    "tab.close" => ~w(tab_id),
    "task.release" => ~w(released),
    "page.snapshot" => ~w(url title ready_state nodes),
    "page.screenshot" => ~w(path mime_type bytes url device_pixel_ratio),
    "page.pdf" => ~w(path mime_type bytes url),
    "page.act" => ~w(url title),
    "page.upload" => ~w(tab_id),
    "dialog.resolve" => ~w(tab_id),
    "cookies.get" => ~w(url cookies),
    "cookies.clear" => ~w(cleared),
    "host.status" => ~w(host_version profile_id available task_tabs person_tabs),
    "host.stop_ack" => []
  }

  @event_required %{
    "attached" => ~w(host_version profile_id),
    "availability" => ~w(available),
    "tab.closed" => ~w(tab_id by),
    "dialog.opened" => ~w(tab_id kind message),
    "download.began" => ~w(download_id tab_id filename),
    "download.progress" => ~w(download_id received_bytes),
    "download.finished" => ~w(download_id tab_id state),
    "task.cancel" => ~w(task_id reason),
    "host_stopping" => []
  }

  @typedoc "One frame the app sent, decoded."
  @type host_frame ::
          {:hello, pos_integer()}
          | {:event, String.t(), map()}
          | {:response, pos_integer(), {:ok, map()} | {:error, map()}}

  @doc "The daemon's current browser host wire version."
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

  @doc "The `page.act` kinds, the `browser` tool's own."
  @spec act_kinds() :: [String.t()]
  def act_kinds, do: @act_kinds

  @doc "Maximum bytes of one inbound line, newline excluded."
  @spec max_line_bytes() :: pos_integer()
  def max_line_bytes, do: @max_line_bytes

  @doc "Longest `error.message` the app may send, in Unicode scalar values."
  @spec max_message_chars() :: pos_integer()
  def max_message_chars, do: @max_message_chars

  @doc "Longest `availability.reason` or `task.cancel.reason` the app may send, in Unicode scalar values."
  @spec max_reason_chars() :: pos_integer()
  def max_reason_chars, do: @max_reason_chars

  @doc "Most nodes one page's `nodes` list may carry."
  @spec max_nodes() :: pos_integer()
  def max_nodes, do: @max_nodes

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

  defp request_fields("tab.open", payload) do
    with :ok <- id_string(payload, "task_id"),
         :ok <- url_field(payload, "url"),
         :ok <- absolute_path(payload, "download_dir"),
         :ok <- positive_u64(payload, "task_tab_cap"),
         :ok <- positive_u64(payload, "tab_cap") do
      observed(payload)
    end
  end

  defp request_fields("tab.navigate", payload) do
    with :ok <- id_string(payload, "tab_id"),
         :ok <- url_field(payload, "url") do
      observed(payload)
    end
  end

  defp request_fields(type, payload) when type in ["tab.list", "task.release"],
    do: id_string(payload, "task_id")

  defp request_fields(type, payload)
       when type in ["tab.focus", "tab.close", "cookies.get", "cookies.clear"],
       do: id_string(payload, "tab_id")

  defp request_fields("page.snapshot", payload) do
    with :ok <- id_string(payload, "tab_id") do
      snapshot_options(payload)
    end
  end

  defp request_fields("page.screenshot", payload) do
    with :ok <- id_string(payload, "tab_id"),
         :ok <- boolean_field(payload, "full_page") do
      absolute_path(payload, "path")
    end
  end

  defp request_fields("page.pdf", payload) do
    with :ok <- id_string(payload, "tab_id") do
      absolute_path(payload, "path")
    end
  end

  defp request_fields("page.act", payload) do
    with :ok <- id_string(payload, "tab_id"),
         :ok <- enum(payload, "kind", @act_kinds),
         :ok <- act_arguments(payload) do
      observed(payload)
    end
  end

  defp request_fields("page.upload", payload) do
    with :ok <- id_string(payload, "tab_id"),
         :ok <- positive_u64(payload, "ref") do
      absolute_path(payload, "path")
    end
  end

  defp request_fields("dialog.resolve", payload) do
    with :ok <- id_string(payload, "tab_id"),
         :ok <- boolean_field(payload, "accept") do
      optional(payload, "text", &bounded_binary(&1, &2, @max_text_chars))
    end
  end

  defp request_fields(type, _payload) when type in ["host.status", "host.stop_ack"], do: :ok

  # `snapshot` rides a request exactly when it asks for the page back.
  defp observed(%{"observe" => true, "snapshot" => options}) when is_map(options) do
    with :ok <- only_fields(~w(mode max_chars depth), options) do
      snapshot_options(options)
    end
  end

  defp observed(%{"observe" => false} = payload) when not is_map_key(payload, "snapshot"),
    do: :ok

  defp observed(%{"observe" => observe}) when is_boolean(observe),
    do: {:error, {:invalid_field, "snapshot"}}

  defp observed(_payload), do: {:error, {:invalid_field, "observe"}}

  defp snapshot_options(options) do
    with :ok <- enum(options, "mode", @snapshot_modes),
         :ok <- integer_range(options, "max_chars", 1, 1_000_000) do
      integer_range(options, "depth", 1, 100)
    end
  end

  defp act_arguments(%{"kind" => kind} = payload) when kind in ~w(click hover submit),
    do: positive_u64(payload, "ref")

  defp act_arguments(%{"kind" => kind} = payload) when kind in ~w(fill type) do
    with :ok <- positive_u64(payload, "ref") do
      bounded_binary(payload, "text", @max_text_chars)
    end
  end

  defp act_arguments(%{"kind" => "fill_form"} = payload), do: form_fields(payload)
  defp act_arguments(%{"kind" => "press"} = payload), do: bounded_nonempty(payload, "key", 64)

  defp act_arguments(%{"kind" => "click_coords"} = payload) do
    with :ok <- number_field(payload, "x") do
      number_field(payload, "y")
    end
  end

  defp act_arguments(%{"kind" => "get"} = payload) do
    with :ok <- optional(payload, "field", &enum(&1, &2, @get_fields)) do
      optional(payload, "selector", &bounded_nonempty(&1, &2, @max_text_chars))
    end
  end

  defp act_arguments(%{"kind" => "wait"} = payload) do
    with :ok <- enum(payload, "wait_until", @wait_modes),
         :ok <- integer_range(payload, "timeout_ms", 1, 600_000),
         :ok <- optional(payload, "text", &bounded_nonempty(&1, &2, @max_text_chars)),
         :ok <- optional(payload, "ref", &positive_u64/2),
         :ok <- optional(payload, "selector", &bounded_nonempty(&1, &2, @max_text_chars)) do
      wait_target(payload)
    end
  end

  # What each wait mode waits for: text in the page or the url, an element by
  # its ref or selector, or nothing beyond the load itself.
  defp wait_target(%{"wait_until" => mode} = payload) when mode in ["text", "url"],
    do: bounded_nonempty(payload, "text", @max_text_chars)

  defp wait_target(%{"wait_until" => "element"} = payload) do
    if Map.has_key?(payload, "ref") or Map.has_key?(payload, "selector"),
      do: :ok,
      else: {:error, {:missing_field, "ref"}}
  end

  defp wait_target(_payload), do: :ok

  defp form_fields(%{"fields" => fields}) when is_list(fields) and fields != [] do
    if length(fields) <= @max_form_fields and Enum.all?(fields, &form_field?/1),
      do: :ok,
      else: {:error, {:invalid_field, "fields"}}
  end

  defp form_fields(_payload), do: {:error, {:invalid_field, "fields"}}

  defp form_field?(%{"ref" => ref, "text" => text} = field)
       when is_integer(ref) and ref > 0 and is_binary(text) and map_size(field) == 2,
       do: String.length(text) <= @max_text_chars

  defp form_field?(_field), do: false

  # ── results ────────────────────────────────────────────────────────────────

  defp result_fields(type, result) when type in ["tab.open", "tab.navigate"] do
    with :ok <- tab_fields(result) do
      optional(result, "page", fn result, field -> page(Map.fetch!(result, field)) end)
    end
  end

  defp result_fields("tab.list", %{"tabs" => tabs}) when is_list(tabs) do
    if Enum.all?(tabs, &listed_tab?/1), do: :ok, else: {:error, {:invalid_field, "tabs"}}
  end

  defp result_fields("tab.list", _result), do: {:error, {:invalid_field, "tabs"}}
  defp result_fields("tab.focus", result), do: tab_fields(result)

  defp result_fields(type, result) when type in ["tab.close", "page.upload", "dialog.resolve"],
    do: id_string(result, "tab_id")

  defp result_fields("task.release", %{"released" => released}) when is_list(released) do
    if Enum.all?(released, &id_string?/1),
      do: :ok,
      else: {:error, {:invalid_field, "released"}}
  end

  defp result_fields("task.release", _result), do: {:error, {:invalid_field, "released"}}
  defp result_fields("page.snapshot", result), do: page(result)

  defp result_fields("page.screenshot", result) do
    with :ok <- artifact(result, @image_types) do
      number_field(result, "device_pixel_ratio")
    end
  end

  defp result_fields("page.pdf", result), do: artifact(result, ["application/pdf"])

  defp result_fields("page.act", result) do
    with :ok <- url_field(result, "url"),
         :ok <- bounded_binary(result, "title", @max_text_chars),
         :ok <- optional(result, "value", &act_value/2) do
      optional(result, "page", fn result, field -> page(Map.fetch!(result, field)) end)
    end
  end

  defp result_fields("cookies.get", %{"cookies" => cookies} = result) when is_list(cookies) do
    with :ok <- url_field(result, "url") do
      if Enum.all?(cookies, &cookie?/1), do: :ok, else: {:error, {:invalid_field, "cookies"}}
    end
  end

  defp result_fields("cookies.get", _result), do: {:error, {:invalid_field, "cookies"}}
  defp result_fields("cookies.clear", result), do: nonnegative_u64(result, "cleared")

  defp result_fields("host.status", result) do
    with :ok <- bounded_nonempty(result, "host_version", @max_id_chars),
         :ok <- bounded_nonempty(result, "profile_id", @max_id_chars),
         :ok <- boolean_field(result, "available"),
         :ok <- nonnegative_u64(result, "task_tabs") do
      nonnegative_u64(result, "person_tabs")
    end
  end

  defp result_fields("host.stop_ack", _result), do: :ok

  defp tab_fields(result) do
    with :ok <- id_string(result, "tab_id"),
         :ok <- url_field(result, "url") do
      bounded_binary(result, "title", @max_text_chars)
    end
  end

  defp listed_tab?(tab) when is_map(tab) do
    tab_fields(tab) == :ok and optional(tab, "active", &boolean_field/2) == :ok and
      optional(tab, "opener_tab_id", &id_string/2) == :ok
  end

  defp listed_tab?(_tab), do: false

  defp artifact(result, mime_types) do
    with :ok <- absolute_path(result, "path"),
         :ok <- enum(result, "mime_type", mime_types),
         :ok <- positive_u64(result, "bytes") do
      url_field(result, "url")
    end
  end

  defp act_value(result, field) do
    case Map.get(result, field) do
      value when is_binary(value) or is_number(value) or is_boolean(value) -> :ok
      value when is_map(value) -> :ok
      _value -> {:error, {:invalid_field, field}}
    end
  end

  # Only the metadata a cookie has, never its value: the app never sends one.
  defp cookie?(%{"name" => name, "domain" => domain} = cookie)
       when is_binary(name) and is_binary(domain),
       do: cookie |> Map.keys() |> Enum.all?(&(&1 in @cookie_keys))

  defp cookie?(_cookie), do: false

  # A page is what the engine's snapshot renderer reads: Chrome's accessibility
  # node subset, so one renderer serves both backends.
  defp page(page) when is_map(page) do
    with :ok <- url_field(page, "url"),
         :ok <- bounded_binary(page, "title", @max_text_chars),
         :ok <- enum(page, "ready_state", @ready_states) do
      nodes(page)
    end
  end

  defp page(_page), do: {:error, {:invalid_field, "page"}}

  defp nodes(%{"nodes" => nodes}) when is_list(nodes) do
    if length(nodes) <= @max_nodes and Enum.all?(nodes, &node?/1),
      do: :ok,
      else: {:error, {:invalid_field, "nodes"}}
  end

  defp nodes(_page), do: {:error, {:invalid_field, "nodes"}}

  defp node?(%{"nodeId" => id} = node) when is_binary(id) or is_integer(id) do
    Enum.all?(~w(role name value), &ax_value?(Map.get(node, &1, :absent))) and
      child_ids?(Map.get(node, "childIds", [])) and
      properties?(Map.get(node, "properties", [])) and
      element_ref?(Map.get(node, "backendDOMNodeId", :absent))
  end

  defp node?(_node), do: false

  defp ax_value?(:absent), do: true
  defp ax_value?(%{"value" => value}) when not is_map(value) and not is_list(value), do: true
  defp ax_value?(_value), do: false

  defp child_ids?(ids) when is_list(ids), do: Enum.all?(ids, &(is_binary(&1) or is_integer(&1)))
  defp child_ids?(_ids), do: false

  defp properties?(properties) when is_list(properties),
    do: Enum.all?(properties, &property?/1)

  defp properties?(_properties), do: false

  defp property?(%{"name" => name} = property) when is_binary(name),
    do: ax_value?(Map.get(property, "value", :absent))

  defp property?(_property), do: false

  defp element_ref?(:absent), do: true
  defp element_ref?(ref), do: is_integer(ref) and ref > 0 and ref <= @max_u64

  # ── events ─────────────────────────────────────────────────────────────────

  defp event_fields("attached", payload) do
    with :ok <- bounded_nonempty(payload, "host_version", @max_id_chars) do
      bounded_nonempty(payload, "profile_id", @max_id_chars)
    end
  end

  # An unavailable pane says why, in words that finish "the Fermix app's
  # browser is no longer available: …".
  defp event_fields("availability", %{"available" => true} = payload),
    do: optional(payload, "reason", &bounded_nonempty(&1, &2, @max_reason_chars))

  defp event_fields("availability", %{"available" => false} = payload),
    do: bounded_nonempty(payload, "reason", @max_reason_chars)

  defp event_fields("availability", _payload), do: {:error, {:invalid_field, "available"}}

  defp event_fields("tab.closed", payload) do
    with :ok <- id_string(payload, "tab_id") do
      enum(payload, "by", @closed_by)
    end
  end

  defp event_fields("dialog.opened", payload) do
    with :ok <- id_string(payload, "tab_id"),
         :ok <- enum(payload, "kind", @dialog_kinds),
         :ok <- bounded_binary(payload, "message", @max_text_chars) do
      optional(payload, "default", &bounded_binary(&1, &2, @max_text_chars))
    end
  end

  defp event_fields("download.began", payload) do
    with :ok <- id_string(payload, "download_id"),
         :ok <- id_string(payload, "tab_id") do
      bounded_nonempty(payload, "filename", 1_024)
    end
  end

  defp event_fields("download.progress", payload) do
    with :ok <- id_string(payload, "download_id"),
         :ok <- nonnegative_u64(payload, "received_bytes") do
      optional(payload, "total_bytes", &nonnegative_u64/2)
    end
  end

  defp event_fields("download.finished", payload) do
    with :ok <- id_string(payload, "download_id"),
         :ok <- id_string(payload, "tab_id"),
         :ok <- enum(payload, "state", @download_states),
         :ok <- optional(payload, "path", &absolute_path/2),
         :ok <- optional(payload, "bytes", &nonnegative_u64/2) do
      optional(payload, "reason", &bounded_nonempty(&1, &2, @max_message_chars))
    end
  end

  # The person's own cancel of one task, from its owned tab in the app.
  defp event_fields("task.cancel", payload) do
    with :ok <- id_string(payload, "task_id") do
      bounded_nonempty(payload, "reason", @max_reason_chars)
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

  defp id_string?(value),
    do: is_binary(value) and value != "" and String.length(value) <= @max_id_chars

  defp url_field(payload, field), do: bounded_nonempty(payload, field, @max_url_chars)

  defp absolute_path(payload, field) do
    with :ok <- bounded_nonempty(payload, field, 4_096) do
      if String.starts_with?(payload[field], "/"),
        do: :ok,
        else: {:error, {:invalid_field, field}}
    end
  end

  # A conditionally-required field (one outside its type's flat required list,
  # such as `availability`'s `reason` when `available` is false) has no earlier
  # `require_fields/2` pass to catch its absence, so this is the one place that
  # tells "never sent" from "sent empty or invalid".
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

  defp number_field(payload, field) do
    if is_number(Map.get(payload, field)), do: :ok, else: {:error, {:invalid_field, field}}
  end

  defp positive_u64(payload, field), do: integer_range(payload, field, 1, @max_u64)
  defp nonnegative_u64(payload, field), do: integer_range(payload, field, 0, @max_u64)

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
