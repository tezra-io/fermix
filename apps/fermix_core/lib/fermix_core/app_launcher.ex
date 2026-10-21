defmodule FermixCore.AppLauncher do
  @moduledoc """
  Opens the Fermix app this engine runs inside: the one owner of "open the
  app" for every wire the app serves the daemon on, the browser host
  (`Browser.HostLauncher`) and the native host
  (`Native.Notifications.MacApp`).

  `launch/1` runs `open -g -j -b <bundle id> --args --background`, so the app
  comes up in the background without taking focus; its hosts attach on their
  own, and each caller waits for that. The engine release carries no bundle
  identifier, because one engine tree ships inside both the app and its
  development identity, which is applied when the app is staged. So the
  identifier is read from the bundle this engine runs inside
  (`EngineOwner.app_bundle_path/0`): its `Info.plist`, which the app's staging
  proves agrees with the product configuration it staged. The development app
  therefore opens the development app.

  The two bounds every caller holds a launch to live here too: the deadline
  for the app to attach once it is opened (`deadline_ms/0`), and the cooldown
  after a launch that never attached (`cooldown_ms/0`), during which no caller
  opens it again, since a launch that crashed before it attached looks
  identical to one still coming up. Each wire records its own launch where its
  decisions read it.
  """

  alias FermixCore.CommandRunner
  alias FermixCore.Setup.EngineOwner

  @open "/usr/bin/open"
  @plutil "/usr/bin/plutil"
  @deadline_ms 3_000
  @cooldown_ms 300_000

  @doc "How long a caller waits for the app to attach once it is opened, in milliseconds."
  @spec deadline_ms() :: pos_integer()
  def deadline_ms, do: @deadline_ms

  @doc "How long after a launch that never attached no caller opens the app again."
  @spec cooldown_ms() :: pos_integer()
  def cooldown_ms, do: @cooldown_ms

  @doc """
  Open the app this engine runs inside, in the background and without taking
  focus. Its hosts attach on their own; the caller waits for that.
  """
  @spec launch(pos_integer()) :: :ok | {:error, String.t()}
  def launch(timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    with {:ok, bundle} <- running_bundle(),
         {:ok, bundle_id} <- bundle_identifier(bundle, timeout_ms) do
      open_app(bundle_id, timeout_ms)
    end
  end

  defp running_bundle do
    case EngineOwner.app_bundle_path() do
      bundle when is_binary(bundle) -> {:ok, bundle}
      nil -> {:error, "this engine is not running inside the app"}
    end
  end

  defp bundle_identifier(bundle, timeout_ms) do
    plist = Path.join([bundle, "Contents", "Info.plist"])
    args = ["-extract", "CFBundleIdentifier", "raw", "-o", "-", plist]

    case CommandRunner.run(@plutil, args, timeout_ms: timeout_ms) do
      {:ok, %{exit: 0, stdout: out}} -> identifier(String.trim(out), plist)
      {:ok, %{exit: code, stdout: out}} -> {:error, "plutil exited #{code}: #{String.trim(out)}"}
      {:error, reason} -> {:error, "plutil could not run: #{inspect(reason)}"}
    end
  end

  defp identifier("", plist), do: {:error, "#{plist} names no bundle identifier"}
  defp identifier(bundle_id, _plist), do: {:ok, bundle_id}

  defp open_app(bundle_id, timeout_ms) do
    args = ["-g", "-j", "-b", bundle_id, "--args", "--background"]

    case CommandRunner.run(@open, args, timeout_ms: timeout_ms) do
      {:ok, %{exit: 0}} -> :ok
      {:ok, %{exit: code, stdout: out}} -> {:error, "open exited #{code}: #{String.trim(out)}"}
      {:error, reason} -> {:error, "open could not run: #{inspect(reason)}"}
    end
  end
end
