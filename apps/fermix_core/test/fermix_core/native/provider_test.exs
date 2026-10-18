defmodule FermixCore.Native.ProviderTest do
  @moduledoc """
  The native-services provider (M76 §4.3): one table over every host
  `BootProfile.host/0` can answer, and the `provider:` and `host:` seams a
  caller names it with.

  `async: false`: one test removes the recorded boot profile, and restores it,
  to show that this build's provider is read from it.
  """

  use ExUnit.Case, async: false

  alias FermixCore.BootProfile
  alias FermixCore.Native.Provider

  @mac_app %{profile: :app_engine, os: :darwin}
  @brew_mac %{profile: :standalone_cli, os: :darwin}
  @mac_checkout %{profile: :source, os: :darwin}

  # Every host a build boots as: the app's engine on a Mac, the Burrito CLIs
  # and a source run, on each operating system Fermix ships for. A Linux
  # package is built for Linux only, and the app's engine for a Mac only.
  @table [
    {@mac_app, :mac_app},
    {@brew_mac, :none},
    {@mac_checkout, :none},
    {%{profile: :standalone_cli, os: :linux}, :dbus},
    {%{profile: :linux_package_cli, os: :linux}, :dbus},
    {%{profile: :source, os: :linux}, :dbus}
  ]

  test "every host selects the provider the table names" do
    for {host, provider} <- @table do
      assert Provider.select(host) == provider, "#{inspect(host)} did not select #{provider}"
    end
  end

  test "a host no build boots as is refused, never guessed" do
    for host <- [
          %{profile: :app_engine, os: :linux},
          %{profile: :linux_package_cli, os: :darwin},
          %{profile: :source, os: :freebsd}
        ] do
      assert_raise FunctionClauseError, fn -> Provider.select(host) end
    end
  end

  test "this build's provider and host are read from the boot profile boot recorded" do
    recorded = Application.fetch_env!(:fermix_core, :boot_profile)
    on_exit(fn -> BootProfile.remember(recorded) end)
    Application.delete_env(:fermix_core, :boot_profile)

    for read <- [&Provider.current/0, fn -> Provider.current([]) end, fn -> Provider.host([]) end] do
      assert_raise ArgumentError, ~r/boot_profile/, read
    end
  end

  test "provider: names the provider; host: names the host that selects it" do
    assert Provider.current(provider: :none) == :none
    assert Provider.current(provider: :dbus, host: @mac_app) == :dbus
    assert Provider.current(host: @mac_app) == :mac_app
    assert Provider.current(host: @brew_mac) == :none
  end

  test "a provider outside the three is refused" do
    assert_raise ArgumentError, ~r/:osascript/, fn -> Provider.current(provider: :osascript) end
  end

  test "host: names the host" do
    assert Provider.host(host: @mac_checkout) == @mac_checkout
  end
end
