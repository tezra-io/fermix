defmodule FermixCore.ComputerUse.GrantTest do
  use ExUnit.Case, async: true

  alias FermixCore.ComputerUse.Grant

  # Stub Drivers run inline in the test process (Grant.request/1 is synchronous), so
  # `self()` inside a callback is the test pid — messages land here.

  @app "/Users/x/.fermix/plugins/compux/0.4.0/macos-aarch64/Fermix.app"
  @exec @app <> "/Contents/MacOS/compux"

  defmodule PromptStub do
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

  describe "app_bundle_root/1" do
    test "extracts the .app root from the inner exec path" do
      assert Grant.app_bundle_root(@exec) == {:ok, @app}
    end

    test ":none for a bare-binary path (dev build / linux)" do
      assert Grant.app_bundle_root("/x/.fermix/plugins/compux/0.4.0/linux-x86_64/compux") == :none
    end
  end

  describe "request/1" do
    test "registers the bundle, prompts, normalizes, and stops" do
      registrar = fn app ->
        send(self(), {:register, app})
        :ok
      end

      assert {:ok, %{screen_capture: true, input_control: false}} =
               Grant.request(driver: PromptStub, binary_path: @exec, registrar: registrar)

      assert_received {:register, @app}
      assert_received {:start, @exec}
      assert_received {:execute, %{"action" => "request_permissions"}}
      assert_received :stop
    end

    test "skips registration for a bare-binary path but still prompts" do
      registrar = fn _app ->
        send(self(), :registered)
        :ok
      end

      assert {:ok, _result} =
               Grant.request(driver: PromptStub, binary_path: "/x/compux", registrar: registrar)

      refute_received :registered
      assert_received {:execute, %{"action" => "request_permissions"}}
    end

    test "a registration failure short-circuits before spawning the sidecar" do
      registrar = fn _app -> {:error, {:lsregister_failed, 1, "boom"}} end

      assert {:error, {:lsregister_failed, 1, "boom"}} =
               Grant.request(driver: PromptStub, binary_path: @exec, registrar: registrar)

      refute_received {:start, _path}
    end

    test "propagates an execute error AND still stops the driver (owns the resource)" do
      assert {:error, {:sidecar_exited, 1}} =
               Grant.request(driver: ErroringStub, binary_path: @exec, registrar: fn _ -> :ok end)

      assert_received :stop
    end
  end
end
