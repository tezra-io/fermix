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
end
