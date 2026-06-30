defmodule FermixCore.ComputerUse.ProbeTest do
  use ExUnit.Case, async: true

  alias FermixCore.ComputerUse.Probe

  # Stub Drivers run inline in the test process (Probe.run/1 is synchronous, spawns
  # nothing), so `self()` inside a callback is the test pid — messages land here.

  defmodule MacStub do
    @behaviour FermixCore.ComputerUse.Driver

    @impl true
    def start(opts) do
      send(self(), {:start, Keyword.get(opts, :binary_path)})
      {:ok, %{}}
    end

    @impl true
    def execute(_state, request) do
      send(self(), {:execute, request})

      {:ok,
       %{
         "ok" => true,
         "platform" => "macos",
         "display_server" => "quartz",
         "screen_capture" => true,
         "input_control" => false
       }}
    end

    @impl true
    def stop(_state) do
      send(self(), :stop)
      :ok
    end
  end

  defmodule SparseStub do
    @behaviour FermixCore.ComputerUse.Driver
    @impl true
    def start(_opts), do: {:ok, %{}}
    @impl true
    def execute(_state, _request), do: {:ok, %{"ok" => true}}
    @impl true
    def stop(_state), do: :ok
  end

  defmodule ErroringStub do
    @behaviour FermixCore.ComputerUse.Driver
    @impl true
    def start(_opts), do: {:ok, %{}}
    @impl true
    def execute(_state, _request), do: {:error, {:sidecar_exited, 1}}
    @impl true
    def stop(_state) do
      send(self(), :stop)
      :ok
    end
  end

  defmodule UnstartableStub do
    @behaviour FermixCore.ComputerUse.Driver
    @impl true
    def start(_opts), do: {:error, {:sidecar_missing, "/nope"}}
    @impl true
    def execute(_state, _request), do: {:ok, %{"ok" => true}}
    @impl true
    def stop(_state), do: :ok
  end

  test "normalizes the sidecar probe response and asks for the probe action" do
    assert {:ok, result} = Probe.run(driver: MacStub, binary_path: "/fake")

    assert result == %{
             platform: "macos",
             display_server: "quartz",
             screen_capture: true,
             input_control: false
           }

    assert_received {:start, "/fake"}
    assert_received {:execute, %{"action" => "probe"}}
    assert_received :stop
  end

  test "missing fields default to unknown/false rather than crashing" do
    assert {:ok, result} = Probe.run(driver: SparseStub, binary_path: "/fake")

    assert result == %{
             platform: "unknown",
             display_server: "unknown",
             screen_capture: false,
             input_control: false
           }
  end

  test "propagates an execute error AND still stops the driver (owns the resource)" do
    assert {:error, {:sidecar_exited, 1}} = Probe.run(driver: ErroringStub, binary_path: "/fake")
    assert_received :stop
  end

  test "a failed start short-circuits without probing" do
    assert {:error, {:sidecar_missing, "/nope"}} =
             Probe.run(driver: UnstartableStub, binary_path: "/fake")
  end
end
