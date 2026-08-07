defmodule FermixCore.Plugins.Http.Interpreter do
  @moduledoc """
  Executes a declarative `http`-rail plugin tool: validate args → build the
  request → call → (optionally) paginate → guard the response (JSON-only, size
  cap) → extract → redact → classify errors (§5.3). This is the in-VM engine
  that replaces hardcoded per-tool Elixir for declarative plugins.

  The HTTP call is an injected seam (`:http`) so the engine is hermetic in
  tests; the default wraps `Net.HttpClient`. The result is the standard tool
  shape (`%{success, output, error}`).
  """

  alias FermixCore.Auth.Redaction
  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Net.Guard
  alias FermixCore.Net.HttpClient
  alias FermixCore.Plugins.Http.Extract
  alias FermixCore.Plugins.Http.ParamSchema
  alias FermixCore.Plugins.Http.Template

  @max_pages_cap 50
  @default_max_pages 10
  @default_max_response_bytes 5 * 1024 * 1024

  # Cumulative response ceiling for one paginated call. The per-page cap bounds
  # a single response; without this a manifest declaring `max_pages: 10` could
  # stack ten of them (50 MiB) into one tool result. Internal constant, not a
  # knob: it is the same class of limit as `@max_pages_cap`.
  @max_paginated_bytes 10 * 1024 * 1024

  @type http_response :: %{status: integer(), headers: [{String.t(), String.t()}], body: binary()}
  @type http_fun :: (map() -> {:ok, http_response()} | {:error, term()})

  @doc """
  Run a tool. `tool` is the manifest tool map (`parameters`, `request`).
  `args` are the model-supplied arguments. Opts:

    * `:http` — the request seam `(req_map -> {:ok, resp} | {:error, _})`
    * `:auth_header` — `{name, value} | nil`, injected after validation
    * `:auth_type` — `:oauth2 | :api_key | :none` (401 classification)
    * `:plugin` — plugin name (for `api_key` reauth guidance)
    * `:max_response_bytes` — response size cap
  """
  @spec run(map(), map(), keyword()) :: {:ok, Tool.tool_result()}
  def run(tool, args, opts \\ []) when is_map(tool) and is_map(args) do
    with {:ok, params} <- validate_params(tool, args),
         {:ok, request} <- build_request(tool, params, opts) do
      execute(tool, request, opts)
    else
      {:error, reason} -> {:ok, Tool.error(param_or_build_message(reason))}
    end
  end

  defp validate_params(tool, args) do
    case ParamSchema.validate(Map.get(tool, "parameters", %{}), args) do
      {:ok, params} -> {:ok, params}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_request(tool, params, opts) do
    Template.build(Map.get(tool, "request", %{}), params, Keyword.get(opts, :auth_header))
  end

  # --- execution ---

  defp execute(tool, request, opts) do
    template = Map.get(tool, "request", %{})

    case Map.get(template, "paginate") do
      nil -> single(request, Map.get(template, "extract"), opts)
      paginate -> paginated(request, paginate, opts)
    end
  end

  defp single(request, extract_spec, opts) do
    case call(request, opts) do
      {:ok, %{status: status} = resp} ->
        if status in request.success,
          do: ok_body(resp, extract_spec, opts),
          else: {:ok, classify_response(resp, opts)}

      {:error, reason} ->
        {:ok, Tool.error("request failed: #{inspect(reason)}")}
    end
  end

  # A caller may supply an `:error_classifier` to keep vendor-specific error
  # messages (e.g. Google's 403 scope/permission/organizer/rate-limit prose) for
  # its own tools; it returns a message string, or nil to fall back to the
  # generic status-based classification.
  defp classify_response(resp, opts) do
    case classifier_message(resp, opts) do
      message when is_binary(message) -> Tool.error(message)
      _ -> classify(resp, opts)
    end
  end

  defp classifier_message(resp, opts) do
    case Keyword.get(opts, :error_classifier) do
      fun when is_function(fun, 3) -> fun.(resp.status, resp.headers, resp.body)
      _ -> nil
    end
  end

  defp ok_body(resp, extract_spec, opts) do
    with {:ok, decoded} <- decode_json(resp, opts) do
      shaped = extract_spec |> Extract.apply(decoded) |> Redaction.redact()
      {:ok, Tool.success(Jason.encode!(shaped))}
    else
      {:error, message} -> {:ok, Tool.error(message)}
    end
  end

  # --- pagination (the one bounded loop) ---

  defp paginated(request, config, opts) do
    max = config |> Map.get("max_pages", @default_max_pages) |> min(@max_pages_cap)
    items_path = Map.get(config, "items_path")
    state = %{items: [], page: 0, bytes: 0}

    case collect_pages(request, config, opts, max, items_path, state) do
      {:ok, items, truncated?} -> {:ok, paginated_result(items, config, truncated?)}
      {:error, message} -> {:ok, Tool.error(message)}
    end
  end

  # Two ceilings, one stop condition, one result shape: the loop ends truncated
  # when it has fetched `max` pages OR when the pages it already decoded total
  # `@max_paginated_bytes`. The byte ceiling is checked between pages, so the
  # peak is bounded by the cumulative cap plus one per-page cap.
  defp collect_pages(_request, _config, _opts, max, _items_path, %{page: page} = state)
       when page >= max do
    {:ok, collected(state), true}
  end

  defp collect_pages(_request, _config, _opts, _max, _items_path, %{bytes: bytes} = state)
       when bytes >= @max_paginated_bytes do
    {:ok, collected(state), true}
  end

  defp collect_pages(request, config, opts, max, items_path, state) do
    case call(request, opts) do
      {:ok, %{status: status} = resp} when status in [200, 201] ->
        with {:ok, decoded} <- decode_json(resp, opts) do
          state = accumulate(state, resp, decoded, items_path)
          continue_pages(request, config, opts, max, items_path, state, decoded)
        else
          {:error, message} -> {:error, message}
        end

      {:ok, resp} ->
        {:error, classify_response(resp, opts).error}

      {:error, reason} ->
        {:error, "request failed: #{inspect(reason)}"}
    end
  end

  defp accumulate(state, resp, decoded, items_path) do
    %{
      state
      | items: [navigate_items(decoded, items_path) | state.items],
        bytes: state.bytes + byte_size(resp.body)
    }
  end

  defp collected(%{items: items}), do: items |> Enum.reverse() |> List.flatten()

  defp continue_pages(request, config, opts, max, items_path, state, decoded) do
    case next_cursor(config, decoded, items_path) do
      nil ->
        {:ok, collected(state), false}

      cursor ->
        collect_pages(
          set_cursor(request, config, cursor),
          config,
          opts,
          max,
          items_path,
          %{state | page: state.page + 1}
        )
    end
  end

  # The next page's cursor. `cursor` mode (default) reads an opaque token from
  # the response body (`cursor_path`) — Slack's `next_cursor`, AgentMail's
  # `next_page_token`. `id_window` mode derives it from the last item's id
  # (`id_field`, default `"id"`) — Discord's `before`/`after` snowflake paging,
  # which no `cursor_path` can express. Both terminate on an exhausted page
  # (nil cursor) and are bounded by `max_pages`.
  defp next_cursor(config, decoded, items_path) do
    case Map.get(config, "mode", "cursor") do
      "id_window" -> id_window_cursor(decoded, items_path, Map.get(config, "id_field", "id"))
      _cursor -> cursor_value(decoded, Map.get(config, "cursor_path"))
    end
  end

  defp id_window_cursor(decoded, items_path, id_field) do
    case decoded |> navigate_items(items_path) |> List.last() do
      %{} = last -> Map.get(last, id_field)
      _empty_or_scalar -> nil
    end
  end

  defp paginated_result(items, config, truncated?) do
    shaped = apply_fields(items, Map.get(config, "fields"))
    payload = %{"items" => Redaction.redact(shaped), "truncated" => truncated?}
    Tool.success(Jason.encode!(payload))
  end

  defp apply_fields(items, nil), do: items

  defp apply_fields(items, fields) when is_list(fields),
    do: Enum.map(items, &take_fields(&1, fields))

  defp take_fields(item, fields) when is_map(item), do: Map.take(item, fields)
  defp take_fields(item, _fields), do: item

  defp navigate_items(decoded, nil), do: List.wrap(decoded)

  defp navigate_items(decoded, path),
    do: %{"path" => path} |> Extract.apply(decoded) |> List.wrap()

  defp cursor_value(_decoded, nil), do: nil
  defp cursor_value(decoded, path), do: Extract.apply(%{"path" => path}, decoded)

  defp set_cursor(request, config, cursor) do
    param = Map.get(config, "cursor_param")

    case Map.get(config, "cursor_in", "query") do
      "body" -> %{request | body: Map.put(request.body || %{}, param, cursor)}
      _ -> %{request | query: List.keystore(request.query, param, 0, {param, to_string(cursor)})}
    end
  end

  # --- response guards ---

  defp decode_json(%{status: 204}, _opts), do: {:ok, %{}}
  defp decode_json(%{body: ""}, _opts), do: {:ok, %{}}

  defp decode_json(%{headers: headers, body: body}, opts) do
    cond do
      byte_size(body) > max_bytes(opts) ->
        {:error, "response exceeds the size cap (downloads belong on the mcp rail)"}

      not json?(headers) ->
        {:error, "unexpected non-JSON response"}

      true ->
        decode_or_error(body)
    end
  end

  defp decode_or_error(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _} -> {:error, "unexpected non-JSON response"}
    end
  end

  defp json?(headers) do
    case List.keyfind(headers, "content-type", 0) || find_ci(headers, "content-type") do
      {_, value} ->
        String.contains?(value, "application/json") or String.contains?(value, "+json")

      nil ->
        false
    end
  end

  defp find_ci(headers, name) do
    Enum.find(headers, fn {k, _} -> String.downcase(k) == name end)
  end

  defp max_bytes(opts), do: Keyword.get(opts, :max_response_bytes, @default_max_response_bytes)

  @doc """
  The response ceiling, in bytes, shared with the transport.

  The transport enforces this while the body streams in; the check inside
  `decode_json/2` re-asserts it on whatever arrived. One constant, two places
  that must agree — so the transport reads it from here rather than keeping a
  second copy that can drift.
  """
  @spec max_response_bytes() :: pos_integer()
  def max_response_bytes, do: @default_max_response_bytes

  # --- error classification (§5.3) ---

  # Both plugin transports set `redirect: false`, so a 3xx arrives here instead
  # of being followed. That is deliberate: `Net.Guard` screens the URL the
  # manifest asked for, and Req's request steps do not re-run on a followed hop,
  # so the second host would reach the network unscreened. Name the status and
  # the Location — a bare "request failed (302)" tells an operator nothing about
  # where the API tried to send us.
  defp classify(%{status: status} = resp, _opts) when status in 300..399 do
    Tool.error(
      "redirect refused: HTTP #{status} to #{redirect_location(resp)}. Plugin requests do not " <>
        "follow redirects — point the manifest at the final URL."
    )
  end

  defp classify(%{status: 401}, opts) do
    case Keyword.get(opts, :auth_type, :none) do
      :oauth2 ->
        name = plugin(opts)
        Tool.error("#{name} needs reconnection. Run `fermix plugins auth reauthorize #{name}`.")

      :api_key ->
        Tool.error("API key rejected — update it with `fermix plugins auth set #{plugin(opts)}`")

      _ ->
        Tool.error("401 unauthorized")
    end
  end

  defp classify(%{status: 403} = resp, opts) do
    scopes = opts |> Keyword.get(:requires_scopes, []) |> Enum.join(", ")
    Tool.error("permission denied (requires: #{scopes}). #{redacted_body(resp)}")
  end

  defp classify(%{status: 429} = resp, _opts) do
    retry =
      case find_ci(resp.headers, "retry-after") do
        {_, value} -> " retry after #{value}s"
        nil -> ""
      end

    Tool.error("rate-limited#{retry}")
  end

  defp classify(%{status: status} = resp, _opts) when status >= 500 do
    Tool.error("provider error (#{status}). #{redacted_body(resp)}")
  end

  defp classify(%{status: status} = resp, _opts) do
    Tool.error("request failed (#{status}). #{redacted_body(resp)}")
  end

  defp redirect_location(%{headers: headers}) do
    case find_ci(headers, "location") do
      {_name, value} -> value
      nil -> "an unstated location (no Location header)"
    end
  end

  # Error bodies bypass the success-path decode, so cap them here too — a huge
  # provider error page must not be copied wholesale into the model's view.
  @error_body_cap 2_048

  defp redacted_body(%{body: body}) do
    capped = cap(body)

    case Jason.decode(capped) do
      {:ok, decoded} -> decoded |> Redaction.redact() |> Jason.encode!()
      {:error, _} -> Redaction.redact(capped)
    end
  end

  defp cap(body) when byte_size(body) > @error_body_cap,
    do: binary_part(body, 0, @error_body_cap) <> "…(truncated)"

  defp cap(body), do: body

  defp plugin(opts), do: Keyword.get(opts, :plugin, "<plugin>")

  defp param_or_build_message({:missing_param, key}), do: "missing required parameter: #{key}"
  defp param_or_build_message({:invalid_param, key, _}), do: "invalid parameter: #{key}"
  defp param_or_build_message(reason), do: "could not build request: #{inspect(reason)}"

  # --- the http seam ---

  defp call(request, opts) do
    http = Keyword.get(opts, :http, &default_http/1)
    http.(request)
  end

  # Production caller: the shared `Net.HttpClient` (Finch pool + stale-socket
  # retry). `decode_body: false` keeps the raw body so this module owns the
  # content-type / size-cap / JSON decoding decisions (§5.3). Net.Guard is the
  # SSRF floor: template URLs never reach loopback/private/metadata hosts, and
  # `redirect: false` keeps that floor meaningful — Req would follow a hop
  # without re-running the guard, landing on a host nothing screened.
  defp default_http(request) do
    case Guard.validate(request.url) do
      :ok -> issue_default(request)
      {:error, reason} -> {:error, {:blocked_url, reason}}
    end
  end

  defp issue_default(request) do
    req =
      Req.new(
        method: request.method,
        url: request.url,
        params: request.query,
        headers: request.headers,
        decode_body: false,
        redirect: false
      )
      |> with_json_body(request.body)

    case HttpClient.request(req, "plugin_http") do
      {:ok, %Req.Response{status: status, headers: headers, body: body}} ->
        {:ok, %{status: status, headers: flatten_headers(headers), body: to_string(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp with_json_body(req, nil), do: req
  defp with_json_body(req, body), do: Req.merge(req, json: body)

  defp flatten_headers(headers) when is_map(headers),
    do: Enum.map(headers, fn {k, v} -> {k, v |> List.wrap() |> Enum.join(", ")} end)

  defp flatten_headers(headers) when is_list(headers), do: headers
end
