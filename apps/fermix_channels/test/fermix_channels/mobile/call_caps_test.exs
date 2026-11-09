defmodule FermixChannels.Mobile.CallCapsTest do
  @moduledoc """
  What a phone's `hello_ack` says of calls (M87 `caps.call`), and the checks a
  `call_open` repeats.
  """

  # Reads and writes the global providers app env, where a voice key lives.
  use ExUnit.Case, async: false

  alias FermixChannels.Mobile.Call
  alias FermixCore.Realtime.Config

  @phone "0d7f6a52-91c3-4b8e-a1f0-5e2d9c4b7a13"

  setup do
    previous = Application.get_env(:fermix_core, :providers, [])
    on_exit(fn -> Application.put_env(:fermix_core, :providers, previous) end)
    Application.put_env(:fermix_core, :providers, Keyword.delete(previous, :openai))
    :ok
  end

  test "a task engine with its key, running, serves calls at its own floor" do
    put_openai_key()
    live = Config.normalize(enabled: true, engine: "openai_live", model: "gpt-live-1")

    assert Call.caps(live, true, @phone) == %{
             "available" => true,
             "min_version" => 2,
             "max_version" => 4,
             "camera" => true
           }
  end

  # M87 Phase 2: a task engine takes the phone's camera frames while the
  # owner's camera_share is on; the Realtime engine takes no phone call at all.
  test "the camera is offered on a task engine with camera_share on, and nowhere else" do
    put_openai_key()
    grok = Config.normalize(enabled: true, engine: "xai_realtime", model: "grok-voice-3.0")

    no_camera =
      Config.normalize(
        enabled: true,
        engine: "openai_live",
        model: "gpt-live-1",
        camera_share: false
      )

    assert %{"camera" => true} = Call.caps(grok, true, @phone)
    assert %{"camera" => false} = Call.caps(no_camera, true, @phone)
    assert %{"camera" => false} = Call.caps(Config.normalize(enabled: true), true, @phone)
  end

  test "each reason a call is not served is said, the window still published" do
    put_openai_key()
    live = Config.normalize(enabled: true, engine: "openai_live", model: "gpt-live-1")
    off = Config.normalize(enabled: false, engine: "openai_live", model: "gpt-live-1")
    realtime = Config.normalize(enabled: true)

    assert %{"available" => false, "reason" => "voice_off", "min_version" => 2} =
             Call.caps(off, true, @phone)

    # Turned on, waiting for the restart that starts its runtime.
    assert %{"available" => false, "reason" => "voice_off"} = Call.caps(live, false, @phone)

    assert %{"available" => false, "reason" => "engine_not_for_phones", "min_version" => 1} =
             Call.caps(realtime, true, @phone)
  end

  # A key kept in the Mac's Keychain moves to a server only as a reference.
  test "a voice key the primary does not hold is no_key" do
    live = Config.normalize(enabled: true, engine: "openai_live", model: "gpt-live-1")

    assert %{"available" => false, "reason" => "no_key"} = Call.caps(live, true, @phone)
    assert Call.readiness(live, true) == {:error, :no_key}
  end

  test "a call_open repeats the voice checks, not the engine's" do
    put_openai_key()
    realtime = Config.normalize(enabled: true)

    assert Call.readiness(realtime, true) == :ok
    assert Call.readiness(Config.normalize(enabled: false), true) == {:error, :voice_off}
    assert Call.readiness(realtime, false) == {:error, :voice_off}
  end

  defp put_openai_key do
    providers = Application.get_env(:fermix_core, :providers, [])

    Application.put_env(
      :fermix_core,
      :providers,
      Keyword.put(providers, :openai, api_key: "sk-1")
    )
  end
end
