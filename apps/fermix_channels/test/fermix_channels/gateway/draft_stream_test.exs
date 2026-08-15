defmodule FermixChannels.Gateway.DraftStreamTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

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

  # A block spec that can also send (and later delete) ephemeral thought
  # messages — the S1 shape for a channel that supports deletion. Every
  # ephemeral send answers with one deterministic id so a test can pin exactly
  # which ids the sweep deletes.
  defp ephemeral_block_spec(test_pid, overrides \\ []) do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    spec =
      DraftStream.build_block_spec(
        "fake",
        fn text ->
          send(test_pid, {:block_sent, text})
          :ok
        end,
        ephemeral_send: fn text ->
          n = Agent.get_and_update(counter, fn n -> {n + 1, n + 1} end)
          ids = ["id-#{n}"]
          send(test_pid, {:thought_sent, text, ids})
          {:ok, ids}
        end,
        delete: fn id ->
          send(test_pid, {:thought_deleted, id})
          :ok
        end
      )

    struct!(spec, overrides)
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
      pid = DraftStream.start_link(ephemeral_block_spec(self()), @block_fast)

      summary =
        "**Checking the weather tool**\n\n" <>
          "The user wants to know if they need an umbrella, so I'll call the weather " <>
          "tool for Singapore first and then summarize the precipitation forecast."

      DraftStream.push(pid, {:reasoning_done, summary})
      assert_receive {:thought_sent, "💭 Checking the weather tool", _ids}, 1_000

      DraftStream.push(pid, {:text_delta, "Checking the weather now, one moment please."})
      DraftStream.push(pid, {:text_done, "Checking the weather now, one moment please."})
      assert_receive {:block_sent, "Checking the weather now, one moment please."}, 1_000

      assert {:ok, nil} = DraftStream.seal(pid, "Checking the weather now, one moment please.")
    end

    test "multi-part reasoning joins its headings into one 💭 line" do
      pid = DraftStream.start_link(ephemeral_block_spec(self()), @block_fast)

      summary =
        "**Reading the config**\n\nFirst I need the current values.\n\n" <>
          "**Planning the edit**\n\nThen I'll apply the change."

      DraftStream.push(pid, {:reasoning_done, summary})
      assert_receive {:thought_sent, "💭 Reading the config · Planning the edit", _ids}, 1_000
    end

    test "a headingless reasoning summary falls back to a truncated first line" do
      pid = DraftStream.start_link(ephemeral_block_spec(self()), @block_fast)

      long_first_line =
        "The user is asking about umbrella weather so I will check the forecast " <>
          "for Singapore and then I will think about precipitation probabilities at length"

      DraftStream.push(pid, {:reasoning_done, long_first_line <> "\nsecond line"})

      assert_receive {:thought_sent, "💭 " <> shown, _ids}, 1_000
      assert String.length(shown) <= 80
      assert String.ends_with?(shown, "…")
      assert String.starts_with?(long_first_line, String.trim_trailing(shown, "…"))
    end

    test "draft mode routes reasoning_done to the 💭 status bubble, text_done to the draft" do
      # S2 replaces S1's "draft mode drops thoughts": a draft-capable channel
      # shows them in one rolling status bubble instead (design §6).
      pid = DraftStream.start_link(spec(self()), @fast)

      DraftStream.push(pid, {:reasoning_done, "thinking about it"})
      assert_receive {:open, "💭 thinking about it"}, 1_000

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

  # -- S1: conditional final drain (CHANNEL_LONGFORM_PRESENTATION §5) --

  describe "block mode: text_done drain" do
    test "an over-max remainder is cut on a paragraph boundary, never a blind slice" do
      pid = DraftStream.start_link(block_spec(self()), @block_fast)

      text =
        "Paragraph one, padded out.\n\nParagraph two, also padded out here.\n\n" <>
          "Paragraph three, the tail of the answer."

      DraftStream.push(pid, {:text_delta, text})
      DraftStream.push(pid, {:text_done, text})

      assert_receive {:block_sent, "Paragraph one, padded out."}, 1_000
      assert_receive {:block_sent, "Paragraph two, also padded out here."}, 1_000
      assert_receive {:block_sent, "Paragraph three, the tail of the answer."}, 1_000

      assert {:ok, nil} = DraftStream.seal(pid, text)
    end

    test "a fence-unbalanced remainder flushes whole instead of wedging until seal" do
      pid = DraftStream.start_link(block_spec(self()), @block_fast)

      text =
        "```elixir\ndefmodule A do\n  def go, do: :ok\nend\n" <>
          "still inside the fence and going on past the window"

      DraftStream.push(pid, {:text_delta, text})
      Process.sleep(20)
      # No balanced cut exists inside the window, so nothing streams yet.
      refute_received {:block_sent, _text}

      DraftStream.push(pid, {:text_done, text})

      # One send, the whole remainder — the adapter ladder-splits it safely.
      assert_receive {:block_sent, sent}, 1_000
      assert sent == text
      refute_received {:block_sent, _more}

      assert {:ok, nil} = DraftStream.seal(pid, text)
    end
  end

  # -- S1: answer priority + thought coalescing (§5) --

  describe "block mode: thought priority and coalescing" do
    test "answer text wins the tick; queued thoughts drain after it" do
      pid =
        DraftStream.start_link(
          ephemeral_block_spec(self()),
          edit_interval_ms: 100,
          block_min_chars: 20,
          block_max_chars: 60,
          idle_flush_ms: 60_000
        )

      # The first send opens the throttle window, so the next two events both
      # sit pending for the same tick.
      DraftStream.push(pid, {:text_delta, "Paragraph one, padded out.\n\n"})
      assert_receive {:block_sent, "Paragraph one, padded out."}, 1_000

      DraftStream.push(pid, {:reasoning_done, "**Checking the calendar**\n\nbody text"})

      DraftStream.push(
        pid,
        {:text_delta, "Paragraph one, padded out.\n\nParagraph two, padded out.\n\n"}
      )

      assert_receive next, 1_000
      assert {:block_sent, "Paragraph two, padded out."} = next
      assert_receive {:thought_sent, "💭 Checking the calendar", _ids}, 1_000
    end

    test "queued thoughts coalesce into exactly one 💭 message with one prefix" do
      pid =
        DraftStream.start_link(
          ephemeral_block_spec(self()),
          edit_interval_ms: 120,
          block_min_chars: 20,
          block_max_chars: 200,
          idle_flush_ms: 60_000
        )

      # The first thought drains alone and opens the throttle window.
      DraftStream.push(pid, {:reasoning_done, "**First thought**\n\nbody text"})
      assert_receive {:thought_sent, "💭 First thought", _first_ids}, 1_000

      for heading <- ["**Alpha**", "**Beta**", "**Gamma**"] do
        DraftStream.push(pid, {:reasoning_done, heading <> "\n\nbody text"})
      end

      assert_receive {:thought_sent, coalesced, _ids}, 1_000
      assert coalesced == "💭 Alpha\nBeta\nGamma"
      refute_received {:thought_sent, _more, _more_ids}
    end
  end

  # -- S1: ephemeral thought sweep (§5, decision §9.1/§9.2) --

  describe "block mode: thought sweep" do
    test "sent thought ids accumulate and the seal deletes each exactly once" do
      pid = DraftStream.start_link(ephemeral_block_spec(self()), @block_fast)

      DraftStream.push(pid, {:reasoning_done, "**First thought**\n\nbody"})
      assert_receive {:thought_sent, "💭 First thought", ["id-1"]}, 1_000

      DraftStream.push(pid, {:reasoning_done, "**Second thought**\n\nbody"})
      assert_receive {:thought_sent, "💭 Second thought", ["id-2"]}, 1_000

      assert {:ok, :no_draft} = DraftStream.seal(pid, "the answer")

      # The sweep runs after the seal reply lands — wait for it.
      assert_receive {:thought_deleted, "id-1"}, 1_000
      assert_receive {:thought_deleted, "id-2"}, 1_000
      refute_received {:thought_deleted, _again}
    end

    test "discard sweeps every thought it sent" do
      pid = DraftStream.start_link(ephemeral_block_spec(self()), @block_fast)

      DraftStream.push(pid, {:reasoning_done, "**Only thought**\n\nbody"})
      assert_receive {:thought_sent, "💭 Only thought", ["id-1"]}, 1_000

      assert :ok = DraftStream.discard(pid)
      assert_receive {:thought_deleted, "id-1"}, 1_000
    end

    test "a failed delete is logged, never retried, and the seal still returns" do
      test_pid = self()

      failing_delete = fn id ->
        send(test_pid, {:thought_deleted, id})
        if id == "id-1", do: {:error, :gone}, else: :ok
      end

      pid =
        DraftStream.start_link(
          ephemeral_block_spec(self(), delete: failing_delete),
          @block_fast
        )

      DraftStream.push(pid, {:reasoning_done, "**First thought**\n\nbody"})
      assert_receive {:thought_sent, _first, ["id-1"]}, 1_000

      DraftStream.push(pid, {:reasoning_done, "**Second thought**\n\nbody"})
      assert_receive {:thought_sent, _second, ["id-2"]}, 1_000

      log =
        capture_log(fn ->
          assert {:ok, :no_draft} = DraftStream.seal(pid, "the answer")
          # Sweep (and its warning) happens after the reply — hold the capture
          # open until both deletes have run.
          assert_receive {:thought_deleted, "id-1"}, 1_000
          assert_receive {:thought_deleted, "id-2"}, 1_000
        end)

      assert log =~ "gone"
      refute_received {:thought_deleted, _retry}
    end

    test "a slow delete never delays the seal reply (swept after the reply)" do
      test_pid = self()

      slow_delete = fn id ->
        Process.sleep(400)
        send(test_pid, {:thought_deleted, id})
        :ok
      end

      pid =
        DraftStream.start_link(
          ephemeral_block_spec(self(), delete: slow_delete),
          @block_fast
        )

      DraftStream.push(pid, {:reasoning_done, "**Only thought**\n\nbody"})
      assert_receive {:thought_sent, _text, ["id-1"]}, 1_000

      # Sync window (200 ms) shorter than one delete (400 ms): before the
      # ordering fix this returned {:error, :draft_stream_timeout} and the
      # queue re-delivered the full reply — a duplicated message in chat.
      assert {:ok, :no_draft} = DraftStream.seal(pid, "the answer", 200)
      assert_receive {:thought_deleted, "id-1"}, 2_000
    end

    test "a spec without ephemeral support drops thoughts instead of sending them" do
      test_pid = self()

      answer_only = fn text ->
        if String.starts_with?(text, "💭"), do: raise("a thought reached the answer path")
        send(test_pid, {:block_sent, text})
        :ok
      end

      pid =
        DraftStream.start_link(
          DraftStream.build_block_spec("fake", answer_only),
          @block_fast
        )

      DraftStream.push(pid, {:reasoning_done, "**Dropped thought**\n\nbody"})
      Process.sleep(30)
      refute_received {:block_sent, _text}
      assert Process.alive?(pid)

      DraftStream.push(pid, {:text_delta, "The answer paragraph, padded.\n\n"})
      assert_receive {:block_sent, "The answer paragraph, padded."}, 1_000
    end

    test "a half-wired thought sweep is refused at spec build" do
      assert_raise ArgumentError, fn ->
        DraftStream.build_block_spec("fake", fn _text -> :ok end,
          ephemeral_send: fn _text -> {:ok, []} end
        )
      end
    end
  end

  # -- S2: draft rotation (CHANNEL_LONGFORM_PRESENTATION §6) -------------------

  # The draft spec the gateway builds for a draft-capable channel: the rotation
  # pair is wired, and every open answers with a FRESH handle so a test can tell
  # the sealed bubbles apart from the live one.
  defp rotating_spec(test_pid, overrides \\ []) do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    base = %Spec{
      channel: "fake",
      open: fn text ->
        n = Agent.get_and_update(counter, fn n -> {n + 1, n + 1} end)
        handle = {:bubble, n}
        send(test_pid, {:open, handle, text})
        {:ok, handle}
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
      end,
      measure: &String.length/1,
      rotate_at: 60
    }

    struct!(base, overrides)
  end

  @rotate_fast [edit_interval_ms: 1, min_draft_chars: 1]

  @para_one "Paragraph one, padded out to a good size here."
  @para_two "Paragraph two is still streaming in"
  @two_paras "Paragraph one, padded out to a good size here.\n\n" <>
               "Paragraph two is still streaming in"

  describe "draft rotation" do
    test "seals the live bubble at the card boundary and opens a fresh one" do
      pid = DraftStream.start_link(rotating_spec(self()), @rotate_fast)

      DraftStream.push(pid, {:text_delta, @two_paras})

      assert_receive {:open, {:bubble, 1}, @two_paras}, 1_000
      assert_receive {:seal, {:bubble, 1}, @para_one}, 1_000

      # The next flush opens a NEW bubble holding only the live slice — the
      # sealed card is never re-rendered.
      DraftStream.push(pid, {:text_delta, @two_paras <> " and finishes."})
      assert_receive {:open, {:bubble, 2}, live}, 1_000
      assert live == @para_two <> " and finishes."
    end

    test "no rotation while the whole live slice still fits one card" do
      pid = DraftStream.start_link(rotating_spec(self()), @rotate_fast)

      DraftStream.push(pid, {:text_delta, "Short enough to stay one bubble."})
      assert_receive {:open, {:bubble, 1}, _text}, 1_000

      Process.sleep(30)
      refute_received {:seal, _handle, _text}
    end

    test "no rotation when the first chunk consumes the whole slice" do
      # An oversized fenced block is atomic: it is the first chunk AND the
      # entire slice, so the boundary is not strictly inside — nothing to seal.
      fence =
        "```sh\n" <> Enum.map_join(1..8, "\n", fn i -> "line #{i} of the log" end) <> "\n```"

      pid = DraftStream.start_link(rotating_spec(self()), @rotate_fast)

      DraftStream.push(pid, {:text_delta, fence})
      assert_receive {:open, {:bubble, 1}, _text}, 1_000

      Process.sleep(30)
      refute_received {:seal, _handle, _text}
    end

    test "a cumulative restart below the sealed prefix clamps, recovers, and seals cleanly" do
      pid = DraftStream.start_link(rotating_spec(self()), @rotate_fast)

      DraftStream.push(pid, {:text_delta, @two_paras})
      assert_receive {:open, {:bubble, 1}, @two_paras}, 1_000
      assert_receive {:seal, {:bubble, 1}, @para_one}, 1_000

      # Mid-stream provider retry: the SSE cumulative restarts from scratch,
      # shorter than the already-sealed prefix. The engine clamps — no write
      # for the empty live slice, no crash.
      DraftStream.push(pid, {:text_delta, "Para"})
      Process.sleep(30)
      refute_received {:open, _handle, _text}

      # The retried stream regrows past the sealed offset; the live slice
      # resumes rendering from there.
      full = @two_paras <> " and now it finishes."
      DraftStream.push(pid, {:text_delta, full})
      assert_receive {:open, {:bubble, 2}, live}, 1_000
      assert live == @para_two <> " and now it finishes."

      final = full <> " Done."
      assert {:ok, nil} = DraftStream.seal(pid, final)
      assert_receive {:seal, {:bubble, 2}, tail_text}, 1_000
      assert tail_text == @para_two <> " and now it finishes. Done."
    end

    test "the sealed prefix advances by BYTES, not characters, on multi-byte content" do
      head = "Résumé — naïve café ☕ notes on the wreck dive."
      tail = "Second paragraph 🌊 continues here."
      text = head <> "\n\n" <> tail

      pid = DraftStream.start_link(rotating_spec(self()), @rotate_fast)

      DraftStream.push(pid, {:text_delta, text})
      assert_receive {:open, {:bubble, 1}, ^text}, 1_000
      assert_receive {:seal, {:bubble, 1}, ^head}, 1_000

      # A grapheme-counted offset would slice mid-word here (the head measures
      # 45 characters but 51 bytes).
      DraftStream.push(pid, {:text_delta, text <> " Done."})
      assert_receive {:open, {:bubble, 2}, live}, 1_000
      assert live == tail <> " Done."
    end

    test "post-rotation edits render only the live slice" do
      pid = DraftStream.start_link(rotating_spec(self()), @rotate_fast)

      DraftStream.push(pid, {:text_delta, @two_paras})
      assert_receive {:seal, {:bubble, 1}, @para_one}, 1_000

      DraftStream.push(pid, {:text_delta, @two_paras <> " more"})
      assert_receive {:open, {:bubble, 2}, _live}, 1_000

      DraftStream.push(pid, {:text_delta, @two_paras <> " more and more"})
      assert_receive {:edit, {:bubble, 2}, edited}, 1_000
      assert edited == @para_two <> " more and more"
      refute edited =~ "Paragraph one"
    end

    test "a refusing rotation stops after two tries; edits and the seal still land" do
      test_pid = self()
      final = @two_paras <> " The end."

      picky_seal = fn handle, text ->
        send(test_pid, {:seal, handle, text})
        if text == final, do: {:ok, nil}, else: {:error, :rotate_boom}
      end

      log =
        capture_log(fn ->
          pid = DraftStream.start_link(rotating_spec(self(), seal: picky_seal), @rotate_fast)

          DraftStream.push(pid, {:text_delta, @two_paras})
          assert_receive {:seal, {:bubble, 1}, @para_one}, 1_000

          DraftStream.push(pid, {:text_delta, @two_paras <> " x"})
          assert_receive {:seal, {:bubble, 1}, _second_try}, 1_000

          # Cap reached: the draft degrades to one growing bubble — still
          # edited, never rotated again.
          DraftStream.push(pid, {:text_delta, @two_paras <> " xy"})
          assert_receive {:edit, {:bubble, 1}, _grown}, 1_000
          refute_received {:seal, {:bubble, 1}, _third_try}

          assert {:ok, nil} = DraftStream.seal(pid, final)
          assert_received {:seal, {:bubble, 1}, ^final}
        end)

      assert log =~ "rotate_boom"
    end

    test "rotation writes count against max_edits" do
      pid =
        DraftStream.start_link(
          rotating_spec(self()),
          edit_interval_ms: 1,
          min_draft_chars: 1,
          max_edits: 2
        )

      # Write 1 = the open, write 2 = the rotation seal ⇒ the cap is spent.
      DraftStream.push(pid, {:text_delta, @two_paras})
      assert_receive {:open, {:bubble, 1}, _text}, 1_000
      assert_receive {:seal, {:bubble, 1}, @para_one}, 1_000

      DraftStream.push(pid, {:text_delta, @two_paras <> " and more text here."})
      Process.sleep(40)
      refute_received {:open, {:bubble, 2}, _live}

      assert {:ok, tail} = DraftStream.seal(pid, @two_paras <> " and more text here.")
      assert tail == @para_two <> " and more text here."
    end

    test "telemetry: a mid-turn rotation is :rotate, never the terminal :seal" do
      handler_id = "draft-stream-rotate-telemetry-#{System.unique_integer()}"
      test_pid = self()
      session_id = "sess-r-#{System.unique_integer([:positive])}"

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

      pid = DraftStream.start_link(rotating_spec(self()), @rotate_fast)

      DraftStream.push(pid, {:session_started, session_id})
      DraftStream.push(pid, {:text_delta, @two_paras})
      assert_receive {:seal, {:bubble, 1}, @para_one}, 1_000

      assert_receive {:stream_telemetry, :open, _open_meas}
      assert_receive {:stream_telemetry, :rotate, rotate_meas}
      assert rotate_meas.edit_index == 2
      refute_received {:stream_telemetry, :seal, _seal_meas}

      assert {:ok, _tail} = DraftStream.seal(pid, @two_paras)
      assert_receive {:stream_telemetry, :seal, seal_meas}
      assert seal_meas.total_edits == 2
    end

    test "a spec with only half the rotation pair is refused at start" do
      assert_raise ArgumentError, ~r/rotation requires both/, fn ->
        DraftStream.start_link(rotating_spec(self(), rotate_at: nil))
      end

      assert_raise ArgumentError, ~r/rotation requires both/, fn ->
        DraftStream.start_link(rotating_spec(self(), measure: nil))
      end
    end
  end

  describe "draft rotation: iteration reset" do
    test "the live bubble is sealed as commentary and the next iteration opens its own" do
      pid =
        DraftStream.start_link(rotating_spec(self()), edit_interval_ms: 300, min_draft_chars: 1)

      DraftStream.push(pid, {:text_delta, "First round commentary."})
      assert_receive {:open, {:bubble, 1}, "First round commentary."}, 1_000

      # Arrives inside the throttle window, so it is still unwritten when the
      # iteration ends — the reset seal is what puts it on screen.
      DraftStream.push(pid, {:text_delta, "First round commentary. Extended."})
      DraftStream.push(pid, {:iteration_started, 2})

      assert_receive {:seal, {:bubble, 1}, "First round commentary. Extended."}, 1_000
      refute_received {:discard, {:bubble, 1}}

      DraftStream.push(pid, {:text_delta, "The actual answer of the final round."})
      assert_receive {:open, {:bubble, 2}, "The actual answer of the final round."}, 1_000

      assert {:ok, nil} = DraftStream.seal(pid, "The actual answer of the final round.")
    end
  end

  describe "draft rotation: turn end" do
    test "a tiny tail merges into the live bubble instead of ringing a new message" do
      pid = DraftStream.start_link(rotating_spec(self()), @rotate_fast)

      DraftStream.push(pid, {:text_delta, @two_paras})
      assert_receive {:seal, {:bubble, 1}, @para_one}, 1_000

      DraftStream.push(pid, {:text_delta, @two_paras})
      assert_receive {:open, {:bubble, 2}, _live}, 1_000

      final = @two_paras <> " and it ends right here."
      assert {:ok, nil} = DraftStream.seal(pid, final)

      # One bubble carries the live slice AND the tail — no queue delivery.
      assert_received {:seal, {:bubble, 2}, merged}
      assert merged == @para_two <> " and it ends right here."
    end

    test "an oversized tail comes back as the channel's overflow for normal delivery" do
      overflowing_seal = fn _handle, _text -> {:ok, "the remainder chunk"} end

      pid = DraftStream.start_link(rotating_spec(self(), seal: overflowing_seal), @rotate_fast)

      DraftStream.push(pid, {:text_delta, @two_paras})
      # The rotation self-schedules the next tick, which opens the new bubble.
      assert_receive {:open, {:bubble, 2}, _live}, 1_000

      assert {:ok, "the remainder chunk"} = DraftStream.seal(pid, @two_paras <> " tail")
    end

    test "with no live bubble the tail goes out through normal delivery" do
      pid =
        DraftStream.start_link(
          rotating_spec(self()),
          edit_interval_ms: 60_000,
          min_draft_chars: 1
        )

      DraftStream.push(pid, {:text_delta, @two_paras})
      assert_receive {:seal, {:bubble, 1}, @para_one}, 1_000

      # The throttle keeps the next bubble from opening, so the remainder has
      # no live bubble to land in.
      assert {:ok, tail} = DraftStream.seal(pid, @two_paras <> " done.")
      assert tail == @para_two <> " done."
      refute_received {:open, {:bubble, 2}, _text}
    end

    test "a final response that is not an extension of the sealed cards delivers in full" do
      log =
        capture_log(fn ->
          pid = DraftStream.start_link(rotating_spec(self()), @rotate_fast)

          DraftStream.push(pid, {:text_delta, @two_paras})
          assert_receive {:seal, {:bubble, 1}, @para_one}, 1_000

          DraftStream.push(pid, {:text_delta, @two_paras})
          assert_receive {:open, {:bubble, 2}, _live}, 1_000

          assert {:ok, :no_draft} =
                   DraftStream.seal(pid, "A completely different final response.")

          # The unconfirmed live bubble goes; the sealed card stands.
          assert_received {:discard, {:bubble, 2}}
          refute_received {:discard, {:bubble, 1}}
        end)

      assert log =~ "not a prefix"
    end

    # The retry that matters is the one that DIVERGES. HttpClient blindly
    # retries a mid-stream :closed and the fresh SSE parser restarts the
    # cumulative at zero, with no :iteration_started to reset the sealed
    # prefix — so the buffer becomes the regenerated stream while the sealed
    # bubbles still hold the first one. Checked against a slice of the buffer
    # this passes tautologically and the delivered answer is spliced at an
    # arbitrary byte offset; checked against the sealed text it is caught.
    test "a diverging mid-stream retry is caught and delivers in full" do
      log =
        capture_log(fn ->
          pid = DraftStream.start_link(rotating_spec(self()), @rotate_fast)

          DraftStream.push(pid, {:text_delta, @two_paras})
          assert_receive {:seal, {:bubble, 1}, @para_one}, 1_000

          # The connection dropped; the provider regenerated a different answer,
          # longer than the sealed prefix so the live slice is non-empty.
          regenerated =
            "A different answer entirely, regenerated after the connection dropped mid-stream."

          DraftStream.push(pid, {:text_delta, regenerated})
          assert_receive {:open, {:bubble, 2}, _live}, 1_000

          assert {:ok, :no_draft} = DraftStream.seal(pid, regenerated)

          assert_received {:discard, {:bubble, 2}}
          refute_received {:discard, {:bubble, 1}}
        end)

      assert log =~ "not a prefix"
    end

    test "/stop discards only the live bubble; sealed cards persist" do
      pid = DraftStream.start_link(rotating_spec(self()), @rotate_fast)

      DraftStream.push(pid, {:text_delta, @two_paras})
      assert_receive {:seal, {:bubble, 1}, @para_one}, 1_000

      DraftStream.push(pid, {:text_delta, @two_paras})
      assert_receive {:open, {:bubble, 2}, _live}, 1_000

      assert :ok = DraftStream.discard(pid)
      assert_received {:discard, {:bubble, 2}}
      refute_received {:discard, {:bubble, 1}}
    end
  end

  # -- S2: rolling 💭 status bubble (§6) --------------------------------------

  describe "draft mode: status bubble" do
    test "opens lazily on the first reasoning heading and rolls in place after that" do
      pid = DraftStream.start_link(rotating_spec(self()), @rotate_fast)

      DraftStream.push(pid, {:text_delta, "Working on it now."})
      assert_receive {:open, {:bubble, 1}, "Working on it now."}, 1_000
      refute_received {:open, _handle, "💭" <> _rest}

      DraftStream.push(pid, {:reasoning_done, "**Comparing operators**\n\nbody text"})
      assert_receive {:open, {:bubble, 2}, "💭 Comparing operators"}, 1_000

      DraftStream.push(pid, {:reasoning_done, "**Checking night dives**\n\nbody text"})

      assert_receive {:edit, {:bubble, 2}, "💭 Comparing operators\nChecking night dives"},
                     1_000
    end

    test "the rolling join keeps the newest headings and marks the trim" do
      pid =
        DraftStream.start_link(
          rotating_spec(self(), rotate_at: 40),
          edit_interval_ms: 1,
          min_draft_chars: 1
        )

      for heading <- ["**Alpha one**", "**Beta two**", "**Gamma three**", "**Delta four**"] do
        DraftStream.push(pid, {:reasoning_done, heading <> "\n\nbody"})
        Process.sleep(10)
      end

      assert_receive {:edit, _handle, "💭 …\n" <> kept}, 1_000
      assert String.contains?(kept, "Delta four")
      refute String.contains?(kept, "Alpha one")
      assert String.length("💭 …\n" <> kept) <= 40
    end

    test "the status bubble never writes on a tick that flushed answer content" do
      pid =
        DraftStream.start_link(rotating_spec(self()), edit_interval_ms: 60, min_draft_chars: 1)

      DraftStream.push(pid, {:text_delta, "First snapshot of the answer."})
      assert_receive {:open, {:bubble, 1}, "First snapshot of the answer."}, 1_000

      DraftStream.push(pid, {:reasoning_done, "**Deferred thought**\n\nbody"})
      DraftStream.push(pid, {:text_delta, "First snapshot of the answer. Second half."})

      assert_receive {:edit, {:bubble, 1}, "First snapshot of the answer. Second half."}, 1_000
      # Answer beat the thought on that tick; the bubble only opens later.
      refute_received {:open, _handle, "💭" <> _rest}
      assert_receive {:open, {:bubble, 2}, "💭 Deferred thought"}, 1_000
    end

    test "the status bubble is deleted when the answer is sealed" do
      pid = DraftStream.start_link(rotating_spec(self()), @rotate_fast)

      DraftStream.push(pid, {:reasoning_done, "**Only thought**\n\nbody"})
      assert_receive {:open, {:bubble, 1}, "💭 Only thought"}, 1_000

      DraftStream.push(pid, {:text_delta, "The answer text arrives."})
      assert_receive {:open, {:bubble, 2}, "The answer text arrives."}, 1_000

      assert {:ok, nil} = DraftStream.seal(pid, "The answer text arrives.")
      assert_receive {:discard, {:bubble, 1}}, 1_000
      refute_received {:discard, {:bubble, 2}}
    end

    test "the status bubble is deleted on /stop along with the live draft" do
      pid = DraftStream.start_link(rotating_spec(self()), @rotate_fast)

      DraftStream.push(pid, {:reasoning_done, "**Only thought**\n\nbody"})
      assert_receive {:open, {:bubble, 1}, "💭 Only thought"}, 1_000

      DraftStream.push(pid, {:text_delta, "Half an answer."})
      assert_receive {:open, {:bubble, 2}, "Half an answer."}, 1_000

      assert :ok = DraftStream.discard(pid)
      assert_received {:discard, {:bubble, 2}}
      assert_receive {:discard, {:bubble, 1}}, 1_000
    end

    test "a failed status write is logged and never fails the seal" do
      test_pid = self()

      failing_open = fn text ->
        if String.starts_with?(text, "💭"), do: {:error, :status_boom}, else: {:ok, {:bubble, 1}}
      end

      log =
        capture_log(fn ->
          pid =
            DraftStream.start_link(rotating_spec(test_pid, open: failing_open), @rotate_fast)

          DraftStream.push(pid, {:reasoning_done, "**Doomed thought**\n\nbody"})
          Process.sleep(40)

          DraftStream.push(pid, {:text_delta, "The answer still lands."})
          Process.sleep(40)

          assert {:ok, nil} = DraftStream.seal(pid, "The answer still lands.")
        end)

      assert log =~ "status_boom"
    end

    # The 💭 bubble writes only on ticks the answer had nothing new, so
    # consecutive status-only ticks are the normal case during a tool-heavy
    # stretch. On a shared breaker two refused cosmetic writes would spend the
    # answer's whole failure budget and freeze its preview for the rest of the
    # turn — the answer's own writes having never failed at all.
    test "consecutive status-write failures never freeze the answer preview" do
      test_pid = self()

      picky_open = fn text ->
        if String.starts_with?(text, "💭") do
          send(test_pid, {:status_refused, text})
          {:error, :status_boom}
        else
          send(test_pid, {:open, {:bubble, 1}, text})
          {:ok, {:bubble, 1}}
        end
      end

      log =
        capture_log(fn ->
          pid = DraftStream.start_link(rotating_spec(test_pid, open: picky_open), @rotate_fast)

          DraftStream.push(pid, {:reasoning_done, "**First thought**\n\nbody"})
          assert_receive {:status_refused, _first}, 1_000

          DraftStream.push(pid, {:reasoning_done, "**Second thought**\n\nbody"})
          assert_receive {:status_refused, _second}, 1_000

          DraftStream.push(pid, {:text_delta, "The answer still opens."})
          assert_receive {:open, {:bubble, 1}, "The answer still opens."}, 1_000
        end)

      assert log =~ "status_boom"
    end

    # ... and the status bubble does not retry a refusing API forever either.
    test "the status bubble stops asking after the failure cap" do
      test_pid = self()

      refusing_open = fn text ->
        send(test_pid, {:status_refused, text})
        {:error, :status_boom}
      end

      capture_log(fn ->
        pid = DraftStream.start_link(rotating_spec(test_pid, open: refusing_open), @rotate_fast)

        for label <- ["**One**", "**Two**", "**Three**", "**Four**"] do
          DraftStream.push(pid, {:reasoning_done, label <> "\n\nbody"})
          Process.sleep(15)
        end

        for _attempt <- 1..2, do: assert_receive({:status_refused, _text}, 1_000)
        refute_received {:status_refused, _text}
      end)
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
