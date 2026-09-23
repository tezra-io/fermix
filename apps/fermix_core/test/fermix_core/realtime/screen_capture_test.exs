defmodule FermixCore.Realtime.ScreenCaptureTest do
  use ExUnit.Case, async: false

  alias FermixCore.Realtime.ScreenCapture

  # A driver stub in place of the compux sidecar: no Port, no binary, no TCC grant
  # (the hermetic-tests rule — this suite must never touch host state). It carries
  # no `:port`: the Port belongs to the transport now, and the sidecar's death
  # reaches this process as a message rather than as a Port event.
  defmodule FakeDriver do
    def start(opts) do
      case Keyword.get(opts, :start) do
        {:error, reason} ->
          {:error, reason}

        _ok ->
          {:ok, %{responses: Keyword.get(opts, :responses, []), owner: opts[:owner]}}
      end
    end

    def execute(state, request) do
      send(state.owner, {:executed, request})

      case state.responses do
        [] -> {:ok, %{"data" => Base.encode64("pixels"), "mime" => "image/png"}}
        [response | _rest] -> response
      end
    end

    def stop(state) do
      send(state.owner, :stopped)
      :ok
    end
  end

  defp start_capture(driver_opts) do
    {:ok, pid} =
      ScreenCapture.start_link(
        owner: self(),
        display: 0,
        driver: {FakeDriver, Keyword.put(driver_opts, :owner, self())}
      )

    on_exit(fn -> if Process.alive?(pid), do: ScreenCapture.stop(pid) end)
    pid
  end

  test "a capture decodes the sidecar's base64 frame into raw bytes" do
    capture = start_capture([])
    ScreenCapture.request(capture, 7)

    assert_receive {:screen_capture, 7, {:ok, frame}}
    assert frame.mime_type == "image/png"
    assert frame.data == "pixels"
  end

  # Stage A adds no new sidecar params: it asks for the same read-only screenshot
  # the model's own `computer_use` look uses, validated through the shared protocol.
  test "the request is a plain read-only screenshot on the configured display" do
    capture = start_capture([])
    ScreenCapture.request(capture, 1)

    assert_receive {:executed, request}
    assert request["action"] == "screenshot"
    assert request["display"] == 0
    # The ambient feed is a look, and a look asks for no evidence of its own: it
    # dispatches nothing, so there is nothing a check could be about.
    refute Map.has_key?(request, "check")
    # Feed frames are awareness-only: never ruler-gridded, never mark-badged —
    # those grounding overlays belong to the tool path (M28), and drawing them
    # on ambient frames would present a pseudo-aiming surface.
    refute Map.has_key?(request, "rulers")
    refute Map.has_key?(request, "marks")
    # M42 slice 3: this process owns its OWN helper, so the ids that helper mints
    # belong to no conversation's table. It names none on the way out, and it must
    # never send a pointer action — a frame the model was shown as awareness is
    # not a surface it may aim in.
    refute Map.has_key?(request, "observation_id")
  end

  # The ambient feed keeps no table, so a reply's observation fields are inert here
  # — the frame decodes exactly as it did before they existed. Nothing may leak an
  # id to the model through this path: the caption a frame carries is written by
  # `Realtime.OpenAIClient`, not from the reply.
  test "the new observation fields on a reply are ignored, and the frame still decodes" do
    capture =
      start_capture(
        responses: [
          {:ok,
           %{
             "data" => Base.encode64("pixels"),
             "mime" => "image/png",
             "observation_id" => "feed-1",
             "observation_kind" => "image",
             "captured_at_monotonic_ns" => 1_000,
             "frame_seq" => 12
           }}
        ]
      )

    ScreenCapture.request(capture, 3)

    assert_receive {:screen_capture, 3, {:ok, frame}}
    assert frame == %{mime_type: "image/png", data: "pixels"}
  end

  test "a malformed frame fails loud rather than shipping garbage to the model" do
    capture = start_capture(responses: [{:ok, %{"data" => "not base64!", "mime" => "image/png"}}])
    ScreenCapture.request(capture, 1)

    assert_receive {:screen_capture, 1, {:error, :invalid_base64_frame}}
  end

  test "a response with no image is an error, not an empty frame" do
    capture = start_capture(responses: [{:ok, %{"ok" => true}}])
    ScreenCapture.request(capture, 1)

    assert_receive {:screen_capture, 1, {:error, :missing_frame_data}}
  end

  test "a driver error is passed through with its type intact" do
    capture = start_capture(responses: [{:error, {:timeout, 30_000}}])
    ScreenCapture.request(capture, 1)

    # The feed classifies wedges by this shape, so it must not be flattened.
    assert_receive {:screen_capture, 1, {:error, {:timeout, 30_000}}}
  end

  test "an unstartable driver refuses to start the process at all" do
    Process.flag(:trap_exit, true)

    assert {:error, :sidecar_missing} =
             ScreenCapture.start_link(
               owner: self(),
               display: 0,
               driver: {FakeDriver, [start: {:error, :sidecar_missing}, owner: self()]}
             )
  end

  # Port close alone leaves the sidecar OS process alive; only the driver's stop
  # ends it, which is what keeps a leaked client from wedging capture system-wide.
  test "stopping releases the driver" do
    capture = start_capture([])
    assert :ok = ScreenCapture.stop(capture)
    assert_receive :stopped
  end

  test "stop is idempotent" do
    capture = start_capture([])
    assert :ok = ScreenCapture.stop(capture)
    assert :ok = ScreenCapture.stop(capture)
  end

  # The sidecar's death reaches this process as a message from the transport, not
  # as a Port event: this process no longer owns a Port. The stop reason has to
  # stay the shape `ScreenFeed.wedge?/1` reads, or the capture-stall self-reap
  # (75) stops feeding the breaker and a wedged host is handed fresh sidecars
  # forever — the amplification that reverted the `watch` construct.
  describe "the sidecar ending" do
    test "a capture-stall exit stops capture with the reason the feed counts as a wedge" do
      Process.flag(:trap_exit, true)
      pid = start_capture([])

      send(pid, {:compux_sidecar_exit, self(), 75})

      assert_receive {:EXIT, ^pid, {:shutdown, {:sidecar_exited, 75}}}
      assert_receive :stopped
    end

    # A transport that ended an unusable wire is a fault, and its payload is a
    # term — so it can never be mistaken for the 75 the sidecar chooses itself.
    test "a poisoned wire stops capture without looking like a capture stall" do
      Process.flag(:trap_exit, true)
      pid = start_capture([])

      send(pid, {:compux_sidecar_exit, self(), {:poisoned, {:malformed_frame, :nope}}})

      assert_receive {:EXIT, ^pid,
                      {:shutdown, {:sidecar_exited, {:poisoned, {:malformed_frame, :nope}}}}}
    end
  end
end
