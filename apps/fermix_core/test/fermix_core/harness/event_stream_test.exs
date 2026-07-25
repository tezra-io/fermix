defmodule FermixCore.Harness.EventStreamTest do
  # Pure module — no processes, no I/O, no global state.
  use ExUnit.Case, async: true

  alias FermixCore.Harness.EventStream

  @fixtures Path.join([__DIR__, "..", "..", "fixtures", "harness"])

  # Vendor terminal predicates live in the tests for P0 (the P1 adapters own them).
  defp codex_terminal, do: fn event -> event["type"] in ["turn.completed", "turn.failed"] end
  defp claude_terminal, do: fn event -> event["type"] == "result" end

  describe "recorded codex streams" do
    test "success: exit 0 with turn.completed is :completed, error items stay events" do
      data = fixture("codex_exec_success.jsonl")
      {emitted, state} = replay(data, 0, codex_terminal())
      summary = EventStream.finalize(state, 0)

      assert summary.outcome == :completed
      assert summary.terminal_seen?
      assert summary.framing_errors == 0
      assert summary.diagnostics_tail == []
      assert summary.events == object_lines(data)

      # A codex `item.completed` carrying an `item.type: "error"` is an event, not a
      # failed run: the outcome above stays :completed.
      assert Enum.any?(events(emitted), fn e -> get_in(e, ["item", "type"]) == "error" end)
    end

    test "failure: non-zero exit dominates even though turn.failed is terminal" do
      data = fixture("codex_exec_failure.jsonl")
      {emitted, state} = replay(data, 0, codex_terminal())
      summary = EventStream.finalize(state, 1)

      assert summary.outcome == {:failed, {:exit, 1}}
      assert summary.terminal_seen?
      assert summary.events == object_lines(data)
      assert Enum.any?(events(emitted), fn e -> e["type"] == "error" end)
    end
  end

  describe "recorded claude streams" do
    test "success: exit 0 with a result event is :completed; unknown types pass through" do
      data = fixture("claude_stream_success.jsonl")
      {emitted, state} = replay(data, 0, claude_terminal())
      summary = EventStream.finalize(state, 0)

      assert summary.outcome == :completed
      assert summary.terminal_seen?
      assert summary.diagnostics_tail == []
      assert summary.events == object_lines(data)

      # Operator hook + rate-limit events are unknown types, emitted verbatim.
      types = Enum.map(events(emitted), & &1["type"])
      assert "system" in types
      assert "rate_limit_event" in types
    end

    test "failure: result is not the last line and subtype is unreliable, exit wins" do
      data = fixture("claude_stream_failure.jsonl")
      {emitted, state} = replay(data, 0, claude_terminal())
      summary = EventStream.finalize(state, 1)

      assert summary.outcome == {:failed, {:exit, 1}}
      # Terminal detection is position-independent: a hook_response trails `result`.
      assert summary.terminal_seen?
      es = events(emitted)
      assert List.last(es)["type"] != "result"
      result = Enum.find(es, fn e -> e["type"] == "result" end)
      assert result["subtype"] == "success"
      assert result["is_error"] == true
    end
  end

  describe "pathological chunk boundaries (deterministic)" do
    test "every fixture reassembles identically at 1/2/3/7/13-byte chunks" do
      cases = [
        {"codex_exec_success.jsonl", codex_terminal(), 0, :completed},
        {"codex_exec_failure.jsonl", codex_terminal(), 1, {:failed, {:exit, 1}}},
        {"claude_stream_success.jsonl", claude_terminal(), 0, :completed},
        {"claude_stream_failure.jsonl", claude_terminal(), 1, {:failed, {:exit, 1}}}
      ]

      for {name, terminal, exit_code, outcome} <- cases, chunk_size <- [1, 2, 3, 7, 13] do
        data = fixture(name)
        {emitted, state} = replay(data, chunk_size, terminal)
        summary = EventStream.finalize(state, exit_code)

        assert summary.outcome == outcome, "#{name} @#{chunk_size}b"
        assert summary.events == object_lines(data), "#{name} @#{chunk_size}b"
        assert summary.diagnostics_tail == [], "#{name} @#{chunk_size}b"
        assert length(events(emitted)) == object_lines(data), "#{name} @#{chunk_size}b"
      end
    end

    test "a byte-split inside a multi-byte UTF-8 sequence reassembles losslessly" do
      # The recorded fixtures are pure ASCII, so their 1-byte replay never cuts a
      # multi-byte codepoint. This deterministic case forces splits mid-sequence
      # (é = 2 bytes, — = 3 bytes, 🚀 = 4 bytes, 世界 = 3 bytes each): a byte-level
      # splitter must buffer the partial line until the next byte completes it and
      # decode the event text byte-identically. A naive String-based split corrupts.
      text = "héllo — 🚀 世界"
      data = ~s({"type":"assistant","text":#{Jason.encode!(text)}}\n{"type":"result"}\n)

      for chunk_size <- [1, 2] do
        {emitted, state} = replay(data, chunk_size, claude_terminal())
        summary = EventStream.finalize(state, 0)

        assert summary.outcome == :completed, "@#{chunk_size}b"
        assert summary.events == 2, "@#{chunk_size}b"
        assert summary.diagnostics_tail == [], "@#{chunk_size}b"

        [assistant | _] = events(emitted)
        assert assistant["text"] == text, "@#{chunk_size}b"
      end
    end
  end

  describe "classification" do
    test "a JSON object line is an event, valid non-object and non-JSON lines are diagnostics" do
      stream = new(claude_terminal())
      chunk = ~s({"type":"assistant"}\n[1,2,3]\n"a string"\n42\nplain stderr noise\n)

      assert {:ok, emitted, state} = EventStream.push(stream, chunk)
      summary = EventStream.finalize(state, 0)

      assert [{:event, %{"type" => "assistant"}} | diags] = emitted

      assert diags == [
               {:diagnostic, "[1,2,3]"},
               {:diagnostic, ~s("a string")},
               {:diagnostic, "42"},
               {:diagnostic, "plain stderr noise"}
             ]

      assert summary.events == 1
      assert summary.framing_errors == 0
      assert summary.diagnostics_tail == ["[1,2,3]", ~s("a string"), "42", "plain stderr noise"]
    end

    test "malformed JSON within budget is a diagnostic, not a framing error" do
      stream = new(claude_terminal())
      chunk = ~s({bad json\n{"type":"result"}\n)

      assert {:ok, emitted, state} = EventStream.push(stream, chunk)
      summary = EventStream.finalize(state, 0)

      assert emitted == [{:diagnostic, "{bad json"}, {:event, %{"type" => "result"}}]
      assert summary.outcome == :completed
      assert summary.framing_errors == 0
    end

    test "empty lines are ignored (no event, no diagnostic)" do
      stream = new(claude_terminal())

      assert {:ok, emitted, state} = EventStream.push(stream, ~s(\n\n{"type":"result"}\n\n))
      summary = EventStream.finalize(state, 0)

      assert emitted == [{:event, %{"type" => "result"}}]
      assert summary.events == 1
      assert summary.diagnostics_tail == []
      assert summary.outcome == :completed
    end

    test "interleaved diagnostics keep chronological order and do not break events" do
      stream = new(codex_terminal())

      chunk =
        "noise A\n" <>
          ~s({"type":"turn.started"}\n) <> "noise B\n" <> ~s({"type":"turn.completed"}\n)

      assert {:ok, _emitted, state} = EventStream.push(stream, chunk)
      summary = EventStream.finalize(state, 0)

      assert summary.events == 2
      assert summary.diagnostics_tail == ["noise A", "noise B"]
      assert summary.outcome == :completed
    end

    test "diagnostics ring keeps only the last 50 lines, chronologically" do
      stream = new(claude_terminal())
      chunk = 1..60 |> Enum.map_join(fn n -> "noise #{n}\n" end)

      assert {:ok, _emitted, state} = EventStream.push(stream, chunk)
      summary = EventStream.finalize(state, 0)

      assert length(summary.diagnostics_tail) == 50
      assert List.first(summary.diagnostics_tail) == "noise 11"
      assert List.last(summary.diagnostics_tail) == "noise 60"
    end
  end

  describe "framing budget" do
    test "an oversized completed line counts one framing error but does not fail alone" do
      stream = new(claude_terminal(), max_event_bytes: 5)

      assert {:ok, [], state} = EventStream.push(stream, "toolongline\n")
      summary = EventStream.finalize(state, 0)

      assert summary.framing_errors == 1
      # No terminal seen and exit 0 -> protocol failure (the matrix, independent of framing).
      assert summary.outcome == {:failed, :protocol}
    end

    test "exceeding the framing budget surfaces {:error, {:protocol, _}} from push" do
      stream = new(claude_terminal(), max_event_bytes: 5, max_framing_errors: 2)
      chunk = "aaaaaaaa\nbbbbbbbb\ncccccccc\n"

      assert {:error, {:protocol, {:framing_budget_exceeded, 3}}, state} =
               EventStream.push(stream, chunk)

      assert state.framing_errors == 3
    end
  end

  describe "outcome matrix" do
    test "exit 0 without the terminal event is a protocol failure" do
      stream = new(codex_terminal())
      assert {:ok, _emitted, state} = EventStream.push(stream, ~s({"type":"turn.started"}\n))
      assert EventStream.finalize(state, 0).outcome == {:failed, :protocol}
    end

    test "a truncated final line (terminal cut mid-line) + exit 0 is a protocol failure" do
      stream = new(codex_terminal())
      # Terminal event cut mid-line: the partial buffer parses as neither object nor JSON.
      assert {:ok, emitted, state} =
               EventStream.push(stream, ~s({"type":"turn.started"}\n{"type":"turn.comp))

      assert emitted == [{:event, %{"type" => "turn.started"}}]
      summary = EventStream.finalize(state, 0)

      assert summary.outcome == {:failed, :protocol}
      refute summary.terminal_seen?
      assert summary.diagnostics_tail == [~s({"type":"turn.comp)]
    end

    test "a partial final line that is a valid terminal object completes the run" do
      stream = new(claude_terminal())
      # No trailing newline: the whole terminal event sits in the buffer at finalize.
      assert {:ok, [], state} = EventStream.push(stream, ~s({"type":"result"}))
      summary = EventStream.finalize(state, 0)

      assert summary.outcome == :completed
      assert summary.terminal_seen?
      assert summary.events == 1
    end

    test "a non-zero exit dominates a clean, terminal stream" do
      stream = new(claude_terminal())
      assert {:ok, _emitted, state} = EventStream.push(stream, ~s({"type":"result"}\n))
      assert EventStream.finalize(state, 3).outcome == {:failed, {:exit, 3}}
    end

    test "an empty stream with exit 0 is a protocol failure with zero events" do
      summary = EventStream.finalize(new(codex_terminal()), 0)
      assert summary.outcome == {:failed, :protocol}
      assert summary.events == 0
      assert summary.diagnostics_tail == []
    end
  end

  describe "new/1 validation" do
    test "rejects a non-positive max_event_bytes" do
      assert_raise ArgumentError, ~r/max_event_bytes/, fn ->
        EventStream.new(max_event_bytes: 0)
      end
    end

    test "rejects a terminal? that is not a 1-arity function" do
      assert_raise ArgumentError, ~r/terminal\?/, fn ->
        EventStream.new(terminal?: fn -> true end)
      end
    end
  end

  # ---- helpers ----

  defp new(terminal_fun, opts \\ []) do
    EventStream.new([terminal?: terminal_fun] ++ opts)
  end

  # Replays `data` in `chunk_size`-byte chunks (0 => a single push) and returns
  # the concatenated emitted list and the advanced accumulator.
  defp replay(data, chunk_size, terminal_fun) do
    stream = EventStream.new(terminal?: terminal_fun)

    data
    |> chunk_binary(chunk_size)
    |> Enum.reduce({[], stream}, fn chunk, {acc, st} ->
      assert {:ok, out, next} = EventStream.push(st, chunk)
      {acc ++ out, next}
    end)
  end

  defp chunk_binary(bin, 0), do: [bin]
  defp chunk_binary(<<>>, _n), do: []
  defp chunk_binary(bin, n) when byte_size(bin) <= n, do: [bin]

  defp chunk_binary(bin, n) do
    <<head::binary-size(n), rest::binary>> = bin
    [head | chunk_binary(rest, n)]
  end

  defp events(emitted), do: for({:event, map} <- emitted, do: map)

  defp object_lines(data), do: data |> String.split("\n", trim: true) |> length()

  defp fixture(name), do: File.read!(Path.join(@fixtures, name))
end
