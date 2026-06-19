defmodule FermixCore.Providers.OpenAI.ResponsesSharedTest do
  use ExUnit.Case, async: true

  alias FermixCore.Providers.OpenAI.ResponsesShared

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

    test "clamps a level above the provider ceiling (:max -> xhigh on OpenAI-family)" do
      assert ResponsesShared.maybe_reasoning_field(:max, :openai) == %{effort: "xhigh"}
      assert ResponsesShared.maybe_reasoning_field(:max, :openai_codex) == %{effort: "xhigh"}
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
