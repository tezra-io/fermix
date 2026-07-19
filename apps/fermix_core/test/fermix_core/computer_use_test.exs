defmodule FermixCore.ComputerUseTest do
  use ExUnit.Case, async: false

  alias FermixCore.ComputerUse

  # A stand-in for `SidecarInstaller` so these tests never touch the network.
  # Behaviour is driven by an Agent set up per test; `install/0` records that it
  # was called and can be told to delay (to exercise the boot-time timeout) or
  # return an error (to exercise fail-soft).
  defmodule InstallerStub do
    use Agent

    def start_link(state) do
      Agent.start_link(fn -> Map.put(state, :install_calls, 0) end, name: __MODULE__)
    end

    def installed?, do: Agent.get(__MODULE__, & &1.installed?)

    def install do
      Agent.update(__MODULE__, &Map.update!(&1, :install_calls, fn n -> n + 1 end))
      state = Agent.get(__MODULE__, & &1)
      if delay = state[:install_delay_ms], do: Process.sleep(delay)
      if state[:install_raise], do: raise("sidecar install blew up")
      state.install_result
    end

    def install_calls, do: Agent.get(__MODULE__, & &1.install_calls)
  end

  setup do
    prev = Application.get_env(:fermix_core, :computer_use)

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:fermix_core, :computer_use)
        value -> Application.put_env(:fermix_core, :computer_use, value)
      end
    end)

    :ok
  end

  defp enable_cu(enabled?),
    do: Application.put_env(:fermix_core, :computer_use, enabled: enabled?)

  defp start_stub(state) do
    {:ok, _pid} = start_supervised({InstallerStub, state})
    :ok
  end

  test "does not download the sidecar when computer-use is disabled" do
    enable_cu(false)
    :ok = start_stub(%{installed?: false, install_result: {:ok, "/unused"}})

    assert :ok == ComputerUse.ensure_sidecar_installed(installer: InstallerStub)
    assert InstallerStub.install_calls() == 0
  end

  test "does not download when the matching sidecar is already installed" do
    enable_cu(true)
    :ok = start_stub(%{installed?: true, install_result: {:ok, "/unused"}})

    assert :ok == ComputerUse.ensure_sidecar_installed(installer: InstallerStub)
    assert InstallerStub.install_calls() == 0
  end

  test "downloads the sidecar when enabled and the matching version is missing" do
    enable_cu(true)
    :ok = start_stub(%{installed?: false, install_result: {:ok, "/cache/0.5.1/compux"}})

    assert :ok == ComputerUse.ensure_sidecar_installed(installer: InstallerStub)
    assert InstallerStub.install_calls() == 1
  end

  test "stays fail-soft (returns :ok, does not raise) when the download errors" do
    enable_cu(true)
    :ok = start_stub(%{installed?: false, install_result: {:error, :network_unreachable}})

    assert :ok == ComputerUse.ensure_sidecar_installed(installer: InstallerStub)
    assert InstallerStub.install_calls() == 1
  end

  test "stays fail-soft (returns :ok, does not raise) when the download itself raises" do
    enable_cu(true)
    :ok = start_stub(%{installed?: false, install_result: {:ok, "/unused"}, install_raise: true})

    assert :ok == ComputerUse.ensure_sidecar_installed(installer: InstallerStub)
    assert InstallerStub.install_calls() == 1
  end

  test "is bounded and fail-soft when the download hangs past the timeout" do
    enable_cu(true)

    :ok =
      start_stub(%{installed?: false, install_result: {:ok, "/slow"}, install_delay_ms: 5_000})

    started = System.monotonic_time(:millisecond)
    result = ComputerUse.ensure_sidecar_installed(installer: InstallerStub, timeout_ms: 100)
    elapsed = System.monotonic_time(:millisecond) - started

    assert result == :ok
    assert elapsed < 2_000, "boot ensure must be bounded, took #{elapsed}ms"
    assert InstallerStub.install_calls() == 1
  end
end
