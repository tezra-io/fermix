defmodule FermixCore.ComputerUse.Grant do
  @moduledoc """
  One-shot macOS TCC grant PROMPT for computer-use.

  Spawns the sidecar and asks the `request_permissions` action, which actively raises
  the Screen Recording + Accessibility dialogs (unlike `Probe`, which only reads grant
  state without prompting). The setup card / `fermix doctor` call this at enable time
  so the OS dialogs appear up front instead of on the model's first screenshot.

  Before prompting it REGISTERS the sidecar's `Fermix.app` bundle with LaunchServices
  (`lsregister`). This is required, not cosmetic: without it macOS cannot resolve the
  bundle id, so no System-Settings row is created and the prompt merely deep-links to
  Settings (verified on macOS 26). Registration is a no-op for a bare-binary dev build
  (no `.app`) and off macOS.

  Like `Probe`, this is a DIRECT sidecar spawn — NOT routed through `SessionManager`,
  whose host-origin access gate fails closed for a non-interactive origin and would
  refuse a grant flow. The Port is always closed (`try/after`). `request/1` takes
  options so a stub driver + stub registrar make it unit-testable without the binary
  or a live `lsregister`.
  """

  alias FermixCore.ComputerUse.PortDriver
  alias FermixCore.ComputerUse.SidecarInstaller

  @lsregister "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

  @type result :: %{screen_capture: boolean(), input_control: boolean()}

  @doc """
  Register the bundle, raise the OS grant prompts, and report the (pre-response)
  grant state. Returns `{:error, reason}` when the sidecar is unavailable, bundle
  registration fails, or the action fails.

  Options (tests only): `:driver` (a `Compux.Driver`, default `PortDriver`),
  `:binary_path` (skip the installer lookup), and `:registrar` (a
  `(String.t() -> :ok | {:error, term()})` bundle registrar, default `lsregister`).
  """
  @spec request(keyword()) :: {:ok, result()} | {:error, term()}
  def request(opts \\ []) when is_list(opts) do
    driver = Keyword.get(opts, :driver, PortDriver)

    with {:ok, path} <- resolve_path(opts),
         :ok <- register_bundle(path, opts),
         {:ok, state} <- driver.start(binary_path: path) do
      try do
        prompt(driver, state)
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

  # Register `Fermix.app` with LaunchServices so TCC can resolve its bundle id (and
  # Settings shows the name + icon). A bare-binary dev build has no bundle to
  # register, and off macOS there is no LaunchServices — both are `:ok`, not failures.
  defp register_bundle(path, opts) do
    registrar = Keyword.get(opts, :registrar, &lsregister/1)

    case app_bundle_root(path) do
      {:ok, app} -> registrar.(app)
      :none -> :ok
    end
  end

  @doc false
  # `.../Fermix.app/Contents/MacOS/compux` -> `.../Fermix.app`; `:none` for a bare path.
  @spec app_bundle_root(String.t()) :: {:ok, String.t()} | :none
  def app_bundle_root(path) do
    case Regex.run(~r"^(.*/Fermix\.app)/Contents/MacOS/", path) do
      [_full, app] -> {:ok, app}
      nil -> :none
    end
  end

  defp lsregister(app) do
    case System.cmd(@lsregister, ["-f", app], stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, code} -> {:error, {:lsregister_failed, code, String.trim(out)}}
    end
  end

  defp prompt(driver, state) do
    case driver.execute(state, %{"action" => "request_permissions"}) do
      {:ok, response} -> {:ok, normalize(response)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize(response) when is_map(response) do
    %{
      screen_capture: Map.get(response, "screen_capture") == true,
      input_control: Map.get(response, "input_control") == true
    }
  end
end
