defmodule FermixCore.Plugins.ToolExecutor do
  @moduledoc """
  Executes first-party plugin tools with tokens resolved outside model input.
  """

  alias FermixCore.Auth.Redaction
  alias FermixCore.Auth.TokenManager
  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Plugins.Config
  alias FermixCore.Plugins.Registry

  @calendar_base "https://www.googleapis.com/calendar/v3"
  @drive_base "https://www.googleapis.com/drive/v3"
  @gmail_base "https://gmail.googleapis.com/gmail/v1"

  @spec parameters(String.t()) :: map()
  def parameters("google_calendar.search_events") do
    object_schema(["query"], %{
      "query" => %{type: "string", description: "Text query for events."},
      "calendar_id" => %{type: "string", description: "Calendar id, default primary."},
      "max_results" => %{type: "integer", description: "Maximum events, default 10."}
    })
  end

  def parameters("google_calendar.create_event") do
    object_schema(["summary", "start", "end"], %{
      "summary" => %{type: "string"},
      "description" => %{type: "string"},
      "calendar_id" => %{type: "string", description: "Calendar id, default primary."},
      "start" => %{type: "string", description: "ISO8601 start date/time."},
      "end" => %{type: "string", description: "ISO8601 end date/time."},
      "time_zone" => %{type: "string", description: "IANA timezone."}
    })
  end

  def parameters("gmail.search_messages") do
    object_schema(["query"], %{
      "query" => %{type: "string", description: "Gmail search query."},
      "max_results" => %{type: "integer", description: "Maximum messages, default 10."}
    })
  end

  def parameters("google_drive.search_files") do
    object_schema(["query"], %{
      "query" => %{type: "string", description: "Text to search for in Drive file names."},
      "max_results" => %{type: "integer", description: "Maximum files, default 10."},
      "include_trashed" => %{type: "boolean", description: "Include trashed files."}
    })
  end

  def parameters("gmail.send_message") do
    object_schema(["to", "subject", "body"], %{
      "to" => %{type: "string"},
      "subject" => %{type: "string"},
      "body" => %{type: "string"}
    })
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
         auth_profile <- Config.auth_profile(plugin),
         {:ok, token} <- get_token(auth_profile, context) do
      tool
      |> Map.get("name")
      |> dispatch(args, context, plugin_name, auth_profile, token, tool)
    else
      {:error, reason} -> {:ok, Tool.error(format_auth_error(plugin_name, reason))}
      :error -> {:ok, Tool.error("unknown plugin: #{plugin_name}")}
    end
  end

  defp dispatch(
         "google_calendar.search_events",
         args,
         context,
         plugin_name,
         auth_profile,
         token,
         tool
       ) do
    calendar_id = Map.get(args, "calendar_id", "primary")

    params =
      %{
        "q" => Map.get(args, "query"),
        "maxResults" => Map.get(args, "max_results", 10),
        "singleEvents" => true,
        "orderBy" => "startTime"
      }
      |> drop_blank_values()

    request(:get, "#{@calendar_base}/calendars/#{URI.encode(calendar_id)}/events", token,
      params: params,
      context: context,
      plugin_name: plugin_name,
      auth_profile: auth_profile,
      tool: tool
    )
  end

  defp dispatch(
         "google_calendar.create_event",
         args,
         context,
         plugin_name,
         auth_profile,
         token,
         tool
       ) do
    calendar_id = Map.get(args, "calendar_id", "primary")
    time_zone = Map.get(args, "time_zone")

    body =
      %{
        "summary" => Map.get(args, "summary"),
        "description" => Map.get(args, "description"),
        "start" => calendar_time(Map.get(args, "start"), time_zone),
        "end" => calendar_time(Map.get(args, "end"), time_zone)
      }
      |> drop_blank_values()

    request(:post, "#{@calendar_base}/calendars/#{URI.encode(calendar_id)}/events", token,
      json: body,
      context: context,
      plugin_name: plugin_name,
      auth_profile: auth_profile,
      tool: tool
    )
  end

  defp dispatch("gmail.search_messages", args, context, plugin_name, auth_profile, token, tool) do
    params =
      %{
        "q" => Map.get(args, "query"),
        "maxResults" => Map.get(args, "max_results", 10)
      }
      |> drop_blank_values()

    request(:get, "#{@gmail_base}/users/me/messages", token,
      params: params,
      context: context,
      plugin_name: plugin_name,
      auth_profile: auth_profile,
      tool: tool
    )
  end

  defp dispatch(
         "google_drive.search_files",
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

  defp dispatch("gmail.send_message", args, context, plugin_name, auth_profile, token, tool) do
    raw =
      [
        "To: #{Map.get(args, "to")}",
        "Subject: #{Map.get(args, "subject")}",
        "Content-Type: text/plain; charset=utf-8",
        "",
        Map.get(args, "body")
      ]
      |> Enum.join("\r\n")
      |> Base.url_encode64(padding: false)

    request(:post, "#{@gmail_base}/users/me/messages/send", token,
      json: %{"raw" => raw},
      context: context,
      plugin_name: plugin_name,
      auth_profile: auth_profile,
      tool: tool
    )
  end

  defp dispatch(name, _args, _context, _plugin_name, _auth_profile, _token, _tool),
    do: {:ok, Tool.error("unsupported plugin tool: #{name}")}

  defp request(method, url, token, opts) do
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

    case request |> Req.merge(req_options) |> Req.request() do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, Tool.success(Jason.encode!(Redaction.redact(body)))}

      {:ok, %{status: 401}} when attempt == 0 ->
        maybe_refresh_and_retry(method, url, opts)

      {:ok, %{status: 401}} ->
        plugin_name = Keyword.fetch!(opts, :plugin_name)
        {:ok, Tool.error(format_auth_error(plugin_name, :reauthorization_required))}

      {:ok, %{status: 403}} ->
        plugin_name = Keyword.fetch!(opts, :plugin_name)
        tool = Keyword.fetch!(opts, :tool)
        {:ok, Tool.error(format_scope_error(plugin_name, tool))}

      {:ok, %{status: status}} ->
        {:ok, Tool.error("provider_error: #{status}")}

      {:error, reason} ->
        {:ok, Tool.error("network: #{Redaction.format(reason)}")}
    end
  end

  defp maybe_refresh_and_retry(method, url, opts) do
    context = Keyword.fetch!(opts, :context)
    plugin_name = Keyword.fetch!(opts, :plugin_name)
    auth_profile = Keyword.fetch!(opts, :auth_profile)
    tool = Keyword.fetch!(opts, :tool)

    if Map.get(tool, "read_only") == true do
      case refresh_token(auth_profile, context) do
        {:ok, token} -> request(method, url, token, Keyword.put(opts, :attempt, 1))
        {:error, reason} -> {:ok, Tool.error(format_auth_error(plugin_name, reason))}
      end
    else
      {:ok, Tool.error(format_auth_error(plugin_name, :reauthorization_required))}
    end
  end

  defp maybe_merge(request, _key, nil), do: request
  defp maybe_merge(request, key, value), do: Req.merge(request, [{key, value}])

  defp calendar_time(nil, _time_zone), do: nil

  defp calendar_time(value, nil) do
    %{"dateTime" => value}
  end

  defp calendar_time(value, time_zone) do
    %{"dateTime" => value, "timeZone" => time_zone}
  end

  defp drop_blank_values(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Enum.into(%{})
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

  defp format_scope_error(plugin_name, tool) do
    profile = Map.get(tool, "requires_scope_profile", "requested")

    "#{plugin_name} needs `#{profile}`. Run `fermix plugins auth reauthorize #{plugin_name} " <>
      "--scope #{profile}`."
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

    :telemetry.execute(
      [:fermix, :tool, :exec],
      %{duration_ms: duration},
      %{
        tool: tool_name || plugin_name,
        agent: Map.get(context, :agent_name, "unknown"),
        success: Map.get(result, :success) == true,
        plugin: plugin_name
      }
    )
  end
end
