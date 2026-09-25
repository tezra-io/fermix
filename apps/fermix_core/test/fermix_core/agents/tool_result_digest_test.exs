defmodule FermixCore.Agents.ToolResultDigestTest do
  use ExUnit.Case, async: true

  alias FermixCore.Agents.ToolResultDigest

  # Records every chat call it receives and answers from a scripted queue.
  defmodule DigestAdapter do
    def chat(messages, capabilities, opts) do
      send(self(), {:digest_call, messages, capabilities, opts})

      case Process.get(:digest_responses, []) do
        [next | rest] ->
          Process.put(:digest_responses, rest)
          next

        [] ->
          {:ok, %{content: "DIGEST", usage: %{total_tokens: 7}}}
      end
    end
  end

  @route_key %{provider: :mock, model: "mock", auth_mode: :api_key, base_url: "mock://"}

  defp opts(overrides \\ []) do
    Keyword.merge(
      [
        task: "count the rows",
        tool_name: "web_fetch",
        adapter: DigestAdapter,
        route: {@route_key, [model: "mock", stream_callback: fn _ -> :ok end, agent: "main"]},
        context_window: 200_000,
        retry_delay_fn: fn _ms -> :ok end
      ],
      overrides
    )
  end

  # 200k window → chunk = min(24_000, 80_000) tokens × 4 = 96_000 bytes.
  @chunk_bytes 96_000

  describe "chunk/2" do
    test "a text within the bound is one chunk" do
      assert ToolResultDigest.chunk("a\nb", 10) == ["a\nb"]
    end

    test "packs whole lines up to the bound" do
      text = Enum.map_join(1..10, "\n", fn _ -> "0123456789" end)
      chunks = ToolResultDigest.chunk(text, 25)

      assert Enum.all?(chunks, &(byte_size(&1) <= 25))
      assert Enum.join(chunks, "\n") == text
      assert length(chunks) == 5
    end

    test "hard-splits a single line longer than the bound on UTF-8 boundaries" do
      line = String.duplicate("é", 50)
      chunks = ToolResultDigest.chunk(line, 21)

      assert Enum.all?(chunks, &(byte_size(&1) <= 21))
      assert Enum.all?(chunks, &String.valid?/1)
      assert Enum.join(chunks) == line
    end
  end

  describe "digest/2" do
    test "a small input is one call carrying the task, the tool and the role fence" do
      Process.put(:digest_responses, [{:ok, %{content: "  short  ", usage: %{total_tokens: 11}}}])
      text = String.duplicate("row\n", 100)

      assert {:ok, "short", 11} = ToolResultDigest.digest(text, opts())

      assert_received {:digest_call, [system, user], [], call_opts}
      assert system.role == "system"
      assert system.content =~ "Output only the digest"
      assert user.content =~ "count the rows"
      assert user.content =~ "web_fetch (part 1 of 1)"
      assert user.content =~ "row\nrow"
      refute_received {:digest_call, _, _, _}
      refute Keyword.has_key?(call_opts, :stream_callback)
      assert call_opts[:agent] == "tool_result_digest"
      assert call_opts[:reasoning_effort] == :medium
    end

    test "a large input is chunked against the route's window and the digests joined" do
      text = Enum.map_join(1..3_500, "\n", fn i -> "line #{i} " <> String.duplicate("x", 90) end)
      assert byte_size(text) > 3 * @chunk_bytes

      Process.put(
        :digest_responses,
        Enum.map(1..4, fn i -> {:ok, %{content: "part#{i}", usage: %{total_tokens: 1}}} end)
      )

      assert {:ok, "part1\n\npart2\n\npart3\n\npart4", 4} = ToolResultDigest.digest(text, opts())

      for i <- 1..4 do
        assert_received {:digest_call, [_system, user], [], _opts}
        assert user.content =~ "(part #{i} of 4)"
      end
    end

    test "a smaller window makes smaller chunks" do
      text = Enum.map_join(1..800, "\n", fn i -> "line #{i} " <> String.duplicate("x", 90) end)
      # 128k window → 24_000 tokens still, so 96 KB; 40k window → 16_000 tokens → 64 KB.
      assert {:ok, _digest, _tokens} = ToolResultDigest.digest(text, opts(context_window: 40_000))

      assert_received {:digest_call, _, _, _}
      assert_received {:digest_call, _, _, _}
      refute_received {:digest_call, _, _, _}
    end

    test "a single line longer than a chunk is split, never sent whole" do
      text = String.duplicate("z", @chunk_bytes * 2 + 10)

      assert {:ok, _digest, _tokens} = ToolResultDigest.digest(text, opts())

      for _ <- 1..3 do
        assert_received {:digest_call, [_system, user], [], _opts}
        assert byte_size(user.content) < @chunk_bytes + 500
      end
    end

    test "a join that still exceeds a chunk is digested again, bounded in depth" do
      text = Enum.map_join(1..3_500, "\n", fn i -> "line #{i} " <> String.duplicate("x", 90) end)
      big = String.duplicate("y", @chunk_bytes)
      # Level 1: four chunk digests, each a full chunk → join exceeds a chunk.
      # Level 2: the join re-chunks into four, digested to full chunks again.
      # Level 3: same. A fourth level is refused.
      Process.put(:digest_responses, List.duplicate({:ok, %{content: big, usage: %{}}}, 40))

      assert {:error, {:digest_failed, :too_deep}} = ToolResultDigest.digest(text, opts())
    end

    test "a digest no shorter than its input is not compressible" do
      Process.put(:digest_responses, [
        {:ok, %{content: "longer than in", usage: %{total_tokens: 2}}}
      ])

      assert {:not_compressible, 2} = ToolResultDigest.digest("short", opts())
    end

    test "an empty summary is a failure" do
      Process.put(:digest_responses, [{:ok, %{content: "   ", usage: %{}}}])
      assert {:error, {:digest_failed, :empty_summary}} = ToolResultDigest.digest("text", opts())
    end

    test "a provider error is returned, not retried past the transient budget" do
      reason = {:provider_error, %{kind: :auth, provider: :mock}}
      Process.put(:digest_responses, [{:error, reason}])
      assert {:error, {:digest_failed, ^reason}} = ToolResultDigest.digest("text", opts())
    end

    test "before_call runs once per summarizer call" do
      test_pid = self()
      text = Enum.map_join(1..3_500, "\n", fn i -> "line #{i} " <> String.duplicate("x", 90) end)

      assert {:ok, _digest, _tokens} =
               ToolResultDigest.digest(text, opts(before_call: fn -> send(test_pid, :before) end))

      for _ <- 1..4, do: assert_received(:before)
      refute_received :before
    end
  end
end
