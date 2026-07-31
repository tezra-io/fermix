defmodule FermixChannels.Gateway.DraftStreamTest do
  use ExUnit.Case, async: true

  alias FermixChannels.Gateway.DraftStream
  alias FermixChannels.Gateway.DraftStream.Spec

  # The engine drives channel-bound closures and never sees a channel module.
  # Tests record every closure call as a message to the test process.

  defp spec(test_pid, overrides \\ []) do
    base = %Spec{
      channel: "fake",
      open: fn text ->
        send(test_pid, {:open, text})
        {:ok, :handle_1}
      end,
      edit: fn handle, text ->
        send(test_pid, {:edit, handle, text})
        :ok
      end,
      seal: fn handle, text ->
        send(test_pid, {:seal, handle, text})
        {:ok, nil}
      end,
      discard: fn handle ->
        send(test_pid, {:discard, handle})
        :ok
      end
    }

    struct!(base, overrides)
  end

  # Fast timings so tests don't sit on the 1 s production throttle.
  @fast [edit_interval_ms: 20, min_draft_chars: 1]

  defp drain_writes(acc \\ []) do
    receive do
      {:open, text} -> drain_writes([{:open, text} | acc])
      {:edit, _handle, text} -> drain_writes([{:edit, text} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "coalescing and throttling" do
    test "(a) rapid pushes coalesce: few writes, newest snapshot wins" do
      pid = DraftStream.start_link(spec(self()), @fast)

      for i <- 1..100 do
        DraftStream.push(pid, {:text_delta, "text#{i}"})
      end

      # Let the trailing timer flush the final snapshot.
      Process.sleep(150)
      assert {:ok, nil} = DraftStream.seal(pid, "sealed")

      writes = drain_writes()
      assert length(writes) < 20
      assert {_kind, "text100"} = List.last(writes)
    end

    test "(e) identical text is never re-written" do
      pid = DraftStream.start_link(spec(self()), @fast)

      DraftStream.push(pid, {:text_delta, "same text"})
      assert_receive {:open, "same text"}, 1_000

      DraftStream.push(pid, {:text_delta, "same text"})
      Process.sleep(80)
      refute_received {:edit, _handle, _text}

      assert {:ok, nil} = DraftStream.seal(pid, "final")
    end

    test "(f) max_edits cap stops writes but seal still lands" do
      pid =
        DraftStream.start_link(spec(self()),
          edit_interval_ms: 1,
          min_draft_chars: 1,
          max_edits: 2
        )

      DraftStream.push(pid, {:text_delta, "a"})
      assert_receive {:open, "a"}, 1_000
      Process.sleep(10)
      DraftStream.push(pid, {:text_delta, "ab"})
      assert_receive {:edit, :handle_1, "ab"}, 1_000
      Process.sleep(10)
      DraftStream.push(pid, {:text_delta, "abc"})
      Process.sleep(50)
      refute_received {:edit, _handle, "abc"}

      assert {:ok, nil} = DraftStream.seal(pid, "final")
      assert_received {:seal, :handle_1, "final"}
    end
  end

  describe "draft opening" do
    test "(b) no draft below the min-chars threshold" do
      pid = DraftStream.start_link(spec(self()), edit_interval_ms: 1)

      DraftStream.push(pid, {:text_delta, "short"})
      Process.sleep(30)
      refute_received {:open, _text}

      assert {:ok, :no_draft} = DraftStream.seal(pid, "short")
      refute_received {:seal, _handle, _text}
    end

    test "(d) reasoning deltas never reach the channel" do
      pid = DraftStream.start_link(spec(self()), @fast)

      DraftStream.push(pid, {:reasoning_delta, "thinking hard about this"})
      Process.sleep(50)
      refute_received {:open, _text}

      assert {:ok, :no_draft} = DraftStream.seal(pid, "answer")
    end
  end

  describe "iteration reset" do
    test "(c)+(l) reset clears the buffer but keeps the live draft until new text arrives" do
      pid = DraftStream.start_link(spec(self()), @fast)

      DraftStream.push(pid, {:text_delta, "tool-round preamble"})
      assert_receive {:open, "tool-round preamble"}, 1_000

      DraftStream.push(pid, {:iteration_started, 2})
      Process.sleep(80)
      # No edit fired by the reset itself — the draft keeps its last text.
      refute_received {:edit, _handle, _text}

      DraftStream.push(pid, {:text_delta, "the actual answer"})
      assert_receive {:edit, :handle_1, "the actual answer"}, 1_000

      assert {:ok, nil} = DraftStream.seal(pid, "the actual answer, final")
    end
  end

  describe "failure handling" do
    test "(g) two consecutive edit failures freeze the preview; seal still lands" do
      test_pid = self()

      failing_edit = fn handle, text ->
        send(test_pid, {:edit, handle, text})
        {:error, :rate_limited}
      end

      pid =
        DraftStream.start_link(
          spec(self(), edit: failing_edit),
          edit_interval_ms: 1,
          min_draft_chars: 1
        )

      DraftStream.push(pid, {:text_delta, "aaaa"})
      assert_receive {:open, "aaaa"}, 1_000

      Process.sleep(10)
      DraftStream.push(pid, {:text_delta, "bbbb"})
      assert_receive {:edit, :handle_1, "bbbb"}, 1_000

      Process.sleep(10)
      DraftStream.push(pid, {:text_delta, "cccc"})
      assert_receive {:edit, :handle_1, "cccc"}, 1_000

      Process.sleep(10)
      DraftStream.push(pid, {:text_delta, "dddd"})
      Process.sleep(50)
      refute_received {:edit, _handle, "dddd"}

      assert {:ok, nil} = DraftStream.seal(pid, "final")
      assert_received {:seal, :handle_1, "final"}
    end

    test "(m) seal error discards the draft and surfaces the error" do
      pid =
        DraftStream.start_link(
          spec(self(), seal: fn _handle, _text -> {:error, :seal_boom} end),
          @fast
        )

      DraftStream.push(pid, {:text_delta, "draft text"})
      assert_receive {:open, "draft text"}, 1_000

      assert {:error, :seal_boom} = DraftStream.seal(pid, "final")
      assert_received {:discard, :handle_1}
    end

    test "(k) wedged seal times out, kills the engine, and reports" do
      pid =
        DraftStream.start_link(
          spec(self(), seal: fn _handle, _text -> Process.sleep(:infinity) end),
          @fast
        )

      DraftStream.push(pid, {:text_delta, "draft text"})
      assert_receive {:open, "draft text"}, 1_000

      assert {:error, :draft_stream_timeout} = DraftStream.seal(pid, "final", 100)

      # The engine was unlinked and killed — caller survives, engine doesn't.
      refute eventually_alive?(pid)
    end
  end

  describe "seal semantics" do
    test "(i) seal with no draft is :no_draft" do
      pid = DraftStream.start_link(spec(self()), @fast)
      assert {:ok, :no_draft} = DraftStream.seal(pid, "anything")
    end

    test "(n) no-op seal: last write already holds the final text" do
      pid = DraftStream.start_link(spec(self()), @fast)

      DraftStream.push(pid, {:text_delta, "the final text"})
      assert_receive {:open, "the final text"}, 1_000

      assert {:ok, nil} = DraftStream.seal(pid, "the final text")
      refute_received {:seal, _handle, _text}
    end

    test "(h) seal returns the channel's overflow remainder" do
      pid =
        DraftStream.start_link(
          spec(self(), seal: fn _handle, _text -> {:ok, "remainder chunk"} end),
          @fast
        )

      DraftStream.push(pid, {:text_delta, "long draft"})
      assert_receive {:open, "long draft"}, 1_000

      assert {:ok, "remainder chunk"} = DraftStream.seal(pid, "very long final")
    end
  end

  describe "lifecycle and cleanup" do
    test "(j) killing the spawning process reaps the engine and discards the draft" do
      test_pid = self()

      parent =
        spawn(fn ->
          pid = DraftStream.start_link(spec(test_pid), @fast)
          send(test_pid, {:engine, pid})

          receive do
            :never -> :ok
          end
        end)

      assert_receive {:engine, pid}

      DraftStream.push(pid, {:text_delta, "draft to orphan"})
      assert_receive {:open, "draft to orphan"}, 1_000

      Process.exit(parent, :kill)

      assert_receive {:discard, :handle_1}, 1_000
      refute eventually_alive?(pid)
    end

    test "discard deletes a live draft" do
      pid = DraftStream.start_link(spec(self()), @fast)

      DraftStream.push(pid, {:text_delta, "to be discarded"})
      assert_receive {:open, "to be discarded"}, 1_000

      assert :ok = DraftStream.discard(pid)
      assert_received {:discard, :handle_1}
    end

    test "discard with no draft is a quiet :ok" do
      pid = DraftStream.start_link(spec(self()), @fast)
      assert :ok = DraftStream.discard(pid)
      refute_received {:discard, _handle}
    end
  end

  describe "telemetry" do
    test "(o) stream events carry session_id, channel, ttfd, and dropped snapshots" do
      handler_id = "draft-stream-telemetry-#{System.unique_integer()}"
      test_pid = self()
      session_id = "sess-42-#{System.unique_integer([:positive])}"

      # A telemetry handler is process-global, so every concurrently-running
      # async module's stream events reach this one too. `self() == test_pid`
      # cannot discriminate here the way it does elsewhere — stream telemetry is
      # emitted from the STREAM's process, never the test's — so key on this
      # test's own session id, which the emitter carries in the metadata.
      :telemetry.attach(
        handler_id,
        [:fermix, :channel, :stream],
        fn _event, measurements, metadata, _config ->
          if metadata.session_id == session_id do
            send(test_pid, {:stream_telemetry, metadata.phase, measurements, metadata})
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      # Huge interval: the first push opens (throttle window starts satisfied),
      # everything after coalesces until seal.
      pid = DraftStream.start_link(spec(self()), edit_interval_ms: 60_000, min_draft_chars: 1)

      DraftStream.push(pid, {:session_started, session_id})
      DraftStream.push(pid, {:text_delta, "a"})
      assert_receive {:open, "a"}, 1_000

      for text <- ["ab", "abc", "abcd", "abcde"] do
        DraftStream.push(pid, {:text_delta, text})
      end

      assert {:ok, nil} = DraftStream.seal(pid, "final answer")

      assert_receive {:stream_telemetry, :open, open_measurements, open_metadata}
      assert open_measurements.ttfd_ms >= 0
      assert open_metadata.channel == "fake"
      assert open_metadata.session_id == session_id

      assert_receive {:stream_telemetry, :seal, seal_measurements, seal_metadata}
      assert seal_metadata.session_id == session_id
      assert seal_measurements.total_edits == 1
      # "ab" arrived on a dirty buffer? No — "a" was flushed. Then "abc",
      # "abcd", "abcde" each overwrote an unflushed snapshot: 3 dropped.
      assert seal_measurements.dropped_snapshots == 3
    end
  end

  # -- Block mode (streaming = "block": completed chunks as separate sends) --

  defp block_spec(test_pid) do
    DraftStream.build_block_spec("fake", fn text ->
      send(test_pid, {:block_sent, text})
      :ok
    end)
  end

  # Tiny thresholds so tests don't need 800-char fixtures.
  @block_fast [
    edit_interval_ms: 1,
    block_min_chars: 20,
    block_max_chars: 60,
    idle_flush_ms: 60_000
  ]

  describe "block mode" do
    test "paragraph-complete chunks send as separate messages; seal returns the tail" do
      pid = DraftStream.start_link(block_spec(self()), @block_fast)

      DraftStream.push(pid, {:text_delta, "First paragraph of the answer."})
      Process.sleep(30)
      refute_received {:block_sent, _text}

      full = "First paragraph of the answer.\n\nSecond paragraph still streaming"
      DraftStream.push(pid, {:text_delta, full})
      assert_receive {:block_sent, "First paragraph of the answer."}, 1_000

      final = "First paragraph of the answer.\n\nSecond paragraph still streaming, now done."
      assert {:ok, tail} = DraftStream.seal(pid, final)
      assert tail == "Second paragraph still streaming, now done."
    end

    test "no blocks sent ⇒ seal is :no_draft (normal full delivery)" do
      pid = DraftStream.start_link(block_spec(self()), @block_fast)

      DraftStream.push(pid, {:text_delta, "Short, no paragraph break."})
      Process.sleep(30)
      refute_received {:block_sent, _text}

      assert {:ok, :no_draft} = DraftStream.seal(pid, "Short, no paragraph break.")
    end

    test "overlong text without a paragraph break is force-cut at a newline" do
      pid = DraftStream.start_link(block_spec(self()), @block_fast)

      text =
        "alpha bravo charlie delta echo foxtrot\ngolf hotel india juliett kilo lima mike november"

      DraftStream.push(pid, {:text_delta, text})

      assert_receive {:block_sent, "alpha bravo charlie delta echo foxtrot"}, 1_000
    end

    test "an open code fence is never split mid-fence" do
      pid =
        DraftStream.start_link(
          block_spec(self()),
          edit_interval_ms: 1,
          block_min_chars: 20,
          block_max_chars: 200,
          idle_flush_ms: 60_000
        )

      open_fence =
        "Look:\n\n```elixir\ndefmodule A do\n  def go, do: :ok\nend\nmore code lines here padding"

      DraftStream.push(pid, {:text_delta, open_fence})
      Process.sleep(30)
      # "Look:" alone is below min_chars and the rest is inside the fence.
      refute_received {:block_sent, _text}

      closed = open_fence <> "\n```\n\nAfter the fence, a normal closing paragraph arrives."
      DraftStream.push(pid, {:text_delta, closed})
      assert_receive {:block_sent, sent}, 1_000
      assert sent =~ "```"
      assert rem(length(String.split(sent, "```")) - 1, 2) == 0
    end

    test "iteration reset discards unsent text; sent blocks stand as commentary" do
      pid = DraftStream.start_link(block_spec(self()), @block_fast)

      DraftStream.push(
        pid,
        {:text_delta, "Tool-round commentary paragraph.\n\nUnsent trailing bit"}
      )

      assert_receive {:block_sent, "Tool-round commentary paragraph."}, 1_000

      DraftStream.push(pid, {:iteration_started, 2})
      final = "The actual final answer from the last iteration."
      DraftStream.push(pid, {:text_delta, final})
      Process.sleep(30)

      # Final iteration sent no blocks ⇒ deliver the response in full.
      assert {:ok, :no_draft} = DraftStream.seal(pid, final)
    end

    test "mismatched final response falls back to full delivery, never a corrupt tail" do
      pid = DraftStream.start_link(block_spec(self()), @block_fast)

      DraftStream.push(pid, {:text_delta, "Streamed paragraph one.\n\nmore text coming here"})
      assert_receive {:block_sent, "Streamed paragraph one."}, 1_000

      assert {:ok, :no_draft} = DraftStream.seal(pid, "A completely different final response.")
    end

    test "idle flush sends fence-balanced unsent text below the min threshold" do
      pid =
        DraftStream.start_link(
          block_spec(self()),
          edit_interval_ms: 1,
          block_min_chars: 500,
          block_max_chars: 900,
          idle_flush_ms: 30
        )

      DraftStream.push(pid, {:text_delta, "A short standalone note before running tools."})
      assert_receive {:block_sent, "A short standalone note before running tools."}, 1_000
    end

    test "a mid-stream provider retry (cumulative restarts shorter) never crashes the engine" do
      pid = DraftStream.start_link(block_spec(self()), @block_fast)

      DraftStream.push(
        pid,
        {:text_delta, "First paragraph fully streamed.\n\nSecond part begins"}
      )

      assert_receive {:block_sent, "First paragraph fully streamed."}, 1_000

      # Transport drop → HttpClient retries with a FRESH SSE parser: the
      # cumulative restarts from a short prefix. Must not binary_part-crash.
      DraftStream.push(pid, {:text_delta, "First par"})
      Process.sleep(30)
      assert Process.alive?(pid)
      refute_received {:block_sent, _early}

      # The retried stream regrows past the consumed offset — emission resumes.
      regrown = "First paragraph fully streamed.\n\nSecond part begins, and finishes properly."
      DraftStream.push(pid, {:text_delta, regrown})
      DraftStream.push(pid, {:text_done, regrown})
      assert_receive {:block_sent, "Second part begins, and finishes properly."}, 1_000

      assert {:ok, nil} = DraftStream.seal(pid, regrown)
    end

    test "discard makes no channel calls in block mode" do
      pid = DraftStream.start_link(block_spec(self()), @block_fast)

      DraftStream.push(pid, {:text_delta, "First paragraph here padded.\n\nSecond one"})
      assert_receive {:block_sent, _text}, 1_000

      assert :ok = DraftStream.discard(pid)
      refute_received {:block_sent, _more}
    end

    test "text_done flushes a complete sub-min message as its own block (semantic boundary)" do
      pid =
        DraftStream.start_link(
          block_spec(self()),
          edit_interval_ms: 1,
          block_min_chars: 500,
          block_max_chars: 900,
          idle_flush_ms: 60_000
        )

      DraftStream.push(pid, {:text_delta, "Let me check the calendar first."})
      Process.sleep(20)
      refute_received {:block_sent, _text}

      DraftStream.push(pid, {:text_done, "Let me check the calendar first."})
      assert_receive {:block_sent, "Let me check the calendar first."}, 1_000

      # Everything streamed ⇒ nothing left to deliver at seal.
      assert {:ok, nil} = DraftStream.seal(pid, "Let me check the calendar first.")
    end

    test "reasoning_done shows only the thought heading, not the summary body" do
      pid = DraftStream.start_link(block_spec(self()), @block_fast)

      summary =
        "**Checking the weather tool**\n\n" <>
          "The user wants to know if they need an umbrella, so I'll call the weather " <>
          "tool for Singapore first and then summarize the precipitation forecast."

      DraftStream.push(pid, {:reasoning_done, summary})
      assert_receive {:block_sent, "💭 Checking the weather tool"}, 1_000

      DraftStream.push(pid, {:text_delta, "Checking the weather now, one moment please."})
      DraftStream.push(pid, {:text_done, "Checking the weather now, one moment please."})
      assert_receive {:block_sent, "Checking the weather now, one moment please."}, 1_000

      assert {:ok, nil} = DraftStream.seal(pid, "Checking the weather now, one moment please.")
    end

    test "multi-part reasoning joins its headings into one 💭 line" do
      pid = DraftStream.start_link(block_spec(self()), @block_fast)

      summary =
        "**Reading the config**\n\nFirst I need the current values.\n\n" <>
          "**Planning the edit**\n\nThen I'll apply the change."

      DraftStream.push(pid, {:reasoning_done, summary})
      assert_receive {:block_sent, "💭 Reading the config · Planning the edit"}, 1_000
    end

    test "a headingless reasoning summary falls back to a truncated first line" do
      pid = DraftStream.start_link(block_spec(self()), @block_fast)

      long_first_line =
        "The user is asking about umbrella weather so I will check the forecast " <>
          "for Singapore and then I will think about precipitation probabilities at length"

      DraftStream.push(pid, {:reasoning_done, long_first_line <> "\nsecond line"})

      assert_receive {:block_sent, "💭 " <> shown}, 1_000
      assert String.length(shown) <= 80
      assert String.ends_with?(shown, "…")
      assert String.starts_with?(long_first_line, String.trim_trailing(shown, "…"))
    end

    test "draft mode ignores reasoning_done and treats text_done as a snapshot" do
      pid = DraftStream.start_link(spec(self()), @fast)

      DraftStream.push(pid, {:reasoning_done, "thinking about it"})
      Process.sleep(50)
      refute_received {:open, _text}

      DraftStream.push(pid, {:text_done, "the full final answer text"})
      assert_receive {:open, "the full final answer text"}, 1_000

      assert {:ok, nil} = DraftStream.seal(pid, "the full final answer text")
    end

    test "telemetry: first block opens the stream, later blocks are :block, seal carries totals" do
      handler_id = "draft-stream-block-telemetry-#{System.unique_integer()}"
      test_pid = self()
      session_id = "sess-b-#{System.unique_integer([:positive])}"

      # Keyed on this test's own session id for the same reason as the draft
      # telemetry test above: the handler is process-global, and the events come
      # from the stream's process, so a `self()` guard would match nothing.
      :telemetry.attach(
        handler_id,
        [:fermix, :channel, :stream],
        fn _event, measurements, metadata, _config ->
          if metadata.session_id == session_id do
            send(test_pid, {:stream_telemetry, metadata.phase, measurements})
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      pid = DraftStream.start_link(block_spec(self()), @block_fast)

      DraftStream.push(pid, {:session_started, session_id})
      two_paras = "Paragraph number one, padded.\n\nParagraph number two, padded!\n\ntrailing"
      DraftStream.push(pid, {:text_delta, two_paras})

      assert_receive {:block_sent, "Paragraph number one, padded."}, 1_000
      assert_receive {:block_sent, "Paragraph number two, padded!"}, 1_000

      assert_receive {:stream_telemetry, :open, open_meas}
      assert open_meas.ttfd_ms >= 0
      assert_receive {:stream_telemetry, :block, block_meas}
      assert block_meas.block_index == 2

      assert {:ok, _tail} = DraftStream.seal(pid, two_paras <> " end.")
      assert_receive {:stream_telemetry, :seal, seal_meas}
      assert seal_meas.total_edits == 2
    end
  end

  describe "channel-agnostic boundary" do
    test "engine source contains no platform-isms (CI grep guard)" do
      source =
        [__DIR__, "..", "..", "..", "lib", "fermix_channels", "gateway", "draft_stream.ex"]
        |> Path.join()
        |> Path.expand()
        |> File.read!()

      refute source =~ "4096"
      refute source =~ "HTML"
      refute source =~ "editMessageText"
      refute source =~ "sendMessage"
      refute source =~ "Telegram"
    end
  end

  defp eventually_alive?(pid) do
    Enum.reduce_while(1..50, true, fn _attempt, _acc ->
      if Process.alive?(pid) do
        Process.sleep(10)
        {:cont, true}
      else
        {:halt, false}
      end
    end)
  end
end
