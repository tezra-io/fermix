defmodule FermixCore.Native.ProviderTest do
  @moduledoc """
  The native-services provider (M76 §4.3): one table over every host
  `BootProfile.host/0` can answer, and the `provider:` and `host:` seams a
  caller names it with.
  """

  use ExUnit.Case, async: true

  alias FermixCore.BootProfile
  alias FermixCore.Native.Provider

  @mac_app %{profile: :app_engine, os: :darwin}
  @brew_mac %{profile: :standalone_cli, os: :darwin}
  @mac_checkout %{profile: :source, os: :darwin}

  # Every host a build boots as: the app's engine, the Burrito CLIs and a
  # source run, on each operating system Fermix ships for. A Linux package is
  # built for Linux only, so no build boots it on a Mac.
  @table [
    {@mac_app, :mac_app},
    {@brew_mac, :none},
    {@mac_checkout, :none},
    {%{profile: :app_engine, os: :linux}, :dbus},
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
    for host <- [%{profile: :linux_package_cli, os: :darwin}, %{profile: :source, os: :freebsd}] do
      assert_raise FunctionClauseError, fn -> Provider.select(host) end
    end
  end

  test "this build's provider is the one its boot profile selects" do
    assert Provider.current() == Provider.select(BootProfile.host())
  end

  test "provider: names the provider; host: names the host that selects it" do
    assert Provider.current(provider: :none) == :none
    assert Provider.current(provider: :dbus, host: @mac_app) == :dbus
    assert Provider.current(host: @mac_app) == :mac_app
    assert Provider.current(host: @brew_mac) == :none
    assert Provider.current([]) == Provider.current()
  end

  test "a provider outside the three is refused" do
    assert_raise ArgumentError, ~r/:osascript/, fn -> Provider.current(provider: :osascript) end
  end

  test "host: names the host, this build's otherwise" do
    assert Provider.host(host: @mac_checkout) == @mac_checkout
    assert Provider.host([]) == BootProfile.host()
  end
end
