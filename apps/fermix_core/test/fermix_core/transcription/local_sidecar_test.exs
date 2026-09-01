defmodule FermixCore.Transcription.Local.SidecarTest do
  # async: true — every case drives its own Port against the perl fake and
  # touches no global state.
  use ExUnit.Case, async: true

  alias FermixCore.Transcription.Local.Sidecar

  @fake Path.expand("fake_stt_sidecar.pl", __DIR__)
  @fixtures Path.expand("fixtures/stt_sidecar", __DIR__)

  # Short deadlines so the hang cases fail fast; production callers pass none of
  # these and get the FermixCore.Timeouts values.
  @fast [hello_timeout_ms: 500, batch_timeout_ms: 500]

  describe "codec" do
    test "decodes every golden frame" do
      assert {:ok, %{"event" => "hello", "protocol_version" => 1, "engine" => "sherpa-onnx"}} =
               decode_fixture("hello.json")

      assert {:ok, %{"event" => "result", "id" => "b1", "text" => text}} =
               decode_fixture("result.json")

      assert text =~ "quick brown fox"

      assert {:ok, %{"event" => "segment", "t0_ms" => 0, "t1_ms" => 1200}} =
               decode_fixture("segment.json")

      assert {:ok, %{"event" => "stream_done", "segments" => 2}} =
               decode_fixture("stream_done.json")

      assert {:ok, %{"event" => "error", "code" => "decode_failed"}} =
               decode_fixture("error.json")

      assert {:ok, %{"event" => "stream_started", "id" => "s1"}} =
               decode_fixture("stream_started.json")
    end

    test "the golden hello matches the version this build speaks" do
      {:ok, hello} = decode_fixture("hello.json")
      assert hello["protocol_version"] == Sidecar.protocol_version()
    end

    test "encode emits one newline-terminated JSON object" do
      line = IO.iodata_to_binary(Sidecar.encode(%{"op" => "shutdown"}))

      assert String.ends_with?(line, "\n")
      assert {:ok, %{"op" => "shutdown"}} = Sidecar.decode_line(String.trim_trailing(line, "\n"))
    end

    test "undecodable and non-object lines are reported, never guessed at" do
      assert {:error, {:malformed, "not json"}} = Sidecar.decode_line("not json")
      assert {:error, {:malformed, "[1,2,3]"}} = Sidecar.decode_line("[1,2,3]")
    end

    test "chunk_pcm splits at the audio frame cap and keeps sample alignment" do
      cap = Sidecar.audio_chunk_bytes()
      pcm = :binary.copy(<<1, 0>>, div(cap, 2) + 7)

      chunks = Sidecar.chunk_pcm(pcm)

      assert [^cap, 14] = Enum.map(chunks, &byte_size/1)
      assert IO.iodata_to_binary(chunks) == pcm
      assert Enum.all?(chunks, &(rem(byte_size(&1), 2) == 0))
    end

    test "chunk_pcm leaves a chunk at or under the cap alone" do
      pcm = :binary.copy(<<0, 1>>, 10)
      assert Sidecar.chunk_pcm(pcm) == [pcm]
    end
  end

  describe "line reassembly" do
    test "a noeol run accumulates until the terminator arrives" do
      state = %{port: nil, acc: "", session_id: nil}
      line = ~s({"event":"result","id":"b1","text":"hello there","duration_ms":1})
      {head, tail} = String.split_at(line, 20)

      assert {:partial, state} = Sidecar.handle_data(state, {:noeol, head})
      assert state.acc == head
      assert {:line, frame, state} = Sidecar.handle_data(state, {:eol, tail})
      assert frame["text"] == "hello there"
      assert state.acc == ""
    end

    test "a line past the cap is a protocol error, not more buffering" do
      state = %{port: nil, acc: "", session_id: nil}
      oversize = :binary.copy("x", 8_388_608 + 1)

      assert {:error, {:protocol_error, {:line_too_long, _bytes}}, state} =
               Sidecar.handle_data(state, {:noeol, oversize})

      assert state.acc == ""
    end

    test "a malformed whole line is a protocol error and clears the accumulator" do
      state = %{port: nil, acc: "", session_id: nil}

      assert {:error, {:protocol_error, {:malformed, "{oops"}}, state} =
               Sidecar.handle_data(state, {:eol, "{oops"})

      assert state.acc == ""
    end
  end

  describe "handshake" do
    test "opens against the fake sidecar and closes cleanly" do
      assert {:ok, state} = Sidecar.open(binary_path: @fake)
      assert is_port(state.port)
      assert Sidecar.close(state) == :ok
    end

    test "refuses a protocol-version mismatch" do
      assert {:error, {:protocol_mismatch, %{fermix: 1, sidecar: 2}}} =
               Sidecar.open(binary_path: @fake, env: [{~c"FAKE_STT_PROTO", ~c"2"}])
    end

    test "a missing binary fails loud without spawning anything" do
      assert Sidecar.open(binary_path: "/no/such/fermix-stt") ==
               {:error, {:sidecar_missing, "/no/such/fermix-stt"}}
    end

    test "a silent sidecar trips the hello deadline with the Timeouts shape" do
      assert {:error, {:timeout, :stt_sidecar_hello, 300}} =
               Sidecar.open(
                 binary_path: @fake,
                 hello_timeout_ms: 300,
                 env: [{~c"FAKE_STT_MODE", ~c"hang_hello"}]
               )
    end

    # Rule 4 (own resources on every path): a sidecar wedged in compute is not
    # reading stdin, so the shutdown op and the port's EOF are never observed —
    # close must SIGKILL its process group after the grace, or every timeout
    # teardown orphans a fermix-stt with the model resident. ERTS makes each
    # spawn_executable child its own group leader, so kill(-os_pid) is exactly
    # the sidecar (and :esrch — already exited — is silent success).
    test "close kills a sidecar that ignores shutdown instead of orphaning it" do
      assert {:ok, state} =
               Sidecar.open(binary_path: @fake, env: [{~c"FAKE_STT_MODE", ~c"hang"}])

      assert is_integer(state.os_pid) and state.os_pid > 0

      # Wedge it: `hang` sleeps 10s inside transcribe, reading nothing.
      :ok =
        Sidecar.send_op(state, %{
          "op" => "transcribe",
          "id" => "w1",
          "path" => "/nonexistent.wav",
          "model_dir" => "/nonexistent"
        })

      assert Sidecar.close(state) == :ok

      # Dead well before the 10s sleep could end on its own, so the exit came
      # from close's kill and not from the sidecar finishing on its own.
      assert eventually_dead(state.os_pid, 3_000)
    end
  end

  defp eventually_dead(os_pid, budget_ms) do
    deadline = System.monotonic_time(:millisecond) + budget_ms
    poll_dead(os_pid, deadline)
  end

  # The probe must OBSERVE liveness, never cause it: probing with
  # kill_pgid(_, :sigkill) would kill the very group it is asking about, so the
  # assertion held whether or not close/1 killed anything and the gate could
  # not fail. `kill -0` is the non-destructive check this suite already uses in
  # command_host_test.exs.
  defp poll_dead(os_pid, deadline) do
    cond do
      not alive?(os_pid) -> true
      System.monotonic_time(:millisecond) >= deadline -> false
      true -> Process.sleep(25) && poll_dead(os_pid, deadline)
    end
  end

  defp alive?(os_pid) do
    {_out, status} =
      System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)

    status == 0
  end

  describe "batch/2" do
    test "returns the sidecar's transcript" do
      assert Sidecar.batch("/tmp/note.ogg", batch_opts()) == {:ok, "fake transcript"}
    end

    test "reassembles a transcript far longer than the port's line window" do
      assert {:ok, text} = Sidecar.batch("/tmp/note.ogg", batch_opts(~c"long"))

      assert byte_size(text) > 65_536
      assert String.starts_with?(text, "fake ")
    end

    test "surfaces an error frame with its code and message" do
      assert {:error, {:sidecar_error, "decode_failed", message}} =
               Sidecar.batch("/tmp/note.ogg", batch_opts(~c"error"))

      assert message == "fake decode failure"
    end

    test "a sidecar that dies mid-request reports its exit status" do
      assert Sidecar.batch("/tmp/note.ogg", batch_opts(~c"die")) ==
               {:error, {:sidecar_exit, 3}}
    end

    test "a sidecar that never answers trips the batch deadline" do
      assert {:error, {:timeout, :stt_sidecar_batch, 500}} =
               Sidecar.batch("/tmp/note.ogg", batch_opts(~c"hang"))
    end

    test "an unresolvable model directory refuses before spawning" do
      assert Sidecar.batch("/tmp/note.ogg", binary_path: @fake) ==
               {:error, :model_not_installed}
    end
  end

  defp batch_opts(mode \\ nil) do
    env = if mode, do: [{~c"FAKE_STT_MODE", mode}], else: []
    Keyword.merge(@fast, binary_path: @fake, model_dir: "/tmp/fake-model", env: env)
  end

  defp decode_fixture(name) do
    @fixtures
    |> Path.join(name)
    |> File.read!()
    |> String.trim_trailing("\n")
    |> Sidecar.decode_line()
  end
end
