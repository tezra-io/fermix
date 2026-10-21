defmodule FermixCore.HostFacts do
  @moduledoc """
  Which Fermix this is and the machine it runs on, read once as the daemon's
  supervision tree starts (M76 §4.1) for the owner's `## This Fermix` prompt
  section, so "how do I…" is answered for the install the person has rather
  than guessed. A CLI verb that starts no tree never reads it.

  It re-derives nothing another module owns: the install is the profile boot
  selected (`BootProfile.current/0`), the operating system is
  `BootProfile.host/0`'s, and the architecture is the build's
  (`BuildInfo.identity/0`). It reads only what nothing else does:

    * the OS name and version: on macOS `ProductName` and `ProductVersion` of
      `SystemVersion.plist` through `plutil -extract … raw`, the way
      `Browser.HostLauncher` reads a bundle's `Info.plist`; on Linux
      `PRETTY_NAME` of `/etc/os-release`. A read that fails is `:unknown`,
      logged with its reason, never a placeholder;
    * on Linux, whether Flatpak exported the desktop app's entry
      (`io.tezra.Fermix.desktop`) in the system or the user installation.
      It is a file the engine does not own, looked at once: an app installed
      later is seen at the next start, which the section says.

  Never read: the hostname, the account name, the serial, any address, or the
  engine's own version.

  The section's last line says whether a reminder can ring on this computer.
  That is `Native.Notifications.offered?/1`'s answer for the host the facts
  name, the same answer `event_store` publishes `delivery` on, so the line and
  the tool never disagree; nothing here re-derives the provider.

  `remember/0` reads through the module `config :fermix_core,
  :host_facts_reader` names (this one by default): `config/test.exs` pins
  `FermixTestSupport.HostFactsStub`, and `read/3` takes `plutil:`,
  `os_release:` and `flatpak_exports:` seams, so a test names the host it
  means and no test reads this machine.
  """

  alias FermixCore.BootProfile
  alias FermixCore.BuildInfo
  alias FermixCore.CommandRunner
  alias FermixCore.Native.Notifications

  require Logger

  @plutil "/usr/bin/plutil"
  @system_version "/System/Library/CoreServices/SystemVersion.plist"
  @os_release "/etc/os-release"
  @system_exports "/var/lib/flatpak/exports/share/applications"
  @user_exports "flatpak/exports/share/applications"
  @linux_app_entry "io.tezra.Fermix.desktop"
  @timeout_ms 2_000

  @type t :: %{
          install: BootProfile.profile(),
          os: atom(),
          os_version: String.t() | :unknown,
          architecture: String.t(),
          linux_app: boolean() | :not_asked
        }

  @doc "Reads the facts of `host` on `architecture`, as `remember/0` does at boot."
  @callback read(BootProfile.host(), String.t()) :: t()

  @doc """
  Reads this host's facts through the configured reader and records them,
  before anything reads them. The daemon's boot calls it once, first thing
  as the supervision tree starts, after `BootProfile.remember/1`.
  """
  @spec remember() :: :ok
  def remember do
    reader = Application.get_env(:fermix_core, :host_facts_reader, __MODULE__)
    facts = reader.read(BootProfile.host(), BuildInfo.identity().architecture)
    Application.put_env(:fermix_core, :host_facts, facts)
  end

  @doc """
  The facts boot recorded. Raises when boot recorded none: a reader outside
  the daemon's tree (a tree-less CLI verb) has no host to describe.
  """
  @spec current() :: t()
  def current, do: Application.fetch_env!(:fermix_core, :host_facts)

  @doc "The `## This Fermix` prompt section, rendered from the facts boot recorded."
  @spec prompt_section() :: String.t()
  def prompt_section, do: render(current())

  @doc """
  Reads the facts of `host` on `architecture`. `opts` may carry `plutil:`
  (`[String.t()] -> {:ok, stdout} | {:error, reason}`), `os_release:`
  (`-> {:ok, contents} | {:error, reason}`) and `flatpak_exports:` (the
  directories an exported desktop entry is looked for in); each defaults to
  the real one. Only the reads `host`'s system has are made.
  """
  @spec read(BootProfile.host(), String.t(), keyword()) :: t()
  def read(%{profile: profile, os: os}, architecture, opts \\ [])
      when is_atom(os) and is_binary(architecture) and is_list(opts) do
    %{
      install: profile,
      os: os,
      os_version: os_version(os, opts),
      architecture: architecture,
      linux_app: linux_app(os, opts)
    }
  end

  @doc """
  Where Flatpak exports an installed app's desktop entry: the system
  installation, then the user's under `$XDG_DATA_HOME`, which the XDG base
  directory rule replaces with `~/.local/share` when it is unset, empty or
  relative.
  """
  @spec flatpak_export_dirs(String.t() | nil, String.t()) :: [Path.t()]
  def flatpak_export_dirs(xdg_data_home, home) when is_binary(home) do
    [@system_exports, Path.join(data_home(xdg_data_home, home), @user_exports)]
  end

  @doc """
  The `## This Fermix` section for `facts`: the install, the machine, then
  whether a reminder can ring on this computer.
  """
  @spec render(t()) :: String.t()
  def render(%{install: _install, os: _os} = facts) do
    lines = [install_line(facts), machine_line(facts), computer_line(facts)]
    Enum.join(["## This Fermix" | lines], "\n")
  end

  defp os_version(os, opts) do
    case read_os_version(os, opts) do
      {:ok, version} ->
        version

      {:error, reason} ->
        Logger.warning("host facts: the operating system version could not be read: #{reason}")
        :unknown
    end
  end

  defp read_os_version(:darwin, opts) do
    plutil = Keyword.get(opts, :plutil, &run_plutil/1)

    with {:ok, name} <- plist_value(plutil, "ProductName"),
         {:ok, version} <- plist_value(plutil, "ProductVersion") do
      {:ok, name <> " " <> version}
    end
  end

  defp read_os_version(:linux, opts) do
    os_release = Keyword.get(opts, :os_release, &read_os_release/0)

    with {:ok, text} <- os_release.() do
      pretty_name(text)
    end
  end

  defp read_os_version(os, _opts), do: {:error, "Fermix reads no version for #{os}"}

  defp plist_value(plutil, key) do
    with {:ok, out} <- plutil.(["-extract", key, "raw", "-o", "-", @system_version]) do
      present(out, "#{@system_version} has no #{key}")
    end
  end

  defp run_plutil(args) do
    case CommandRunner.run(@plutil, args, timeout_ms: @timeout_ms, supervised: false) do
      {:ok, %{exit: 0, stdout: out}} -> {:ok, out}
      {:ok, %{exit: code, stdout: out}} -> {:error, "plutil exited #{code}: #{String.trim(out)}"}
      {:error, reason} -> {:error, "plutil could not run: #{inspect(reason)}"}
    end
  end

  defp read_os_release do
    case File.read(@os_release) do
      {:ok, text} -> {:ok, text}
      {:error, reason} -> {:error, "#{@os_release}: #{:file.format_error(reason)}"}
    end
  end

  # os-release is shell-style assignments: a value may be bare, or in double
  # quotes with backslash escapes, or in single quotes.
  defp pretty_name(text) do
    lines = String.split(text, "\n")

    case Enum.find_value(lines, &pretty_value(String.trim(&1))) do
      nil -> {:error, "#{@os_release} has no PRETTY_NAME"}
      value -> present(value, "#{@os_release} has an empty PRETTY_NAME")
    end
  end

  defp pretty_value("PRETTY_NAME=" <> value), do: unquote_value(value)
  defp pretty_value(_other_line), do: nil

  defp unquote_value("\"" <> rest) do
    inner = String.replace_suffix(rest, "\"", "")
    Regex.replace(~r/\\(.)/, inner, "\\1")
  end

  defp unquote_value("'" <> rest), do: String.replace_suffix(rest, "'", "")
  defp unquote_value(bare), do: bare

  defp present(value, reason) do
    case String.trim(value) do
      "" -> {:error, reason}
      trimmed -> {:ok, trimmed}
    end
  end

  defp linux_app(:linux, opts) do
    opts
    |> Keyword.get_lazy(:flatpak_exports, &default_export_dirs/0)
    |> Enum.any?(&File.exists?(Path.join(&1, @linux_app_entry)))
  end

  defp linux_app(_os, _opts), do: :not_asked

  defp default_export_dirs,
    do: flatpak_export_dirs(System.get_env("XDG_DATA_HOME"), System.user_home!())

  defp data_home(xdg_data_home, home) do
    if is_binary(xdg_data_home) and Path.type(xdg_data_home) == :absolute,
      do: xdg_data_home,
      else: Path.join(home, ".local/share")
  end

  # The install line says who owns setup and where "how do I" is answered.
  defp install_line(%{install: :app_engine, os: :darwin}) do
    "- Install: the Fermix app on this Mac. The app owns setup, settings, the background " <>
      "service and updates, and ships no `fermix` command: answer \"how do I\" with the " <>
      "app's own labels (Settings > <pane>), never a CLI verb or config.toml."
  end

  defp install_line(%{install: :standalone_cli, os: :darwin}) do
    "- Install: the standalone Fermix on this Mac (Homebrew formula or a downloaded " <>
      "binary), run by its own launchd service and managed with the `fermix` command, " <>
      "browser setup and config.toml. No Fermix app is attached."
  end

  defp install_line(%{install: :linux_package_cli, os: :linux, linux_app: app}) do
    "- Install: the Fermix Linux package (.deb or .rpm), run as the systemd user unit " <>
      "fermix.service and managed with the `fermix` command, browser setup and " <>
      "config.toml. " <> linux_app_sentence(app)
  end

  defp install_line(%{install: :standalone_cli, os: :linux, linux_app: app}) do
    "- Install: the standalone Fermix binary on this Linux machine, run by its own " <>
      "systemd service and managed with the `fermix` command, browser setup and " <>
      "config.toml. " <> linux_app_sentence(app)
  end

  defp install_line(%{install: :source}) do
    "- Install: a development run from a source checkout (`mix fermix.dev`), managed with " <>
      "the `fermix` command, browser setup and config.toml."
  end

  # Read once at boot, so the sentence says when it was true.
  defp linux_app_sentence(true) do
    "The Fermix desktop app (Flatpak io.tezra.Fermix) was installed when Fermix started: " <>
      "it shows settings, chat, voice and logs, so answer \"how do I\" with its own labels " <>
      "for anything it has a control for."
  end

  defp linux_app_sentence(false) do
    "No Fermix desktop app was installed when Fermix started; the `fermix` command and " <>
      "browser setup are the surfaces."
  end

  defp machine_line(%{os_version: :unknown, os: :darwin} = facts),
    do: "- Machine: macOS on #{processor(facts)}; its version could not be read."

  defp machine_line(%{os_version: :unknown, os: :linux} = facts),
    do:
      "- Machine: Linux on #{processor(facts)}; the distribution and its version could not be read."

  defp machine_line(%{os_version: :unknown, os: os} = facts),
    do: "- Machine: #{os} on #{processor(facts)}; its version could not be read."

  defp machine_line(%{os_version: version} = facts) when is_binary(version),
    do: "- Machine: #{version} on #{processor(facts)}."

  # Whether it rings is the build's offer for the host the facts name; the
  # wording then says how, or where else a reminder goes.
  defp computer_line(%{install: install, os: os} = facts) do
    computer_sentence(Notifications.offered?(host: %{profile: install, os: os}), facts)
  end

  defp computer_sentence(true, %{os: :darwin}) do
    "- This computer: a reminder or timer can ring here as a notification from the Fermix " <>
      "app (`event_store` with `delivery: \"computer\"`); its Notifications permission is in " <>
      "Settings > Permissions."
  end

  # Whether a desktop session is running is asked when a reminder is stored and
  # when it fires, never at boot: a lingering unit starts before anyone logs in.
  defp computer_sentence(true, %{os: :linux}) do
    "- This computer: a reminder or timer can ring here as a desktop notification while a " <>
      "desktop session is running (`event_store` with `delivery: \"computer\"`); a headless " <>
      "host or a system-wide service has none."
  end

  defp computer_sentence(false, %{install: :standalone_cli, os: :darwin}) do
    "- This computer: nothing can ring here; reminders go to a chat channel. The Fermix app " <>
      "can ring on this Mac (`fermix migrate-to-app`)."
  end

  defp computer_sentence(false, %{install: :source, os: :darwin}),
    do: "- This computer: nothing can ring here; the Fermix app's own engine can."

  defp processor(%{os: :darwin, architecture: "arm64"}), do: "Apple silicon (arm64)"
  defp processor(%{os: :darwin, architecture: "x86_64"}), do: "Intel (x86_64)"
  defp processor(%{architecture: architecture}), do: architecture
end
