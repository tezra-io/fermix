defmodule FermixCore.Providers.OpenAI.ChatGPTPlan do
  @moduledoc """
  OpenAI Codex (`:openai_codex`) on the person's ChatGPT plan (Sign in with
  ChatGPT, M57 D5): the public Responses API at `api.openai.com/v1/responses`,
  billed to the signed-in person's ChatGPT plan.

  The wire is the Responses item list `ResponsesShared` already speaks
  (instructions split out of `input`, function tools, `function_call` parsing,
  `function_call_output` replay) and the stream is read by the shared SSE
  parser (`OpenAI.Codex.SSEParser`). Its instructions end with the Codex/GPT-5
  family behavior contract (`Prompt.ModelOverlays.apply_codex/1`, M10 P3),
  appended once at the end so the composed prefix stays byte-stable for
  caching. What this route narrows:

    * Every request is `store: false, stream: true` with `input` as an array,
      and history is replayed inline (`ResponsesShared.replayable_output_items/1`).
    * Function tools travel as ONE `additional_tools` input item placed first
      in `input`, never as a top-level `tools` field ("Group function/custom
      tools in namespaces or supply them through `additional_tools` input
      items").
    * Reasoning (`effort`, `summary: "auto"`) and
      `include: ["reasoning.encrypted_content"]` ride only when an effort is
      set.
    * Never sent: `temperature`, `top_p`, `max_output_tokens`, `metadata`,
      `user`, `truncation`, `background`, `previous_response_id`,
      `service_tier` (the route refuses each).
    * Headers: the bearer, `content-type` and `accept: text/event-stream`. No
      account-id or beta header.

  Auth: a bearer from the token server under the provider's auth profile
  (`Store.profile(:openai_codex)`, passed as `:auth_profile`) or an explicit
  `:access_token`. A 401 refreshes once and retries once; a 401 alone never
  marks the account revoked.

  Only `response.completed` is a delivered turn. `response.failed`,
  `response.incomplete`, a stream `error` event and a stream that ends before
  any terminal event are four distinct errors, each recorded at `:mid_stream`.
  A refusal before the stream keeps the vendor's own words: a bare
  `{"detail": ...}` body is quoted as `provider_words` and never read as a code.
  The `subscription_sharing_*` codes are classified by `Providers.Error`.
  Telemetry is one `Providers.Telemetry.emit_call/3` per logical call.
  """

  @behaviour FermixCore.Providers.Adapter

  alias FermixCore.Auth.TokenSupervisor
  alias FermixCore.Net.HttpClient
  alias FermixCore.Prompt.ModelOverlays
  alias FermixCore.Providers.Error, as: ProviderError
  alias FermixCore.Providers.OpenAI.Codex.SSEParser
  alias FermixCore.Providers.OpenAI.ResponsesShared
  alias FermixCore.Providers.Telemetry, as: ProviderTelemetry

  require Logger

  @provider :openai_codex
  @adapter :chatgpt_plan
  @default_base_url "https://api.openai.com/v1"
  @default_instructions "You are a helpful AI assistant."
  @provider_words_limit 300

  @impl true
  def chat(messages, capabilities, opts)
      when is_list(messages) and messages != [] and is_list(capabilities) and is_list(opts) do
    {req_options, opts} = Keyword.pop(opts, :req_options, [])

    with {:ok, auth} <- resolve_auth(opts) do
      {instructions, input} = ResponsesShared.build_input(messages)
      tools = ResponsesShared.to_provider_tools(capabilities, @adapter)

      request = %{
        model: Keyword.fetch!(opts, :model),
        # The behavior contract goes at the END, so the prefix stays cacheable.
        instructions: ModelOverlays.apply_codex(instructions || @default_instructions),
        input: input,
        tools: tools,
        capabilities: capabilities,
        invariant_metrics: ResponsesShared.invariant_metrics(tools, capabilities)
      }

      post(request, auth, req_options, opts)
    end
  end

  @impl true
  def continue(provider_state, tool_results, opts)
      when is_map(provider_state) and is_list(tool_results) and tool_results != [] and
             is_list(opts) do
    {req_options, opts} = Keyword.pop(opts, :req_options, [])

    with {:ok, auth} <- resolve_auth(opts) do
      post(continuation_request(provider_state, tool_results, opts), auth, req_options, opts)
    end
  end

  defp continuation_request(provider_state, tool_results, opts) do
    %{
      input: prior_input,
      output_items: output_items,
      tools: tools,
      capabilities: capabilities,
      instructions: instructions,
      invariant_metrics: invariant_metrics
    } = provider_state

    history =
      ResponsesShared.substitute_tool_results(
        prior_input,
        Keyword.get(opts, :tool_result_substitutions, %{})
      )

    input =
      (history ++
         ResponsesShared.replayable_output_items(output_items) ++
         ResponsesShared.build_function_call_outputs(tool_results))
      |> ResponsesShared.retain_screenshots(Keyword.get(opts, :max_retained_screenshots))

    %{
      model: Keyword.fetch!(opts, :model),
      instructions: instructions,
      input: input,
      tools: tools,
      capabilities: capabilities,
      invariant_metrics: invariant_metrics
    }
  end

  @impl true
  def to_provider_tools(capabilities),
    do: ResponsesShared.to_provider_tools(capabilities, @adapter)

  @impl true
  def parse_tool_calls(response), do: ResponsesShared.parse_tool_calls(response)

  @impl true
  def parse_response(body) when is_map(body) do
    {:ok, turn} = ResponsesShared.build_turn(body, body["model"] || "unknown", [], [], [])
    turn
  end

  @impl true
  def supports_streaming?, do: true

  @usage_limit_sentence "Your ChatGPT plan's usage limit for Fermix is reached. Review your " <>
                          "plan or Fermix's limit in ChatGPT settings: " <>
                          "https://chatgpt.com/settings/usage"
  @usage_unavailable_codes ~w(subscription_sharing_usage_unavailable
                              subscription_sharing_user_unavailable
                              subscription_sharing_v2_user_unavailable)

  @doc """
  The person-facing sentence for a refusal this route reported (M57 §8), or
  `nil` when the error is not one of its own. The one source for the reply a
  turn ends with and the line the doctor prints. A usage limit names no reset
  time: the route sends none, and the docs say not to infer one.
  """
  @spec refusal_sentence(term()) :: String.t() | nil
  def refusal_sentence({:provider_error, %{provider: @provider} = error}),
    do: sentence_for(error.kind, error)

  def refusal_sentence(_reason), do: nil

  defp sentence_for(:quota, %{code: "subscription_sharing_usage_limit_exceeded"}),
    do: @usage_limit_sentence

  defp sentence_for(:provider_unavailable, %{code: code}) when code in @usage_unavailable_codes,
    do: "ChatGPT could not check your plan's usage right now. Try again shortly."

  defp sentence_for(:plan_not_eligible, %{code: "subscription_sharing_v2_client_not_enabled"}),
    do: "OpenAI has not enabled plan usage for Fermix's sign-in."

  defp sentence_for(:plan_not_eligible, _error),
    do:
      "This ChatGPT account or workspace can't use its plan in Fermix. " <>
        "ChatGPT Plus and Pro plans can."

  defp sentence_for(
         :invalid_request,
         %{code: "subscription_sharing_unsupported_capability"} = error
       ) do
    case Map.get(error, :param) do
      param when is_binary(param) -> "ChatGPT refused part of this request (`#{param}`)."
      nil -> "ChatGPT refused part of this request."
    end
  end

  defp sentence_for(:invalid_request, _error),
    do: "ChatGPT plan usage does not cover this request type."

  # A 401 that survived the refresh, or no usable token at all. A 403 is a
  # policy verdict rather than a stale credential and keeps no sentence here.
  defp sentence_for(:auth, %{status: status}) when status in [401, nil],
    do: "Your ChatGPT connection needs to be renewed. Sign in again."

  defp sentence_for(_kind, _error), do: nil

  @doc """
  The request body for one call: `request` carries `model`, `instructions`,
  `input` (without the tools item) and the provider `tools`. Public so the
  request contract can be pinned without a socket.
  """
  @spec request_body(map(), keyword()) :: map()
  def request_body(%{model: model, input: input, tools: tools} = request, opts)
      when is_binary(model) and is_list(input) and is_list(tools) and is_list(opts) do
    reasoning = reasoning_field(Keyword.get(opts, :reasoning_effort))

    %{model: model, input: tools_item(tools) ++ input, store: false, stream: true}
    |> maybe_put(:instructions, Map.get(request, :instructions))
    |> maybe_put(:reasoning, reasoning)
    |> maybe_put(:include, include_field(reasoning))
    |> maybe_put(:text, text_field(opts))
  end

  defp tools_item([]), do: []
  defp tools_item(tools), do: [%{type: "additional_tools", role: "developer", tools: tools}]

  defp reasoning_field(effort) do
    case ResponsesShared.maybe_reasoning_field(effort, @provider) do
      nil -> nil
      reasoning -> Map.put(reasoning, :summary, "auto")
    end
  end

  defp include_field(nil), do: nil
  defp include_field(_reasoning), do: ["reasoning.encrypted_content"]

  defp text_field(opts) do
    case Keyword.get(opts, :text_format) do
      nil -> nil
      format -> %{format: format}
    end
  end

  # Between-chunk window: the deepest efforts can stay silent for
  # over a minute while the model thinks. An explicit req_options
  # receive_timeout still wins (`Req.merge/2` applies it after this).
  defp receive_timeout_for(%{reasoning: %{effort: effort}}) when effort in ["xhigh", "max"],
    do: 120_000

  defp receive_timeout_for(_body), do: 60_000

  defp turn_state(request, opts) do
    %{
      model: request.model,
      input: request.input,
      tools: request.tools,
      capabilities: request.capabilities,
      instructions: request.instructions,
      invariant_metrics: request.invariant_metrics,
      base_url: Keyword.get(opts, :base_url, @default_base_url),
      stream_callback: Keyword.get(opts, :stream_callback),
      agent: Keyword.get(opts, :agent),
      session_id: Keyword.get(opts, :session_id),
      parent_session: Keyword.get(opts, :parent_session),
      reasoning_effort: Keyword.get(opts, :reasoning_effort),
      request_metrics:
        Map.merge(
          ResponsesShared.input_metrics(request.input, request.instructions),
          request.invariant_metrics
        )
    }
  end

  # --- auth ---

  defp resolve_auth(opts) do
    access_token = Keyword.get(opts, :access_token)
    auth_profile = Keyword.get(opts, :auth_profile)

    cond do
      is_binary(access_token) and access_token != "" ->
        {:ok, {:static, access_token}}

      is_binary(auth_profile) and auth_profile != "" ->
        {:ok, {:server, Keyword.get(opts, :token_server, TokenSupervisor), auth_profile}}

      true ->
        error =
          ProviderError.auth(
            @provider,
            @adapter,
            "OpenAI Codex requires :access_token or :auth_profile"
          )

        log_error(error)
        {:error, tag_oauth(error)}
    end
  end

  defp current_bearer({:static, token}), do: {:ok, token}

  defp current_bearer({:server, server, profile}),
    do: token_call(fn -> server.get_token(profile) end)

  # A wedged or crashed token server exits the GenServer call; that becomes an
  # error so the route can fail over instead of taking the agent loop down.
  defp token_call(call) do
    case call.() do
      {:ok, token} when is_binary(token) and token != "" -> {:ok, token}
      {:ok, _empty} -> {:error, :empty_token}
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, reason -> {:error, {:token_server_unavailable, exit_kind(reason)}}
  end

  defp exit_kind({kind, _call}) when is_atom(kind), do: kind
  defp exit_kind(reason) when is_atom(reason), do: reason
  defp exit_kind(_reason), do: :exit

  # --- transport ---

  # Telemetry fires once per logical call, so a refreshed 401 leaves no
  # phantom error event behind it.
  defp post(request, auth, req_options, opts) do
    turn_state = turn_state(request, opts)
    body = request_body(request, opts)
    start = System.monotonic_time(:millisecond)

    wire = exchange_with_retry(body, auth, req_options, turn_state)
    result = handle_response(wire, turn_state)

    emit_telemetry(result, wire, turn_state, System.monotonic_time(:millisecond) - start)
    result
  end

  # One bound retry: a 401 on a server-managed token refreshes once and posts
  # again with the refreshed bearer. A failed refresh keeps the first 401.
  defp exchange_with_retry(body, auth, req_options, turn_state) do
    wire = attempt(body, auth, req_options, turn_state)

    case {wire, auth} do
      {{:ok, %Req.Response{status: 401}}, {:server, server, profile}} ->
        retry_after_refresh(wire, server, profile, body, req_options, turn_state)

      _other ->
        wire
    end
  end

  defp retry_after_refresh(wire, server, profile, body, req_options, turn_state) do
    case token_call(fn -> server.refresh(profile) end) do
      {:ok, fresh} ->
        attempt(body, {:static, fresh}, req_options, turn_state)

      {:error, reason} ->
        Logger.warning("OpenAI Codex token refresh after a 401 failed: #{inspect(reason)}")
        wire
    end
  end

  defp attempt(body, auth, req_options, turn_state) do
    case current_bearer(auth) do
      {:ok, bearer} -> exchange(bearer, body, req_options, turn_state)
      {:error, reason} -> {:bearer_unavailable, reason}
    end
  end

  # The stream is consumed through Req's `:into` callback so the parser runs
  # incrementally and `receive_timeout` measures the gap between chunks. The
  # byte counter tells a connection that died before any data from one that
  # died mid-stream.
  defp exchange(bearer, body, req_options, turn_state) do
    bytes_seen = :counters.new(1, [])

    Req.new(
      url: turn_state.base_url <> "/responses",
      method: :post,
      json: body,
      headers: [
        {"authorization", "Bearer " <> bearer},
        {"content-type", "application/json"},
        {"accept", "text/event-stream"}
      ],
      receive_timeout: receive_timeout_for(body),
      into: fn {:data, data} = chunk, acc ->
        :counters.add(bytes_seen, 1, byte_size(data))
        collect(chunk, acc, turn_state.stream_callback)
      end
    )
    |> Req.merge(req_options)
    |> HttpClient.request("OpenAI Codex")
    |> finalize(:counters.get(bytes_seen, 1))
  end

  defp collect({:data, chunk}, {req, response}, stream_callback) when is_binary(chunk) do
    if event_stream?(response) do
      state = response |> sse_state(stream_callback) |> SSEParser.feed(chunk)
      sse_step(state, req, response)
    else
      {:cont, {req, %{response | body: binary_body(response.body) <> chunk}}}
    end
  end

  # The parser's leftover ceiling bounds memory; halting bounds the transfer
  # (a trickling peer never trips an idle window).
  defp sse_step(%SSEParser{overflowed?: true} = state, req, response),
    do: {:halt, {req, Req.Response.put_private(response, :chatgpt_sse_state, state)}}

  defp sse_step(%SSEParser{} = state, req, response),
    do: {:cont, {req, Req.Response.put_private(response, :chatgpt_sse_state, state)}}

  defp sse_state(%{private: %{chatgpt_sse_state: %SSEParser{} = state}}, _callback), do: state
  defp sse_state(_response, callback), do: SSEParser.new(delta_callback: callback)

  # The route can answer valid SSE with no Content-Type, so only a DIFFERENT
  # content type is refused (M57 §6.1).
  defp event_stream?(%Req.Response{status: status} = response) when status in 200..299,
    do: acceptable_content_type?(response)

  defp event_stream?(_response), do: false

  defp acceptable_content_type?(response) do
    case Req.Response.get_header(response, "content-type") do
      [] -> true
      [type | _rest] -> type |> String.downcase() |> String.starts_with?("text/event-stream")
    end
  end

  defp binary_body(body) when is_binary(body), do: body
  defp binary_body(_body), do: ""

  defp finalize({:ok, %Req.Response{private: private} = response}, bytes) do
    response = Req.Response.put_private(response, :bytes_seen, bytes)

    case Map.get(private, :chatgpt_sse_state) do
      %SSEParser{} = state -> {:ok, %{response | body: SSEParser.finalize(state)}}
      nil -> {:ok, response}
    end
  end

  defp finalize({:error, %Req.TransportError{} = error}, bytes),
    do: {:error, error, stage(bytes)}

  defp finalize(other, _bytes), do: other

  defp stage(0), do: :before_response
  defp stage(_bytes), do: :mid_stream

  # --- outcomes ---

  defp handle_response({:bearer_unavailable, reason}, _turn_state) do
    error =
      ProviderError.auth(@provider, @adapter, "No OpenAI Codex access token: #{inspect(reason)}")

    log_error(error)
    {:error, tag_oauth(error)}
  end

  defp handle_response({:ok, %Req.Response{status: 200} = response}, turn_state) do
    if acceptable_content_type?(response) do
      response.body |> parsed_stream() |> stream_outcome(response, turn_state)
    else
      unexpected_content_type(response)
    end
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}, _turn_state) do
    if ResponsesShared.context_length_error?(body) do
      Logger.error("OpenAI Codex refused the request as too long for the context window")
      {:error, :context_length_exceeded}
    else
      api_error(status, body, provider_words: vendor_words(body), stage: :before_response)
    end
  end

  defp handle_response({:error, %Req.TransportError{reason: reason}, stage}, _turn_state) do
    error =
      ProviderError.transport(@provider, @adapter, reason,
        stage: stage,
        message: "OpenAI Codex transport error (#{stage}): #{inspect(reason)}"
      )

    log_error(error)
    {:error, error}
  end

  # A Finch pool-checkout timeout comes back as a bare RuntimeError: nothing was
  # sent, so it is the typed `:connection_unavailable`. Every
  # other RuntimeError is a bug and stays bare.
  defp handle_response({:error, %RuntimeError{} = reason}, _turn_state) do
    if HttpClient.connection_unavailable?(reason) do
      error =
        ProviderError.transport(@provider, @adapter, :connection_unavailable,
          stage: :before_response,
          message: "OpenAI Codex could not obtain an HTTP connection; nothing was sent."
        )

      log_error(error)
      {:error, error}
    else
      Logger.error("OpenAI Codex request failed: #{inspect(reason)}")
      {:error, reason}
    end
  end

  defp handle_response({:error, reason}, _turn_state) do
    Logger.error("OpenAI Codex request failed: #{inspect(reason)}")
    {:error, reason}
  end

  defp parsed_stream(body) when is_map(body), do: body
  defp parsed_stream(body) when is_binary(body), do: SSEParser.parse(body)

  # Only `response.completed` delivers. The `error` event is checked before the
  # status because it, too, reads "failed".
  defp stream_outcome(%{"status" => "completed"} = parsed, _response, turn_state),
    do: completed(parsed, turn_state)

  defp stream_outcome(%{"terminal_event" => "error"} = parsed, _response, _turn_state),
    do: declared_failure(parsed, "a stream error event")

  defp stream_outcome(%{"status" => "incomplete"} = parsed, _response, _turn_state),
    do: incomplete(parsed)

  defp stream_outcome(%{"status" => nil}, response, _turn_state), do: early_end(response)

  defp stream_outcome(parsed, _response, _turn_state),
    do: declared_failure(parsed, "response.failed")

  # A completed response that produced no output item delivered nothing; it
  # is an error, never an empty success (`code: "empty_response"`).
  defp completed(parsed, turn_state) do
    {:ok, turn} = build_turn(parsed, turn_state)

    case Map.get(parsed, "output", []) do
      [_item | _rest] ->
        {:ok, turn}

      [] ->
        api_error(
          200,
          %{
            "error" => %{
              "code" => "empty_response",
              "message" => "ChatGPT reported the response completed and sent no output."
            }
          },
          stage: :mid_stream
        )
    end
  end

  defp build_turn(parsed, turn_state) do
    {:ok, turn} =
      ResponsesShared.build_turn(
        parsed,
        turn_state.model,
        turn_state.input,
        turn_state.tools,
        turn_state.capabilities,
        turn_state.invariant_metrics
      )

    {:ok,
     %{
       turn
       | provider_state: Map.put(turn.provider_state, :instructions, turn_state.instructions)
     }}
  end

  # `response.failed` and a stream `error` event: the server's verdict on an
  # intact 200. The code (a usage limit arrives here after text has streamed)
  # and `param` ride the error; the message rides `provider_words`.
  defp declared_failure(parsed, source) do
    failure =
      parsed
      |> Map.get("failure")
      |> failure_object()
      |> Map.put_new("message", "ChatGPT ended the response with #{source} and gave no reason.")

    api_error(200, %{"error" => failure},
      provider_words: bounded(failure["message"]),
      stage: :mid_stream
    )
  end

  defp failure_object(%{"error" => %{} = error}), do: error
  defp failure_object(%{} = failure), do: failure
  defp failure_object(_absent), do: %{}

  defp incomplete(parsed) do
    reason = incomplete_reason(Map.get(parsed, "failure"))

    api_error(
      200,
      %{
        "error" => %{
          "code" => "response_incomplete",
          "message" => "ChatGPT stopped the response before it finished (#{reason})."
        }
      },
      provider_words: reason,
      stage: :mid_stream
    )
  end

  defp incomplete_reason(%{"reason" => reason}) when is_binary(reason) and reason != "",
    do: reason

  defp incomplete_reason(_details), do: "no reason given"

  defp early_end(response) do
    error =
      ProviderError.transport(@provider, @adapter, :closed,
        stage: stage(Map.get(response.private, :bytes_seen, 0)),
        message: "ChatGPT's response stream ended before response.completed."
      )

    log_error(error)
    {:error, error}
  end

  defp unexpected_content_type(response) do
    [type | _rest] = Req.Response.get_header(response, "content-type")

    api_error(
      200,
      %{
        "error" => %{
          "code" => "unexpected_content_type",
          "message" => "ChatGPT answered with #{type} instead of an event stream."
        }
      },
      provider_words: raw_words(response.body),
      stage: :before_response
    )
  end

  defp api_error(status, body, opts) do
    error = ProviderError.api(@provider, @adapter, status, body, opts)
    log_error(error)
    {:error, tag_oauth(error)}
  end

  # The vendor's own sentence: a structured `error.message`, or a bare
  # `{"detail": ...}`, which is quoted and never read as a code.
  defp vendor_words(body) do
    case decode(body) do
      %{"error" => %{"message" => message}} when is_binary(message) -> bounded(message)
      %{"detail" => detail} when is_binary(detail) -> bounded(detail)
      %{"detail" => detail} when is_map(detail) -> detail |> Jason.encode!() |> bounded()
      _other -> nil
    end
  end

  defp decode(body) when is_map(body), do: body

  defp decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _not_json -> %{}
    end
  end

  defp decode(_body), do: %{}

  # Req decodes a JSON body even when it is streamed into a callback, so the
  # words arrive as text or as the decoded map.
  defp raw_words(body) when is_binary(body), do: bounded(body)
  defp raw_words(body) when is_map(body), do: body |> Jason.encode!() |> bounded()
  defp raw_words(_body), do: nil

  defp bounded(nil), do: nil
  defp bounded(""), do: nil
  defp bounded(text) when is_binary(text), do: String.slice(text, 0, @provider_words_limit)

  # The route has one auth mode; carrying it on the error lets replies and
  # failover tell a subscription sign-in from an API key.
  defp tag_oauth({:provider_error, error}),
    do: {:provider_error, Map.put(error, :auth_mode, :oauth)}

  defp log_error({_tag, error}) do
    Logger.error(
      "OpenAI Codex call failed: kind=#{error.kind} code=#{inspect(Map.get(error, :code))} " <>
        "stage=#{error.stage} — #{error.message}"
    )
  end

  # --- telemetry ---

  defp emit_telemetry(result, wire, turn_state, duration_ms) do
    {status, tokens, output, tool_calls, error_metadata} =
      case result do
        {:ok, turn} ->
          {:ok, telemetry_tokens(turn.usage), turn.content, turn.tool_calls, %{}}

        {:error, reason} ->
          {:error, error_tokens(wire), nil, nil, ProviderError.telemetry_metadata(reason)}
      end

    metadata =
      %{
        provider: @provider,
        adapter: @adapter,
        auth_mode: :oauth,
        model: turn_state.model,
        status: status,
        tokens: tokens,
        reasoning_effort: turn_state.reasoning_effort
      }
      |> Map.merge(turn_state.request_metrics)
      |> Map.merge(error_metadata)
      |> maybe_put(:terminal_event, terminal_event(wire))
      |> maybe_put(:agent, turn_state.agent)

    ProviderTelemetry.emit_call(metadata, duration_ms,
      session_id: turn_state.session_id,
      parent_session: turn_state.parent_session,
      output: output,
      tool_calls: tool_calls
    )
  end

  defp terminal_event({:ok, %Req.Response{status: 200, body: %{} = body}}),
    do: Map.get(body, "terminal_event")

  defp terminal_event(_wire), do: nil

  # Usage is a measured fact of the response, kept on a failed stream too; a
  # transport failure or a refusal before the stream has none to report.
  defp error_tokens({:ok, %Req.Response{status: 200, body: %{"usage" => usage}}})
       when is_map(usage) and is_map_key(usage, "input_tokens") and
              is_map_key(usage, "output_tokens") do
    {:ok, turn} = ResponsesShared.build_turn(%{"usage" => usage}, "unknown", [], [], [])
    telemetry_tokens(turn.usage)
  end

  defp error_tokens(_wire), do: %{}

  defp telemetry_tokens(usage) do
    %{prompt: usage.prompt_tokens, completion: usage.completion_tokens}
    |> maybe_put(:cached, Map.get(usage, :cached_input_tokens))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
