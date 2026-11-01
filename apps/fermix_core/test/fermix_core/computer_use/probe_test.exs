defmodule FermixCore.ComputerUse.ProbeTest do
  use ExUnit.Case, async: true

  alias FermixCore.ComputerUse.Probe

  # Stub Drivers run inline in the test process (Probe.run/1 is synchronous, spawns
  # nothing), so `self()` inside a callback is the test pid — messages land here.

  defmodule MacStub do
    @behaviour Compux.Driver

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
    @behaviour Compux.Driver
    @impl true
    def start(_opts), do: {:ok, %{}}
    @impl true
    def execute(_state, _request), do: {:ok, %{"ok" => true}}
    @impl true
    def stop(_state), do: :ok
  end

  defmodule ErroringStub do
    @behaviour Compux.Driver
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
    @behaviour Compux.Driver
    @impl true
    def start(_opts), do: {:error, {:sidecar_missing, "/nope"}}
    @impl true
    def execute(_state, _request), do: {:ok, %{"ok" => true}}
    @impl true
    def stop(_state), do: :ok
  end

  # A Linux helper's answer, as the wire documents it: the owner's 22.04 X11
  # desktop, with a portal too old for its Registry.
  defmodule LinuxStub do
    @behaviour Compux.Driver
    @impl true
    def start(_opts), do: {:ok, %{}}

    @impl true
    def execute(_state, _request) do
      {:ok,
       %{
         "ok" => true,
         "platform" => "linux",
         "display_server" => "x11",
         "x11_endpoint" => true,
         "display_adopted" => true,
         "screen_capture" => true,
         "input_control" => true,
         "x11_pixels" => %{"xtest" => true, "keymap" => false},
         "portal" => %{
           "running" => false,
           "version" => "1.14.4-1ubuntu2~22.04.2",
           "registry" => nil,
           "screenshot_permission" => "no"
         },
         "accessibility_bus" => %{
           "state" => "answering",
           "applications" => 7,
           "status" => %{"is_enabled" => false, "screen_reader_enabled" => false}
         },
         "accessibility_packages" => %{
           "source" => "dpkg",
           "at_spi2_core" => "2.44.0-3",
           "atk_bridge" => "2.38.0-3"
         },
         "toolkit_notes" => [
           %{"toolkit" => "qt", "note" => "start it with QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1"}
         ]
       }}
    end

    @impl true
    def stop(_state), do: :ok
  end

  # Values this build does not know, in every Linux field: each reads as unknown.
  defmodule OddStub do
    @behaviour Compux.Driver
    @impl true
    def start(_opts), do: {:ok, %{}}

    @impl true
    def execute(_state, _request) do
      {:ok,
       %{
         "ok" => true,
         "platform" => "linux",
         "display_server" => "wayland",
         "display_adopted" => "yes",
         "x11_pixels" => %{"xtest" => "true"},
         "portal" => %{
           "running" => "maybe",
           "version" => 1.18,
           "registry" => 1,
           "screenshot_permission" => "ask"
         },
         "accessibility_bus" => %{"state" => "dozing", "applications" => -1, "cause" => 3},
         "accessibility_packages" => %{"source" => "rpm", "atk_bridge" => 2.52},
         "toolkit_notes" => [%{"toolkit" => "qt"}, "chromium", %{"note" => "orphan"}]
       }}
    end

    @impl true
    def stop(_state), do: :ok
  end

  # What a build that reports no Linux facts (macOS) leaves in each of them.
  @no_linux_facts %{
    display_adopted: nil,
    x11_pixels: nil,
    portal: nil,
    accessibility_bus: nil,
    accessibility_packages: nil,
    toolkit_notes: nil
  }

  test "normalizes the sidecar probe response and asks for the probe action" do
    assert {:ok, result} = Probe.run(driver: MacStub, binary_path: "/fake")

    assert result ==
             Map.merge(@no_linux_facts, %{
               platform: "macos",
               display_server: "quartz",
               screen_capture: true,
               input_control: false
             })

    assert_received {:start, "/fake"}
    assert_received {:execute, %{"action" => "probe"}}
    assert_received :stop
  end

  test "missing fields default to unknown/false rather than crashing" do
    assert {:ok, result} = Probe.run(driver: SparseStub, binary_path: "/fake")

    assert result ==
             Map.merge(@no_linux_facts, %{
               platform: "unknown",
               display_server: "unknown",
               screen_capture: false,
               input_control: false
             })
  end

  test "propagates an execute error AND still stops the driver (owns the resource)" do
    assert {:error, {:sidecar_exited, 1}} = Probe.run(driver: ErroringStub, binary_path: "/fake")
    assert_received :stop
  end

  test "a failed start short-circuits without probing" do
    assert {:error, {:sidecar_missing, "/nope"}} =
             Probe.run(driver: UnstartableStub, binary_path: "/fake")
  end

  # The doctor's Linux rows read these, so each is carried as the helper said it.
  test "carries the Linux facts the doctor shows" do
    assert {:ok, result} = Probe.run(driver: LinuxStub, binary_path: "/fake")

    assert result.display_server == "x11"
    assert result.display_adopted == true
    assert result.x11_pixels == %{xtest: true, keymap: false}

    assert result.portal == %{
             running: false,
             version: "1.14.4-1ubuntu2~22.04.2",
             registry: nil,
             screenshot_permission: "no"
           }

    assert result.accessibility_bus == %{
             state: "answering",
             applications: 7,
             cause: nil,
             detail: nil
           }

    assert result.accessibility_packages == %{
             source: "dpkg",
             at_spi2_core: "2.44.0-3",
             atk_bridge: "2.38.0-3"
           }

    assert result.toolkit_notes == [
             %{toolkit: "qt", note: "start it with QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1"}
           ]
  end

  # A value this build does not know is unknown (nil, or "unknown" for the bus's
  # state), never read as the nearest one it does: a "maybe" running portal is not
  # a running one, and a permission it cannot name is not "unset".
  test "a Linux value this build does not know reads as unknown, never guessed" do
    assert {:ok, result} = Probe.run(driver: OddStub, binary_path: "/fake")

    assert result.display_adopted == nil
    assert result.x11_pixels == %{xtest: nil, keymap: nil}

    assert result.portal == %{
             running: nil,
             version: nil,
             registry: nil,
             screenshot_permission: nil
           }

    assert result.accessibility_bus == %{
             state: "unknown",
             applications: nil,
             cause: nil,
             detail: nil
           }

    assert result.accessibility_packages == %{source: "rpm", at_spi2_core: nil, atk_bridge: nil}
    assert result.toolkit_notes == []
  end
end
