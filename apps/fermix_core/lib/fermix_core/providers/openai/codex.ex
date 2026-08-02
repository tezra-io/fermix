defmodule FermixCore.Providers.OpenAI.Codex do
  @moduledoc """
  OpenAI Codex adapter (ChatGPT Plus / OAuth path).

  Posts to `chatgpt.com/backend-api/codex/responses` with the SSE-streamed
  Codex Responses shape. Codex is a separate provider key (`:openai_codex`)
  because the URL, headers, and the fact that the surface is streaming
  diverge from the standard `api.openai.com/v1/responses` flow handled by
  `OpenAI.Responses`. The wire shape (item-list `input`, item-list
  `output`, `function_call`/`function_call_output` pairs keyed by
  `call_id`) is identical and lives in `OpenAI.ResponsesShared`.

  Codex tool-call flow:

    1. `chat/3` posts initial `input` + `tools` (`stream: true`) and
       consumes the SSE stream into a body-shaped map via `SSEParser`.
       Returns `provider_state` carrying the prior `input`, every output
       item, the tools list, and the original capabilities.
    2. `AgentLoop` executes returned tool calls.
    3. `continue/3` builds `input = prior_input ++ replayable output_items ++
       function_call_outputs` (with API-emitted `call_id`s) and posts again.
       Codex requires `store: false`, so continuation replays inline
       function calls/reasoning and strips response item ids that would
       require provider-side storage.

  Auth: a ChatGPT Plus OAuth bearer (Codex auth flow). The bearer's JWT
  payload may carry an account id under one of several claims; we extract
  it and forward as `chatgpt-account-id` when present.
  """

  @behaviour FermixCore.Providers.Adapter

  alias FermixCore.Auth.CodexToken
  alias FermixCore.Auth.TokenManager
  alias FermixCore.Net.HttpClient
  alias FermixCore.Prompt.ModelOverlays
  alias FermixCore.Providers.Error, as: ProviderError
  alias FermixCore.Providers.OpenAI.Codex.SSEParser
  alias FermixCore.Providers.OpenAI.ResponsesShared
  alias FermixCore.Providers.Telemetry, as: ProviderTelemetry

  require Logger

  @default_url "https://chatgpt.com/backend-api/codex/responses"
  @default_instructions "You are a helpful AI assistant."

  @impl true
  def chat(messages, capabilities, opts) when is_list(messages) and is_list(capabilities) do
    {req_options, opts} = Keyword.pop(opts, :req_options, [])

    with {:ok, auth} <- resolve_auth(opts) do
      do_chat(messages, capabilities, auth, req_options, opts)
    end
  end

  defp do_chat(messages, capabilities, auth, req_options, opts) do
    model = Keyword.fetch!(opts, :model)
    url = Keyword.get(opts, :base_url, @default_url)

    {instructions, input} = ResponsesShared.build_input(messages)

    # Codex/GPT-5 family behavior contract (M10 P3): appended at the END of
    # instructions, so the composed prefix stays byte-stable for caching.
    resolved_instructions = ModelOverlays.apply_codex(instructions || @default_instructions)
    tools = ResponsesShared.to_provider_tools(capabilities)
    invariant_metrics = ResponsesShared.invariant_metrics(tools, capabilities)
    reasoning_effort = Keyword.get(opts, :reasoning_effort)

    reasoning =
      codex_reasoning(ResponsesShared.maybe_reasoning_field(reasoning_effort, :openai_codex))

    include = codex_include(reasoning)
    service_tier = codex_service_tier(Keyword.get(opts, :fast))
    text = text_field(opts)

    body =
      %{
        model: model,
        input: input,
        instructions: resolved_instructions,
        store: false,
        stream: true
      }
      |> maybe_put(:tools, tools)
      |> maybe_put(:reasoning, reasoning)
      |> maybe_put(:include, include)
      |> maybe_put(:service_tier, service_tier)
      |> maybe_put(:text, text)

    turn_state = %{
      model: model,
      input: input,
      tools: tools,
      capabilities: capabilities,
      instructions: resolved_instructions,
      agent: Keyword.get(opts, :agent),
      session_id: Keyword.get(opts, :session_id),
      parent_session: Keyword.get(opts, :parent_session),
      reasoning_effort: reasoning_effort,
      fast: Keyword.get(opts, :fast, false) == true,
      invariant_metrics: invariant_metrics,
      request_metrics:
        Map.merge(ResponsesShared.input_metrics(input, resolved_instructions), invariant_metrics)
    }

    post(url, body, auth, req_options, turn_state, Keyword.get(opts, :stream_callback))
  end

  @impl true
  def continue(provider_state, tool_results, opts) do
    {req_options, opts} = Keyword.pop(opts, :req_options, [])

    with {:ok, auth} <- resolve_auth(opts) do
      do_continue(provider_state, tool_results, auth, req_options, opts)
    end
  end

  defp do_continue(provider_state, tool_results, auth, req_options, opts) do
    model = Keyword.fetch!(opts, :model)
    url = Keyword.get(opts, :base_url, @default_url)

    %{
      input: prior_input,
      output_items: output_items,
      tools: tools,
      capabilities: caps,
      instructions: instructions
    } = provider_state

    # invariant_metrics is precomputed once per turn in the chat/continue path
    # and carried in provider_state; recompute here only if an isolated caller
    # built the state without it (identical value — memoization, not a fallback).
    invariant_metrics =
      Map.get(provider_state, :invariant_metrics) ||
        ResponsesShared.invariant_metrics(tools, caps)

    reasoning_effort = Keyword.get(opts, :reasoning_effort)

    reasoning =
      codex_reasoning(ResponsesShared.maybe_reasoning_field(reasoning_effort, :openai_codex))

    include = codex_include(reasoning)
    service_tier = codex_service_tier(Keyword.get(opts, :fast))
    text = text_field(opts)
    outputs = ResponsesShared.build_function_call_outputs(tool_results)

    next_input =
      (prior_input ++ replayable_output_items(output_items) ++ outputs)
      |> ResponsesShared.retain_screenshots(Keyword.get(opts, :max_retained_screenshots))

    body =
      %{
        model: model,
        input: next_input,
        instructions: instructions,
        store: false,
        stream: true
      }
      |> maybe_put(:tools, tools)
      |> maybe_put(:reasoning, reasoning)
      |> maybe_put(:include, include)
      |> maybe_put(:service_tier, service_tier)
      |> maybe_put(:text, text)

    turn_state = %{
      model: model,
      input: next_input,
      tools: tools,
      capabilities: caps,
      instructions: instructions,
      agent: Keyword.get(opts, :agent),
      session_id: Keyword.get(opts, :session_id),
      parent_session: Keyword.get(opts, :parent_session),
      reasoning_effort: reasoning_effort,
      fast: Keyword.get(opts, :fast, false) == true,
      invariant_metrics: invariant_metrics,
      request_metrics:
        Map.merge(ResponsesShared.input_metrics(next_input, instructions), invariant_metrics)
    }

    post(url, body, auth, req_options, turn_state, Keyword.get(opts, :stream_callback))
  end

  @impl true
  def to_provider_tools(capabilities), do: ResponsesShared.to_provider_tools(capabilities)

  @impl true
  def parse_tool_calls(response), do: ResponsesShared.parse_tool_calls(response)

  @impl true
  def parse_response(body) when is_map(body) do
    {:ok, turn} = ResponsesShared.build_turn(body, body["model"] || "unknown", [], [], [])
    turn
  end

  @impl true
  def supports_streaming?, do: true

  defp build_headers(token) do
    [
      {"authorization", "Bearer #{token}"},
      {"openai-beta", "responses=experimental"},
      {"originator", "pi"},
      {"content-type", "application/json"}
    ]
    |> maybe_put_header("chatgpt-account-id", decode_jwt_account_id(token))
  end

  defp post(url, body, auth, req_options, turn_state, stream_callback) do
    start = System.monotonic_time(:millisecond)

    wire_result =
      request_once(url, body, auth.token, req_options, stream_callback)
      |> maybe_refresh_and_retry(url, body, auth, req_options, stream_callback)

    result = handle_response(wire_result, turn_state)

    duration_ms = System.monotonic_time(:millisecond) - start
    emit_telemetry(result, wire_result, turn_state, duration_ms)
    result
  end

  # SSE responses are consumed via Req's `:into` callback so the parser
  # runs incrementally and `receive_timeout` measures gaps between
  # chunks, not the whole turn. Without this, `Req.request()` buffers the
  # entire SSE body and the default 15 s receive_timeout fires while
  # Codex is still reasoning, surfacing as a `:closed` transport error.
  # The HttpClient wrapper retries once on stale-pool transport errors
  # (`:closed`, `:econnrefused`) so the first request after macOS sleep
  # recovers transparently. The connect timeout lives on the shared
  # `FermixCore.Finch` chatgpt.com pool (Req forbids combining `:finch`
  # with `:connect_options`).
  #
  # `chunks_seen` counts body chunks across both HttpClient attempts so
  # transport errors can be classified: zero chunks means the connection
  # died before Codex sent anything (stale pool / network blip), not
  # mid-response.
  defp request_once(url, body, token, req_options, stream_callback) do
    chunks_seen = :counters.new(1, [])

    Req.new(
      url: url,
      method: :post,
      json: body,
      headers: build_headers(token),
      receive_timeout: receive_timeout_for(body),
      into: fn chunk, acc ->
        :counters.add(chunks_seen, 1, 1)
        collect_sse(chunk, acc, stream_callback)
      end
    )
    |> Req.merge(req_options)
    |> HttpClient.request("Codex")
    |> finalize_streamed_body()
    |> tag_transport_errors(chunks_seen)
  end

  # Between-chunk SSE window. xhigh reasoning can legitimately stay silent
  # for >60s while the model thinks (concurrent Codex streams compound it),
  # so it gets a wider window. An explicit req_options receive_timeout still
  # wins — `Req.merge/2` applies it after this default.
  @doc false
  @spec receive_timeout_for(map()) :: pos_integer()
  def receive_timeout_for(%{reasoning: %{effort: "xhigh"}}), do: 120_000
  def receive_timeout_for(body) when is_map(body), do: 60_000

  defp tag_transport_errors({:error, %Req.TransportError{} = error}, chunks_seen) do
    stage = if :counters.get(chunks_seen, 1) > 0, do: :mid_stream, else: :before_response
    {:error, error, stage}
  end

  defp tag_transport_errors(result, _chunks_seen), do: result

  defp collect_sse({:data, chunk}, {req, response}, stream_callback) when is_binary(chunk) do
    if response.status in 200..299 do
      state = current_sse_state(response, stream_callback) |> SSEParser.feed(chunk)
      sse_step(state, req, response)
    else
      body = ensure_binary_body(response.body)
      {:cont, {req, %{response | body: body <> chunk}}}
    end
  end

  # The parser's leftover ceiling bounds MEMORY; this halt bounds the TRANSFER,
  # and neither is a bound without the other. `receive_timeout` is an idle
  # window a peer that trickles bytes never trips, and no wall-clock deadline
  # exists anywhere on this request, so returning `{:cont, ...}` past the
  # ceiling leaves Req reading a stream the parser has already abandoned — the
  # turn never returns, wedging the conversation's single-flight slot and
  # holding a pooled connection open. `{:halt, acc}` aborts the real transfer
  # (`Finch.stream_while/5`); the accumulated state, latched `status: "failed"`
  # and all, still rides `:codex_sse_state` into `finalize_streamed_body/1`.
  defp sse_step(%SSEParser{overflowed?: true} = state, req, response),
    do: {:halt, {req, Req.Response.put_private(response, :codex_sse_state, state)}}

  defp sse_step(%SSEParser{} = state, req, response),
    do: {:cont, {req, Req.Response.put_private(response, :codex_sse_state, state)}}

  defp current_sse_state(%{private: %{codex_sse_state: %SSEParser{} = state}}, _callback),
    do: state

  defp current_sse_state(_response, callback),
    do: SSEParser.new(delta_callback: callback)

  defp ensure_binary_body(body) when is_binary(body), do: body
  defp ensure_binary_body(_body), do: ""

  defp finalize_streamed_body({:ok, %Req.Response{private: private} = response}) do
    case Map.get(private, :codex_sse_state) do
      %SSEParser{} = state -> {:ok, %{response | body: SSEParser.finalize(state)}}
      nil -> {:ok, response}
    end
  end

  defp finalize_streamed_body(other), do: other

  defp maybe_refresh_and_retry(
         {:ok, %Req.Response{status: 401, body: response_body}} = response,
         url,
         request_body,
         %{refreshable?: true, token_server: token_server},
         req_options,
         stream_callback
       ) do
    if token_invalidated?(response_body) do
      Logger.warning("Codex bearer was invalidated; refreshing token and retrying once")

      case refresh_token(token_server) do
        {:ok, refreshed_token} ->
          request_once(url, request_body, refreshed_token, req_options, stream_callback)

        {:error, :auth_invalidated} ->
          {:auth_invalidated, response_body}

        {:error, reason} ->
          Logger.error("Codex token refresh after invalidation failed: #{inspect(reason)}")
          {:refresh_failed, reason}
      end
    else
      response
    end
  end

  defp maybe_refresh_and_retry(response, _url, _body, _auth, _req_options, _stream_callback),
    do: response

  # Failover-relevant failures return structured `Providers.Error` values
  # (kind + stage) like every other adapter — `Failover.eligible?/1` reads
  # the contract, never message strings. A residual `kind: :auth` here means
  # the internal refresh+retry above already ran and failed, so it is tagged
  # `auth_mode: :oauth` (terminal for this route, eligible for fallback).
  defp handle_response({:auth_invalidated, body}, _turn_state) do
    Logger.error("Codex auth invalidated and refresh exhausted: #{inspect(body)}")
    {:error, tag_oauth(ProviderError.api(:openai_codex, :codex, 401, body))}
  end

  defp handle_response({:refresh_failed, reason}, _turn_state) do
    Logger.error("Codex token refresh failed: #{inspect(reason)}")

    {:error,
     tag_oauth(
       ProviderError.auth(:openai_codex, :codex, "Codex token refresh failed: #{inspect(reason)}")
     )}
  end

  # A 200 is not by itself a delivered response, and neither is a non-empty
  # output list. `build_turn/5` reads an absent usage map as zero tokens and an
  # output list carrying no message text as empty content, so a stream that
  # ended early became a SUCCESSFUL EMPTY TURN — the loop had nothing to say,
  # the channel sent its canned "I didn't get a response" line, and nothing was
  # logged.
  #
  # The gate is therefore what the turn DELIVERED — text or a tool call — not
  # how the stream ended and not how many output items arrived. Keying it on
  # `output != []` still let the empty turn through: this adapter asks for
  # reasoning on every call (`summary: "auto"` + `include:
  # ["reasoning.encrypted_content"]`), so a `reasoning` item is the first frame
  # on the wire and renders neither text nor a tool call. `completed` is no
  # exemption either — a terminal event that carried nothing delivered nothing.
  #
  # Content that arrived is never discarded. `items` fills from
  # `response.output_item.added` and `.done`, independently of the terminal
  # event, so a cut stream can still carry a finished message or a
  # `function_call`; that turn is returned with a warning (a half-built
  # `function_call`'s arguments will not parse, which the model is already told
  # about and recovers from). Erroring on it would discard delivered content and,
  # on a CONTINUATION, convert a recoverable turn into a dead one:
  # `AgentLoop.continue_with_retry/3` runs with `eligible?: false`, and
  # `Jobs.Runner` refuses the whole-loop replay once tools have started.
  #
  # That also makes the retry safe by construction rather than by veto: every
  # streamed text delta the user can already see rides a message item, so a turn
  # whose text reached the channel is never the empty case and can never be
  # re-issued.
  defp handle_response({:ok, %Req.Response{status: 200, body: body}}, turn_state) do
    parsed = parse_body_to_map(body)
    {:ok, turn} = turn_from(parsed, turn_state)

    delivered_turn(turn, Map.get(parsed, "status"), parsed)
  end

  defp handle_response({:ok, %Req.Response{status: 404, body: body}}, _turn_state) do
    if unpersisted_item_error?(body) do
      {:error,
       "Codex requires store=false, and this continuation referenced a persisted response item id. " <>
         "Restart the request/server so Fermix can replay inline encrypted reasoning instead of stale item ids."}
    else
      log_api_error(404, body)
    end
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}, _turn_state) do
    if ResponsesShared.context_length_error?(body) do
      {:error, :context_length_exceeded}
    else
      log_api_error(status, body)
    end
  end

  defp handle_response({:error, %Req.TransportError{reason: reason}, stage}, _turn_state) do
    Logger.error("Codex transport error: #{inspect(reason)} (#{stage})")

    {:error,
     ProviderError.transport(:openai_codex, :codex, reason,
       stage: stage,
       message: transport_error_message(reason, stage)
     )}
  end

  # A Finch pool-checkout queue timeout comes back from HttpClient as a bare
  # RuntimeError (not a transport tuple). The wake-from-sleep variant — no
  # connection could be obtained at all — is minted as a typed
  # `:connection_unavailable` transport error so the scheduled-job runner can
  # retry it with backoff. Every other RuntimeError is a genuine bug and stays
  # bare so it fails loud.
  defp handle_response({:error, %RuntimeError{} = reason}, _turn_state) do
    if HttpClient.connection_unavailable?(reason) do
      Logger.warning("Codex connection unavailable (pool checkout): #{Exception.message(reason)}")

      {:error,
       ProviderError.transport(:openai_codex, :codex, :connection_unavailable,
         stage: :before_response,
         message: transport_error_message(:connection_unavailable, :before_response)
       )}
    else
      Logger.error("Codex request failed: #{inspect(reason)}")
      {:error, reason}
    end
  end

  defp handle_response({:error, reason}, _turn_state) do
    Logger.error("Codex request failed: #{inspect(reason)}")
    {:error, reason}
  end

  defp tag_oauth({:provider_error, %{kind: :auth} = error}),
    do: {:provider_error, Map.put(error, :auth_mode, :oauth)}

  defp tag_oauth(error), do: error

  @doc false
  @spec transport_error_message(atom() | tuple(), :before_response | :mid_stream) :: String.t()
  def transport_error_message(:closed, :before_response) do
    "Codex connection closed before any response data arrived — a stale pooled " <>
      "connection or network blip, not a model or account problem. Fermix " <>
      "retried once on a fresh connection; retry the request, and check " <>
      "network/ChatGPT status if it persists."
  end

  def transport_error_message(:closed, :mid_stream) do
    "Codex stream closed by peer mid-response. Retry; if it persists, check " <>
      "ChatGPT account status or network stability."
  end

  def transport_error_message(:timeout, :before_response) do
    "Codex request timed out before any response data arrived — either the " <>
      "pool's TCP+TLS connect timeout fired, or the response never started " <>
      "within the receive_timeout window. Zero response chunks were seen " <>
      "(not stream starvation), so re-issuing the call cannot duplicate " <>
      "output."
  end

  def transport_error_message(:timeout, :mid_stream) do
    "Codex stream had no data for the configured receive_timeout (between-chunk " <>
      "window; 120s at xhigh reasoning, 60s otherwise). Likely provider-side " <>
      "stream starvation — e.g. several concurrent Codex streams — or a network " <>
      "stall. Pass req_options: [receive_timeout: ms] to widen the window for a " <>
      "specific call."
  end

  def transport_error_message(:econnrefused, _stage) do
    "Codex endpoint refused the connection (chatgpt.com unreachable from this host)."
  end

  def transport_error_message(:connection_unavailable, _stage) do
    "Codex could not obtain an HTTP connection from the pool before the checkout " <>
      "timeout — the host network was not ready, typically just after the machine " <>
      "woke from sleep. Fermix treats this as a transient infrastructure failure; " <>
      "scheduled runs retry it with backoff."
  end

  def transport_error_message(reason, _stage), do: "Codex transport error: #{inspect(reason)}"

  defp parse_body_to_map(body) when is_binary(body), do: SSEParser.parse(body)
  defp parse_body_to_map(body) when is_map(body), do: body
  defp parse_body_to_map(_), do: %{"output" => [], "usage" => %{}, "model" => nil}

  defp decode_jwt_account_id(token) when is_binary(token) do
    case CodexToken.account_id_from_token(token) do
      {:ok, account_id} ->
        account_id

      {:error, reason} ->
        Logger.debug("Codex account id decode skipped: #{inspect(reason)}")
        nil
    end
  end

  defp maybe_put_header(headers, _key, nil), do: headers
  defp maybe_put_header(headers, key, value), do: [{key, value} | headers]

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp text_field(opts) do
    case Keyword.get(opts, :text_format) do
      nil -> nil
      format -> %{format: format}
    end
  end

  # Codex fast mode is a product-facing boolean in Fermix. The Codex/Responses
  # request expresses it as priority service tier.
  defp codex_service_tier(true), do: "priority"
  defp codex_service_tier(value) when value in [false, nil], do: nil

  defp codex_service_tier(value) do
    raise ArgumentError, "invalid Codex fast mode: #{inspect(value)}; expected true or false"
  end

  defp codex_reasoning(nil), do: nil

  defp codex_reasoning(%{effort: _effort} = reasoning) do
    Map.put(reasoning, :summary, "auto")
  end

  defp codex_include(nil), do: nil
  defp codex_include(_reasoning), do: ["reasoning.encrypted_content"]

  defp replayable_output_items(output_items) do
    output_items
    |> Enum.flat_map(&replayable_output_item/1)
  end

  defp replayable_output_item(%{"type" => "function_call"} = item) do
    with call_id when is_binary(call_id) and call_id != "" <- item["call_id"],
         name when is_binary(name) and name != "" <- item["name"] do
      [
        %{
          "type" => "function_call",
          "call_id" => call_id,
          "name" => name,
          "arguments" => normalize_arguments(item["arguments"])
        }
      ]
    else
      _ -> []
    end
  end

  defp replayable_output_item(%{"type" => "reasoning"} = item) do
    case item["encrypted_content"] do
      encrypted when is_binary(encrypted) and encrypted != "" ->
        [
          %{
            "type" => "reasoning",
            "encrypted_content" => encrypted,
            "summary" => normalize_reasoning_summary(item["summary"])
          }
        ]

      _ ->
        []
    end
  end

  defp replayable_output_item(%{"type" => "message"} = item) do
    case message_text(item) do
      "" -> []
      text -> [%{"role" => "assistant", "content" => text}]
    end
  end

  defp replayable_output_item(_item), do: []

  defp normalize_arguments(arguments) when is_binary(arguments) and arguments != "", do: arguments
  defp normalize_arguments(arguments) when is_map(arguments), do: Jason.encode!(arguments)
  defp normalize_arguments(_arguments), do: "{}"

  defp normalize_reasoning_summary(summary) when is_list(summary), do: summary
  defp normalize_reasoning_summary(_summary), do: []

  defp message_text(%{"content" => parts}) when is_list(parts) do
    parts
    |> Enum.flat_map(fn
      %{"type" => "output_text", "text" => text} when is_binary(text) -> [text]
      %{"text" => text} when is_binary(text) -> [text]
      _ -> []
    end)
    |> Enum.join("")
  end

  defp message_text(_item), do: ""

  defp resolve_auth(opts) do
    case Keyword.get(opts, :access_token) do
      token when is_binary(token) and token != "" ->
        {:ok, %{token: token, refreshable?: false, token_server: nil}}

      _ ->
        token_server = Keyword.get(opts, :token_server, TokenManager)

        case fetch_token(token_server) do
          {:ok, token} ->
            {:ok, %{token: token, refreshable?: true, token_server: token_server}}

          {:error, reason} ->
            # Tagged oauth: an unusable token (or a dead token server) is
            # terminal for this route and eligible for fallback — the chain
            # must be able to try a configured fallback provider.
            {:error,
             tag_oauth(
               ProviderError.auth(
                 :openai_codex,
                 :codex,
                 "Codex auth required: #{inspect(reason)}"
               )
             )}
        end
    end
  end

  # The token server can be down entirely (crashed at runtime, or never
  # started in this boot). GenServer.call would exit :noproc/:timeout and
  # crash the whole agent loop — bypassing failover. Degrade it to an error
  # tuple so the route fails over instead.
  defp fetch_token(token_server) do
    TokenManager.get_token(token_server)
  catch
    :exit, reason -> {:error, {:token_server_unavailable, exit_kind(reason)}}
  end

  defp refresh_token(token_server) do
    TokenManager.refresh(token_server)
  catch
    :exit, reason -> {:error, {:token_server_unavailable, exit_kind(reason)}}
  end

  defp exit_kind({kind, _call}) when is_atom(kind), do: kind
  defp exit_kind(reason) when is_atom(reason), do: reason
  defp exit_kind(_reason), do: :exit

  defp token_invalidated?(body) do
    body
    |> decode_error_body()
    |> get_in(["error", "code"])
    |> Kernel.==("token_invalidated")
  end

  defp decode_error_body(body) when is_map(body), do: body

  defp decode_error_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp decode_error_body(_body), do: %{}

  defp turn_from(parsed, turn_state) do
    case ResponsesShared.build_turn(
           parsed,
           turn_state.model,
           turn_state.input,
           turn_state.tools,
           turn_state.capabilities,
           turn_state.invariant_metrics
         ) do
      {:ok, turn} ->
        provider_state =
          turn.provider_state
          |> Map.put(:instructions, turn_state.instructions)

        {:ok, %{turn | provider_state: provider_state}}
    end
  end

  defp delivered_turn(turn, status, parsed) do
    cond do
      status == "completed" -> completed_turn(turn, status, parsed)
      delivered?(turn) -> warn_truncated(turn, status, parsed)
      true -> undelivered(status, parsed)
    end
  end

  # A response the API itself reported `completed` that PRODUCED OUTPUT ITEMS is
  # a real turn even when it renders neither text nor a tool call. The rest of
  # the loop already models that ending — a tool was the deliverable and the
  # model has nothing left to say (`AgentLoop`'s empty completion, the queue's
  # `handle_empty_completion/1` and its side-effect ledger) — and under Buzz,
  # where the model publishes its reply by running the `buzz` CLI through the
  # shell tool, it is the NORMAL ending. Calling it a provider failure made the
  # ACP peer answer `-32603`, which made the harness requeue the batch and the
  # model post its reply five times.
  #
  # ITEM COUNT is the discriminator, not usage: `output_tokens` counts reasoning
  # tokens, so it is non-zero for turns that produced nothing at all. Zero items
  # under a terminal event is the cron regression 811d0ad3/c258142c closed — the
  # response carried nothing to render and must stay an error.
  defp completed_turn(turn, status, parsed) do
    case Map.get(parsed, "output", []) do
      [] -> undelivered(status, parsed)
      [_item | _rest] -> {:ok, turn}
    end
  end

  defp delivered?(%{content: content, tool_calls: tool_calls}) do
    content != "" or tool_calls != []
  end

  # The stream carried something usable but never said it finished, so what
  # arrived may be truncated. Returning it preserves the behavior that actually
  # recovers; the warning is what used to be missing entirely.
  defp warn_truncated(turn, status, parsed) do
    Logger.warning(
      "Codex stream ended #{status || "with no terminal event"} after delivering " <>
        "#{length(Map.get(parsed, "output", []))} output item(s): #{failure_text(parsed)}. " <>
        "Keeping what arrived; it may be truncated."
    )

    {:ok, turn}
  end

  # The undelivered path was SILENT through the 2026-08 Buzz incident: the
  # daemon log carried no Codex line for the whole window, so the only evidence
  # a turn had failed was the caller's error tuple. These three facts are what
  # separate an empty wire (no usage, no items) from a model that reasoned and
  # then said nothing (reasoning tokens, a reasoning item) — the distinction the
  # gate above turns on.
  defp undelivered(status, parsed) do
    Logger.error(
      "Codex delivered nothing: status=#{status || "no terminal event"} " <>
        "usage=#{inspect(Map.get(parsed, "usage", %{}))} " <>
        "items=#{inspect(output_item_types(parsed))} — #{failure_text(parsed)}"
    )

    {:error, undelivered_error(status, parsed)}
  end

  defp output_item_types(parsed) do
    parsed
    |> Map.get("output", [])
    |> Enum.map(&Map.get(&1, "type"))
  end

  # Three undelivered facts, three errors — not a fallback. A stream that
  # DECLARED its failure (`response.failed`/`response.incomplete`/stream `error`
  # on an intact HTTP 200) is an API-level verdict, not a transport cut: it is
  # minted through `ProviderError.api/5` so `api_kind` classifies the server's
  # own text ("overload"/"server_error" → :provider_unavailable — retryable and
  # failover-eligible on fresh calls), and the server's sentence rides
  # `:provider_words` for `Agents.TurnRunner.provider_error_reply/1` to quote
  # at the operator (2026-07-31: "Our servers are currently overloaded"
  # rendered as "closed the connection" without it). A stream CUT with no
  # declared reason stays transport `:closed` — `:transport_closed` is the one
  # transport kind with its own user-facing sentence; a bespoke reason atom
  # falls to the catch-all, which renders `inspect(reason)` at the operator.
  defp undelivered_error(_status, %{"failure" => failure} = parsed) when is_map(failure) do
    words = failure_text(parsed)

    ProviderError.api(
      :openai_codex,
      :codex,
      200,
      %{"error" => %{"code" => failure["code"] || failure["reason"], "message" => words}},
      provider_words: String.slice(words, 0, 300)
    )
  end

  defp undelivered_error(nil, _parsed) do
    ProviderError.transport(:openai_codex, :codex, :closed,
      message: "Codex response stream ended before any terminal event and delivered no output."
    )
  end

  # And a response the server declared TERMINAL — it said `completed` (or any
  # other terminal status) and delivered nothing — is a third fact, distinct
  # from both. It is NOT `:transport_closed`: nothing was cut. Minting that lie
  # is what put this on `AgentLoop`'s continuation-retry allowlist, so a turn
  # that had already published its Buzz reply through a tool was re-issued twice
  # more, and told the operator "the provider closed the connection… Retry".
  #
  # It is minted through `ProviderError.api/5` for the same reason the declared
  # failure above is: an intact 200 that reported its own terminal state is an
  # API-level verdict. `api_kind` reads it as `:provider` — retryable by no
  # classifier (`Transient.@retryable_api_kinds`, `AgentLoop`'s continuation
  # allowlist) and eligible for no failover (`Failover.@fallback_api_kinds`), so
  # the turn fails once and stops. That is also why it is NOT a bespoke
  # transport reason atom: those land on `TurnRunner.provider_error_reply/1`'s
  # transport catch-all, which shows the operator `inspect(reason)`, while every
  # api kind reaches the `%{status: status}` floor clause and is rendered with
  # THIS message. `code: "empty_response"` is the distinct, greppable marker —
  # it rides telemetry as `error_code`, and is the field a dedicated
  # `provider_error_reply/1` sentence should key on.
  defp undelivered_error(status, parsed) do
    count = parsed |> Map.get("output", []) |> length()

    ProviderError.api(:openai_codex, :codex, 200, %{
      "error" => %{
        "code" => "empty_response",
        "message" =>
          "The response was reported #{status} carrying #{count} output item(s), " <>
            "and delivered no text and no tool call."
      }
    })
  end

  defp failure_text(parsed) do
    case Map.get(parsed, "failure") do
      %{"message" => message} when is_binary(message) and message != "" -> message
      %{"reason" => reason} when is_binary(reason) and reason != "" -> reason
      %{"code" => code} when is_binary(code) and code != "" -> code
      nil -> "the stream gave no reason"
      other -> inspect(other)
    end
  end

  defp unpersisted_item_error?(body) do
    body
    |> decode_error_body()
    |> get_in(["error", "message"])
    |> then(fn
      message when is_binary(message) ->
        String.contains?(message, "Items are not persisted") or
          String.contains?(message, "store` is set to false")

      _ ->
        false
    end)
  end

  defp log_api_error(status, body) do
    Logger.error("Codex Responses API error: #{status} - #{inspect(body)}")
    {:error, tag_oauth(ProviderError.api(:openai_codex, :codex, status, body))}
  end

  defp emit_telemetry(result, wire_result, turn_state, duration_ms) do
    {status, tokens, output, tool_calls, error_metadata} =
      case result do
        {:ok, resp} ->
          {:ok, %{prompt: resp.usage.prompt_tokens, completion: resp.usage.completion_tokens},
           Map.get(resp, :content), Map.get(resp, :tool_calls), %{}}

        {:error, reason} ->
          {:error, error_tokens(wire_result), nil, nil, error_metadata(reason, wire_result)}
      end

    metadata =
      %{
        provider: :openai_codex,
        adapter: :codex,
        model: turn_state.model,
        status: status,
        tokens: tokens,
        reasoning_effort: Map.get(turn_state, :reasoning_effort),
        fast: Map.get(turn_state, :fast, false)
      }
      |> Map.merge(Map.get(turn_state, :request_metrics, %{}))
      |> Map.merge(error_metadata)
      |> maybe_put(:agent, Map.get(turn_state, :agent))

    ProviderTelemetry.emit_call(metadata, duration_ms,
      session_id: Map.get(turn_state, :session_id),
      parent_session: Map.get(turn_state, :parent_session),
      output: output,
      tool_calls: tool_calls
    )
  end

  # Usage is a MEASURED fact of the response, not a property of success. Hard-
  # coding an empty map on every error is why the Buzz incident's trace read as
  # "nothing came back on the wire" when the model had in fact spent 12.5k
  # prompt tokens and reasoned. Only a streamed 200 has a parsed body to read;
  # a transport failure or a non-200 has no usage, and inventing zeros there
  # would be a second lie.
  defp error_tokens({:ok, %Req.Response{status: 200, body: body}}) do
    body
    |> parse_body_to_map()
    |> Map.get("usage", %{})
    |> usage_tokens()
  end

  defp error_tokens(_wire_result), do: %{}

  defp usage_tokens(%{"input_tokens" => prompt, "output_tokens" => completion}),
    do: %{prompt: prompt, completion: completion}

  defp usage_tokens(_usage), do: %{}

  defp error_metadata(:context_length_exceeded, _wire_result) do
    %{error_kind: :context_length, error: "context_length_exceeded"}
  end

  # `transport_stage` keeps its historical telemetry field name now that the
  # stage rides on the structured error itself.
  defp error_metadata({:provider_transport_error, %{stage: stage}} = reason, _wire_result) do
    reason
    |> ProviderError.telemetry_metadata()
    |> Map.put(:transport_stage, stage)
  end

  defp error_metadata({:provider_error, _error} = reason, _wire_result) do
    ProviderError.telemetry_metadata(reason)
  end

  defp error_metadata(reason, _wire_result),
    do: %{error_kind: :provider, error: error_text(reason)}

  defp error_text(reason) when is_binary(reason), do: reason
  defp error_text(reason), do: inspect(reason)
end
