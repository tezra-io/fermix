defmodule FermixCore.HostFactsTest do
  # async: false — one test removes and restores the facts boot recorded.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixCore.BootProfile
  alias FermixCore.BuildInfo
  alias FermixCore.HostFacts
  alias FermixCore.Native.Notifications
  alias FermixCore.Tools.EventStore
  alias FermixTestSupport.HostFactsStub
  alias FermixTestSupport.SafeRm

  @plist "/System/Library/CoreServices/SystemVersion.plist"
  @entry "io.tezra.Fermix.desktop"
  @package_entries "/usr/share/applications"
  @system_exports "/var/lib/flatpak/exports/share/applications"
  @user_exports "/home/me/.local/share/flatpak/exports/share/applications"

  # A plutil that answers SystemVersion.plist's two keys and fails on anything else.
  defp plutil(name, version) do
    fn
      ["-extract", "ProductName", "raw", "-o", "-", @plist] -> {:ok, name <> "\n"}
      ["-extract", "ProductVersion", "raw", "-o", "-", @plist] -> {:ok, version <> "\n"}
      args -> flunk("plutil asked #{inspect(args)}")
    end
  end

  defp os_release(text), do: fn -> {:ok, text} end

  defp never(seam), do: fn _args -> flunk("#{seam} must not be asked") end

  defp exports_dir(context) do
    SafeRm.make_tmp_dir!("host-facts-#{context}-#{System.unique_integer([:positive])}")
  end

  # Reads a Linux package host for /home/me whose real entry directories sit
  # under a scratch root, with the app's entry written in each of `installed`.
  defp read_with_entries(installed) do
    root = exports_dir("root")
    on_exit(fn -> SafeRm.rm_rf!(root) end)

    for dir <- installed do
      File.mkdir_p!(Path.join(root, dir))
      File.write!(Path.join([root, dir, @entry]), "[Desktop Entry]\n")
    end

    HostFacts.read(%{profile: :linux_package_cli, os: :linux}, "x86_64",
      os_release: os_release("PRETTY_NAME=\"Ubuntu 24.04 LTS\"\n"),
      app_entry_dirs: Enum.map(HostFacts.app_entry_dirs(nil, "/home/me"), &Path.join(root, &1))
    )
  end

  # A Mac reads macOS 26.1 on arm64, a Linux machine Ubuntu 24.04 LTS on x86_64
  # with no desktop app, unless `overrides` says otherwise.
  defp facts(install, os, overrides \\ []) do
    Map.merge(
      %{
        install: install,
        os: os,
        os_version: if(os == :darwin, do: "macOS 26.1", else: "Ubuntu 24.04 LTS"),
        architecture: if(os == :darwin, do: "arm64", else: "x86_64"),
        linux_app: if(os == :darwin, do: :not_asked, else: false)
      },
      Map.new(overrides)
    )
  end

  describe "read/3" do
    test "a Mac reads its name and version from SystemVersion.plist and asks no desktop app question" do
      facts =
        HostFacts.read(%{profile: :app_engine, os: :darwin}, "arm64",
          plutil: plutil("macOS", "26.1"),
          os_release: fn -> flunk("a Mac has no os-release") end,
          app_entry_dirs: ["/nonexistent-must-not-be-read"]
        )

      assert facts == %{
               install: :app_engine,
               os: :darwin,
               os_version: "macOS 26.1",
               architecture: "arm64",
               linux_app: :not_asked
             }
    end

    test "Linux reads PRETTY_NAME from os-release, quoted or bare" do
      for {text, expected} <- [
            {~s(NAME="Ubuntu"\nPRETTY_NAME="Ubuntu 24.04 LTS"\nID=ubuntu\n), "Ubuntu 24.04 LTS"},
            {"ID=fedora\nPRETTY_NAME='Fedora Linux 42 (Workstation Edition)'\n",
             "Fedora Linux 42 (Workstation Edition)"},
            {"ID=gentoo\nPRETTY_NAME=Gentoo\n", "Gentoo"},
            {~s(PRETTY_NAME="Debian \\"trixie\\""\n), ~s(Debian "trixie")}
          ] do
        facts =
          HostFacts.read(%{profile: :linux_package_cli, os: :linux}, "x86_64",
            plutil: never(:plutil),
            os_release: os_release(text),
            app_entry_dirs: []
          )

        assert facts.os_version == expected
      end
    end

    # The app's .deb or .rpm package installs its entry in /usr/share/applications,
    # the earlier Flatpak exported it; an entry anywhere else is no install of it.
    test "the Linux desktop app is seen where its package or its Flatpak installs its entry" do
      for {installed, expected} <- [
            {[], false},
            {[@package_entries], true},
            {[@system_exports], true},
            {[@user_exports], true},
            {[@package_entries, @system_exports], true},
            {[@package_entries, @user_exports], true},
            {["/usr/local/share/applications"], false},
            {["/home/me/.local/share/applications"], false},
            {["/home/me/.config/autostart"], false}
          ] do
        assert read_with_entries(installed).linux_app == expected,
               "the entry in #{inspect(installed)} read #{!expected}"
      end
    end

    test "a version that cannot be read is :unknown and says why, never a placeholder" do
      cases = [
        {%{profile: :app_engine, os: :darwin},
         [plutil: fn _args -> {:error, "plutil exited 1: no such key"} end], "plutil exited 1"},
        {%{profile: :app_engine, os: :darwin}, [plutil: plutil("macOS", "  ")], "ProductVersion"},
        {%{profile: :linux_package_cli, os: :linux},
         [os_release: fn -> {:error, "/etc/os-release: no such file or directory"} end],
         "/etc/os-release"},
        {%{profile: :linux_package_cli, os: :linux},
         [os_release: os_release("NAME=Ubuntu\nID=ubuntu\n")], "PRETTY_NAME"},
        {%{profile: :linux_package_cli, os: :linux},
         [os_release: os_release("PRETTY_NAME=\"\"\n")], "PRETTY_NAME"}
      ]

      for {host, seams, reason} <- cases do
        log =
          capture_log(fn ->
            facts = HostFacts.read(host, "arm64", [app_entry_dirs: []] ++ seams)
            assert facts.os_version == :unknown
          end)

        assert log =~ "host facts: the operating system version could not be read"
        assert log =~ reason
      end
    end

    # What `## This Fermix` may say is what these keys hold: no hostname, account
    # name, serial, address or engine version is ever read (M76 §4.1).
    test "reads exactly the five facts and nothing about the person or the build's version" do
      facts =
        HostFacts.read(%{profile: :source, os: :darwin}, "arm64", plutil: plutil("macOS", "26.1"))

      assert facts |> Map.keys() |> Enum.sort() ==
               [:architecture, :install, :linux_app, :os, :os_version]
    end
  end

  describe "app_entry_dirs/2" do
    test "the package's entries, the system Flatpak exports, then the user's under XDG_DATA_HOME or ~/.local/share" do
      assert HostFacts.app_entry_dirs("/data/me", "/home/me") ==
               [@package_entries, @system_exports, "/data/me/flatpak/exports/share/applications"]

      # The XDG base directory rule: unset, empty or relative means the default.
      for unset <- [nil, "", "relative/share"] do
        assert HostFacts.app_entry_dirs(unset, "/home/me") ==
                 [@package_entries, @system_exports, @user_exports]
      end
    end
  end

  describe "render/2" do
    # One table over every install M76 §4.2 names: the install, the machine,
    # and whether a reminder can ring on this computer.
    test "names the install, the machine and what can ring here for every host" do
      table = [
        {facts(:app_engine, :darwin),
         """
         ## This Fermix
         - Install: the Fermix app on this Mac. The app owns setup, settings, the background service and updates, and ships no `fermix` command: answer "how do I" with the app's own labels (Settings > <pane>), never a CLI verb or config.toml.
         - Machine: macOS 26.1 on Apple silicon (arm64).
         - This computer: a reminder or timer can ring here as a notification from the Fermix app (`event_store` with `delivery: "computer"`); its Notifications permission is in Settings > Permissions.
         """},
        {facts(:standalone_cli, :darwin, architecture: "x86_64"),
         """
         ## This Fermix
         - Install: the standalone Fermix on this Mac (Homebrew formula or a downloaded binary), run by its own launchd service and managed with the `fermix` command, browser setup and config.toml. No Fermix app is attached.
         - Machine: macOS 26.1 on Intel (x86_64).
         - This computer: nothing can ring here; reminders go to a chat channel. The Fermix app can ring on this Mac (`fermix migrate-to-app`).
         """},
        {facts(:linux_package_cli, :linux, linux_app: true),
         """
         ## This Fermix
         - Install: the Fermix Linux package (.deb or .rpm), run as the systemd user unit fermix.service and managed with the `fermix` command, browser setup and config.toml. The Fermix desktop app (io.tezra.Fermix) was installed when Fermix started: it shows settings, chat, voice and logs, so answer "how do I" with its own labels for anything it has a control for.
         - Machine: Ubuntu 24.04 LTS on x86_64.
         - This computer: a reminder or timer can ring here as a desktop notification while a desktop session is running (`event_store` with `delivery: "computer"`); a headless host or a system-wide service has none.
         """},
        {facts(:linux_package_cli, :linux),
         """
         ## This Fermix
         - Install: the Fermix Linux package (.deb or .rpm), run as the systemd user unit fermix.service and managed with the `fermix` command, browser setup and config.toml. No Fermix desktop app was installed when Fermix started; the `fermix` command and browser setup are the surfaces.
         - Machine: Ubuntu 24.04 LTS on x86_64.
         - This computer: a reminder or timer can ring here as a desktop notification while a desktop session is running (`event_store` with `delivery: "computer"`); a headless host or a system-wide service has none.
         """},
        {facts(:standalone_cli, :linux, linux_app: true, architecture: "arm64"),
         """
         ## This Fermix
         - Install: the standalone Fermix binary on this Linux machine, run by its own systemd service and managed with the `fermix` command, browser setup and config.toml. The Fermix desktop app (io.tezra.Fermix) was installed when Fermix started: it shows settings, chat, voice and logs, so answer "how do I" with its own labels for anything it has a control for.
         - Machine: Ubuntu 24.04 LTS on arm64.
         - This computer: a reminder or timer can ring here as a desktop notification while a desktop session is running (`event_store` with `delivery: "computer"`); a headless host or a system-wide service has none.
         """},
        {facts(:standalone_cli, :linux),
         """
         ## This Fermix
         - Install: the standalone Fermix binary on this Linux machine, run by its own systemd service and managed with the `fermix` command, browser setup and config.toml. No Fermix desktop app was installed when Fermix started; the `fermix` command and browser setup are the surfaces.
         - Machine: Ubuntu 24.04 LTS on x86_64.
         - This computer: a reminder or timer can ring here as a desktop notification while a desktop session is running (`event_store` with `delivery: "computer"`); a headless host or a system-wide service has none.
         """},
        {facts(:source, :darwin),
         """
         ## This Fermix
         - Install: a development run from a source checkout (`mix fermix.dev`), managed with the `fermix` command, browser setup and config.toml.
         - Machine: macOS 26.1 on Apple silicon (arm64).
         - This computer: nothing can ring here; the Fermix app's own engine can.
         """},
        {facts(:source, :linux),
         """
         ## This Fermix
         - Install: a development run from a source checkout (`mix fermix.dev`), managed with the `fermix` command, browser setup and config.toml.
         - Machine: Ubuntu 24.04 LTS on x86_64.
         - This computer: a reminder or timer can ring here as a desktop notification while a desktop session is running (`event_store` with `delivery: "computer"`); a headless host or a system-wide service has none.
         """}
      ]

      for {facts, expected} <- table do
        assert HostFacts.render(facts, placement: :here) == String.trim_trailing(expected)
      end
    end

    # M99 §10.1: an Always On server shows no notification itself, so the line
    # says the owner's computers ring, never the server; a home that never
    # moved says what it said, and the tools word `delivery` the same way.
    test "on an Always On server the line names the owner's computers, as the tools do" do
      server = [
        role: :primary,
        always_on: true,
        home: "/nonexistent/fermix-home",
        server_primary: fn "/nonexistent/fermix-home" -> :server end
      ]

      facts = facts(:linux_package_cli, :linux)

      assert [_heading, _install, _machine, line] =
               String.split(HostFacts.render(facts, server), "\n")

      assert line ==
               "- This computer: the Always On server, which shows no notification itself. A " <>
                 "reminder or timer with `delivery: \"computer\"` (`event_store`) rings as a " <>
                 "notification on each of your computers that is awake, through the Fermix on " <>
                 "it; one due while none is awake is tried again while it is still valid."

      refute line =~ "can ring here"

      context = %{host: %{profile: :linux_package_cli, os: :linux}, placement: :computers}
      assert EventStore.when_to_use(context) =~ "never on this server"

      assert EventStore.dynamic_parameters(context).properties.delivery.description =~
               "never on this server"

      device = Keyword.put(server, :role, :device)
      assert [_h, _i, _m, here] = String.split(HostFacts.render(facts, device), "\n")
      assert here =~ "- This computer: a reminder or timer can ring here"
    end

    test "an unread version is said plainly, with the machine still named" do
      assert HostFacts.render(facts(:app_engine, :darwin, os_version: :unknown)) =~
               "\n- Machine: macOS on Apple silicon (arm64); its version could not be read."

      assert HostFacts.render(facts(:linux_package_cli, :linux, os_version: :unknown)) =~
               "\n- Machine: Linux on x86_64; the distribution and its version could not be read."
    end

    # The truthfulness rule (M76 §4.2, §4.11): the line the model reads, the
    # build's offer and the tool's schema are one answer. The third line says
    # this computer can ring exactly where `Native.Notifications.offered?/1`
    # holds for the host the facts name, which is exactly where `event_store`
    # publishes `delivery`.
    test "the third line says this computer can ring iff the build offers it and the schema has delivery" do
      hosts =
        [facts(:app_engine, :darwin), facts(:standalone_cli, :darwin), facts(:source, :darwin)] ++
          for install <- [:linux_package_cli, :standalone_cli, :source], app <- [true, false] do
            facts(install, :linux, linux_app: app)
          end

      for %{install: install, os: os} = facts <- hosts do
        host = %{profile: install, os: os}

        assert [_heading, _install, _machine, computer] =
                 String.split(HostFacts.render(facts, placement: :here), "\n")

        rings? =
          String.starts_with?(computer, "- This computer: a reminder or timer can ring here")

        silent? = String.starts_with?(computer, "- This computer: nothing can ring here")
        offered? = Notifications.offered?(host: host)

        published? =
          Map.has_key?(EventStore.dynamic_parameters(%{host: host}).properties, :delivery)

        assert rings? != silent?, "#{inspect(host)}: #{computer}"
        assert rings? == offered?, "#{inspect(host)} rings #{rings?}, offered #{offered?}"
        assert rings? == published?, "#{inspect(host)} rings #{rings?}, schema #{published?}"
        assert computer =~ ~s(delivery: "computer") == rings?
      end
    end
  end

  describe "the facts boot recorded" do
    # The application's own start read them through the stub `config/test.exs`
    # pins, on this run's real host profile and architecture: no test reads the
    # machine's plist, os-release or desktop entry directories.
    test "boot read them through the pinned stub, and the section renders from them" do
      expected = HostFactsStub.read(BootProfile.host(), BuildInfo.identity().architecture)

      assert HostFacts.current() == expected
      assert HostFacts.prompt_section() == HostFacts.render(expected)
    end

    test "remember/0 is what current/0 reads, and nothing remembered raises" do
      before = Application.fetch_env!(:fermix_core, :host_facts)
      on_exit(fn -> Application.put_env(:fermix_core, :host_facts, before) end)

      Application.delete_env(:fermix_core, :host_facts)
      assert_raise ArgumentError, ~r/host_facts/, fn -> HostFacts.current() end

      assert HostFacts.remember() == :ok
      assert HostFacts.current() == before
    end
  end
end
