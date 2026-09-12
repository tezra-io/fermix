defmodule FermixCore.Providers.OpenAI.ChatCompletions do
  @moduledoc """
  OpenAI Chat Completions adapter.

  Posts to `<base_url>/chat/completions` with the standard `tools: [{type:
  "function", function: {...}}]` shape. Used for OpenAI-compatible
  providers and as the fallback for OpenAI models the Responses route
  doesn't claim.

  Because this adapter serves multiple providers, the owning provider atom
  is REQUIRED in opts (`provider:` — placed by `RouteResolver`) and is
  used for error attribution and telemetry. There is no `:openai` default:
  a missing opt is a bug at the resolver seam and fails loud (M12 §2.3).

  Continuation model: assistant messages carry `tool_calls`; results go
  back as `role: "tool"` messages keyed by `tool_call_id`. The same shape
  `Providers.OpenAI` has used since M1.

  `provider_state` carries only adapter-internal continuation data
  (messages history + capabilities). Opts (api_key, model, base_url) are
  re-passed by `AgentLoop` on every `continue/3` so secrets don't sit in
  per-turn state.
  """

  @behaviour FermixCore.Providers.Adapter

  alias FermixCore.Capabilities.Capability
  alias FermixCore.Net.HttpClient
  alias FermixCore.Net.TimeoutPolicy
  alias FermixCore.Providers.Error, as: ProviderError
  alias FermixCore.Providers.ReasoningEffort
  alias FermixCore.Providers.ScreenshotRetention
  alias FermixCore.Providers.Telemetry, as: ProviderTelemetry
  alias FermixCore.Telemetry

  require Logger

  @default_base_url "https://api.openai.com/v1"
  @default_temperature 0.7

  @impl true
  def chat(messages, capabilities, opts) when is_list(messages) and is_list(capabilities) do
    request(messages, capabilities, opts)
  end

  # A `tool` message is text-only on every OpenAI-shaped surface, so a screenshot
  # cannot ride inside it. The replay-safe shape (no `previous_response_id` here):
  # the `tool` message keeps the call/result pairing and carries the text (or a
  # short placeholder when the image is the whole payload), then the image(s) ride
  # a SUBSEQUENT user turn — emitted after ALL tool messages so every tool_call is
  # paired before any user turn. State carries by full replay, so the image is
  # re-sent each turn (bounded by the screenshot-retention cap once it lands).
  @image_followup_label "Screen state returned by the preceding tool call:"
  @image_followup_placeholder "[screen state in the following message]"
  # Replaces a screenshot follow-up turn once it ages out of the retention
  # window (ScreenshotRetention) — the image bytes drop, the textual trail stays.
  @image_followup_elided "[earlier screen state omitted to bound context]"

  @impl true
  def continue(
        %{messages: prior, assistant: assistant, capabilities: capabilities},
        tool_results,
        opts
      ) do
    tool_messages = Enum.map(tool_results, &tool_result_message/1)
    image_turns = tool_results |> Enum.filter(&has_images?/1) |> Enum.map(&image_user_message/1)

    next_messages =
      (prior ++ [assistant] ++ tool_messages ++ image_turns)
      |> ScreenshotRetention.keep_last(
        Keyword.get(opts, :max_retained_screenshots),
        &screenshot_message?/1,
        &elide_screenshot_message/1
      )

    request(next_messages, capabilities, opts)
  end

  # A screenshot carrier is the dedicated follow-up user turn (labelled, carrying
  # `image_parts`) emitted after the tool messages — NOT an inbound user image
  # (those also carry `image_parts` but never this label), so user content is
  # left untouched.
  defp screenshot_message?(%{content: @image_followup_label, image_parts: [_ | _]}), do: true
  defp screenshot_message?(_), do: false

  defp elide_screenshot_message(message),
    do: message |> Map.delete(:image_parts) |> Map.put(:content, @image_followup_elided)

  defp tool_result_message(%{call_id: call_id, output: output} = result) do
    text = to_string(output)
    content = if text == "" and has_images?(result), do: @image_followup_placeholder, else: text
    %{role: "tool", tool_call_id: call_id, content: content}
  end

  defp image_user_message(%{images: images}) do
    %{role: "user", content: @image_followup_label, image_parts: images}
  end

  defp has_images?(%{images: [_ | _]}), do: true
  defp has_images?(_), do: false

  @impl true
  def to_provider_tools(capabilities) when is_list(capabilities) do
    {tools, duration_us} =
      Telemetry.timed_us(fn ->
        Enum.map(capabilities, fn %Capability{} = cap ->
          %{
            type: "function",
            function: %{
              name: cap.name,
              description: cap.description,
              parameters: cap.parameters
            }
          }
        end)
      end)

    emit_tool_schema_telemetry(tools, capabilities, duration_us)
    tools
  end

  @impl true
  def parse_tool_calls(%{"choices" => [%{"message" => %{"tool_calls" => calls}} | _]})
      when is_list(calls) do
    Enum.map(calls, &normalize_tool_call/1)
  end

  def parse_tool_calls(_), do: []

  @impl true
  def parse_response(body) when is_map(body) do
    {:ok, turn} = build_turn(body, body["model"] || "unknown", [], [])
    turn
  end

  @impl true
  def supports_streaming?, do: false

  defp request(messages, capabilities, opts) do
    provider = required_provider!(opts)

    with {:ok, api_key} <- fetch_api_key(provider, opts) do
      do_request(messages, capabilities, api_key, provider, opts)
    end
  end

  # The owning provider atom is mandatory: this adapter serves several
  # providers and attribution (errors, telemetry, Opik cost) must never
  # silently default to :openai (M12 §2.3-5).
  defp required_provider!(opts) do
    case Keyword.get(opts, :provider) do
      provider when is_atom(provider) and not is_nil(provider) ->
        provider

      other ->
        raise ArgumentError,
              "ChatCompletions requires a :provider atom in opts (set by RouteResolver), " <>
                "got: #{inspect(other)}"
    end
  end

  defp do_request(messages, capabilities, api_key, provider, opts) do
    model = Keyword.fetch!(opts, :model)
    temperature = Keyword.get(opts, :temperature, @default_temperature)
    base_url = Keyword.get(opts, :base_url, @default_base_url)
    response_format = Keyword.get(opts, :response_format)
    reasoning_effort = Keyword.get(opts, :reasoning_effort)
    correlation = Keyword.take(opts, [:agent, :session_id, :parent_session])
    {req_options, _opts} = Keyword.pop(opts, :req_options, [])

    body =
      %{model: model, messages: format_messages(messages), temperature: temperature}
      |> maybe_put_tools(to_provider_tools(capabilities))
      |> maybe_put(:response_format, response_format)
      |> maybe_put_reasoning_effort(provider, reasoning_effort)

    ctx = %{
      provider: provider,
      model: model,
      prior_messages: messages,
      capabilities: capabilities,
      correlation: correlation,
      reasoning_effort: reasoning_effort
    }

    post(base_url, api_key, body, req_options, ctx)
  end

  defp post(base_url, api_key, body, req_options, ctx) do
    start = System.monotonic_time(:millisecond)

    result =
      Req.new(
        url: "#{base_url}/chat/completions",
        method: :post,
        json: body,
        receive_timeout: TimeoutPolicy.receive_timeout_for(:llm_buffered),
        headers: auth_headers(api_key) ++ provider_headers(ctx.provider)
      )
      |> Req.merge(req_options)
      |> HttpClient.request("#{ctx.provider} ChatCompletions")
      |> handle_response(ctx.provider, ctx.model, ctx.prior_messages, ctx.capabilities)

    duration_ms = System.monotonic_time(:millisecond) - start

    emit_telemetry(
      result,
      ctx.provider,
      ctx.model,
      ctx.reasoning_effort,
      duration_ms,
      ctx.correlation
    )

    result
  end

  # Effort only reaches this adapter for direct-OpenAI routes that fall to
  # ChatCompletions (non-`gpt-`/`o-` models or a custom base_url); effort-less
  # providers (openrouter/ollama) never stamp it. The level is already clamped
  # to the provider's range by `RoutingOverrides.apply_effort`, so `:omit`/`:ok`
  # are the only outcomes — an `:error` would be an upstream bug, not a wire value.
  defp maybe_put_reasoning_effort(body, _provider, nil), do: body

  defp maybe_put_reasoning_effort(body, provider, level) when is_atom(level) do
    case ReasoningEffort.to_provider(level, provider) do
      {:ok, wire} -> Map.put(body, :reasoning_effort, wire)
      :omit -> body
      {:error, _unsupported} -> body
    end
  end

  defp handle_response(
         {:ok, %Req.Response{status: 200, body: body}},
         provider,
         model,
         prior_messages,
         capabilities
       ) do
    case body do
      %{"choices" => [_ | _]} ->
        build_turn(body, model, prior_messages, capabilities)

      _ ->
        Logger.error("Unexpected #{provider} Chat Completions response: #{inspect(body)}")
        {:error, "Unexpected response format"}
    end
  end

  defp handle_response(
         {:ok, %Req.Response{status: status, body: body}},
         provider,
         _model,
         _prior,
         _caps
       ) do
    Logger.error("#{provider} Chat Completions error: #{status} - #{inspect(body)}")
    {:error, ProviderError.api(provider, :chat_completions, status, body)}
  end

  defp handle_response(
         {:error, %Req.TransportError{reason: reason}},
         provider,
         _model,
         _prior,
         _caps
       ) do
    Logger.error("#{provider} Chat Completions transport error: #{inspect(reason)}")
    {:error, ProviderError.transport(provider, :chat_completions, reason)}
  end

  defp handle_response({:error, reason}, provider, _model, _prior, _caps) do
    Logger.error("#{provider} Chat Completions request failed: #{inspect(reason)}")
    {:error, reason}
  end

  defp build_turn(
         %{"choices" => [choice | _], "usage" => usage},
         model,
         prior_messages,
         capabilities
       ) do
    message = choice["message"]
    raw_tool_calls = message["tool_calls"] || []
    normalized = Enum.map(raw_tool_calls, &normalize_tool_call/1)
    assistant_message = build_assistant_message(message, raw_tool_calls)

    {:ok,
     %{
       content: message["content"] || "",
       tool_calls: normalized,
       provider_state: %{
         messages: prior_messages,
         assistant: assistant_message,
         capabilities: capabilities
       },
       usage: usage_map(usage),
       model: choice["model"] || model
     }}
  end

  # `prompt_tokens_details.cached_tokens` is the cache-READ subset of
  # `prompt_tokens`, so it rides ALONGSIDE the totals rather than being
  # subtracted out: `prompt_tokens` keeps the meaning every existing consumer
  # already reads, and a pricing consumer subtracts to get the uncached
  # remainder. This surface publishes no cache-WRITE count, so none is emitted.
  defp usage_map(usage) do
    %{
      prompt_tokens: usage["prompt_tokens"] || 0,
      completion_tokens: usage["completion_tokens"] || 0,
      total_tokens: usage["total_tokens"] || 0
    }
    |> maybe_put(:cached_input_tokens, cached_input_tokens(usage))
  end

  defp cached_input_tokens(%{"prompt_tokens_details" => %{} = details}),
    do: cache_count!(Map.get(details, "cached_tokens"), "prompt_tokens_details.cached_tokens")

  defp cached_input_tokens(_usage), do: nil

  # Absent stays absent. A reported 0 means "the vendor cached nothing"; a
  # missing key means "the vendor reported nothing", and cache-aware pricing has
  # to tell those apart — so a count is never defaulted to 0. A present count
  # that is not a non-negative integer is a vendor-contract break, not a value to
  # quietly round off.
  defp cache_count!(nil, _field), do: nil
  defp cache_count!(value, _field) when is_integer(value) and value >= 0, do: value

  defp cache_count!(value, field) do
    raise ArgumentError, "#{field} must be a non-negative integer, got: #{inspect(value)}"
  end

  defp build_assistant_message(message, raw_tool_calls) do
    base = %{role: "assistant", content: message["content"] || ""}
    if raw_tool_calls == [], do: base, else: Map.put(base, :tool_calls, raw_tool_calls)
  end

  defp normalize_tool_call(%{"id" => id, "function" => %{"name" => name, "arguments" => args}}) do
    %{id: id, call_id: id, name: name, arguments: args}
  end

  defp format_messages(messages) do
    Enum.map(messages, fn msg ->
      tool_calls = Map.get(msg, :tool_calls)

      %{role: msg.role}
      |> put_content(Map.get(msg, :content), Map.get(msg, :image_parts, []), tool_calls)
      |> maybe_put_field(:tool_call_id, Map.get(msg, :tool_call_id))
      |> maybe_put_tool_calls(tool_calls)
    end)
  end

  # Inbound images (M14) → a multimodal content array (text + image_url parts).
  # Only user turns carry them; image bytes ride as a base64 data URI. Checked
  # first so the text-only clauses below stay byte-identical when there are none.
  defp put_content(map, content, [_ | _] = image_parts, _calls) do
    text_part = %{type: "text", text: content || ""}
    Map.put(map, :content, [text_part | Enum.map(image_parts, &chat_image_part/1)])
  end

  # Mistral's strict validator 422s on empty-string `content` sent alongside
  # `tool_calls`; the cross-ecosystem fix (langchain #21196, litellm #13355,
  # vllm #38738) is to omit the `content` key in exactly that case. A real
  # preamble (non-empty content + tool_calls) is kept, and OpenAI/OpenRouter/
  # Ollama tolerate the omission — one wire shape valid on every provider.
  defp put_content(map, content, _no_images, calls)
       when is_list(calls) and calls != [] and content in [nil, ""],
       do: map

  defp put_content(map, content, _no_images, _calls), do: Map.put(map, :content, content || "")

  defp chat_image_part(%{type: :image, mime_type: mime, data: data})
       when is_binary(mime) and is_binary(data),
       do: %{type: "image_url", image_url: %{url: "data:#{mime};base64,#{Base.encode64(data)}"}}

  defp chat_image_part(part),
    do:
      raise(
        ArgumentError,
        "unsupported image content part for Chat Completions encoder: #{inspect(part)}"
      )

  defp maybe_put_field(map, _key, nil), do: map
  defp maybe_put_field(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_tool_calls(map, nil), do: map
  defp maybe_put_tool_calls(map, []), do: map
  defp maybe_put_tool_calls(map, calls) when is_list(calls), do: Map.put(map, :tool_calls, calls)
  defp maybe_put_tool_calls(map, _invalid), do: map

  defp maybe_put_tools(body, []), do: body
  defp maybe_put_tools(body, tools) when is_list(tools), do: Map.put(body, :tools, tools)
  defp maybe_put(body, _key, nil), do: body
  defp maybe_put(body, key, value), do: Map.put(body, key, value)

  defp emit_tool_schema_telemetry(tools, capabilities, duration_us) do
    :telemetry.execute(
      [:fermix, :provider, :tool_schema],
      %{
        duration_us: duration_us,
        tools_count: length(tools),
        capabilities_count: length(capabilities)
      },
      %{adapter: :chat_completions}
    )
  end

  defp auth_headers(nil), do: []
  defp auth_headers(api_key), do: [{"authorization", "Bearer #{api_key}"}]

  # OpenRouter app-attribution headers (M12 §3.1, decision D3: static, not
  # configurable). Other providers add nothing.
  defp provider_headers(:openrouter) do
    [{"http-referer", "https://fermix.sh"}, {"x-title", "Fermix"}]
  end

  defp provider_headers(_provider), do: []

  # Keyless providers (auth: :none, e.g. Ollama) demand no key and send no
  # authorization header — one explicit branch per configuration, not a
  # fallback (M12 §3.2 / Code Rule 12).
  defp fetch_api_key(provider, opts) do
    case {Keyword.get(opts, :auth), Keyword.get(opts, :api_key)} do
      {:none, _ignored} ->
        {:ok, nil}

      {_auth, key} when is_binary(key) and key != "" ->
        {:ok, key}

      _missing ->
        {:error,
         ProviderError.auth(
           provider,
           :chat_completions,
           "OpenAI.ChatCompletions.chat/3 requires :api_key"
         )}
    end
  end

  defp emit_telemetry(result, provider, model, reasoning_effort, duration_ms, correlation) do
    {status, tokens, output, tool_calls, error_metadata} =
      case result do
        {:ok, resp} ->
          {:ok, telemetry_tokens(resp.usage), Map.get(resp, :content), Map.get(resp, :tool_calls),
           %{}}

        {:error, reason} ->
          {:error, %{}, nil, nil, ProviderError.telemetry_metadata(reason)}
      end

    metadata =
      %{
        provider: provider,
        adapter: :chat_completions,
        model: model,
        status: status,
        tokens: tokens,
        reasoning_effort: reasoning_effort
      }
      |> Map.merge(error_metadata)
      |> maybe_put(:agent, Keyword.get(correlation, :agent))

    ProviderTelemetry.emit_call(metadata, duration_ms,
      session_id: Keyword.get(correlation, :session_id),
      parent_session: Keyword.get(correlation, :parent_session),
      output: output,
      tool_calls: tool_calls
    )
  end

  # The token map the shared provider emitter carries into the Opik llm span.
  # `:cached` is present only when the vendor reported it, so a span keeps
  # "no cache activity" distinguishable from "no cache reporting".
  defp telemetry_tokens(usage) do
    %{prompt: usage.prompt_tokens, completion: usage.completion_tokens}
    |> maybe_put(:cached, Map.get(usage, :cached_input_tokens))
  end
end
