defmodule FermixCore.Capabilities.MCP.Remote.SSETest do
  use ExUnit.Case, async: true

  alias FermixCore.Capabilities.MCP.Remote.Limits
  alias FermixCore.Capabilities.MCP.Remote.SSE

  defp feed_all(chunks) do
    Enum.reduce(chunks, {:ok, [], SSE.new()}, fn chunk, {:ok, acc, state} ->
      {:ok, events, state} = SSE.feed(state, chunk)
      {:ok, acc ++ events, state}
    end)
  end

  describe "incremental parsing" do
    test "emits an event only once its terminating blank line arrives" do
      {:ok, events, state} = SSE.feed(SSE.new(), "data: {\"a\":1}")
      assert events == []

      {:ok, events, _state} = SSE.feed(state, "\n\n")
      assert [%{data: "{\"a\":1}"}] = events
    end

    test "reassembles an event split across arbitrary chunk boundaries" do
      chunks = for <<c::binary-1 <- "event: message\ndata: hello\n\n">>, do: c
      {:ok, events, _state} = feed_all(chunks)

      assert [%{data: "hello", event: "message"}] = events
    end

    test "carries id and multi-line data" do
      {:ok, events, _state} = SSE.feed(SSE.new(), "id: 7\ndata: one\ndata: two\n\n")

      assert [%{data: "one\ntwo", id: "7"}] = events
    end

    test "strips exactly one space after the colon" do
      {:ok, events, _state} = SSE.feed(SSE.new(), "data:  padded\n\n")

      assert [%{data: " padded"}] = events
    end

    test "ignores comment lines and keep-alive blocks" do
      {:ok, events, _state} = SSE.feed(SSE.new(), ": keep-alive\n\ndata: real\n\n")

      assert [%{data: "real"}] = events
    end
  end

  describe "line-ending normalization" do
    test "handles CRLF terminators" do
      {:ok, events, _state} = SSE.feed(SSE.new(), "data: x\r\n\r\n")

      assert [%{data: "x"}] = events
    end

    # A chunk ending in "\r" whose next chunk starts with "\n" must not be
    # normalized into "\n\n" — that would fabricate an event boundary in the
    # middle of one CRLF pair and split a single event in two.
    test "does not fabricate an event boundary from a CRLF split across chunks" do
      {:ok, events, state} = SSE.feed(SSE.new(), "data: first\r")
      assert events == []

      {:ok, events, state} = SSE.feed(state, "\ndata: second\r\n\r\n")

      assert [%{data: "first\nsecond"}] = events
      assert :ok = SSE.finish(state)
    end

    test "handles bare CR terminators" do
      {:ok, events, _state} = SSE.feed(SSE.new(), "data: x\r\rdata: y\r\r")

      assert [%{data: "x"}, %{data: "y"}] = events
    end
  end

  describe "bounds" do
    test "refuses a single event larger than the per-event cap" do
      oversized = String.duplicate("x", Limits.max_sse_event_bytes() + 1)

      assert {:error, {:sse_limit, :event_bytes, _size}} =
               SSE.feed(SSE.new(), "data: " <> oversized <> "\n\n")
    end

    test "refuses an unterminated event that grows past the per-event cap" do
      oversized = String.duplicate("x", Limits.max_sse_event_bytes() + 1)

      assert {:error, {:sse_limit, :event_bytes, _size}} = SSE.feed(SSE.new(), oversized)
    end

    test "refuses a stream larger than the whole-stream cap" do
      chunk = String.duplicate("a", 512 * 1024)
      chunks = List.duplicate("data: " <> chunk <> "\n\n", 16)

      assert {:error, {:sse_limit, :stream_bytes, _size}} =
               Enum.reduce_while(chunks, {:ok, SSE.new()}, fn chunk, {:ok, state} ->
                 case SSE.feed(state, chunk) do
                   {:ok, _events, state} -> {:cont, {:ok, state}}
                   {:error, _reason} = error -> {:halt, error}
                 end
               end)
    end

    test "refuses more events than the event-count cap" do
      one = "data: x\n\n"
      chunk = String.duplicate(one, Limits.max_sse_events() + 1)

      assert {:error, {:sse_limit, :event_count, _count}} = SSE.feed(SSE.new(), chunk)
    end
  end

  describe "finish/1" do
    test "accepts a cleanly terminated stream" do
      {:ok, _events, state} = SSE.feed(SSE.new(), "data: x\n\n")

      assert :ok = SSE.finish(state)
    end

    # A peer that stops mid-event delivered a truncated response. Salvaging the
    # partial buffer as a final event would hand on half a JSON-RPC message.
    test "refuses a stream that ended mid-event" do
      {:ok, _events, state} = SSE.feed(SSE.new(), "data: partial")

      assert {:error, {:sse_truncated_event, _bytes}} = SSE.finish(state)
    end
  end
end
