defmodule FermixCore.BootProfileTest do
  use ExUnit.Case, async: false

  alias FermixCore.BootProfile

  test "app-engine identity wins without consulting Burrito detection" do
    detector = fn -> flunk("Burrito detection must not run for an app engine") end

    assert BootProfile.select("macos_app", detector) == :app_engine
  end

  test "standalone identity preserves Burrito and source boot postures" do
    assert BootProfile.select("standalone", fn -> true end) == :standalone_cli
    assert BootProfile.select("standalone", fn -> false end) == :source
  end

  # A linux_package stamp on a source tree is a developer's own checkout, not a
  # packaged install: the packaged CLI posture is claimed only by the wrapper.
  test "linux-package identity separates the packaged CLI from a source run" do
    assert BootProfile.select("linux_package", fn -> true end) == :linux_package_cli
    assert BootProfile.select("linux_package", fn -> false end) == :source
  end

  # The application's own start recorded what it selected; under `mix test` a
  # source checkout, never a Burrito wrapper or an app engine.
  test "boot remembers the profile it selected, and the host pairs it with the system" do
    assert BootProfile.current() == :source

    {_family, os} = :os.type()
    assert BootProfile.host() == %{profile: :source, os: os}
  end

  test "remember/1 is what current/0 reads, and nothing remembered raises" do
    before = Application.fetch_env!(:fermix_core, :boot_profile)
    on_exit(fn -> BootProfile.remember(before) end)

    :ok = BootProfile.remember(:standalone_cli)
    assert BootProfile.current() == :standalone_cli

    Application.delete_env(:fermix_core, :boot_profile)
    assert_raise ArgumentError, ~r/boot_profile/, fn -> BootProfile.current() end
  end

  test "preparing the packaged Linux CLI opens the same daemon surfaces" do
    endpoint_before = Application.get_env(:fermix_web, FermixWebWeb.Endpoint)
    daemon_before = Application.get_env(:fermix_core, :daemon_socket_enabled)
    realtime_before = Application.get_env(:fermix_core, :realtime_socket_enabled)

    on_exit(fn ->
      restore_env(:fermix_web, FermixWebWeb.Endpoint, endpoint_before)
      restore_env(:fermix_core, :daemon_socket_enabled, daemon_before)
      restore_env(:fermix_core, :realtime_socket_enabled, realtime_before)
    end)

    Application.put_env(:fermix_web, FermixWebWeb.Endpoint, custom: :preserved, server: false)
    Application.put_env(:fermix_core, :daemon_socket_enabled, false)
    Application.put_env(:fermix_core, :realtime_socket_enabled, false)

    assert BootProfile.prepare(:linux_package_cli) == :ok

    endpoint = Application.get_env(:fermix_web, FermixWebWeb.Endpoint)
    assert endpoint[:custom] == :preserved
    assert endpoint[:server] == true

    assert Application.get_env(:fermix_core, :daemon_socket_enabled) == true
    assert Application.get_env(:fermix_core, :realtime_socket_enabled) == true
  end

  test "preparing app-engine boot enables every daemon surface" do
    endpoint_before = Application.get_env(:fermix_web, FermixWebWeb.Endpoint)
    daemon_before = Application.get_env(:fermix_core, :daemon_socket_enabled)
    realtime_before = Application.get_env(:fermix_core, :realtime_socket_enabled)

    on_exit(fn ->
      restore_env(:fermix_web, FermixWebWeb.Endpoint, endpoint_before)
      restore_env(:fermix_core, :daemon_socket_enabled, daemon_before)
      restore_env(:fermix_core, :realtime_socket_enabled, realtime_before)
    end)

    Application.put_env(:fermix_web, FermixWebWeb.Endpoint, custom: :preserved, server: false)
    Application.put_env(:fermix_core, :daemon_socket_enabled, false)
    Application.put_env(:fermix_core, :realtime_socket_enabled, false)

    assert BootProfile.prepare(:app_engine) == :ok

    endpoint = Application.get_env(:fermix_web, FermixWebWeb.Endpoint)
    assert endpoint[:custom] == :preserved
    assert endpoint[:server] == true

    assert Application.get_env(:fermix_core, :daemon_socket_enabled) == true
    assert Application.get_env(:fermix_core, :realtime_socket_enabled) == true
  end

  test "source preparation does not change daemon surface gates" do
    endpoint_before = Application.get_env(:fermix_web, FermixWebWeb.Endpoint)
    daemon_before = Application.get_env(:fermix_core, :daemon_socket_enabled)
    realtime_before = Application.get_env(:fermix_core, :realtime_socket_enabled)

    assert BootProfile.prepare(:source) == :ok

    assert Application.get_env(:fermix_web, FermixWebWeb.Endpoint) == endpoint_before
    assert Application.get_env(:fermix_core, :daemon_socket_enabled) == daemon_before
    assert Application.get_env(:fermix_core, :realtime_socket_enabled) == realtime_before
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
