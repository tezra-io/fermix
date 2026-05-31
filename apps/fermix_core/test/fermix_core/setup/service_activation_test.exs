defmodule FermixCore.Setup.ServiceActivationTest do
  use ExUnit.Case, async: true

  alias FermixCore.Setup.ServiceActivation

  test "skips when explicitly opted out" do
    service = fake_service(installed?: false)

    assert {:skipped, :opted_out} =
             ServiceActivation.ensure_running(:user, service: service, no_service: true)

    refute_receive {:service, _, _, _}
  end

  test "skips outside the standalone binary" do
    service = fake_service(installed?: false)

    assert {:skipped, :not_standalone} =
             ServiceActivation.ensure_running(:user,
               service: service,
               standalone?: fn -> false end
             )

    refute_receive {:service, _, _, _}
  end

  test "installs and starts when the service is not installed" do
    service = fake_service(installed?: false)

    assert {:ok, %{scope: :user, action: :installed_started}} =
             ServiceActivation.ensure_running(:user,
               service: service,
               standalone?: fn -> true end
             )

    assert_receive {:service, :installed?, :user, []}
    assert_receive {:service, :install, :user, []}
    assert_receive {:service, :start, :user, []}
  end

  test "restarts when the service is already installed" do
    service = fake_service(installed?: true)

    assert {:ok, %{scope: :system, action: :restarted}} =
             ServiceActivation.ensure_running(:system,
               service: service,
               standalone?: fn -> true end
             )

    assert_receive {:service, :installed?, :system, []}
    assert_receive {:service, :restart, :system, []}
    refute_receive {:service, :install, _, _}
  end

  test "starts an installed service when restart fails" do
    service = fake_service(installed?: true, restart: {:error, :not_running})

    assert {:ok, %{scope: :user, action: :started}} =
             ServiceActivation.ensure_running(:user,
               service: service,
               standalone?: fn -> true end
             )

    assert_receive {:service, :restart, :user, []}
    assert_receive {:service, :start, :user, []}
    refute_receive {:service, :install, _, _}
  end

  test "returns restart and start errors when installed service cannot recover" do
    service =
      fake_service(installed?: true, restart: {:error, :bad_restart}, start: {:error, :bad_start})

    assert {:error, {:restart_failed, :bad_restart, :start_failed, :bad_start}} =
             ServiceActivation.ensure_running(:user,
               service: service,
               standalone?: fn -> true end
             )

    assert_receive {:service, :restart, :user, []}
    assert_receive {:service, :start, :user, []}
  end

  test "returns install errors without starting" do
    service = fake_service(installed?: false, install: {:error, :denied})

    assert {:error, {:install_failed, :denied}} =
             ServiceActivation.ensure_running(:user,
               service: service,
               standalone?: fn -> true end
             )

    assert_receive {:service, :install, :user, []}
    refute_receive {:service, :start, _, _}
  end

  defp fake_service(opts) do
    parent = self()
    installed? = Keyword.fetch!(opts, :installed?)
    install = Keyword.get(opts, :install, :ok)
    start = Keyword.get(opts, :start, :ok)
    restart = Keyword.get(opts, :restart, :ok)

    %{
      installed?: fn scope, service_opts ->
        send(parent, {:service, :installed?, scope, service_opts})
        installed?
      end,
      install: fn scope, service_opts ->
        send(parent, {:service, :install, scope, service_opts})
        install
      end,
      start: fn scope, service_opts ->
        send(parent, {:service, :start, scope, service_opts})
        start
      end,
      restart: fn scope, service_opts ->
        send(parent, {:service, :restart, scope, service_opts})
        restart
      end
    }
  end
end
