defmodule FermixCore.Providers.Anthropic.Messages do
  @moduledoc """
  Anthropic Messages adapter — `api.anthropic.com/v1/messages`.

  Two auth modes, selected by which adapter opts the route supplies
  (design doc §5.2; the resolver guarantees exclusivity, no fallbacks):

    * `:api_key` — `x-api-key` header.
    * `:oauth` (Claude Code / subscription) — bearer auth via
      `:access_token` or a token server + `:auth_profile`, plus Claude
      Code request emulation (§4): the OAuth beta/user-agent/`x-app`
      headers, the Claude Code identity block prepended to `system`, and
      `mcp_` tool-name prefixing on the wire (restored on parse). A 401 on
      a server-managed token refreshes once and retries once.

  Anthropic-specific shape notes:

    * Tools are `[%{name, description, input_schema}]` at the top level
      of the request — no `function` wrapper, schema field is
      `input_schema` not `parameters`.
    * Assistant turns use `content: [%{type: "text", ...} |
      %{type: "tool_use", id, name, input}]`. Tool results go back as a
      single user-role message of `[%{type: "tool_result", tool_use_id,
      content}]` blocks that must immediately follow the assistant turn
      that issued them. `id` and `tool_use_id` correlate the call.
    * `stop_reason` of `"tool_use"` signals the model wants tools run;
      `"end_turn"` (and `"refusal"`) are terminal.

  Continuation replays the full transcript: `provider_state` carries the
  request `messages`, the response's raw `assistant_content` blocks, plus
  `system`/`tools`/`capabilities`. `continue/3` appends the assistant turn
  and the tool results, posts again, and returns a new `provider_state`
  with the round folded in (design doc §5.3).

  Prompt caching (design doc §5.8): static `cache_control` breakpoints are
  applied at request-build time only — last system block, last tool, final
  block of the final message — so markers never accumulate across rounds
  (the API allows at most 4). Request messages are kept block-form so the
  prefix stays byte-stable and moving the breakpoint forward still hits
  the cached prefix.

  Non-streaming (design doc §5.1): `max_tokens` is required by the API and
  is clamped to a non-streaming-safe ceiling; larger generations are an
  SSE follow-up.
  """

  @behaviour FermixCore.Providers.Adapter

  alias FermixCore.Auth.TokenSupervisor
  alias FermixCore.Capabilities.Capability
  alias FermixCore.Net.HttpClient
  alias FermixCore.Providers.Error, as: ProviderError
  alias FermixCore.Providers.ModelCatalog
  alias FermixCore.Providers.ReasoningEffort
  alias FermixCore.Providers.Telemetry, as: ProviderTelemetry

  require Logger

  @default_base_url "https://api.anthropic.com/v1"
  @anthropic_version "2023-06-01"
  # §5.1: non-streaming requests need a bounded output ceiling; the SSE
  # follow-up raises this toward ModelCatalog.max_output_tokens_for/2.
  @non_streaming_max_tokens 8_192
  # Codex precedent — HttpClient sets no receive timeout of its own.
  @receive_timeout_ms 120_000
  @cache_control %{type: "ephemeral"}
  # Claude 4.7+ rejects sampling params (temperature/top_p/top_k) — §5.1.
  @no_sampling_substrings ["4-7", "4.7", "4-8", "4.8"]
  @known_stop_reasons ["end_turn", "tool_use", "max_tokens", "stop_sequence", "refusal"]
  @context_length_markers [
    "prompt is too long",
    "context limit",
    "maximum context length",
    "too many tokens"
  ]
  # Claude Code emulation for subscription OAuth (design doc §4): headers,
  # identity system block, and MCP-shaped tool names are load-bearing for
  # subscription routing. Version is the Hermes-observed Claude Code
  # release; verify when bumping.
  @oauth_beta "claude-code-20250219,oauth-2025-04-20"
  @claude_code_system_prefix "You are Claude Code, Anthropic's official CLI for Claude."
  @claude_code_version "2.1.74"
  @oauth_user_agent "claude-cli/#{@claude_code_version} (external, cli)"
  @wire_tool_prefix "mcp_"

  @impl true
  def chat(messages, capabilities, opts)
      when is_list(messages) and messages != [] and is_list(capabilities) and is_list(opts) do
    {system, anthropic_messages} = split_system(messages)
    request(anthropic_messages, system, to_provider_tools(capabilities), capabilities, opts)
  end

  @impl true
  def continue(provider_state, tool_results, opts)
      when is_map(provider_state) and is_list(tool_results) and tool_results != [] and
             is_list(opts) do
    %{
      system: system,
      messages: messages,
      assistant_content: assistant_content,
      tools: tools,
      capabilities: capabilities
    } = provider_state

    next_messages =
      messages ++
        [
          %{role: "assistant", content: assistant_content},
          %{role: "user", content: tool_result_blocks(tool_results)}
        ]

    request(next_messages, system, tools, capabilities, opts)
  end

  @impl true
  def to_provider_tools([]), do: []

  def to_provider_tools(capabilities) when is_list(capabilities) do
    Enum.map(capabilities, fn %Capability{} = cap ->
      %{
        name: cap.name,
        description: cap.description,
        input_schema: cap.parameters
      }
    end)
  end

  @impl true
  def parse_tool_calls(%{"content" => blocks}) when is_list(blocks) do
    Enum.flat_map(blocks, &normalize_tool_use/1)
  end

  def parse_tool_calls(_), do: []

  @impl true
  def parse_response(body) when is_map(body) do
    blocks = Map.get(body, "content", [])

    %{
      content: extract_text(blocks),
      tool_calls: Enum.flat_map(blocks, &normalize_tool_use/1),
      provider_state: %{stop_reason: Map.get(body, "stop_reason"), content: blocks},
      usage: parse_usage(body),
      model: Map.get(body, "model", "unknown")
    }
  end

  @impl true
  def supports_streaming?, do: false

  # --- request build ---

  defp request(messages, system, tools, capabilities, opts) do
    {req_options, opts} = Keyword.pop(opts, :req_options, [])

    with {:ok, auth} <- resolve_auth(opts) do
      do_request(messages, system, tools, capabilities, auth, req_options, opts)
    end
  end

  defp do_request(messages, system, tools, capabilities, auth, req_options, opts) do
    mode = auth_mode(auth)
    model = Keyword.fetch!(opts, :model)
    base_url = Keyword.get(opts, :base_url, @default_base_url)

    body =
      %{
        model: model,
        max_tokens: resolve_max_tokens(model, opts),
        messages: cache_final_message(messages)
      }
      |> maybe_put(:system, system_blocks(system, mode))
      |> maybe_put(:tools, tools |> wire_tools(mode) |> cache_final_tool())
      |> maybe_put(:temperature, resolve_temperature(model, opts))
      |> maybe_put(:output_config, output_config(Keyword.get(opts, :reasoning_effort)))

    turn_state = %{
      model: model,
      auth_mode: mode,
      reasoning_effort: Keyword.get(opts, :reasoning_effort),
      system: system,
      messages: messages,
      tools: tools,
      capabilities: capabilities,
      agent: Keyword.get(opts, :agent),
      session_id: Keyword.get(opts, :session_id),
      parent_session: Keyword.get(opts, :parent_session),
      request_metrics: request_metrics(messages, system, tools, capabilities)
    }

    post(base_url, auth, body, req_options, turn_state)
  end

  # Mode is decided by which credential opts the route supplied; the
  # resolver guarantees exclusivity (api_key never reaches an oauth route).
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
           :anthropic,
           :messages,
           "Anthropic.Messages requires :api_key, :access_token, or :auth_profile"
         )}
    end
  end

  defp auth_mode({:api_key, _key}), do: :api_key
  defp auth_mode(_auth), do: :oauth

  defp nonempty_string(value) when is_binary(value) and value != "", do: value
  defp nonempty_string(_value), do: nil

  defp split_system(messages) do
    {system_messages, rest} = Enum.split_while(messages, &(&1.role == "system"))

    if rest == [] do
      raise ArgumentError, "Anthropic.Messages requires at least one non-system message"
    end

    system =
      case system_messages do
        [] -> nil
        parts -> Enum.map_join(parts, "\n\n", & &1.content)
      end

    {system, Enum.map(rest, &to_block_message/1)}
  end

  # Block-form keeps the message shape byte-stable across rounds, so moving
  # the cache breakpoint forward still hits the previously cached prefix.
  defp to_block_message(%{role: "assistant", content: content}),
    do: %{role: "assistant", content: [%{type: "text", text: content || ""}]}

  # Fail loud instead of silently rewriting an instruction into a user turn
  # (Code Rule #6) — only a leading system run maps to the `system` field.
  defp to_block_message(%{role: "system"}) do
    raise ArgumentError, "Anthropic.Messages requires system messages to lead the transcript"
  end

  defp to_block_message(%{content: content} = message),
    do: %{
      role: "user",
      content: [%{type: "text", text: content || ""} | anthropic_image_blocks(message)]
    }

  # Inbound images (M14) ride the user message's `image_parts`; append them after
  # the text block. Text-only turns produce `[%{type: "text", ...}]` unchanged,
  # keeping the cached prefix byte-stable.
  defp anthropic_image_blocks(message) do
    message
    |> Map.get(:image_parts, [])
    |> Enum.map(&anthropic_image_block/1)
  end

  defp anthropic_image_block(%{type: :image, mime_type: mime, data: data})
       when is_binary(mime) and is_binary(data),
       do: %{
         type: "image",
         source: %{type: "base64", media_type: mime, data: Base.encode64(data)}
       }

  defp anthropic_image_block(part),
    do:
      raise(
        ArgumentError,
        "unsupported image content part for Anthropic encoder: #{inspect(part)}"
      )

  defp tool_result_blocks(tool_results) do
    Enum.map(tool_results, fn %{call_id: call_id, output: output} ->
      %{type: "tool_result", tool_use_id: call_id, content: to_string(output)}
    end)
  end

  defp system_blocks(nil, :api_key), do: nil

  defp system_blocks(system, :api_key) when is_binary(system),
    do: cache_last_block([%{type: "text", text: system}])

  # Subscription requests must look like Claude Code (§4): identity block
  # first; the cache breakpoint stays on the last block.
  defp system_blocks(nil, :oauth),
    do: cache_last_block([%{type: "text", text: @claude_code_system_prefix}])

  defp system_blocks(system, :oauth) when is_binary(system) do
    cache_last_block([
      %{type: "text", text: @claude_code_system_prefix},
      %{type: "text", text: system}
    ])
  end

  defp wire_tools(tools, :api_key), do: tools

  # MCP-shaped tool names for subscription routing (§4); names already
  # carrying the prefix (Fermix MCP capabilities) stay as-is. Prefixing can
  # collide (`shell` vs a capability literally named `mcp_shell`) — fail
  # loud instead of shipping duplicate wire names / ambiguous restores.
  defp wire_tools(tools, :oauth) do
    wired = Enum.map(tools, fn tool -> %{tool | name: wire_tool_name(tool.name)} end)
    assert_unique_wire_names!(wired)
    wired
  end

  defp assert_unique_wire_names!(tools) do
    names = Enum.map(tools, & &1.name)
    duplicates = Enum.uniq(names -- Enum.uniq(names))

    if duplicates != [] do
      raise ArgumentError,
            "Anthropic OAuth tool-name prefixing collided on #{inspect(duplicates)}; " <>
              "rename the conflicting capability"
    end
  end

  defp wire_tool_name(@wire_tool_prefix <> _rest = name), do: name
  defp wire_tool_name(name), do: @wire_tool_prefix <> name

  defp cache_final_tool([]), do: []

  defp cache_final_tool(tools),
    do: List.update_at(tools, -1, &Map.put(&1, :cache_control, @cache_control))

  defp cache_final_message(messages) do
    List.update_at(messages, -1, fn %{content: blocks} = message when is_list(blocks) ->
      %{message | content: cache_last_block(blocks)}
    end)
  end

  defp cache_last_block(blocks),
    do: List.update_at(blocks, -1, &Map.put(&1, :cache_control, @cache_control))

  defp resolve_max_tokens(model, opts) do
    case Keyword.get(opts, :max_tokens) do
      nil ->
        min(ModelCatalog.max_output_tokens_for(:anthropic, model), @non_streaming_max_tokens)

      max_tokens when is_integer(max_tokens) and max_tokens > 0 ->
        max_tokens
    end
  end

  defp resolve_temperature(model, opts) do
    case Keyword.get(opts, :temperature) do
      nil -> nil
      temperature -> unless forbids_sampling?(model), do: temperature
    end
  end

  defp forbids_sampling?(model),
    do: Enum.any?(@no_sampling_substrings, &String.contains?(model, &1))

  # Maps the canonical effort level to Anthropic's `output_config.effort` wire
  # value (low/medium/high/xhigh/max — no `:none`, the floor is `:low`). nil =>
  # omit the field and let Anthropic apply its own default (high). Per-model
  # support (e.g. xhigh is Opus-only) is enforced by the API's 400, not
  # here (ReasoningEffort moduledoc).
  defp output_config(nil), do: nil

  defp output_config(effort) do
    case ReasoningEffort.parse(effort) do
      {:ok, level} -> output_config_for_level(level)
      :error -> raise ArgumentError, "invalid reasoning_effort: #{inspect(effort)}"
    end
  end

  defp output_config_for_level(level) do
    case ReasoningEffort.to_provider(level, :anthropic) do
      :omit ->
        nil

      {:ok, value} ->
        %{effort: value}

      {:error, {:unsupported, lvl, prov}} ->
        raise ArgumentError, "reasoning_effort #{lvl} is not supported by #{prov}"
    end
  end

  # --- transport + response handling ---

  # Telemetry is emitted exactly once per logical call (Codex precedent) —
  # a refreshed 401 must not leave a phantom error event in the trace.
  defp post(base_url, auth, body, req_options, turn_state) do
    start = System.monotonic_time(:millisecond)
    {result, request_id} = attempt_with_retry(base_url, auth, body, req_options, turn_state)
    duration_ms = System.monotonic_time(:millisecond) - start
    emit_telemetry(result, turn_state, duration_ms, request_id)
    result
  end

  # One bound retry: a 401 on a server-managed token refreshes once and
  # reposts with the refreshed bearer (design doc §12, Anthropic OAuth #6).
  defp attempt_with_retry(base_url, auth, body, req_options, turn_state) do
    {result, request_id} = attempt(base_url, auth, body, req_options, turn_state)

    case {result, auth} do
      {{:error, {:provider_error, %{status: 401}}}, {:oauth_server, server, profile}} ->
        case server.refresh(profile) do
          {:ok, fresh_token} ->
            {retry_result, retry_id} =
              attempt(base_url, {:oauth_static, fresh_token}, body, req_options, turn_state)

            {tag_auth_mode(retry_result, auth), retry_id}

          {:error, reason} ->
            Logger.warning("Anthropic Messages token refresh failed: #{inspect(reason)}")
            {tag_auth_mode(result, auth), request_id}
        end

      _other ->
        {tag_auth_mode(result, auth), request_id}
    end
  end

  defp attempt(base_url, auth, body, req_options, turn_state) do
    case current_credential(auth) do
      {:error, _reason} = error -> {error, nil}
      credential -> do_attempt(base_url, credential, body, req_options, turn_state)
    end
  end

  defp do_attempt(base_url, credential, body, req_options, turn_state) do
    raw =
      Req.new(
        url: "#{base_url}/messages",
        method: :post,
        json: body,
        receive_timeout: @receive_timeout_ms,
        headers: request_headers(credential)
      )
      |> Req.merge(req_options)
      |> HttpClient.request("Anthropic Messages")

    {handle_response(raw, turn_state), request_id(raw)}
  end

  defp request_headers({:api_key, key}) do
    [
      {"x-api-key", key},
      {"anthropic-version", @anthropic_version},
      {"content-type", "application/json"}
    ]
  end

  defp request_headers({:oauth, token}) do
    [
      {"authorization", "Bearer " <> token},
      {"anthropic-version", @anthropic_version},
      {"anthropic-beta", @oauth_beta},
      {"user-agent", @oauth_user_agent},
      {"x-app", "cli"},
      {"content-type", "application/json"}
    ]
  end

  defp current_credential({:api_key, key}), do: {:api_key, key}
  defp current_credential({:oauth_static, token}), do: {:oauth, token}

  defp current_credential({:oauth_server, server, profile}) do
    case server.get_token(profile) do
      {:ok, token} ->
        {:oauth, token}

      {:error, reason} ->
        {:error,
         ProviderError.auth(
           :anthropic,
           :messages,
           "Anthropic.Messages requires a bearer token: token server returned #{inspect(reason)}"
         )}
    end
  end

  # The auth mode is part of the error identity so channel replies can
  # distinguish "check the API key" from "reconnect the subscription".
  defp tag_auth_mode({:error, {:provider_error, error}}, auth),
    do: {:error, {:provider_error, Map.put(error, :auth_mode, auth_mode(auth))}}

  defp tag_auth_mode(result, _auth), do: result

  defp handle_response({:ok, %Req.Response{status: 200, body: body}}, turn_state)
       when is_map(body) do
    build_turn(body, turn_state)
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}, _turn_state) do
    if context_length_error?(status, body) do
      {:error, :context_length_exceeded}
    else
      Logger.error("Anthropic Messages API error: #{status} - #{inspect(body)}")
      {:error, ProviderError.api(:anthropic, :messages, status, body)}
    end
  end

  defp handle_response({:error, %Req.TransportError{reason: reason}}, _turn_state) do
    Logger.error("Anthropic Messages transport error: #{inspect(reason)}")
    {:error, ProviderError.transport(:anthropic, :messages, reason)}
  end

  defp handle_response({:error, reason}, _turn_state) do
    Logger.error("Anthropic Messages request failed: #{inspect(reason)}")
    {:error, reason}
  end

  defp build_turn(body, turn_state) do
    blocks = Map.get(body, "content", [])
    stop_reason = Map.get(body, "stop_reason")
    log_unknown_stop_reason(stop_reason)

    tool_calls =
      blocks
      |> Enum.flat_map(&normalize_tool_use/1)
      |> restore_tool_names(turn_state)

    {:ok,
     %{
       content: extract_text(blocks),
       tool_calls: tool_calls,
       provider_state: %{
         system: turn_state.system,
         messages: turn_state.messages,
         assistant_content: blocks,
         tools: turn_state.tools,
         capabilities: turn_state.capabilities,
         stop_reason: stop_reason
       },
       usage: parse_usage(body),
       model: Map.get(body, "model") || turn_state.model
     }}
  end

  # OAuth tool_use blocks come back with wire (mcp_-prefixed) names; map
  # them back to Fermix capability names so the loop can execute them.
  # Unknown names pass through untouched — the loop fails loud on those.
  defp restore_tool_names(tool_calls, %{auth_mode: :oauth, capabilities: capabilities}) do
    mapping =
      Map.new(capabilities, fn %Capability{name: name} -> {wire_tool_name(name), name} end)

    Enum.map(tool_calls, fn call -> %{call | name: Map.get(mapping, call.name, call.name)} end)
  end

  defp restore_tool_names(tool_calls, _turn_state), do: tool_calls

  defp log_unknown_stop_reason(stop_reason)
       when stop_reason in @known_stop_reasons or is_nil(stop_reason),
       do: :ok

  defp log_unknown_stop_reason(stop_reason) do
    Logger.warning("Anthropic Messages returned unknown stop_reason: #{inspect(stop_reason)}")
  end

  # §5.4: prompt = input + cache writes + cache reads; Anthropic sends no total.
  defp parse_usage(body) do
    usage = Map.get(body, "usage", %{})

    prompt =
      int(usage["input_tokens"]) + int(usage["cache_creation_input_tokens"]) +
        int(usage["cache_read_input_tokens"])

    completion = int(usage["output_tokens"])
    %{prompt_tokens: prompt, completion_tokens: completion, total_tokens: prompt + completion}
  end

  defp int(value) when is_integer(value) and value >= 0, do: value
  defp int(_value), do: 0

  defp request_id({:ok, %Req.Response{} = response}) do
    case Req.Response.get_header(response, "request-id") do
      [id | _rest] -> id
      [] -> nil
    end
  end

  defp request_id(_raw), do: nil

  # Token overflow only: Anthropic signals it as 400 invalid_request_error
  # with a "prompt is too long"-style message. 413/request_too_large is the
  # raw 32 MB byte limit — a different failure with a different remedy — so we
  # gate on the 400 status and let any other status keep its provider error.
  defp context_length_error?(400, body) do
    case anthropic_error(body) do
      %{"message" => message} when is_binary(message) -> context_length_message?(message)
      _other -> false
    end
  end

  defp context_length_error?(_status, _body), do: false

  defp anthropic_error(body) when is_map(body), do: Map.get(body, "error")

  defp anthropic_error(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => error}} -> error
      _not_json -> nil
    end
  end

  defp anthropic_error(_body), do: nil

  defp context_length_message?(message) do
    downcased = String.downcase(message)
    Enum.any?(@context_length_markers, &String.contains?(downcased, &1))
  end

  # --- telemetry ---

  defp emit_telemetry(result, turn_state, duration_ms, request_id) do
    {status, tokens, stop_reason, output, tool_calls, error_metadata} =
      case result do
        {:ok, turn} ->
          {:ok, %{prompt: turn.usage.prompt_tokens, completion: turn.usage.completion_tokens},
           turn.provider_state.stop_reason, turn.content, turn.tool_calls, %{}}

        {:error, reason} ->
          {:error, %{}, nil, nil, nil, ProviderError.telemetry_metadata(reason)}
      end

    metadata =
      %{
        provider: :anthropic,
        adapter: :messages,
        auth_mode: turn_state.auth_mode,
        model: turn_state.model,
        status: status,
        tokens: tokens,
        # The configured effort sent as `output_config.effort` (or nil when
        # unset → Anthropic's own default), kept uniform across adapters.
        reasoning_effort: turn_state.reasoning_effort
      }
      |> Map.merge(turn_state.request_metrics)
      |> Map.merge(error_metadata)
      |> maybe_put(:stop_reason, stop_reason)
      |> maybe_put(:request_id, request_id)
      |> maybe_put(:agent, turn_state.agent)

    ProviderTelemetry.emit_call(metadata, duration_ms,
      session_id: turn_state.session_id,
      parent_session: turn_state.parent_session,
      output: output,
      tool_calls: tool_calls
    )
  end

  defp request_metrics(messages, system, tools, capabilities) do
    %{
      input_items: length(messages),
      input_bytes: encoded_size(messages),
      instructions_bytes: if(is_binary(system), do: byte_size(system), else: 0),
      tools_count: length(tools),
      tools_bytes: encoded_size(tools),
      capabilities_count: length(capabilities)
    }
  end

  defp encoded_size(value), do: value |> Jason.encode_to_iodata!() |> IO.iodata_length()

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp normalize_tool_use(%{"type" => "tool_use", "id" => id, "name" => name, "input" => input}) do
    [%{id: id, call_id: id, name: name, arguments: input}]
  end

  defp normalize_tool_use(_), do: []

  defp extract_text(blocks) do
    blocks
    |> Enum.flat_map(fn
      %{"type" => "text", "text" => t} when is_binary(t) -> [t]
      _ -> []
    end)
    |> Enum.join("")
  end
end
