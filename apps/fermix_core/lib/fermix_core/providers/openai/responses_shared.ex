defmodule FermixCore.Providers.OpenAI.ResponsesShared do
  @moduledoc """
  Shared item-list logic for the two OpenAI Responses-shape adapters
  (`OpenAI.Responses` for `api.openai.com/v1/responses`, `OpenAI.Codex`
  for `chatgpt.com/backend-api/codex/responses`).

  The wire shape is identical between the two surfaces:

    * `input` is an item list (user/assistant content + previous turn's
      output items + `function_call_output` items keyed by `call_id`).
    * `output` is an item list (`function_call`, `reasoning`, `message`).
    * Tool shape is `%{type: "function", name, description, parameters,
      strict: false}` — no nested `function: %{...}` wrapper.

  Only the URL, headers, request-body extras, and transport (stream vs.
  non-stream) differ. Adapters delegate the wire-shape work here so the
  surface diverges only where it actually has to.
  """

  alias FermixCore.Capabilities.Capability
  alias FermixCore.Providers.ReasoningEffort
  alias FermixCore.Telemetry

  @type tool_result :: %{required(:call_id) => String.t(), required(:output) => term()}

  @doc """
  Builds the OpenAI-family `reasoning` body field for `provider`, or `nil`
  to indicate "omit".

  The canonical effort enum and per-provider mapping live in
  `FermixCore.Providers.ReasoningEffort`; this only wraps the mapped value
  in the `%{effort: ...}` shape both Responses adapters share. `:none` (and
  `nil`) omit the field; a level above the provider's ceiling clamps (e.g.
  `:max` -> `"xhigh"` on OpenAI). Invalid or provider-unsupported values
  raise — config bugs we refuse to silently round-trip (CLAUDE.md #6, #12).
  Per-*model* rejection (a model that doesn't accept `xhigh`) stays the
  API's 400 to decide.
  """
  @spec maybe_reasoning_field(atom() | String.t() | nil, ReasoningEffort.provider()) ::
          %{required(:effort) => String.t()} | nil
  def maybe_reasoning_field(nil, _provider), do: nil

  def maybe_reasoning_field(effort, provider) do
    case ReasoningEffort.parse(effort) do
      {:ok, level} -> reasoning_field(level, provider)
      :error -> raise_invalid_effort!(effort)
    end
  end

  defp reasoning_field(level, provider) do
    case ReasoningEffort.to_provider(level, provider) do
      :omit ->
        nil

      {:ok, value} ->
        %{effort: value}

      {:error, {:unsupported, lvl, prov}} ->
        raise ArgumentError, "reasoning_effort #{lvl} is not supported by #{prov}"
    end
  end

  defp raise_invalid_effort!(effort) do
    raise ArgumentError,
          "invalid reasoning_effort: #{inspect(effort)}; " <>
            "expected one of #{inspect(ReasoningEffort.levels())}"
  end

  # The optional `adapter` tag keeps tool-schema telemetry distinguishable
  # per consumer (e.g. :xai_responses vs the OpenAI adapters' default).
  @spec to_provider_tools([Capability.t()], atom()) :: [map()]
  def to_provider_tools(capabilities, adapter \\ :responses_shared)
      when is_list(capabilities) and is_atom(adapter) do
    {tools, duration_us} =
      Telemetry.timed_us(fn ->
        Enum.map(capabilities, fn %Capability{} = cap ->
          %{
            type: "function",
            name: cap.name,
            description: cap.description,
            parameters: cap.parameters,
            strict: false
          }
        end)
      end)

    emit_tool_schema_telemetry(tools, capabilities, duration_us, adapter)
    tools
  end

  @spec request_metrics([map()], String.t() | nil, [map()], [Capability.t()]) :: map()
  def request_metrics(input, instructions, tools, capabilities)
      when is_list(input) and is_list(tools) and is_list(capabilities) do
    %{
      input_items: length(input),
      input_bytes: encoded_size(input),
      instructions_bytes: string_size(instructions),
      tools_count: length(tools),
      tools_bytes: encoded_size(tools),
      capabilities_count: length(capabilities)
    }
  end

  @spec build_input([map()]) :: {String.t() | nil, [map()]}
  def build_input(messages) do
    {system_parts, rest} = Enum.split_while(messages, fn msg -> msg.role == "system" end)

    instructions =
      case system_parts do
        [] -> nil
        parts -> Enum.map_join(parts, "\n\n", & &1.content)
      end

    input = Enum.map(rest, &message_to_item/1)

    {instructions, input}
  end

  @spec build_function_call_outputs([tool_result()]) :: [map()]
  def build_function_call_outputs(tool_results) when is_list(tool_results) do
    Enum.map(tool_results, fn %{call_id: call_id, output: output} ->
      %{type: "function_call_output", call_id: call_id, output: to_string(output)}
    end)
  end

  @context_length_markers [
    "context_length_exceeded",
    "maximum context length",
    "context window",
    "too many tokens",
    "prompt is too long",
    "reduce the length"
  ]

  @doc """
  True if an OpenAI-family error `body` (a decoded map or a JSON string) is a
  context-length / too-many-tokens error. Shared by the Codex and Responses
  adapters so a turn that overflows the model's context window surfaces a clear,
  actionable reason (start a fresh session / compact) instead of a generic API
  error.
  """
  @spec context_length_error?(term()) :: boolean()
  def context_length_error?(body) do
    # `error` may be a map (`%{"code" => ..., "message" => ...}`), a bare string
    # (`%{"error" => "boom"}`), or absent — only the map shape carries a
    # context-length signal, so other shapes are simply "not a context error".
    case decode_error_body(body) do
      %{"error" => %{} = error} ->
        error["code"] == "context_length_exceeded" or context_length_message?(error["message"])

      _other ->
        false
    end
  end

  defp context_length_message?(message) when is_binary(message) do
    downcased = String.downcase(message)
    Enum.any?(@context_length_markers, &String.contains?(downcased, &1))
  end

  defp context_length_message?(_message), do: false

  defp decode_error_body(body) when is_map(body), do: body

  defp decode_error_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _not_json -> %{}
    end
  end

  defp decode_error_body(_body), do: %{}

  defp encoded_size(value) do
    value
    |> Jason.encode_to_iodata!()
    |> IO.iodata_length()
  end

  defp string_size(value) when is_binary(value), do: byte_size(value)
  defp string_size(_value), do: 0

  defp emit_tool_schema_telemetry(tools, capabilities, duration_us, adapter) do
    :telemetry.execute(
      [:fermix, :provider, :tool_schema],
      %{
        duration_us: duration_us,
        tools_count: length(tools),
        capabilities_count: length(capabilities)
      },
      %{adapter: adapter}
    )
  end

  @spec build_turn(map(), String.t(), [map()], term(), [Capability.t()]) ::
          {:ok, map()}
  def build_turn(body, fallback_model, input, tools, capabilities) do
    output_items = Map.get(body, "output") || []
    usage = Map.get(body, "usage") || %{}

    tool_calls =
      output_items
      |> Enum.with_index()
      |> Enum.flat_map(fn {item, idx} -> normalize_tool_call(item, idx) end)

    prompt = Map.get(usage, "input_tokens", 0)
    completion = Map.get(usage, "output_tokens", 0)

    {:ok,
     %{
       content: extract_text(output_items),
       tool_calls: tool_calls,
       provider_state: %{
         input: input,
         output_items: output_items,
         tools: tools,
         capabilities: capabilities
       },
       usage: %{
         prompt_tokens: prompt,
         completion_tokens: completion,
         total_tokens: prompt + completion
       },
       model: Map.get(body, "model") || fallback_model
     }}
  end

  @spec parse_tool_calls(term()) :: [map()]
  def parse_tool_calls(%{"output" => items}) when is_list(items) do
    items
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, idx} -> normalize_tool_call(item, idx) end)
  end

  def parse_tool_calls(_), do: []

  @spec deterministic_call_id(String.t(), String.t(), non_neg_integer()) :: String.t()
  def deterministic_call_id(name, arguments, idx) do
    hash =
      :crypto.hash(:sha256, "#{name}:#{arguments}:#{idx}")
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)

    "call_#{hash}"
  end

  defp message_to_item(%{role: "assistant", content: content}),
    do: %{role: "assistant", content: [%{type: "output_text", text: content || ""}]}

  defp message_to_item(%{role: "user"} = message), do: user_item(message)

  defp message_to_item(message), do: user_item(message)

  # User content: the text caption (a plain string) plus any image parts the
  # gateway materialized (M14). Appending image parts to the single-element text
  # list keeps text-only turns byte-identical to the pre-multimodal shape, so the
  # provider prompt-cache prefix is unaffected (see the characterization test).
  defp user_item(message) do
    text = Map.get(message, :content) || ""

    image_parts =
      message
      |> Map.get(:image_parts, [])
      |> Enum.map(&image_part_to_responses/1)

    %{role: "user", content: [%{type: "input_text", text: text} | image_parts]}
  end

  # Image bytes ride as a base64 data URI in `image_url` (the same field a remote
  # URL would use), the shape the Codex/Responses backend accepts.
  defp image_part_to_responses(%{type: :image, mime_type: mime, data: data})
       when is_binary(mime) and is_binary(data),
       do: %{type: "input_image", image_url: "data:#{mime};base64,#{Base.encode64(data)}"}

  defp image_part_to_responses(part),
    do:
      raise(
        ArgumentError,
        "unsupported image content part for Responses encoder: #{inspect(part)}"
      )

  defp normalize_tool_call(%{"type" => "function_call"} = item, idx) do
    name = Map.get(item, "name", "")
    raw_args = Map.get(item, "arguments", "{}")
    id = Map.get(item, "id", "fc_#{idx}")
    call_id = Map.get(item, "call_id") || deterministic_call_id(name, raw_args, idx)

    [%{id: id, call_id: call_id, name: name, arguments: raw_args}]
  end

  defp normalize_tool_call(_item, _idx), do: []

  defp extract_text(items) when is_list(items) do
    items
    |> Enum.flat_map(fn
      %{"type" => "message", "content" => parts} when is_list(parts) -> parts
      _ -> []
    end)
    |> Enum.flat_map(fn
      %{"type" => "output_text", "text" => t} when is_binary(t) -> [t]
      %{"text" => t} when is_binary(t) -> [t]
      _ -> []
    end)
    |> Enum.join("")
  end
end
