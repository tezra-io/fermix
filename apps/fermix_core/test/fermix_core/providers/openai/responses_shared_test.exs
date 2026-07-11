defmodule FermixCore.Providers.OpenAI.ResponsesSharedTest do
  use ExUnit.Case, async: true

  alias FermixCore.Capabilities.Capability
  alias FermixCore.Providers.OpenAI.ResponsesShared

  describe "request-metric split (turn-invariant tools hoist)" do
    # A capability whose schema carries enough bytes that tools_bytes is a
    # non-trivial, stable number across calls.
    defp cap(name) do
      %Capability{
        name: name,
        description: "description for #{name}",
        parameters: %{
          "type" => "object",
          "properties" => %{"q" => %{"type" => "string"}},
          "required" => ["q"]
        },
        kind: :builtin,
        executor: {Kernel, :is_map, []}
      }
    end

    defp tools_and_caps do
      caps = [cap("search"), cap("fetch")]
      tools = ResponsesShared.to_provider_tools(caps)
      {tools, caps}
    end

    test "request_metrics/4 == Map.merge(input_metrics, invariant_metrics), all 6 keys" do
      {tools, caps} = tools_and_caps()
      input = [%{role: "user", content: [%{type: "input_text", text: "hello there"}]}]
      instructions = "be concise"

      merged =
        Map.merge(
          ResponsesShared.input_metrics(input, instructions),
          ResponsesShared.invariant_metrics(tools, caps)
        )

      assert merged == ResponsesShared.request_metrics(input, instructions, tools, caps)

      assert Enum.sort(Map.keys(merged)) == [
               :capabilities_count,
               :input_bytes,
               :input_items,
               :instructions_bytes,
               :tools_bytes,
               :tools_count
             ]
    end

    test "continuation metric map is byte-identical to a fresh per-call computation" do
      {tools, caps} = tools_and_caps()

      # The continuation hoist: carry invariant_metrics from the initial call and
      # merge it onto the recomputed input_metrics for the (larger) next_input.
      carried_invariant = ResponsesShared.invariant_metrics(tools, caps)

      next_input = [
        %{role: "user", content: [%{type: "input_text", text: "first"}]},
        %{type: "function_call_output", call_id: "c1", output: "tool said x"},
        %{role: "user", content: [%{type: "input_text", text: "second turn"}]}
      ]

      hoisted = Map.merge(ResponsesShared.input_metrics(next_input, nil), carried_invariant)

      assert hoisted == ResponsesShared.request_metrics(next_input, nil, tools, caps)
    end

    test "invariant_metrics is independent of the input/instructions" do
      {tools, caps} = tools_and_caps()

      input_a = [%{role: "user", content: [%{type: "input_text", text: "a"}]}]
      input_b = [%{role: "user", content: [%{type: "input_text", text: "a much longer turn"}]}]

      from_a = ResponsesShared.request_metrics(input_a, "sys a", tools, caps)
      from_b = ResponsesShared.request_metrics(input_b, "sys b longer", tools, caps)

      invariant_keys = [:tools_count, :tools_bytes, :capabilities_count]

      assert Map.take(from_a, invariant_keys) ==
               Map.take(from_b, invariant_keys)

      assert Map.take(from_a, invariant_keys) == ResponsesShared.invariant_metrics(tools, caps)

      # The input-dependent fields DO differ, proving the split is real.
      assert from_a.input_bytes != from_b.input_bytes
    end
  end

  describe "build_input/1 multimodal content encoding" do
    test "text-only transcript is byte-identical to the pre-multimodal shape (prompt-cache stability)" do
      msgs = [
        %{role: "user", content: "hello world"},
        %{role: "assistant", content: "hi back"}
      ]

      {_instructions, input} = ResponsesShared.build_input(msgs)

      # Pinned literal — any future key added to a text part fails here loudly
      # rather than silently eroding cache hit rate.
      assert Jason.encode!(input) ==
               ~s([{"role":"user","content":[{"type":"input_text","text":"hello world"}]},{"role":"assistant","content":[{"type":"output_text","text":"hi back"}]}])
    end

    test "nil text content stays byte-identical (empty string)" do
      {_instructions, input} = ResponsesShared.build_input([%{role: "user", content: nil}])

      assert Jason.encode!(input) ==
               ~s([{"role":"user","content":[{"type":"input_text","text":""}]}])
    end

    test "a user turn with image_parts emits input_text + input_image (base64 data URI)" do
      png = <<137, 80, 78, 71>>

      msgs = [
        %{
          role: "user",
          content: "what is this?",
          image_parts: [%{type: :image, mime_type: "image/png", data: png}]
        }
      ]

      {_instructions, [item]} = ResponsesShared.build_input(msgs)

      assert item == %{
               role: "user",
               content: [
                 %{type: "input_text", text: "what is this?"},
                 %{type: "input_image", image_url: "data:image/png;base64," <> Base.encode64(png)}
               ]
             }
    end

    test "an unsupported image part fails loud (no silent drop)" do
      msgs = [%{role: "user", content: "x", image_parts: [%{type: :video, data: "x"}]}]

      assert_raise ArgumentError, ~r/unsupported image content part/, fn ->
        ResponsesShared.build_input(msgs)
      end
    end
  end

  describe "build_function_call_outputs/1" do
    test "text-only results are byte-identical to the pre-image shape (no extra items)" do
      assert ResponsesShared.build_function_call_outputs([%{call_id: "call_1", output: "echoed"}]) ==
               [%{type: "function_call_output", call_id: "call_1", output: "echoed"}]
    end

    test "an image-bearing result appends a subsequent user input_image item AFTER the output" do
      png = <<137, 80, 78, 71>>

      results = [
        %{
          call_id: "call_shot",
          output: "captured",
          images: [%{type: :image, mime_type: "image/png", data: png}]
        }
      ]

      assert ResponsesShared.build_function_call_outputs(results) == [
               %{type: "function_call_output", call_id: "call_shot", output: "captured"},
               %{
                 role: "user",
                 content: [
                   %{
                     type: "input_text",
                     text: "Screen state returned by the preceding tool call:"
                   },
                   %{
                     type: "input_image",
                     image_url: "data:image/png;base64," <> Base.encode64(png)
                   }
                 ]
               }
             ]
    end

    test "empty output + images uses a placeholder so the function_call_output is never empty" do
      results = [
        %{call_id: "c", output: "", images: [%{type: :image, mime_type: "image/png", data: "x"}]}
      ]

      assert [fco | _] = ResponsesShared.build_function_call_outputs(results)

      assert fco == %{
               type: "function_call_output",
               call_id: "c",
               output: "[screen state in the following message]"
             }
    end

    test "ordering: all function_call_outputs precede any user image item" do
      results = [
        %{call_id: "a", output: "no image"},
        %{
          call_id: "b",
          output: "shot",
          images: [%{type: :image, mime_type: "image/png", data: "z"}]
        }
      ]

      kinds =
        results
        |> ResponsesShared.build_function_call_outputs()
        |> Enum.map(fn
          %{type: type} -> type
          %{role: role} -> role
        end)

      assert kinds == ["function_call_output", "function_call_output", "user"]
    end
  end

  describe "retain_screenshots/2" do
    @label "Screen state returned by the preceding tool call:"
    @elided "[earlier screen state omitted to bound context]"

    defp screenshot_item(n) do
      %{
        role: "user",
        content: [
          %{type: "input_text", text: @label},
          %{type: "input_image", image_url: "data:image/png;base64,shot#{n}"}
        ]
      }
    end

    defp inbound_image_item do
      %{
        role: "user",
        content: [
          %{type: "input_text", text: "look at my photo"},
          %{type: "input_image", image_url: "data:image/png;base64,user"}
        ]
      }
    end

    test "nil keep returns the input unchanged" do
      input = [screenshot_item(1), screenshot_item(2)]
      assert ResponsesShared.retain_screenshots(input, nil) == input
    end

    test "keeps the most recent N screenshot items, elides the older bytes" do
      input = [
        %{type: "function_call_output", call_id: "a", output: "x"},
        screenshot_item(1),
        screenshot_item(2),
        screenshot_item(3)
      ]

      result = ResponsesShared.retain_screenshots(input, 1)

      # screenshots 1 and 2 lose their image bytes; only the newest (3) keeps them
      assert [_fco, elided1, elided2, kept] = result

      assert elided1.content == [%{type: "input_text", text: @elided}]
      assert elided2.content == [%{type: "input_text", text: @elided}]
      assert Enum.any?(kept.content, &match?(%{type: "input_image"}, &1))
    end

    test "an inbound user image (no screenshot label) is never elided" do
      input = [inbound_image_item(), screenshot_item(1), screenshot_item(2)]

      result = ResponsesShared.retain_screenshots(input, 1)

      # the user's own image is untouched; only the older screenshot is elided
      assert Enum.at(result, 0) == inbound_image_item()
      assert Enum.at(result, 1).content == [%{type: "input_text", text: @elided}]
      assert Enum.any?(Enum.at(result, 2).content, &match?(%{type: "input_image"}, &1))
    end
  end

  describe "maybe_reasoning_field/2" do
    test "returns nil for nil, :none, and \"none\" — caller omits the body field" do
      assert ResponsesShared.maybe_reasoning_field(nil, :openai) == nil
      assert ResponsesShared.maybe_reasoning_field(:none, :openai) == nil
      assert ResponsesShared.maybe_reasoning_field("none", :openai) == nil
    end

    test "returns %{effort: <string>} for each supported level (atom and string)" do
      for level <- [:low, :medium, :high, :xhigh] do
        assert ResponsesShared.maybe_reasoning_field(level, :openai) ==
                 %{effort: Atom.to_string(level)}

        assert ResponsesShared.maybe_reasoning_field(Atom.to_string(level), :openai) ==
                 %{effort: Atom.to_string(level)}
      end
    end

    test "sends :max verbatim on OpenAI-family (now a supported level, not clamped)" do
      assert ResponsesShared.maybe_reasoning_field(:max, :openai) == %{effort: "max"}
      assert ResponsesShared.maybe_reasoning_field(:max, :openai_codex) == %{effort: "max"}
    end

    test "raises ArgumentError on a removed level (minimal)" do
      assert_raise ArgumentError, ~r/invalid reasoning_effort: :minimal/, fn ->
        ResponsesShared.maybe_reasoning_field(:minimal, :openai)
      end
    end

    test "raises ArgumentError on an unknown string level" do
      assert_raise ArgumentError, ~r/invalid reasoning_effort: \"absurd\"/, fn ->
        ResponsesShared.maybe_reasoning_field("absurd", :openai)
      end
    end

    test "raises ArgumentError on a non-atom non-string value" do
      assert_raise ArgumentError, ~r/invalid reasoning_effort: 7/, fn ->
        ResponsesShared.maybe_reasoning_field(7, :openai)
      end
    end
  end

  describe "context_length_error?/1" do
    test "detects the context_length_exceeded error code (decoded map)" do
      body = %{"error" => %{"code" => "context_length_exceeded", "message" => "too long"}}
      assert ResponsesShared.context_length_error?(body)
    end

    test "detects the error code in a raw JSON string body" do
      body = ~s({"error":{"code":"context_length_exceeded","message":"too long"}})
      assert ResponsesShared.context_length_error?(body)
    end

    test "detects context-length wording when no machine code is present" do
      body = %{"error" => %{"message" => "This model's maximum context length is 400000 tokens."}}
      assert ResponsesShared.context_length_error?(body)
    end

    test "is case-insensitive on the message" do
      body = %{"error" => %{"message" => "Prompt is too long for the CONTEXT WINDOW"}}
      assert ResponsesShared.context_length_error?(body)
    end

    test "returns false for unrelated provider errors" do
      refute ResponsesShared.context_length_error?(%{
               "error" => %{"code" => "rate_limit_exceeded", "message" => "slow down"}
             })
    end

    test "returns false when error is a bare string (not a map)" do
      refute ResponsesShared.context_length_error?(%{"error" => "boom"})
    end

    test "returns false for non-error and malformed bodies" do
      refute ResponsesShared.context_length_error?(%{"output" => []})
      refute ResponsesShared.context_length_error?("not json")
      refute ResponsesShared.context_length_error?(nil)
    end
  end
end
