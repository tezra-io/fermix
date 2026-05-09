defmodule FermixCore.Providers.OpenAI.Codex.SSEParser do
  @moduledoc false

  # Parses a Codex Responses SSE body into a body-shaped map
  # `%{"output" => [items], "usage" => map(), "model" => string | nil}`
  # equivalent to what `OpenAI.Responses` receives synchronously, so the
  # downstream `ResponsesShared.build_turn/5` can be reused.
  #
  # Two entry points:
  #
  #   * `parse/1` — single-shot, takes the full SSE body as a binary.
  #   * `new/0` + `feed/2` + `finalize/1` — incremental, for use inside a
  #     `Req` `:into` callback. `feed/2` carries a `leftover` buffer for
  #     partial events that straddle chunk boundaries; `finalize/1` drains
  #     any tail and produces the body-shaped map.
  #
  # Event grammar handled (others are ignored):
  #
  #   * `response.created`                     — capture model
  #   * `response.output_item.added`           — register an in-progress item
  #     at `output_index`; init the per-item buffer for delta accumulation
  #   * `response.function_call_arguments.delta` — append to that item's
  #     arguments buffer
  #   * `response.output_text.delta`           — append to that item's text
  #     buffer
  #   * `response.output_item.done`            — finalize the item; the
  #     `item` field is the canonical finalized shape (Codex sends complete
  #     `arguments` / `content` here), but if those are missing we fall
  #     back to the buffered deltas
  #   * `response.completed` / `response.done` — capture final usage and
  #     final model id; if `response.output` is present it is used for
  #     usage/model only — items still come from `output_item.done` events
  #
  # Items are returned in `output_index` order.
  #
  # Tolerates malformed JSON lines (skipped) and out-of-order events
  # (last-write-wins for items, append-only for buffers). A truncated
  # stream returns whatever was finalized — no exception. Callers should
  # detect this by checking transport-level errors before calling parse/1.

  defstruct items: %{},
            arg_buffers: %{},
            text_buffers: %{},
            usage: %{},
            model: nil,
            leftover: ""

  @type t :: %__MODULE__{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec parse(binary()) :: %{required(String.t()) => term()}
  def parse(body) when is_binary(body) do
    new() |> feed(body) |> finalize()
  end

  @spec feed(t(), binary()) :: t()
  def feed(%__MODULE__{} = state, chunk) when is_binary(chunk) do
    buffer = state.leftover <> chunk
    {complete, leftover} = split_complete_events(buffer)

    events = Enum.flat_map(complete, &decode_chunk/1)
    state = Enum.reduce(events, state, &reduce_event/2)
    %{state | leftover: leftover}
  end

  @spec finalize(t()) :: %{required(String.t()) => term()}
  def finalize(%__MODULE__{leftover: ""} = state), do: build_body(state)

  def finalize(%__MODULE__{leftover: tail} = state) do
    events = decode_chunk(tail)
    state = Enum.reduce(events, %{state | leftover: ""}, &reduce_event/2)
    build_body(state)
  end

  defp split_complete_events(buffer) do
    case String.split(buffer, "\n\n") do
      [single] ->
        {[], single}

      parts ->
        {complete, [last]} = Enum.split(parts, length(parts) - 1)
        {complete, last}
    end
  end

  defp decode_chunk(chunk) do
    chunk
    |> String.split("\n", trim: true)
    |> Enum.flat_map(&decode_line/1)
  end

  defp decode_line("data: [DONE]"), do: []

  defp decode_line("data: " <> json) do
    case Jason.decode(json) do
      {:ok, event} when is_map(event) -> [event]
      _ -> []
    end
  end

  defp decode_line(_), do: []

  defp reduce_event(%{"type" => "response.created", "response" => resp}, state)
       when is_map(resp) do
    %{state | model: resp["model"] || state.model}
  end

  defp reduce_event(
         %{"type" => "response.output_item.added", "output_index" => idx, "item" => item},
         state
       )
       when is_map(item) do
    state
    |> put_item(idx, item)
    |> init_buffers(idx, item)
  end

  defp reduce_event(
         %{
           "type" => "response.function_call_arguments.delta",
           "output_index" => idx,
           "delta" => delta
         },
         state
       )
       when is_binary(delta) do
    %{state | arg_buffers: append_buffer(state.arg_buffers, idx, delta)}
  end

  defp reduce_event(
         %{"type" => "response.output_text.delta", "output_index" => idx, "delta" => delta},
         state
       )
       when is_binary(delta) do
    %{state | text_buffers: append_buffer(state.text_buffers, idx, delta)}
  end

  defp reduce_event(
         %{"type" => "response.output_item.done", "output_index" => idx, "item" => item},
         state
       )
       when is_map(item) do
    %{state | items: Map.put(state.items, idx, item)}
  end

  defp reduce_event(%{"type" => type, "response" => resp}, state)
       when type in ["response.completed", "response.done"] and is_map(resp) do
    %{
      state
      | usage: resp["usage"] || state.usage,
        model: resp["model"] || state.model
    }
  end

  defp reduce_event(_event, state), do: state

  defp put_item(state, idx, item) do
    %{state | items: Map.put(state.items, idx, item)}
  end

  defp init_buffers(state, idx, %{"type" => "function_call"}) do
    %{state | arg_buffers: Map.put_new(state.arg_buffers, idx, "")}
  end

  defp init_buffers(state, idx, %{"type" => "message"}) do
    %{state | text_buffers: Map.put_new(state.text_buffers, idx, "")}
  end

  defp init_buffers(state, _idx, _item), do: state

  defp append_buffer(buffers, idx, delta) do
    Map.update(buffers, idx, delta, &(&1 <> delta))
  end

  defp build_body(state) do
    output =
      state.items
      |> Enum.sort_by(fn {idx, _item} -> idx end)
      |> Enum.map(fn {idx, item} -> finalize_item(item, idx, state) end)

    %{
      "output" => output,
      "usage" => state.usage,
      "model" => state.model
    }
  end

  defp finalize_item(%{"type" => "function_call"} = item, idx, state) do
    item_args = item["arguments"]
    buffered = Map.get(state.arg_buffers, idx, "")

    args =
      cond do
        is_binary(item_args) and item_args != "" -> item_args
        buffered != "" -> buffered
        true -> "{}"
      end

    Map.put(item, "arguments", args)
  end

  defp finalize_item(%{"type" => "message"} = item, idx, state) do
    case item["content"] do
      [_ | _] ->
        item

      _ ->
        case Map.get(state.text_buffers, idx, "") do
          "" -> item
          text -> Map.put(item, "content", [%{"type" => "output_text", "text" => text}])
        end
    end
  end

  defp finalize_item(item, _idx, _state), do: item
end
