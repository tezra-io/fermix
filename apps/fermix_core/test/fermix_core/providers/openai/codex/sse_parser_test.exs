defmodule FermixCore.Providers.OpenAI.Codex.SSEParserTest do
  use ExUnit.Case, async: true

  alias FermixCore.Providers.OpenAI.Codex.SSEParser

  describe "parse/1" do
    test "empty body returns empty output, empty usage, nil model" do
      assert SSEParser.parse("") == %{"output" => [], "usage" => %{}, "model" => nil}
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
end
