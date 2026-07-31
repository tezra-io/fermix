defmodule FermixCore.Realtime.ScreenCaptureTest do
  use ExUnit.Case, async: false

  alias FermixCore.Realtime.ScreenCapture

  # A driver stub in place of the compux sidecar: no Port, no binary, no TCC grant
  # (the hermetic-tests rule — this suite must never touch host state).
  defmodule FakeDriver do
    def start(opts) do
      case Keyword.get(opts, :start) do
        {:error, reason} ->
          {:error, reason}

        _ok ->
          {:ok, %{port: nil, responses: Keyword.get(opts, :responses, []), owner: opts[:owner]}}
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

    assert_receive {:screen_capture, 7, {:ok, frame}}, 1_000
    assert frame.mime_type == "image/png"
    assert frame.data == "pixels"
  end

  # Stage A adds no new sidecar params: it asks for the same read-only screenshot
  # the model's own `computer_use` look uses, validated through the shared protocol.
  test "the request is a plain read-only screenshot on the configured display" do
    capture = start_capture([])
    ScreenCapture.request(capture, 1)

    assert_receive {:executed, request}, 1_000
    assert request["action"] == "screenshot"
    assert request["display"] == 0
    refute Map.has_key?(request, "screenshot_after")
    # Feed frames are awareness-only: never ruler-gridded, never mark-badged —
    # those grounding overlays belong to the tool path (M28), and drawing them
    # on ambient frames would present a pseudo-aiming surface.
    refute Map.has_key?(request, "rulers")
    refute Map.has_key?(request, "marks")
  end

  test "a malformed frame fails loud rather than shipping garbage to the model" do
    capture = start_capture(responses: [{:ok, %{"data" => "not base64!", "mime" => "image/png"}}])
    ScreenCapture.request(capture, 1)

    assert_receive {:screen_capture, 1, {:error, :invalid_base64_frame}}, 1_000
  end

  test "a response with no image is an error, not an empty frame" do
    capture = start_capture(responses: [{:ok, %{"ok" => true}}])
    ScreenCapture.request(capture, 1)

    assert_receive {:screen_capture, 1, {:error, :missing_frame_data}}, 1_000
  end

  test "a driver error is passed through with its type intact" do
    capture = start_capture(responses: [{:error, {:timeout, 30_000}}])
    ScreenCapture.request(capture, 1)

    # The feed classifies wedges by this shape, so it must not be flattened.
    assert_receive {:screen_capture, 1, {:error, {:timeout, 30_000}}}, 1_000
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
    assert_receive :stopped, 1_000
  end

  test "stop is idempotent" do
    capture = start_capture([])
    assert :ok = ScreenCapture.stop(capture)
    assert :ok = ScreenCapture.stop(capture)
  end
end
