defmodule FermixCore.Providers.OpenAI.Codex.SSEParserTest do
  use ExUnit.Case, async: true

  alias FermixCore.Providers.OpenAI.Codex.SSEParser

  describe "parse/1" do
    test "empty body returns empty output, empty usage, nil model, and no terminal status" do
      assert SSEParser.parse("") == %{
               "output" => [],
               "usage" => %{},
               "model" => nil,
               "status" => nil,
               "failure" => nil
             }
    end

    # `status` is the only thing separating "the stream ended early" from "the
    # model had nothing to say": both leave output and usage bare, and the caller
    # renders the second as a valid empty turn.
    test "a terminal completed event sets status" do
      sse = """
      data: {"type":"response.completed","response":{"model":"gpt-5","usage":{"input_tokens":2,"output_tokens":3}}}

      """

      assert SSEParser.parse(sse)["status"] == "completed"
    end

    test "a terminal event's own status wins over the event name" do
      sse = """
      data: {"type":"response.done","response":{"status":"incomplete","model":"gpt-5"}}

      """

      assert SSEParser.parse(sse)["status"] == "incomplete"
    end

    test "response.failed keeps the server's error payload" do
      sse = """
      data: {"type":"response.failed","response":{"status":"failed","error":{"code":"server_error","message":"upstream blew up"}}}

      """

      result = SSEParser.parse(sse)
      assert result["status"] == "failed"
      assert result["failure"] == %{"code" => "server_error", "message" => "upstream blew up"}
      assert result["usage"] == %{}
    end

    test "response.incomplete keeps its reason" do
      sse = """
      data: {"type":"response.incomplete","response":{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"}}}

      """

      result = SSEParser.parse(sse)
      assert result["status"] == "incomplete"
      assert result["failure"] == %{"reason" => "max_output_tokens"}
    end

    test "a stream-level error event carries its inline payload" do
      sse = """
      data: {"type":"error","code":"rate_limit_exceeded","message":"slow down"}

      """

      result = SSEParser.parse(sse)
      assert result["status"] == "failed"
      assert result["failure"] == %{"code" => "rate_limit_exceeded", "message" => "slow down"}
    end

    # The pairing matters more than either half: a cut stream reports NO terminal
    # status while still carrying output. `items` fills from output_item.added/.done,
    # which are independent of `response.completed`, so "no status" must never be
    # read as "nothing arrived".
    test "a stream cut after real output reports no terminal status but keeps the output" do
      sse = """
      data: {"type":"response.output_item.added","output_index":0,"item":{"type":"message","content":[]}}

      data: {"type":"response.output_text.delta","output_index":0,"delta":"partial"}

      """

      result = SSEParser.parse(sse)
      assert result["status"] == nil
      assert result["usage"] == %{}
      assert [%{"type" => "message"}] = result["output"]
    end

    test "a declared failure after real output keeps both the output and the reason" do
      sse = """
      data: {"type":"response.output_item.added","output_index":0,"item":{"type":"message","content":[]}}

      data: {"type":"response.output_item.done","output_index":0,"item":{"type":"message","content":[{"type":"output_text","text":"done bit"}]}}

      data: {"type":"response.failed","response":{"status":"failed","error":{"message":"upstream died"}}}

      """

      result = SSEParser.parse(sse)
      assert result["status"] == "failed"
      assert result["failure"] == %{"message" => "upstream died"}
      assert length(result["output"]) == 1
    end

    # The caller returns this turn, so it must be billed for what it generated.
    test "an incomplete response's usage is kept, not read as zero" do
      sse = """
      data: {"type":"response.incomplete","response":{"status":"incomplete","model":"gpt-5","usage":{"input_tokens":900,"output_tokens":40},"incomplete_details":{"reason":"max_output_tokens"}}}

      """

      result = SSEParser.parse(sse)
      assert result["usage"] == %{"input_tokens" => 900, "output_tokens" => 40}
      assert result["model"] == "gpt-5"
    end

    test "skips malformed JSON lines and unknown event types without raising" do
      sse = """
      data: {garbage}

      data: {"type":"unknown.event","output_index":7}

      : a comment line

      data: {"type":"response.completed","response":{"model":"gpt-5","usage":{"input_tokens":2,"output_tokens":3}}}

      data: [DONE]

      """

      result = SSEParser.parse(sse)
      assert result["output"] == []
      assert result["usage"] == %{"input_tokens" => 2, "output_tokens" => 3}
      assert result["model"] == "gpt-5"
    end

    test "out-of-order output_item.done events still produce items in output_index order" do
      sse = """
      data: {"type":"response.output_item.done","output_index":2,"item":{"type":"function_call","id":"fc_2","call_id":"call_2","name":"x","arguments":"{}"}}

      data: {"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","id":"fc_0","call_id":"call_0","name":"x","arguments":"{}"}}

      data: {"type":"response.output_item.done","output_index":1,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"x","arguments":"{}"}}

      data: [DONE]

      """

      assert %{"output" => items} = SSEParser.parse(sse)
      assert Enum.map(items, & &1["call_id"]) == ["call_0", "call_1", "call_2"]
    end

    test "function_call arguments fall back to deltas when item.arguments is empty" do
      sse = """
      data: {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","id":"fc_a","call_id":"call_a","name":"echo","arguments":""}}

      data: {"type":"response.function_call_arguments.delta","output_index":0,"delta":"{\\"k\\":1}"}

      data: {"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","id":"fc_a","call_id":"call_a","name":"echo","arguments":""}}

      data: [DONE]

      """

      assert %{"output" => [item]} = SSEParser.parse(sse)
      assert item["arguments"] == "{\"k\":1}"
    end

    test "function_call arguments default to {} when neither item.arguments nor deltas are present" do
      sse = """
      data: {"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","id":"fc_a","call_id":"call_a","name":"echo"}}

      data: [DONE]

      """

      assert %{"output" => [item]} = SSEParser.parse(sse)
      assert item["arguments"] == "{}"
    end

    test "message item content is built from output_text deltas when item.content is empty" do
      sse = """
      data: {"type":"response.output_item.added","output_index":0,"item":{"type":"message","id":"msg_1","content":[]}}

      data: {"type":"response.output_text.delta","output_index":0,"delta":"hi "}

      data: {"type":"response.output_text.delta","output_index":0,"delta":"world"}

      data: {"type":"response.output_item.done","output_index":0,"item":{"type":"message","id":"msg_1","content":[]}}

      data: [DONE]

      """

      assert %{"output" => [msg]} = SSEParser.parse(sse)
      assert msg["content"] == [%{"type" => "output_text", "text" => "hi world"}]
    end

    test "message item with non-empty content from output_item.done is preserved verbatim" do
      sse = """
      data: {"type":"response.output_item.done","output_index":0,"item":{"type":"message","id":"msg_1","content":[{"type":"output_text","text":"final"}]}}

      data: [DONE]

      """

      assert %{"output" => [msg]} = SSEParser.parse(sse)
      assert msg["content"] == [%{"type" => "output_text", "text" => "final"}]
    end

    test "reasoning items pass through encrypted_content unchanged" do
      sse = """
      data: {"type":"response.output_item.done","output_index":0,"item":{"type":"reasoning","id":"rs_1","encrypted_content":"abc123"}}

      data: [DONE]

      """

      assert %{"output" => [reasoning]} = SSEParser.parse(sse)
      assert reasoning["type"] == "reasoning"
      assert reasoning["encrypted_content"] == "abc123"
    end

    test "response.created provides model when response.completed omits one" do
      sse = """
      data: {"type":"response.created","response":{"model":"gpt-5"}}

      data: {"type":"response.completed","response":{"usage":{"input_tokens":1,"output_tokens":1}}}

      data: [DONE]

      """

      assert SSEParser.parse(sse)["model"] == "gpt-5"
    end

    test "response.done is treated equivalently to response.completed" do
      sse = """
      data: {"type":"response.done","response":{"model":"gpt-5","usage":{"input_tokens":2,"output_tokens":4}}}

      data: [DONE]

      """

      result = SSEParser.parse(sse)
      assert result["usage"] == %{"input_tokens" => 2, "output_tokens" => 4}
      assert result["model"] == "gpt-5"
    end
  end

  describe "feed/2 + finalize/1 — streaming API" do
    @sse_body """
    data: {"type":"response.created","response":{"model":"gpt-5"}}

    data: {"type":"response.output_item.added","output_index":0,"item":{"type":"message","id":"msg_1","content":[]}}

    data: {"type":"response.output_text.delta","output_index":0,"delta":"hi "}

    data: {"type":"response.output_text.delta","output_index":0,"delta":"world"}

    data: {"type":"response.output_item.done","output_index":0,"item":{"type":"message","id":"msg_1","content":[]}}

    data: {"type":"response.completed","response":{"usage":{"input_tokens":2,"output_tokens":3}}}

    data: [DONE]

    """

    test "single feed reproduces parse/1 result" do
      streamed = SSEParser.new() |> SSEParser.feed(@sse_body) |> SSEParser.finalize()
      assert streamed == SSEParser.parse(@sse_body)
    end

    test "byte-by-byte feed reproduces parse/1 result" do
      streamed =
        @sse_body
        |> :binary.bin_to_list()
        |> Enum.reduce(SSEParser.new(), fn byte, acc ->
          SSEParser.feed(acc, <<byte>>)
        end)
        |> SSEParser.finalize()

      assert streamed == SSEParser.parse(@sse_body)
    end

    test "chunks straddling event boundaries reproduce parse/1 result" do
      mid = div(byte_size(@sse_body), 2)
      <<first::binary-size(mid), rest::binary>> = @sse_body

      streamed =
        SSEParser.new()
        |> SSEParser.feed(first)
        |> SSEParser.feed(rest)
        |> SSEParser.finalize()

      assert streamed == SSEParser.parse(@sse_body)
    end

    test "buffer holds partial event until next feed completes it" do
      # Split right inside the JSON of the second event.
      partial_first = "data: {\"type\":\"response.created\",\"response\":{\"model\":"
      rest_first = "\"gpt-5\"}}\n\ndata: [DONE]\n\n"

      state = SSEParser.new() |> SSEParser.feed(partial_first)
      assert state.leftover == partial_first
      assert state.model == nil

      finalized = state |> SSEParser.feed(rest_first) |> SSEParser.finalize()
      assert finalized["model"] == "gpt-5"
    end

    test "finalize drains a tail without trailing blank line" do
      # Truncated stream — no trailing \n\n on the last event.
      truncated = "data: {\"type\":\"response.created\",\"response\":{\"model\":\"gpt-5\"}}"

      finalized = SSEParser.new() |> SSEParser.feed(truncated) |> SSEParser.finalize()
      assert finalized["model"] == "gpt-5"
    end
  end

  describe "new/1 with delta_callback" do
    defp text_delta_event(idx, delta) do
      "data: " <>
        Jason.encode!(%{
          "type" => "response.output_text.delta",
          "output_index" => idx,
          "delta" => delta
        }) <> "\n\n"
    end

    defp collect_deltas(sse_chunks) do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      cb = fn event -> Agent.update(agent, &[event | &1]) end

      state =
        Enum.reduce(sse_chunks, SSEParser.new(delta_callback: cb), &SSEParser.feed(&2, &1))

      events = Agent.get(agent, &Enum.reverse/1)
      Agent.stop(agent)
      {state, events}
    end

    test "fires {:text_delta, cumulative} per output_text.delta with growing cumulative" do
      chunks = [
        text_delta_event(0, "Hel"),
        text_delta_event(0, "lo "),
        text_delta_event(0, "world")
      ]

      {_state, events} = collect_deltas(chunks)

      assert events == [
               {:text_delta, "Hel"},
               {:text_delta, "Hello "},
               {:text_delta, "Hello world"}
             ]
    end

    test "cumulative composes across output indices in index order" do
      # Two message items; deltas interleave. The cumulative snapshot must be
      # the index-ordered join — matching ResponsesShared.extract_text/1's
      # composition of the finalized body — never just the changed index.
      chunks = [
        text_delta_event(2, "Second part."),
        text_delta_event(0, "First "),
        text_delta_event(0, "part. ")
      ]

      {_state, events} = collect_deltas(chunks)

      assert events == [
               {:text_delta, "Second part."},
               {:text_delta, "First Second part."},
               {:text_delta, "First part. Second part."}
             ]
    end

    test "function_call argument deltas do not fire the callback" do
      arg_delta =
        "data: " <>
          Jason.encode!(%{
            "type" => "response.function_call_arguments.delta",
            "output_index" => 0,
            "delta" => "{\"k\":1}"
          }) <> "\n\n"

      {_state, events} = collect_deltas([arg_delta])
      assert events == []
    end

    test "new/0 still parses without a callback" do
      state = SSEParser.new() |> SSEParser.feed(text_delta_event(0, "hi"))
      assert state.text_buffers == %{0 => "hi"}
    end

    test "new/1 rejects a non-function callback" do
      assert_raise FunctionClauseError, fn ->
        SSEParser.new(delta_callback: :not_a_fun)
      end
    end

    test "a completed message item fires {:text_done, composed} — the semantic block boundary" do
      done_event =
        "data: " <>
          Jason.encode!(%{
            "type" => "response.output_item.done",
            "output_index" => 0,
            "item" => %{
              "type" => "message",
              "id" => "msg_1",
              "content" => [%{"type" => "output_text", "text" => "Hello world"}]
            }
          }) <> "\n\n"

      {_state, events} =
        collect_deltas([text_delta_event(0, "Hello"), text_delta_event(0, " world"), done_event])

      assert events == [
               {:text_delta, "Hello"},
               {:text_delta, "Hello world"},
               {:text_done, "Hello world"}
             ]
    end

    test "a completed reasoning item fires {:reasoning_done, summary}" do
      reasoning_done =
        "data: " <>
          Jason.encode!(%{
            "type" => "response.output_item.done",
            "output_index" => 0,
            "item" => %{
              "type" => "reasoning",
              "summary" => [
                %{"type" => "summary_text", "text" => "Deciding to check the calendar first."},
                %{"type" => "summary_text", "text" => "Then summarize."}
              ]
            }
          }) <> "\n\n"

      {_state, events} = collect_deltas([reasoning_done])

      assert events == [
               {:reasoning_done, "Deciding to check the calendar first.\n\nThen summarize."}
             ]
    end

    test "a reasoning item without summary text fires nothing" do
      bare_reasoning =
        "data: " <>
          Jason.encode!(%{
            "type" => "response.output_item.done",
            "output_index" => 0,
            "item" => %{"type" => "reasoning", "summary" => [], "encrypted_content" => "xx"}
          }) <> "\n\n"

      {_state, events} = collect_deltas([bare_reasoning])
      assert events == []
    end

    # Reimplements the pre-accumulator composition — a fresh index-ordered join
    # after every delta — so the accumulated `composed` is PROVED byte-identical
    # rather than assumed to be. The interleaved scripts matter: arrival order is
    # not index order in general, which is exactly the assumption a naive
    # append-only accumulator would have silently broken.
    defp reference_cumulatives(deltas) do
      deltas
      |> Enum.reduce({%{}, []}, fn {idx, text}, {buffers, acc} ->
        buffers = Map.update(buffers, idx, text, &(&1 <> text))

        joined =
          buffers
          |> Enum.sort_by(fn {i, _text} -> i end)
          |> Enum.map_join("", fn {_i, text} -> text end)

        {buffers, [joined | acc]}
      end)
      |> elem(1)
      |> Enum.reverse()
    end

    test "multi-delta composition is byte-identical to a fresh index-ordered join" do
      scripts = [
        [{0, "Hel"}, {0, "lo "}, {0, "world"}],
        [{0, "First "}, {0, "part. "}, {1, "Second "}, {1, "part."}],
        [{0, "a"}, {2, "b"}, {2, "c"}, {5, "d"}],
        [{2, "Second part."}, {0, "First "}, {0, "part. "}],
        [{1, "b"}, {0, "a"}, {2, "c"}, {0, "!"}],
        [{0, "héllo "}, {0, "🚀"}, {1, " 世界"}, {0, " —"}]
      ]

      for deltas <- scripts do
        chunks = Enum.map(deltas, fn {idx, text} -> text_delta_event(idx, text) end)
        {_state, events} = collect_deltas(chunks)

        assert Enum.map(events, fn {:text_delta, cumulative} -> cumulative end) ==
                 reference_cumulatives(deltas),
               "script: #{inspect(deltas)}"
      end
    end

    test "the last streamed cumulative equals the finalized body's message text" do
      added =
        "data: " <>
          Jason.encode!(%{
            "type" => "response.output_item.added",
            "output_index" => 0,
            "item" => %{"type" => "message", "id" => "msg_1", "content" => []}
          }) <> "\n\n"

      done =
        "data: " <>
          Jason.encode!(%{
            "type" => "response.output_item.done",
            "output_index" => 0,
            "item" => %{"type" => "message", "id" => "msg_1", "content" => []}
          }) <> "\n\n"

      chunks = [added, text_delta_event(0, "Hello "), text_delta_event(0, "world"), done]
      {state, events} = collect_deltas(chunks)

      assert {:text_delta, last_cumulative} =
               events |> Enum.filter(&match?({:text_delta, _text}, &1)) |> List.last()

      assert %{"output" => [msg]} = SSEParser.finalize(state)
      assert msg["content"] == [%{"type" => "output_text", "text" => last_cumulative}]
    end

    test "function_call item completion fires nothing" do
      fc_done =
        "data: " <>
          Jason.encode!(%{
            "type" => "response.output_item.done",
            "output_index" => 0,
            "item" => %{
              "type" => "function_call",
              "call_id" => "c1",
              "name" => "x",
              "arguments" => "{}"
            }
          }) <> "\n\n"

      {_state, events} = collect_deltas([fc_done])
      assert events == []
    end
  end

  # The shipped ceiling, hardcoded on purpose: the only wall-clock bound on this
  # stream is an IDLE window, so a peer that trickles bytes without ever closing
  # an event is bounded by this constant alone.
  describe "leftover ceiling" do
    @cap 1_048_576

    defp unterminated_event(payload_bytes) do
      ~s(data: {"type":"response.output_text.delta","output_index":0,"delta":") <>
        String.duplicate("x", payload_bytes)
    end

    defp message_done_event(text) do
      "data: " <>
        Jason.encode!(%{
          "type" => "response.output_item.done",
          "output_index" => 0,
          "item" => %{
            "type" => "message",
            "id" => "msg_1",
            "content" => [%{"type" => "output_text", "text" => text}]
          }
        }) <> "\n\n"
    end

    test "an event that never reaches its boundary is abandoned past the ceiling" do
      state = SSEParser.new() |> SSEParser.feed(unterminated_event(@cap + 1))
      body = SSEParser.finalize(state)

      assert state.leftover == ""
      assert body["status"] == "failed"
      assert body["failure"]["code"] == "sse_event_too_large"
      assert body["failure"]["message"] =~ "no event boundary"
    end

    test "the ceiling holds when the oversized event arrives across many chunks" do
      opened = SSEParser.new() |> SSEParser.feed(~s(data: {"type":"x","d":"))
      chunk = String.duplicate("y", 64 * 1024)

      state =
        Enum.reduce(1..32, opened, fn _i, acc ->
          next = SSEParser.feed(acc, chunk)
          assert byte_size(next.leftover) <= @cap
          next
        end)

      assert SSEParser.finalize(state)["status"] == "failed"
    end

    test "content parsed before the ceiling is kept" do
      body =
        SSEParser.new()
        |> SSEParser.feed(message_done_event("delivered"))
        |> SSEParser.feed(unterminated_event(@cap + 1))
        |> SSEParser.finalize()

      assert body["status"] == "failed"
      assert [%{"type" => "message", "content" => [%{"text" => "delivered"}]}] = body["output"]
    end

    # Clearing the buffer without latching would let the very next event rewrite
    # `status` and turn an abandoned response back into a silent success.
    test "a later terminal event cannot resurrect an abandoned stream" do
      completed =
        ~s(data: {"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":1}}}\n\n)

      body =
        SSEParser.new()
        |> SSEParser.feed(unterminated_event(@cap + 1))
        |> SSEParser.feed(completed)
        |> SSEParser.finalize()

      assert body["status"] == "failed"
      assert body["usage"] == %{}
    end

    test "a large event that DOES reach its boundary under the ceiling parses normally" do
      text = String.duplicate("z", 900 * 1024)

      event =
        "data: " <>
          Jason.encode!(%{"type" => "response.created", "response" => %{"model" => text}})

      state =
        SSEParser.new()
        |> SSEParser.feed(event)
        |> SSEParser.feed("\n\n")

      body = SSEParser.finalize(state)

      assert body["status"] == nil
      assert body["failure"] == nil
      assert body["model"] == text
    end

    # `overflowed?` is the flag `Codex.collect_sse/3` reads to return
    # `{:halt, acc}`. The cap bounds memory only; without a reader that stops
    # the transfer the request never returns at all, so the flag has to survive
    # into the state the collector inspects — not just clear the buffer.
    test "the abandoned state is flagged, so the collector can stop the transfer" do
      abandoned = SSEParser.new() |> SSEParser.feed(unterminated_event(@cap + 1))
      healthy = SSEParser.new() |> SSEParser.feed(message_done_event("fine"))

      assert abandoned.overflowed?
      refute healthy.overflowed?
    end
  end
end
