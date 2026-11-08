defmodule FermixCore.BootProfileTest do
  use ExUnit.Case, async: false

  alias FermixCore.BootProfile
  alias FermixTestSupport.SafeRm

  # A home of the test's own, and no operator key in the environment: the
  # key a packaged boot signs its cookies with is the one this home keeps.
  setup do
    home = SafeRm.make_tmp_dir!("boot-profile-home")
    previous = System.get_env("SECRET_KEY_BASE")
    System.delete_env("SECRET_KEY_BASE")

    on_exit(fn ->
      if previous, do: System.put_env("SECRET_KEY_BASE", previous)
      SafeRm.rm_rf!(home)
    end)

    %{home: home}
  end

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

  test "preparing the packaged Linux CLI opens the same daemon surfaces", %{home: home} do
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

    assert BootProfile.prepare(:linux_package_cli, home) == :ok

    endpoint = Application.get_env(:fermix_web, FermixWebWeb.Endpoint)
    assert endpoint[:custom] == :preserved
    assert endpoint[:server] == true
    assert endpoint[:secret_key_base] == File.read!(Path.join(home, "secret_key_base"))

    assert Application.get_env(:fermix_core, :daemon_socket_enabled) == true
    assert Application.get_env(:fermix_core, :realtime_socket_enabled) == true
  end

  # The endpoint serves only after this, so its signing key is made only
  # here: a verb that serves nothing writes no home (EC2 test 2026-11-08).
  test "preparing app-engine boot enables every daemon surface", %{home: home} do
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

    assert BootProfile.prepare(:app_engine, home) == :ok

    endpoint = Application.get_env(:fermix_web, FermixWebWeb.Endpoint)
    assert endpoint[:custom] == :preserved
    assert endpoint[:server] == true
    key = endpoint[:secret_key_base]
    assert key == File.read!(Path.join(home, "secret_key_base"))

    # The next boot signs with the same key, so a session survives a restart.
    assert BootProfile.prepare(:app_engine, home) == :ok
    assert Application.get_env(:fermix_web, FermixWebWeb.Endpoint)[:secret_key_base] == key

    assert Application.get_env(:fermix_core, :daemon_socket_enabled) == true
    assert Application.get_env(:fermix_core, :realtime_socket_enabled) == true
  end

  test "source preparation does not change daemon surface gates", %{home: home} do
    endpoint_before = Application.get_env(:fermix_web, FermixWebWeb.Endpoint)
    daemon_before = Application.get_env(:fermix_core, :daemon_socket_enabled)
    realtime_before = Application.get_env(:fermix_core, :realtime_socket_enabled)

    assert BootProfile.prepare(:source, home) == :ok
    refute File.exists?(Path.join(home, "secret_key_base"))

    assert Application.get_env(:fermix_web, FermixWebWeb.Endpoint) == endpoint_before
    assert Application.get_env(:fermix_core, :daemon_socket_enabled) == daemon_before
    assert Application.get_env(:fermix_core, :realtime_socket_enabled) == realtime_before
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
