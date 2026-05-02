defmodule FermixCore.Providers.Anthropic.Messages do
  @moduledoc """
  Anthropic Messages adapter — scaffold.

  The schema-translation surface (`to_provider_tools/1`,
  `parse_tool_calls/1`, `parse_response/1`) is implemented against the
  documented Anthropic Messages format so the rest of `AgentLoop` can be
  routed here without surprises. `chat/3` and `continue/3` return
  `{:error, :not_implemented}` until token storage and the OAuth flow
  land in a follow-on milestone — see M5 plan.

  Anthropic-specific shape notes:

    * Tools are `[%{name, description, input_schema}]` at the top level
      of the request — no `function` wrapper, schema field is
      `input_schema` not `parameters`.
    * Assistant turns use `content: [%{type: "text", ...} |
      %{type: "tool_use", id, name, input}]`. Tool results go back as
      user-role messages with `[%{type: "tool_result", tool_use_id,
      content}]` blocks. `id` and `tool_use_id` correlate the call.
    * `stop_reason` of `"tool_use"` signals the model wants tools run;
      `"end_turn"` means the response is terminal.
  """

  @behaviour FermixCore.Providers.Adapter

  alias FermixCore.Capabilities.Capability

  @impl true
  def chat(_messages, _capabilities, _opts), do: {:error, :not_implemented}

  @impl true
  def continue(_provider_state, _tool_results, _opts), do: {:error, :not_implemented}

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
    usage = Map.get(body, "usage", %{})

    %{
      content: extract_text(blocks),
      tool_calls: Enum.flat_map(blocks, &normalize_tool_use/1),
      provider_state: %{stop_reason: Map.get(body, "stop_reason"), content: blocks},
      usage: %{
        prompt_tokens: Map.get(usage, "input_tokens", 0),
        completion_tokens: Map.get(usage, "output_tokens", 0),
        total_tokens: Map.get(usage, "input_tokens", 0) + Map.get(usage, "output_tokens", 0)
      },
      model: Map.get(body, "model", "unknown")
    }
  end

  @impl true
  def supports_streaming?, do: false

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
