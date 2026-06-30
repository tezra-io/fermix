defmodule FermixCore.ComputerUse.Probe do
  @moduledoc """
  One-shot OS-permission probe for computer-use: spawns the sidecar, asks the
  read-only `probe` action, and reports whether screen capture and input control
  are actually available — the macOS TCC grant state (Screen Recording +
  Accessibility, reported distinctly) or the Linux X11/Wayland reality
  (docs/design/COMPUTER_USE_V2.md, Phase A).

  This is an operator-facing DIAGNOSTIC (surfaced in `fermix doctor` and the setup
  card), not a boot gate: a screenshot still works without input permission, so a
  missing Accessibility grant must INFORM the operator — never silently hide the
  tool, and never silently drop clicks. The probe is non-prompting (the sidecar
  queries `AXIsProcessTrusted` / `CGPreflightScreenCaptureAccess`, which never raise
  a permission dialog).

  The Port is always closed (`try/after`) — owning the resource on every path.
  `run/1` takes options so a stub driver + fixed binary path make it unit-testable
  without the native binary.
  """

  alias FermixCore.ComputerUse.PortDriver
  alias FermixCore.ComputerUse.SidecarInstaller

  @type result :: %{
          platform: String.t(),
          display_server: String.t(),
          screen_capture: boolean(),
          input_control: boolean()
        }

  @doc """
  Probe the installed sidecar. Returns the grant breakdown, or `{:error, reason}`
  when the sidecar is unavailable or the probe action fails.

  Options (tests only): `:driver` (a `ComputerUse.Driver` module, default
  `PortDriver`) and `:binary_path` (skip the installer lookup).
  """
  @spec run(keyword()) :: {:ok, result()} | {:error, term()}
  def run(opts \\ []) when is_list(opts) do
    driver = Keyword.get(opts, :driver, PortDriver)

    with {:ok, path} <- resolve_path(opts),
         {:ok, state} <- driver.start(binary_path: path) do
      try do
        probe(driver, state)
      after
        driver.stop(state)
      end
    end
  end

  defp resolve_path(opts) do
    case Keyword.fetch(opts, :binary_path) do
      {:ok, path} -> {:ok, path}
      :error -> SidecarInstaller.binary_path()
    end
  end

  defp probe(driver, state) do
    case driver.execute(state, %{"action" => "probe"}) do
      {:ok, response} -> {:ok, normalize(response)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize(response) when is_map(response) do
    %{
      platform: string(response, "platform"),
      display_server: string(response, "display_server"),
      screen_capture: Map.get(response, "screen_capture") == true,
      input_control: Map.get(response, "input_control") == true
    }
  end

  defp string(response, key) do
    case Map.get(response, key) do
      value when is_binary(value) -> value
      _other -> "unknown"
    end
  end
end
