defmodule FermixCore.Plugins.ToolExecutor do
  @moduledoc """
  Executes first-party plugin tools with tokens resolved outside model input.
  """

  alias FermixCore.Auth.Redaction
  alias FermixCore.Auth.TokenManager
  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Net.Guard
  alias FermixCore.Plugins.Config
  alias FermixCore.Plugins.Http.Interpreter
  alias FermixCore.Plugins.Registry
  alias FermixCore.Plugins.Status
  alias FermixCore.Tools.Telemetry, as: ToolTelemetry

  @calendar_base "https://www.googleapis.com/calendar/v3"
  @drive_base "https://www.googleapis.com/drive/v3"
  @drive_upload_base "https://www.googleapis.com/upload/drive/v3/files"
  @drive_boundary "fermix_drive_upload_boundary_8f2a1c"
  @gmail_base "https://gmail.googleapis.com/gmail/v1"
  @gmail_metadata_headers ["From", "To", "Subject", "Date"]
  @max_mime_depth 8
  @rate_limit_reasons ~w(rateLimitExceeded userRateLimitExceeded dailyLimitExceeded quotaExceeded)

  @spec parameters(String.t()) :: map()
  def parameters("gmail_search_messages") do
    object_schema(["query"], %{
      "query" => %{type: "string", description: "Gmail search query."},
      "max_results" => %{type: "integer", description: "Maximum messages, default 10."}
    })
  end

  def parameters("google_drive_search_files") do
    object_schema(["query"], %{
      "query" => %{type: "string", description: "Text to search for in Drive file names."},
      "max_results" => %{type: "integer", description: "Maximum files, default 10."},
      "include_trashed" => %{type: "boolean", description: "Include trashed files."}
    })
  end

  def parameters("gmail_get_message") do
    object_schema(["id"], %{
      "id" => %{type: "string", description: "Gmail message id from gmail_search_messages."}
    })
  end

  def parameters("gmail_send_message") do
    object_schema(["to", "subject", "body"], %{
      "to" => %{type: "string"},
      "subject" => %{type: "string"},
      "body" => %{type: "string"}
    })
  end

  def parameters("gmail_reply_to_thread") do
    object_schema(["thread_id", "to", "subject", "body"], %{
      "thread_id" => %{type: "string", description: "Gmail threadId to reply within."},
      "to" => %{type: "string"},
      "subject" => %{type: "string", description: "Usually \"Re: <original subject>\"."},
      "body" => %{type: "string"},
      "cc" => %{type: "string"},
      "bcc" => %{type: "string"},
      "in_reply_to" => %{type: "string", description: "Message-Id of the message replied to."},
      "references" => %{type: "string", description: "References header for threading."}
    })
  end

  def parameters("gmail_create_draft") do
    object_schema(["to", "subject", "body"], %{
      "to" => %{type: "string"},
      "subject" => %{type: "string"},
      "body" => %{type: "string"},
      "cc" => %{type: "string"},
      "bcc" => %{type: "string"},
      "thread_id" => %{type: "string", description: "Optional threadId to attach the draft to."}
    })
  end

  def parameters("google_calendar_respond_to_event") do
    object_schema(["event_id", "response_status"], %{
      "event_id" => %{type: "string"},
      "response_status" => %{
        type: "string",
        enum: ["accepted", "declined", "tentative"],
        description: "accepted | declined | tentative."
      },
      "calendar_id" => %{type: "string", description: "Calendar id, default primary."},
      "send_updates" => %{type: "string", description: "all | externalOnly | none."}
    })
  end

  def parameters("google_drive_upload_file") do
    object_schema(["name", "content"], %{
      "name" => %{type: "string", description: "File name with extension."},
      "content" => %{type: "string", description: "Text content of the file."},
      "mime_type" => %{type: "string", description: "MIME type, default text/plain."},
      "parent_id" => %{type: "string", description: "Parent folder id; omit for root."}
    })
  end

  def parameters("google_drive_trash_file") do
    object_schema(["file_id"], %{
      "file_id" => %{type: "string"},
      "restore" => %{
        type: "boolean",
        description: "true restores from trash; default false trashes."
      }
    })
  end

  def parameters("google_drive_delete_file") do
    object_schema(["file_id"], %{"file_id" => %{type: "string"}})
  end

  def parameters(_name), do: object_schema([], %{})

  @spec execute(map(), map(), String.t(), map()) :: {:ok, Tool.tool_result()}
  def execute(args, context, plugin_name, tool)
      when is_map(args) and is_map(context) and is_binary(plugin_name) and is_map(tool) do
    start = System.monotonic_time(:millisecond)
    result = do_execute(args, context, plugin_name, tool)
    emit_telemetry(result, context, plugin_name, Map.get(tool, "name"), start)
    result
  end

  defp do_execute(args, context, plugin_name, tool) do
    with {:ok, plugin} <- Registry.find(plugin_name),
         :ok <- ensure_enabled(plugin),
         :ok <- ensure_granted(plugin, tool, context),
         auth_profile <- Config.auth_profile(plugin),
         {:ok, token} <- get_token(auth_profile, context) do
      run_tool(args, context, plugin, plugin_name, auth_profile, token, tool)
    else
      {:error, reason} -> {:ok, Tool.error(format_auth_error(plugin_name, reason))}
      {:missing_scope, result} -> {:ok, result}
      {:disabled, result} -> {:ok, result}
      :error -> {:ok, Tool.error("unknown plugin: #{plugin_name}")}
    end
  end

  # Call-time refusal for the stale-context window (§4.5 gap 2): a disabled
  # plugin's tool answers with honest enable guidance instead of falling
  # through to the auth ladder. Every other status proceeds — the downstream
  # auth errors already say the right thing (e.g. "enabled but not connected").
  defp ensure_enabled(plugin) do
    if Status.status(plugin) == :not_configured do
      {:disabled,
       Tool.error(
         "#{plugin.name} is disabled — enable it on the setup page or run " <>
           "`fermix plugins enable #{plugin.name}`."
       )}
    else
      :ok
    end
  end

  # A tool with a declarative `request` template runs through the in-VM HTTP
  # interpreter (§5.3); a tool without one uses its hardcoded dispatch clause.
  defp run_tool(args, context, plugin, plugin_name, auth_profile, token, tool) do
    if Map.has_key?(tool, "request") do
      run_declarative(args, context, plugin, plugin_name, auth_profile, token, tool)
    else
      tool
      |> Map.get("name")
      |> dispatch(args, context, plugin_name, auth_profile, token, tool)
    end
  end

  defp run_declarative(args, context, plugin, plugin_name, auth_profile, token, tool) do
    Interpreter.run(tool, args,
      http: declarative_seam(context, plugin_name, auth_profile, tool, token),
      auth_header: nil,
      auth_type: plugin.auth.type,
      plugin: plugin_name,
      requires_scopes: Map.get(tool, "requires_scopes", []),
      error_classifier: google_error_classifier(plugin, plugin_name, tool)
    )
  end

  # Google plugins keep their machine-readable 403/401 classification
  # (`format_forbidden`/`format_auth_error`) instead of the interpreter's
  # generic prose; other providers (github/notion api_key) fall back to generic.
  defp google_error_classifier(%{auth: %{provider: "google"}}, plugin_name, tool) do
    fn
      403, _headers, body -> format_forbidden(plugin_name, tool, decode_body_or_empty(body))
      401, _headers, _body -> format_auth_error(plugin_name, :reauthorization_required)
      _status, _headers, _body -> nil
    end
  end

  defp google_error_classifier(_plugin, _plugin_name, _tool), do: nil

  defp decode_body_or_empty(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _} -> %{}
    end
  end

  # The interpreter shapes the request/response; this seam owns transport, the
  # `Authorization` header, the test plug passthrough, and the one-shot 401
  # refresh-retry for read-only tools (parity with the hardcoded path).
  defp declarative_seam(context, plugin_name, auth_profile, tool, token) do
    fn request ->
      declarative_call(request, token, 0, context, plugin_name, auth_profile, tool)
    end
  end

  defp declarative_call(request, token, attempt, context, plugin_name, auth_profile, tool) do
    case guard_url(request.url, context) do
      :ok -> issue_declarative(request, token, attempt, context, plugin_name, auth_profile, tool)
      {:error, reason} -> {:error, {:blocked_url, reason}}
    end
  end

  # SSRF floor for manifest-supplied URLs (same posture as web_fetch): block
  # loopback/private/metadata hosts before any transport. Injectable for
  # hermetic tests (`:plugin_url_guard`); production default is the real guard.
  defp guard_url(url, context) do
    guard = Map.get(context, :plugin_url_guard, &Guard.validate/1)
    guard.(url)
  end

  defp issue_declarative(request, token, attempt, context, plugin_name, auth_profile, tool) do
    req_options = Map.get(context, :plugin_req_options, [])

    req =
      Req.new(
        method: request.method,
        url: request.url,
        params: request.query,
        headers: [{"authorization", "Bearer #{token}"} | request.headers],
        decode_body: false
      )
      |> maybe_merge(:json, request.body)
      |> Req.merge(req_options)

    case Req.request(req) do
      {:ok, %{status: 401}} when attempt == 0 ->
        refresh_or_pass(request, attempt, context, plugin_name, auth_profile, tool)

      {:ok, response} ->
        {:ok,
         %{
           status: response.status,
           headers: normalize_headers(response.headers),
           body: to_string(response.body)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp refresh_or_pass(request, _attempt, context, plugin_name, auth_profile, tool) do
    if Map.get(tool, "read_only") == true do
      case refresh_token(auth_profile, context) do
        {:ok, fresh} ->
          declarative_call(request, fresh, 1, context, plugin_name, auth_profile, tool)

        {:error, reason} ->
          # Surface the refresh failure itself (network vs revoked grant)
          # instead of synthesizing a 401 that classifies as a generic
          # reauthorize — parity with the hardcoded path's format_auth_error.
          {:error, {:token_refresh_failed, reason}}
      end
    else
      # A write 401 is terminal — hand the 401 to the interpreter to classify.
      {:ok, %{status: 401, headers: [], body: ""}}
    end
  end

  defp normalize_headers(headers) when is_map(headers),
    do: Enum.map(headers, fn {k, v} -> {k, v |> List.wrap() |> Enum.join(", ")} end)

  defp normalize_headers(headers) when is_list(headers), do: headers

  # Pre-flight: if the connection never granted this tool's scope, fail with
  # reauthorize guidance before spending an API call.
  defp ensure_granted(plugin, tool, context) do
    required = MapSet.new(Map.get(tool, "requires_scopes", []))
    granted = MapSet.new(granted_scopes(plugin, context))

    if MapSet.subset?(required, granted),
      do: :ok,
      else: {:missing_scope, Tool.error(format_scope_error(plugin.name, tool))}
  end

  defp granted_scopes(plugin, context) do
    getter = Map.get(context, :plugin_granted_scopes_getter, &Status.granted_scopes/1)
    getter.(plugin)
  end

  defp dispatch(
         "google_calendar_respond_to_event",
         args,
         context,
         plugin_name,
         auth_profile,
         token,
         tool
       ) do
    base = base_opts(context, plugin_name, auth_profile, tool)
    url = event_url(args)
    status = Map.get(args, "response_status")

    with :ok <- validate_response_status(status),
         {:ok, event} <- http_request(:get, url, token, base),
         {:ok, attendees} <- rsvp_attendees(Map.get(event, "attendees"), status) do
      request(:patch, url, token, [
        {:json, %{"attendees" => attendees}},
        {:params, calendar_send_updates(args)} | base
      ])
    else
      {:error, result} -> {:ok, result}
    end
  end

  defp dispatch(
         "google_calendar_move_event",
         args,
         context,
         plugin_name,
         auth_profile,
         token,
         tool
       ) do
    base = base_opts(context, plugin_name, auth_profile, tool)

    params =
      drop_blank_values(%{
        "destination" => Map.get(args, "destination_calendar_id"),
        "sendUpdates" => Map.get(args, "send_updates")
      })

    request(:post, "#{event_url(args)}/move", token, [{:params, params} | base])
  end

  defp dispatch("gmail_search_messages", args, context, plugin_name, auth_profile, token, tool) do
    params =
      %{
        "q" => Map.get(args, "query"),
        "maxResults" => Map.get(args, "max_results", 10)
      }
      |> drop_blank_values()

    base = [context: context, plugin_name: plugin_name, auth_profile: auth_profile, tool: tool]

    # messages.list returns only {id, threadId}; enrich each id with a metadata get
    # so callers receive sender/subject/date/snippet, bounded by max_results.
    with {:ok, listing} <-
           http_request(:get, "#{@gmail_base}/users/me/messages", token, [
             {:params, params} | base
           ]),
         {:ok, summaries} <- gmail_summaries(Map.get(listing, "messages", []), token, base) do
      {:ok, Tool.success(Jason.encode!(Redaction.redact(%{"messages" => summaries})))}
    else
      {:error, result} -> {:ok, result}
    end
  end

  defp dispatch(
         "google_drive_search_files",
         args,
         context,
         plugin_name,
         auth_profile,
         token,
         tool
       ) do
    params =
      %{
        "q" => drive_file_query(Map.get(args, "query"), Map.get(args, "include_trashed", false)),
        "pageSize" => Map.get(args, "max_results", 10),
        "fields" => "files(id,name,mimeType,webViewLink,modifiedTime)"
      }
      |> drop_blank_values()

    request(:get, "#{@drive_base}/files", token,
      params: params,
      context: context,
      plugin_name: plugin_name,
      auth_profile: auth_profile,
      tool: tool
    )
  end

  defp dispatch("google_drive_upload_file", args, context, plugin_name, auth_profile, token, tool) do
    base = base_opts(context, plugin_name, auth_profile, tool)
    mime = Map.get(args, "mime_type", "text/plain")

    metadata =
      drop_blank_values(%{
        "name" => Map.get(args, "name"),
        "mimeType" => mime,
        "parents" => drive_parents(args)
      })

    {body, content_type} = drive_multipart(metadata, Map.get(args, "content", ""), mime)

    request(:post, @drive_upload_base, token, [
      {:params, %{"uploadType" => "multipart"}},
      {:body, body},
      {:content_type, content_type} | base
    ])
  end

  # google_drive_trash_file and google_drive_delete_file are implemented and tested
  # but withheld from google_drive/plugin.json (so they do not register as agent
  # tools) pending the M10 runtime approval flow. Re-add their manifest entries to
  # enable; kept together here so both stay verified.
  defp dispatch("google_drive_trash_file", args, context, plugin_name, auth_profile, token, tool) do
    base = base_opts(context, plugin_name, auth_profile, tool)
    trashed = Map.get(args, "restore", false) != true

    request(:patch, "#{@drive_base}/files/#{Map.get(args, "file_id")}", token, [
      {:json, %{"trashed" => trashed}} | base
    ])
  end

  defp dispatch("google_drive_delete_file", args, context, plugin_name, auth_profile, token, tool) do
    base = base_opts(context, plugin_name, auth_profile, tool)
    request(:delete, "#{@drive_base}/files/#{Map.get(args, "file_id")}", token, base)
  end

  defp dispatch("gmail_send_message", args, context, plugin_name, auth_profile, token, tool) do
    base = base_opts(context, plugin_name, auth_profile, tool)

    request(:post, "#{@gmail_base}/users/me/messages/send", token, [
      {:json, %{"raw" => gmail_raw(args)}} | base
    ])
  end

  defp dispatch("gmail_reply_to_thread", args, context, plugin_name, auth_profile, token, tool) do
    base = base_opts(context, plugin_name, auth_profile, tool)

    body =
      drop_blank_values(%{"raw" => gmail_raw(args), "threadId" => Map.get(args, "thread_id")})

    request(:post, "#{@gmail_base}/users/me/messages/send", token, [{:json, body} | base])
  end

  defp dispatch("gmail_create_draft", args, context, plugin_name, auth_profile, token, tool) do
    base = base_opts(context, plugin_name, auth_profile, tool)

    message =
      drop_blank_values(%{"raw" => gmail_raw(args), "threadId" => Map.get(args, "thread_id")})

    request(:post, "#{@gmail_base}/users/me/drafts", token, [
      {:json, %{"message" => message}} | base
    ])
  end

  defp dispatch("gmail_get_message", args, context, plugin_name, auth_profile, token, tool) do
    base = [context: context, plugin_name: plugin_name, auth_profile: auth_profile, tool: tool]

    case gmail_get(token, Map.get(args, "id"), "full", base) do
      {:ok, body} -> {:ok, Tool.success(Jason.encode!(Redaction.redact(gmail_message(body))))}
      {:error, result} -> {:ok, result}
    end
  end

  defp dispatch(name, _args, _context, _plugin_name, _auth_profile, _token, _tool),
    do: {:ok, Tool.error("unsupported plugin tool: #{name}")}

  # Single-call tools: perform the request and JSON-encode the redacted body.
  defp request(method, url, token, opts) do
    case http_request(method, url, token, opts) do
      {:ok, body} -> {:ok, Tool.success(encode_body(body))}
      {:error, result} -> {:ok, result}
    end
  end

  # DELETE and other 204s come back with an empty body — report a clear success.
  defp encode_body(body) when body in [nil, ""], do: ~s({"ok":true})
  defp encode_body(body), do: Jason.encode!(Redaction.redact(body))

  # Performs one authorized call; returns the parsed body on 2xx, or a tool-error
  # result on any handled failure. Refreshes once on 401 for read-only tools.
  defp http_request(method, url, token, opts) do
    context = Keyword.fetch!(opts, :context)
    req_options = Map.get(context, :plugin_req_options, [])
    attempt = Keyword.get(opts, :attempt, 0)

    request =
      Req.new(
        method: method,
        url: url,
        headers: [{"authorization", "Bearer #{token}"}]
      )
      |> maybe_merge(:params, Keyword.get(opts, :params))
      |> maybe_merge(:json, Keyword.get(opts, :json))
      |> maybe_put_body(Keyword.get(opts, :body), Keyword.get(opts, :content_type))

    case request |> Req.merge(req_options) |> Req.request() do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: 401}} when attempt == 0 ->
        maybe_refresh_and_retry(method, url, opts)

      {:ok, %{status: 401}} ->
        plugin_name = Keyword.fetch!(opts, :plugin_name)
        {:error, Tool.error(format_auth_error(plugin_name, :reauthorization_required))}

      {:ok, %{status: 403, body: body}} ->
        plugin_name = Keyword.fetch!(opts, :plugin_name)
        tool = Keyword.fetch!(opts, :tool)
        {:error, Tool.error(format_forbidden(plugin_name, tool, body))}

      {:ok, %{status: status}} ->
        {:error, Tool.error("provider_error: #{status}")}

      {:error, reason} ->
        {:error, Tool.error("network: #{Redaction.format(reason)}")}
    end
  end

  defp maybe_refresh_and_retry(method, url, opts) do
    context = Keyword.fetch!(opts, :context)
    plugin_name = Keyword.fetch!(opts, :plugin_name)
    auth_profile = Keyword.fetch!(opts, :auth_profile)
    tool = Keyword.fetch!(opts, :tool)

    if Map.get(tool, "read_only") == true do
      case refresh_token(auth_profile, context) do
        {:ok, token} -> http_request(method, url, token, Keyword.put(opts, :attempt, 1))
        {:error, reason} -> {:error, Tool.error(format_auth_error(plugin_name, reason))}
      end
    else
      {:error, Tool.error(format_auth_error(plugin_name, :reauthorization_required))}
    end
  end

  defp base_opts(context, plugin_name, auth_profile, tool) do
    [context: context, plugin_name: plugin_name, auth_profile: auth_profile, tool: tool]
  end

  # Build a base64url RFC-2822 message shared by send / reply / draft.
  defp gmail_raw(args) do
    headers =
      [
        {"To", Map.get(args, "to")},
        {"Cc", Map.get(args, "cc")},
        {"Bcc", Map.get(args, "bcc")},
        {"Subject", Map.get(args, "subject")},
        {"In-Reply-To", Map.get(args, "in_reply_to")},
        {"References", Map.get(args, "references")}
      ]
      |> Enum.reject(fn {_name, value} -> value in [nil, ""] end)
      |> Enum.map(fn {name, value} -> "#{name}: #{value}" end)

    (headers ++ ["Content-Type: text/plain; charset=utf-8", "", Map.get(args, "body", "")])
    |> Enum.join("\r\n")
    |> Base.url_encode64(padding: false)
  end

  defp gmail_summaries(messages, token, base) do
    messages
    |> Enum.reduce_while([], fn message, acc ->
      case gmail_get(token, Map.get(message, "id"), "metadata", base) do
        {:ok, body} -> {:cont, [gmail_summary(body) | acc]}
        {:error, result} -> {:halt, {:error, result}}
      end
    end)
    |> finalize_summaries()
  end

  defp finalize_summaries({:error, result}), do: {:error, result}
  defp finalize_summaries(summaries) when is_list(summaries), do: {:ok, Enum.reverse(summaries)}

  defp gmail_get(token, id, format, base) when is_binary(id) and id != "" do
    params = gmail_get_params(format)

    http_request(:get, "#{@gmail_base}/users/me/messages/#{id}", token, [{:params, params} | base])
  end

  defp gmail_get(_token, _id, _format, _base),
    do: {:error, Tool.error("gmail message id is required")}

  # metadataHeaders is a repeated query key, so emit duplicate tuples rather than a
  # list value (Req's encoder rejects list-valued params).
  defp gmail_get_params("metadata"),
    do: [{"format", "metadata"} | Enum.map(@gmail_metadata_headers, &{"metadataHeaders", &1})]

  defp gmail_get_params(format), do: %{"format" => format}

  defp gmail_summary(body) do
    headers = gmail_headers(body)

    %{
      "id" => Map.get(body, "id"),
      "threadId" => Map.get(body, "threadId"),
      "snippet" => Map.get(body, "snippet"),
      "from" => gmail_header(headers, "From"),
      "to" => gmail_header(headers, "To"),
      "subject" => gmail_header(headers, "Subject"),
      "date" => gmail_header(headers, "Date")
    }
  end

  defp gmail_message(body) do
    headers = gmail_headers(body)

    body
    |> gmail_summary()
    |> Map.put("cc", gmail_header(headers, "Cc"))
    |> Map.put("message_id", gmail_header(headers, "Message-Id"))
    |> Map.put("references", gmail_header(headers, "References"))
    |> Map.put("body", gmail_text(Map.get(body, "payload", %{})))
  end

  defp gmail_headers(body), do: body |> Map.get("payload", %{}) |> Map.get("headers", [])

  defp gmail_header(headers, name) do
    target = String.downcase(name)

    headers
    |> Enum.find(fn header -> String.downcase(Map.get(header, "name", "")) == target end)
    |> case do
      nil -> nil
      header -> Map.get(header, "value")
    end
  end

  defp gmail_text(payload), do: gmail_text(payload, 0) || ""

  defp gmail_text(_payload, depth) when depth > @max_mime_depth, do: nil

  defp gmail_text(payload, depth) do
    case Map.get(payload, "parts") do
      parts when is_list(parts) ->
        parts |> Enum.map(&gmail_text(&1, depth + 1)) |> Enum.find(&is_binary/1)

      _missing ->
        gmail_leaf_text(payload)
    end
  end

  defp gmail_leaf_text(%{"mimeType" => mime} = payload)
       when mime in ["text/plain", "text/html"] do
    payload |> Map.get("body", %{}) |> Map.get("data") |> decode_b64url()
  end

  defp gmail_leaf_text(_payload), do: nil

  defp decode_b64url(nil), do: nil

  defp decode_b64url(data) when is_binary(data) do
    case Base.url_decode64(data, padding: false) do
      {:ok, text} -> text
      :error -> nil
    end
  end

  defp maybe_merge(request, _key, nil), do: request
  defp maybe_merge(request, key, value), do: Req.merge(request, [{key, value}])

  defp maybe_put_body(request, nil, _content_type), do: request

  defp maybe_put_body(request, body, content_type) do
    Req.merge(request, body: body, headers: [{"content-type", content_type}])
  end

  defp event_url(args) do
    calendar_id = Map.get(args, "calendar_id", "primary")
    event_id = Map.get(args, "event_id")
    "#{@calendar_base}/calendars/#{URI.encode(calendar_id)}/events/#{URI.encode(event_id)}"
  end

  defp calendar_send_updates(args) do
    drop_blank_values(%{"sendUpdates" => Map.get(args, "send_updates")})
  end

  defp validate_response_status(status) when status in ~w(accepted declined tentative), do: :ok

  defp validate_response_status(_status) do
    {:error, Tool.error("response_status must be one of: accepted, declined, tentative")}
  end

  # RSVP preserves the full attendee list and only flips the authenticated
  # user's entry (Google marks it with "self": true).
  defp rsvp_attendees(attendees, status) when is_list(attendees) and is_binary(status) do
    updated =
      Enum.map(attendees, fn attendee ->
        if Map.get(attendee, "self") == true,
          do: Map.put(attendee, "responseStatus", status),
          else: attendee
      end)

    if Enum.any?(updated, &(Map.get(&1, "self") == true)),
      do: {:ok, updated},
      else: {:error, Tool.error("you are not an attendee of this event")}
  end

  defp rsvp_attendees(_attendees, _status) do
    {:error, Tool.error("this event has no attendees to respond to")}
  end

  defp drop_blank_values(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Enum.into(%{})
  end

  defp drive_parents(args) do
    case Map.get(args, "parent_id") do
      id when is_binary(id) and id != "" -> [id]
      _missing -> nil
    end
  end

  # Drive media upload wants a multipart/related body: JSON metadata part, then
  # the file content part, both delimited by a shared boundary.
  defp drive_multipart(metadata, content, mime) do
    body =
      [
        "--#{@drive_boundary}",
        "Content-Type: application/json; charset=UTF-8",
        "",
        Jason.encode!(metadata),
        "--#{@drive_boundary}",
        "Content-Type: #{mime}",
        "",
        content,
        "--#{@drive_boundary}--"
      ]
      |> Enum.join("\r\n")

    {body, "multipart/related; boundary=#{@drive_boundary}"}
  end

  defp drive_file_query(query, true), do: drive_name_clause(query)

  defp drive_file_query(query, _include_trashed) do
    ["trashed = false", drive_name_clause(query)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" and ")
  end

  defp drive_name_clause(value) when is_binary(value) and value != "" do
    "name contains '#{drive_query_string(value)}'"
  end

  defp drive_name_clause(_value), do: ""

  defp drive_query_string(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("'", "\\'")
  end

  defp object_schema(required, properties) do
    %{type: "object", required: required, properties: properties}
  end

  defp get_token(auth_profile, context) do
    context
    |> Map.get(:plugin_token_getter, &TokenManager.get_token/1)
    |> then(& &1.(auth_profile))
  end

  defp refresh_token(auth_profile, context) do
    context
    |> Map.get(:plugin_token_refresher, &TokenManager.refresh/1)
    |> then(& &1.(auth_profile))
  end

  # Not every 403 is a missing scope. Classify on Google's machine-readable
  # `reason` so the message tells the user what actually went wrong.
  defp format_forbidden(plugin_name, tool, body) do
    case forbidden_reason(body) do
      reason when reason in ["ACCESS_TOKEN_SCOPE_INSUFFICIENT", "insufficientPermissions"] ->
        format_scope_error(plugin_name, tool)

      reason when reason in ["insufficientFilePermissions", "appNotAuthorizedToFile"] ->
        "#{plugin_name} does not have access to that item. It can act only on resources your " <>
          "connected account can edit — this is not a scope problem, so reconnecting will not help."

      "forbiddenForNonOrganizer" ->
        "#{plugin_name}: only the event's organizer can change this event."

      reason when reason in @rate_limit_reasons ->
        "#{plugin_name} is rate-limited by Google right now. Wait a moment and try again."

      _other ->
        "provider_error: 403"
    end
  end

  defp forbidden_reason(%{"error" => error}) when is_map(error) do
    reason_from(Map.get(error, "details")) || reason_from(Map.get(error, "errors"))
  end

  defp forbidden_reason(_body), do: nil

  defp reason_from(entries) when is_list(entries) do
    Enum.find_value(entries, fn
      %{"reason" => reason} -> reason
      _entry -> nil
    end)
  end

  defp reason_from(_entries), do: nil

  defp format_scope_error(plugin_name, tool) do
    scopes = tool |> Map.get("requires_scopes", []) |> Enum.join(", ")

    "#{plugin_name} is missing a required scope (#{scopes}). " <>
      "Run `fermix plugins auth reauthorize #{plugin_name}` and grant it at sign-in."
  end

  defp format_auth_error(plugin_name, :reauthorization_required) do
    "#{plugin_name} needs reconnection. Run `fermix plugins auth reauthorize #{plugin_name}`."
  end

  defp format_auth_error(plugin_name, :no_auth_file) do
    format_auth_error(plugin_name, :no_auth_profile)
  end

  defp format_auth_error(plugin_name, :no_token) do
    format_auth_error(plugin_name, :no_auth_profile)
  end

  defp format_auth_error(plugin_name, :no_auth_profile) do
    "#{plugin_name} is enabled but not connected. Run `fermix plugins auth login #{plugin_name}`."
  end

  defp format_auth_error(plugin_name, {:provider_missing, _profile}) do
    format_auth_error(plugin_name, :no_auth_profile)
  end

  defp format_auth_error(_plugin_name, reason),
    do: "plugin auth unavailable: #{Redaction.format(reason)}"

  defp emit_telemetry({:ok, result}, context, plugin_name, tool_name, start) do
    duration = System.monotonic_time(:millisecond) - start
    success = Map.get(result, :success) == true

    ToolTelemetry.exec(tool_name || plugin_name, context, success, duration,
      metadata: %{plugin: plugin_name},
      result: {:ok, result}
    )
  end
end
