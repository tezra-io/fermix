defmodule FermixCore.Realtime.VoiceBridgeTest do
  @moduledoc """
  Core owns the voice-bridge behaviour; `fermix_channels` registers the
  implementation at boot. Core must never name a Channels module, so the only
  thing it can assert is the resolution contract and the callback list.
  """

  use ExUnit.Case, async: false

  alias FermixCore.Realtime.VoiceBridge

  defmodule StubBridge do
    @moduledoc false
    @behaviour FermixCore.Realtime.VoiceBridge

    @impl true
    def open_call(_call), do: {:ok, :handle}

    @impl true
    def submit(_handle, _request, _callbacks), do: {:ok, :task}

    @impl true
    def cancel(_handle, _task_ref), do: :ok

    @impl true
    def close_call(_handle), do: :ok
  end

  setup do
    previous = Application.get_env(:fermix_core, :voice_bridge)
    Application.delete_env(:fermix_core, :voice_bridge)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:fermix_core, :voice_bridge)
        module -> Application.put_env(:fermix_core, :voice_bridge, module)
      end
    end)

    :ok
  end

  test "resolve refuses when no channel app registered a bridge" do
    assert {:error, :voice_bridge_unavailable} = VoiceBridge.resolve()
  end

  test "resolve returns the registered bridge module" do
    Application.put_env(:fermix_core, :voice_bridge, StubBridge)

    assert {:ok, StubBridge} = VoiceBridge.resolve()
  end

  test "resolve fails loud on a value that is not a module" do
    Application.put_env(:fermix_core, :voice_bridge, "FermixChannels.Voice.Bridge")

    assert_raise ArgumentError, ~r/voice_bridge must be a module/, fn -> VoiceBridge.resolve() end
  end

  test "the behaviour declares the four call-scoped callbacks" do
    assert Enum.sort(VoiceBridge.behaviour_info(:callbacks)) ==
             Enum.sort(open_call: 1, submit: 3, cancel: 2, close_call: 1)
  end
end
