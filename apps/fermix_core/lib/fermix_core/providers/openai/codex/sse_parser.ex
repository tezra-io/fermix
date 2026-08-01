defmodule FermixCore.Providers.OpenAI.Codex.SSEParser do
  @moduledoc false

  # Parses a Codex Responses SSE body into a body-shaped map
  # `%{"output" => [items], "usage" => map(), "model" => string | nil,
  #    "status" => string | nil, "failure" => map() | nil}`
  # equivalent to what `OpenAI.Responses` receives synchronously, so the
  # downstream `ResponsesShared.build_turn/5` can be reused.
  #
  # `"status"` is nil until a TERMINAL event arrives, which is how the caller
  # tells a stream that ended early from one that finished with nothing to say —
  # `build_turn/5` cannot: it reads an absent usage map as zero tokens and an
  # empty output list as empty text, so both shapes render as a valid empty turn.
  # `"failure"` carries the terminal event's own account of why (`error` or
  # `incomplete_details`), which used to be dropped by the catch-all.
  #
  # Two entry points:
  #
  #   * `parse/1` — single-shot, takes the full SSE body as a binary.
  #   * `new/1` + `feed/2` + `finalize/1` — incremental, for use inside a
  #     `Req` `:into` callback. `feed/2` carries a `leftover` buffer for
  #     partial events that straddle chunk boundaries; `finalize/1` drains
  #     any tail and produces the body-shaped map.
  #
  # `new/1` accepts `delta_callback:` — a 1-arity function invoked with:
  #   * `{:text_delta, cumulative}` after each `response.output_text.delta`,
  #     where `cumulative` is the composed text across ALL output indices in
  #     index order (mirroring `ResponsesShared.extract_text/1`, so the
  #     streamed prefix always matches the final answer's composition);
  #   * `{:text_done, cumulative}` when a message output item completes — the
  #     SEMANTIC block boundary (one model "thought"/message), which block
  #     streaming uses instead of character counts;
  #   * `{:reasoning_done, summary}` when a reasoning item completes with a
  #     non-empty summary (the model's decision-making notes; requested via
  #     `reasoning.summary = "auto"`).
  # This is the provider delta seam for channel streaming
  # (docs/design/CHANNEL_STREAMING.md §5.2); the finalized-body path is
  # unaffected by the callback.
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
  #   * `response.failed` / `response.incomplete` / `error` — capture the
  #     status and the reason payload; these are the stream's own account of a
  #     response that will not complete, and ignoring them made a declared
  #     failure indistinguishable from a truncated connection
  #
  # Items are returned in `output_index` order.
  #
  # Tolerates malformed JSON lines (skipped) and out-of-order events
  # (last-write-wins for items, append-only for buffers). A truncated
  # stream returns whatever was finalized — no exception. Callers should
  # detect this by checking transport-level errors before calling parse/1.
  #
  # `leftover` is capped at `@max_leftover_bytes`. The only wall-clock bound on
  # this stream is an IDLE window (`Codex.receive_timeout_for/1`), which a peer
  # that trickles bytes never trips, so an event body that never reaches its
  # `\n\n` boundary would grow the binary for as long as the peer kept sending.
  #
  # Passing the cap latches `status: "failed"` + `failure` AND sets
  # `overflowed?`, which `Codex.collect_sse/3` reads to return `{:halt, acc}`.
  # The two halves are one fix: the cap bounds the MEMORY, the halt ends the
  # TRANSFER. Bounding memory alone leaves the request hanging forever on a
  # trickling peer — the conversation's single-flight slot and a pooled
  # connection held indefinitely, which is the denial the cap exists to close.
  # Anything parsed before the cap is still returned.
  #
  # What the caller does with the latched failure depends on what the turn
  # DELIVERED, and the two arms differ in how loud they are:
  #
  #   * nothing delivered — `Codex.undelivered_error/2` mints a `ProviderError`
  #     carrying this message, which `Agents.TurnRunner` quotes to the operator.
  #   * text or a tool call already delivered — `Codex.warn_truncated/3` logs a
  #     warning and RETURNS the turn, so the operator sees a possibly-truncated
  #     answer explained only in the log. That is deliberate, not an oversight:
  #     erroring would discard delivered content and dead-end a continuation,
  #     and no layer recovers it — `AgentLoop.continue_with_retry/3` runs
  #     `eligible?: fn _ -> false end`, and `Jobs.Runner` refuses the whole-loop
  #     replay once tools have started.

  @max_leftover_bytes 1_048_576

  defstruct items: %{},
            arg_buffers: %{},
            text_buffers: %{},
            composed: "",
            usage: %{},
            model: nil,
            status: nil,
            failure: nil,
            leftover: "",
            overflowed?: false,
            delta_callback: nil

  @type t :: %__MODULE__{}
  @type delta_callback :: ({:text_delta, String.t()} -> any())

  @spec new(keyword()) :: t()
  def new(opts \\ []) when is_list(opts) do
    %__MODULE__{delta_callback: validate_delta_callback(Keyword.get(opts, :delta_callback))}
  end

  defp validate_delta_callback(nil), do: nil
  defp validate_delta_callback(cb) when is_function(cb, 1), do: cb

  @spec parse(binary()) :: %{required(String.t()) => term()}
  def parse(body) when is_binary(body) do
    new() |> feed(body) |> finalize()
  end

  @spec feed(t(), binary()) :: t()
  def feed(%__MODULE__{overflowed?: true} = state, chunk) when is_binary(chunk), do: state

  def feed(%__MODULE__{} = state, chunk) when is_binary(chunk) do
    buffer = state.leftover <> chunk
    {complete, leftover} = split_complete_events(buffer)

    events = Enum.flat_map(complete, &decode_chunk/1)
    state = Enum.reduce(events, state, &reduce_event/2)
    bound_leftover(%{state | leftover: leftover})
  end

  defp bound_leftover(%__MODULE__{leftover: leftover} = state)
       when byte_size(leftover) <= @max_leftover_bytes,
       do: state

  # Latched, not merely cleared: a later `response.completed` arriving on the
  # same corrupt stream would otherwise overwrite `status` and turn an abandoned
  # response back into a silent success.
  defp bound_leftover(%__MODULE__{leftover: leftover} = state) do
    %{
      state
      | leftover: "",
        overflowed?: true,
        status: "failed",
        failure: %{
          "code" => "sse_event_too_large",
          "message" =>
            "Codex sent #{byte_size(leftover)} bytes of a single SSE event with no event " <>
              "boundary, past the #{@max_leftover_bytes}-byte parser ceiling. The rest of the " <>
              "stream was abandoned; whatever parsed before it is kept."
        }
    }
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
    buffers = append_buffer(state.text_buffers, idx, delta)

    state = %{
      state
      | text_buffers: buffers,
        composed: recompose(state.composed, buffers, idx, delta)
    }

    emit_text_delta(state)
    state
  end

  defp reduce_event(
         %{"type" => "response.output_item.done", "output_index" => idx, "item" => item},
         state
       )
       when is_map(item) do
    state = %{state | items: Map.put(state.items, idx, item)}
    emit_item_done(state, item)
    state
  end

  defp reduce_event(%{"type" => type, "response" => resp}, state)
       when type in ["response.completed", "response.done"] and is_map(resp) do
    %{
      state
      | usage: resp["usage"] || state.usage,
        model: resp["model"] || state.model,
        status: resp["status"] || "completed"
    }
  end

  # A response the server has given up on. It is terminal like `completed`, so it
  # sets `status` — but it carries no usage and no finished items, which is exactly
  # the shape a cut connection leaves. Recording the reason is the only thing that
  # tells them apart afterwards.
  defp reduce_event(%{"type" => type, "response" => resp}, state)
       when type in ["response.failed", "response.incomplete"] and is_map(resp) do
    %{
      state
      | status: resp["status"] || String.replace_prefix(type, "response.", ""),
        failure: resp["error"] || resp["incomplete_details"] || state.failure,
        # An `incomplete` response is billed for what it did generate, and the
        # caller now RETURNS that turn when output arrived — so its usage has to be
        # real, not the zero an absent map renders as.
        usage: resp["usage"] || state.usage,
        model: resp["model"] || state.model
    }
  end

  # A stream-level error carries its payload inline rather than under "response".
  defp reduce_event(%{"type" => "error"} = event, state),
    do: %{state | status: "failed", failure: Map.delete(event, "type")}

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

  defp emit_text_delta(%__MODULE__{delta_callback: nil}), do: :ok

  defp emit_text_delta(%__MODULE__{delta_callback: cb} = state) when is_function(cb, 1) do
    cb.({:text_delta, state.composed})
    :ok
  end

  defp emit_item_done(%__MODULE__{delta_callback: nil}, _item), do: :ok

  defp emit_item_done(%__MODULE__{delta_callback: cb} = state, %{"type" => "message"})
       when is_function(cb, 1) do
    cb.({:text_done, state.composed})
    :ok
  end

  defp emit_item_done(%__MODULE__{delta_callback: cb}, %{"type" => "reasoning"} = item)
       when is_function(cb, 1) do
    case reasoning_summary_text(item) do
      "" -> :ok
      summary -> cb.({:reasoning_done, summary})
    end

    :ok
  end

  defp emit_item_done(_state, _item), do: :ok

  defp reasoning_summary_text(%{"summary" => parts}) when is_list(parts) do
    parts
    |> Enum.flat_map(fn
      %{"text" => text} when is_binary(text) -> [text]
      _part -> []
    end)
    |> Enum.join("\n\n")
    |> String.trim()
  end

  defp reasoning_summary_text(_item), do: ""

  # `composed` is the text buffers joined in output-index order — the same
  # composition ResponsesShared.extract_text/1 applies to the finalized body.
  # Recomputing that join on EVERY delta re-copied the whole answer each time
  # (O(N x L) for an N-delta response) on the main agent's streaming path.
  #
  # A delta for the highest index so far only extends the tail, so it appends in
  # place; the Responses protocol produces output items sequentially, so that is
  # every delta of a real stream. A delta for an EARLIER index changes the middle
  # of the string, so the join is redone — the assumption that arrival order
  # equals index order does not hold universally and is pinned by test. Both arms
  # are the same function of `text_buffers`: the append is a cache of the join,
  # never a second answer.
  defp recompose(composed, buffers, idx, delta) do
    if idx == buffers |> Map.keys() |> Enum.max() do
      composed <> delta
    else
      join_in_index_order(buffers)
    end
  end

  defp join_in_index_order(buffers) do
    buffers
    |> Enum.sort_by(fn {idx, _text} -> idx end)
    |> Enum.map_join("", fn {_idx, text} -> text end)
  end

  defp build_body(state) do
    output =
      state.items
      |> Enum.sort_by(fn {idx, _item} -> idx end)
      |> Enum.map(fn {idx, item} -> finalize_item(item, idx, state) end)

    %{
      "output" => output,
      "usage" => state.usage,
      "model" => state.model,
      "status" => state.status,
      "failure" => state.failure
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
