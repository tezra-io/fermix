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
  alias FermixCore.Telemetry

  @type tool_result :: %{required(:call_id) => String.t(), required(:output) => term()}

  @valid_reasoning_efforts ~w(none minimal low medium high xhigh)a

  @doc """
  Returns the list of accepted `reasoning_effort` values (atoms).

  Mirrors hermes-agent's `VALID_REASONING_EFFORTS`. `:none` is the
  "disable reasoning" sentinel — caller-side, that means "omit the
  reasoning field entirely from the request body". The wizard surfaces
  the same list to the user.
  """
  @spec valid_reasoning_efforts() :: [atom()]
  def valid_reasoning_efforts, do: @valid_reasoning_efforts

  @doc """
  Builds the `reasoning` body field, or `nil` to indicate "omit".

  Returns `nil` for `nil`, `:none`, or `"none"`. Returns
  `%{effort: "..."}` for the other valid levels. Raises `ArgumentError`
  on any other value — invalid effort levels are configuration bugs we
  refuse to silently round-trip (CLAUDE.md #6, #12).

  Per-model rejection (e.g., a model that doesn't accept `xhigh`) is
  intentionally NOT clamped here (design §4 Q2). The API's 400 is the
  source of truth.
  """
  @spec maybe_reasoning_field(atom() | String.t() | nil) ::
          %{required(:effort) => String.t()} | nil
  def maybe_reasoning_field(nil), do: nil
  def maybe_reasoning_field(:none), do: nil
  def maybe_reasoning_field("none"), do: nil

  def maybe_reasoning_field(effort) when effort in @valid_reasoning_efforts do
    %{effort: Atom.to_string(effort)}
  end

  def maybe_reasoning_field(effort) when is_binary(effort) do
    case Enum.find(@valid_reasoning_efforts, fn atom -> Atom.to_string(atom) == effort end) do
      nil -> raise_invalid_effort!(effort)
      _atom -> %{effort: effort}
    end
  end

  def maybe_reasoning_field(effort), do: raise_invalid_effort!(effort)

  defp raise_invalid_effort!(effort) do
    raise ArgumentError,
          "invalid reasoning_effort: #{inspect(effort)}; " <>
            "expected one of #{inspect(@valid_reasoning_efforts)}"
  end

  @spec to_provider_tools([Capability.t()]) :: [map()]
  def to_provider_tools(capabilities) when is_list(capabilities) do
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

    emit_tool_schema_telemetry(tools, capabilities, duration_us)
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

  defp encoded_size(value) do
    value
    |> Jason.encode_to_iodata!()
    |> IO.iodata_length()
  end

  defp string_size(value) when is_binary(value), do: byte_size(value)
  defp string_size(_value), do: 0

  defp emit_tool_schema_telemetry(tools, capabilities, duration_us) do
    :telemetry.execute(
      [:fermix, :provider, :tool_schema],
      %{
        duration_us: duration_us,
        tools_count: length(tools),
        capabilities_count: length(capabilities)
      },
      %{adapter: :responses_shared}
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

  defp message_to_item(%{role: "user", content: content}),
    do: %{role: "user", content: [%{type: "input_text", text: content || ""}]}

  defp message_to_item(%{role: "assistant", content: content}),
    do: %{role: "assistant", content: [%{type: "output_text", text: content || ""}]}

  defp message_to_item(%{content: content}),
    do: %{role: "user", content: [%{type: "input_text", text: content || ""}]}

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
