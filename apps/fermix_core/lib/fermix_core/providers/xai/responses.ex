defmodule FermixCore.Providers.XAI.Responses do
  @moduledoc """
  xAI Grok adapter — `api.x.ai/v1/responses` (OpenAI Responses wire shape).

  Wire-shape conversion (tool list, item-list input/output, call_id
  fallback, context-length detection) is shared with the OpenAI Responses
  adapters via `OpenAI.ResponsesShared`; telemetry and structured errors
  say `:xai`, never `:openai`. xAI-specific shaping (design doc §6):

    * `store: false` and `parallel_tool_calls: true` on every request.
    * Reasoning effort `none|low|medium|high` via `ReasoningEffort`
      (above-ceiling clamps to `high`); models that reject
      `reasoning.effort` get the field omitted.
    * Tool schemas are sanitized — xAI rejects enum values containing
      slashes (Hermes parity); offending values are dropped and emptied
      enums removed.

  Auth: bearer API key, or an `xai_oauth` bearer via `:access_token` /
  token server + `:auth_profile` (login flow lands in Stage 4). A 401 on
  a server-managed token refreshes once and retries once; telemetry is
  emitted once per logical call (Codex precedent).
  """

  @behaviour FermixCore.Providers.Adapter

  alias FermixCore.Auth.TokenSupervisor
  alias FermixCore.Net.HttpClient
  alias FermixCore.Providers.Error, as: ProviderError
  alias FermixCore.Providers.ModelCatalog
  alias FermixCore.Providers.OpenAI.ResponsesShared
  alias FermixCore.Providers.Telemetry, as: ProviderTelemetry

  require Logger

  @default_base_url "https://api.x.ai/v1"
  @receive_timeout_ms 120_000

  @impl true
  def chat(messages, capabilities, opts)
      when is_list(messages) and messages != [] and is_list(capabilities) and is_list(opts) do
    {req_options, opts} = Keyword.pop(opts, :req_options, [])

    with {:ok, auth} <- resolve_auth(opts) do
      do_chat(messages, capabilities, auth, req_options, opts)
    end
  end

  defp do_chat(messages, capabilities, auth, req_options, opts) do
    model = Keyword.fetch!(opts, :model)

    {instructions, input} = ResponsesShared.build_input(messages)

    tools =
      capabilities
      |> ResponsesShared.to_provider_tools(:xai_responses)
      |> sanitize_tools()

    body = build_body(model, input, instructions, tools, opts)
    turn_state = turn_state(model, auth, input, instructions, tools, capabilities, opts)
    post(base_url(opts), auth, body, req_options, turn_state)
  end

  @impl true
  def continue(provider_state, tool_results, opts)
      when is_map(provider_state) and is_list(tool_results) and tool_results != [] and
             is_list(opts) do
    {req_options, opts} = Keyword.pop(opts, :req_options, [])

    with {:ok, auth} <- resolve_auth(opts) do
      do_continue(provider_state, tool_results, auth, req_options, opts)
    end
  end

  defp do_continue(provider_state, tool_results, auth, req_options, opts) do
    model = Keyword.fetch!(opts, :model)

    %{input: prior_input, output_items: output_items, tools: tools, capabilities: capabilities} =
      provider_state

    outputs = ResponsesShared.build_function_call_outputs(tool_results)
    next_input = prior_input ++ output_items ++ outputs

    body = build_body(model, next_input, nil, tools, opts)
    turn_state = turn_state(model, auth, next_input, nil, tools, capabilities, opts)
    post(base_url(opts), auth, body, req_options, turn_state)
  end

  @impl true
  def to_provider_tools(capabilities),
    do: capabilities |> ResponsesShared.to_provider_tools(:xai_responses) |> sanitize_tools()

  @impl true
  def parse_tool_calls(response), do: ResponsesShared.parse_tool_calls(response)

  @impl true
  def parse_response(body) when is_map(body) do
    {:ok, turn} = ResponsesShared.build_turn(body, body["model"] || "unknown", [], [], [])
    turn
  end

  @impl true
  def supports_streaming?, do: false

  # --- request build ---

  defp build_body(model, input, instructions, tools, opts) do
    %{model: model, input: input, store: false, parallel_tool_calls: true}
    |> maybe_put(:instructions, instructions)
    |> maybe_put(:tools, tools)
    |> maybe_put(:temperature, Keyword.get(opts, :temperature))
    |> maybe_put(:reasoning, maybe_reasoning(model, Keyword.get(opts, :reasoning_effort)))
  end

  defp maybe_reasoning(model, effort) do
    if ModelCatalog.reasoning_effort?(:xai, model) do
      ResponsesShared.maybe_reasoning_field(effort, :xai)
    else
      log_dropped_effort(model, effort)
      nil
    end
  end

  defp log_dropped_effort(_model, nil), do: :ok

  defp log_dropped_effort(model, _effort),
    do: Logger.debug("xAI model #{model} rejects reasoning.effort — field omitted")

  # xAI rejects tool schemas whose enum values contain slashes (Hermes
  # parity); MCP-provided capabilities can carry such enums.
  defp sanitize_tools(tools),
    do: Enum.map(tools, &Map.update!(&1, :parameters, fn schema -> sanitize_schema(schema) end))

  defp sanitize_schema(map) when is_map(map) do
    map
    |> Enum.flat_map(fn
      {key, values} when key in ["enum", :enum] and is_list(values) ->
        case Enum.reject(values, &slash_value?/1) do
          [] -> []
          kept -> [{key, kept}]
        end

      {key, value} ->
        [{key, sanitize_schema(value)}]
    end)
    |> Map.new()
  end

  defp sanitize_schema(list) when is_list(list), do: Enum.map(list, &sanitize_schema/1)
  defp sanitize_schema(value), do: value

  defp slash_value?(value) when is_binary(value), do: String.contains?(value, "/")
  defp slash_value?(_value), do: false

  defp turn_state(model, auth, input, instructions, tools, capabilities, opts) do
    %{
      model: model,
      auth_mode: auth_mode(auth),
      input: input,
      tools: tools,
      capabilities: capabilities,
      agent: Keyword.get(opts, :agent),
      session_id: Keyword.get(opts, :session_id),
      parent_session: Keyword.get(opts, :parent_session),
      reasoning_effort: Keyword.get(opts, :reasoning_effort),
      request_metrics: ResponsesShared.request_metrics(input, instructions, tools, capabilities)
    }
  end

  defp base_url(opts), do: Keyword.get(opts, :base_url, @default_base_url)

  # --- auth ---

  defp resolve_auth(opts) do
    api_key = nonempty_string(Keyword.get(opts, :api_key))
    access_token = nonempty_string(Keyword.get(opts, :access_token))
    auth_profile = Keyword.get(opts, :auth_profile)

    cond do
      api_key ->
        {:ok, {:api_key, api_key}}

      access_token ->
        {:ok, {:oauth_static, access_token}}

      is_binary(auth_profile) ->
        {:ok, {:oauth_server, Keyword.get(opts, :token_server, TokenSupervisor), auth_profile}}

      true ->
        {:error,
         ProviderError.auth(
           :xai,
           :responses,
           "XAI.Responses requires :api_key, :access_token, or :auth_profile"
         )}
    end
  end

  defp auth_mode({:api_key, _key}), do: :api_key
  defp auth_mode(_auth), do: :oauth

  defp current_bearer({:api_key, key}), do: {:ok, key}
  defp current_bearer({:oauth_static, token}), do: {:ok, token}

  defp current_bearer({:oauth_server, server, profile}) do
    case server.get_token(profile) do
      {:ok, token} ->
        {:ok, token}

      {:error, reason} ->
        {:error,
         ProviderError.auth(
           :xai,
           :responses,
           "XAI.Responses requires a bearer token: token server returned #{inspect(reason)}"
         )}
    end
  end

  defp nonempty_string(value) when is_binary(value) and value != "", do: value
  defp nonempty_string(_value), do: nil

  # --- transport + response handling ---

  # Telemetry fires exactly once per logical call — a refreshed 401 must
  # not leave a phantom error event in the trace (Codex precedent).
  defp post(base_url, auth, body, req_options, turn_state) do
    start = System.monotonic_time(:millisecond)
    result = attempt_with_retry(base_url, auth, body, req_options, turn_state)
    duration_ms = System.monotonic_time(:millisecond) - start
    emit_telemetry(result, turn_state, duration_ms)
    result
  end

  # One bound retry: a 401 on a server-managed token refreshes once and
  # reposts with the refreshed bearer (design doc §12, xAI OAuth #5).
  defp attempt_with_retry(base_url, auth, body, req_options, turn_state) do
    result = attempt(base_url, auth, body, req_options, turn_state)

    case {result, auth} do
      {{:error, {:provider_error, %{status: 401}}}, {:oauth_server, server, profile}} ->
        case server.refresh(profile) do
          {:ok, fresh_token} ->
            retried =
              attempt(base_url, {:oauth_static, fresh_token}, body, req_options, turn_state)

            tag_auth_mode(retried, auth)

          {:error, reason} ->
            Logger.warning("xAI Responses token refresh failed: #{inspect(reason)}")
            tag_auth_mode(result, auth)
        end

      _other ->
        tag_auth_mode(result, auth)
    end
  end

  defp attempt(base_url, auth, body, req_options, turn_state) do
    case current_bearer(auth) do
      {:ok, bearer} -> do_attempt(base_url, bearer, body, req_options, turn_state)
      {:error, _reason} = error -> error
    end
  end

  defp do_attempt(base_url, bearer, body, req_options, turn_state) do
    raw =
      Req.new(
        url: "#{base_url}/responses",
        method: :post,
        json: body,
        receive_timeout: @receive_timeout_ms,
        headers: [
          {"authorization", "Bearer " <> bearer},
          {"content-type", "application/json"}
        ]
      )
      |> Req.merge(req_options)
      |> HttpClient.request("xAI Responses")

    handle_response(raw, turn_state)
  end

  defp handle_response({:ok, %Req.Response{status: 200, body: body}}, turn_state)
       when is_map(body) do
    ResponsesShared.build_turn(
      body,
      turn_state.model,
      turn_state.input,
      turn_state.tools,
      turn_state.capabilities
    )
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}, _turn_state) do
    if ResponsesShared.context_length_error?(body) do
      {:error, :context_length_exceeded}
    else
      Logger.error("xAI Responses API error: #{status} - #{inspect(body)}")
      {:error, ProviderError.api(:xai, :responses, status, body)}
    end
  end

  defp handle_response({:error, %Req.TransportError{reason: reason}}, _turn_state) do
    Logger.error("xAI Responses transport error: #{inspect(reason)}")
    {:error, ProviderError.transport(:xai, :responses, reason)}
  end

  defp handle_response({:error, reason}, _turn_state) do
    Logger.error("xAI Responses request failed: #{inspect(reason)}")
    {:error, reason}
  end

  # The auth mode is part of the error identity so channel replies can
  # distinguish "check the API key" from "reconnect the subscription".
  defp tag_auth_mode({:error, {:provider_error, error}}, auth),
    do: {:error, {:provider_error, Map.put(error, :auth_mode, auth_mode(auth))}}

  defp tag_auth_mode(result, _auth), do: result

  # --- telemetry ---

  defp emit_telemetry(result, turn_state, duration_ms) do
    {status, tokens, output, tool_calls, error_metadata} =
      case result do
        {:ok, turn} ->
          {:ok, %{prompt: turn.usage.prompt_tokens, completion: turn.usage.completion_tokens},
           turn.content, turn.tool_calls, %{}}

        {:error, reason} ->
          {:error, %{}, nil, nil, ProviderError.telemetry_metadata(reason)}
      end

    metadata =
      %{
        provider: :xai,
        adapter: :responses,
        auth_mode: turn_state.auth_mode,
        model: turn_state.model,
        status: status,
        tokens: tokens,
        reasoning_effort: turn_state.reasoning_effort
      }
      |> Map.merge(turn_state.request_metrics)
      |> Map.merge(error_metadata)
      |> maybe_put(:agent, turn_state.agent)

    ProviderTelemetry.emit_call(metadata, duration_ms,
      session_id: turn_state.session_id,
      parent_session: turn_state.parent_session,
      output: output,
      tool_calls: tool_calls
    )
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
