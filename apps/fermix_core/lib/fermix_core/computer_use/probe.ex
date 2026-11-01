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

  A Linux helper also reports, read-only, what the doctor's Linux rows show: whether
  the display was adopted from the user manager, the X11 pixel route's two needs,
  the desktop portal, the accessibility bus, the accessibility package versions and
  the toolkit notes. Each is carried as the helper said it. A value this build does
  not know reads as unknown (`nil`, or `"unknown"` for the bus's state), never as
  the nearest one it does; a build that reports none (macOS) leaves each `nil`.
  """

  alias FermixCore.ComputerUse.PortDriver
  alias FermixCore.ComputerUse.SidecarInstaller

  @type portal :: %{
          running: boolean() | nil,
          version: String.t() | nil,
          registry: boolean() | nil,
          screenshot_permission: String.t() | nil
        }

  @type bus :: %{
          state: String.t(),
          applications: non_neg_integer() | nil,
          cause: String.t() | nil,
          detail: String.t() | nil
        }

  @type packages :: %{
          source: String.t() | nil,
          at_spi2_core: String.t() | nil,
          atk_bridge: String.t() | nil
        }

  @type result :: %{
          platform: String.t(),
          display_server: String.t(),
          screen_capture: boolean(),
          input_control: boolean(),
          display_adopted: boolean() | nil,
          x11_pixels: %{xtest: boolean() | nil, keymap: boolean() | nil} | nil,
          portal: portal() | nil,
          accessibility_bus: bus() | nil,
          accessibility_packages: packages() | nil,
          toolkit_notes: [%{toolkit: String.t(), note: String.t()}] | nil
        }

  @bus_states ~w(answering empty unavailable)
  @stored_answers ~w(yes no unset not_running)

  @doc """
  Probe the installed sidecar. Returns the grant breakdown, or `{:error, reason}`
  when the sidecar is unavailable or the probe action fails.

  Options (tests only): `:driver` (a `Compux.Driver` module, default
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
      input_control: Map.get(response, "input_control") == true,
      display_adopted: boolean(response["display_adopted"]),
      x11_pixels: x11_pixels(response["x11_pixels"]),
      portal: portal(response["portal"]),
      accessibility_bus: bus(response["accessibility_bus"]),
      accessibility_packages: packages(response["accessibility_packages"]),
      toolkit_notes: notes(response["toolkit_notes"])
    }
  end

  defp string(response, key) do
    case Map.get(response, key) do
      value when is_binary(value) -> value
      _other -> "unknown"
    end
  end

  defp x11_pixels(%{} = pixels),
    do: %{xtest: boolean(pixels["xtest"]), keymap: boolean(pixels["keymap"])}

  defp x11_pixels(_absent), do: nil

  defp portal(%{} = portal) do
    %{
      running: boolean(portal["running"]),
      version: text(portal["version"]),
      registry: boolean(portal["registry"]),
      screenshot_permission: one_of(portal["screenshot_permission"], @stored_answers)
    }
  end

  defp portal(_absent), do: nil

  defp bus(%{} = bus) do
    %{
      state: one_of(bus["state"], @bus_states) || "unknown",
      applications: count(bus["applications"]),
      cause: text(bus["cause"]),
      detail: text(bus["detail"])
    }
  end

  defp bus(_absent), do: nil

  defp packages(%{} = packages) do
    %{
      source: text(packages["source"]),
      at_spi2_core: text(packages["at_spi2_core"]),
      atk_bridge: text(packages["atk_bridge"])
    }
  end

  defp packages(_absent), do: nil

  # A note that is not a toolkit and a sentence has nothing to show, so it is left
  # out rather than shown half.
  defp notes(notes) when is_list(notes) do
    for %{"toolkit" => toolkit, "note" => note} <- notes,
        is_binary(toolkit) and is_binary(note),
        do: %{toolkit: toolkit, note: note}
  end

  defp notes(_absent), do: nil

  defp boolean(value) when is_boolean(value), do: value
  defp boolean(_unknown), do: nil

  defp text(value) when is_binary(value), do: value
  defp text(_unknown), do: nil

  defp count(value) when is_integer(value) and value >= 0, do: value
  defp count(_unknown), do: nil

  defp one_of(value, known), do: if(value in known, do: value)
end
