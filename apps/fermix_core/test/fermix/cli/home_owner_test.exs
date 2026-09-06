defmodule Fermix.CLI.HomeOwnerTest do
  @moduledoc """
  The home-owner decision table from M34 native setup §15.2, and the four verbs
  that consult it.

  It is a table over two disjoint states of the machine, not a precedence chain:
  when a daemon answers, its `hello` decides and the marker is not read at all;
  when none answers, the marker decides.
  """

  use ExUnit.Case, async: true

  alias Fermix.CLI.HomeOwner
  alias Fermix.CLI.ServiceCommand
  alias Fermix.CLI.StartCommand
  alias Fermix.CLI.StopCommand

  import ExUnit.CaptureIO

  defmodule FormulaBuild do
    @moduledoc false
    def app_engine?, do: false
  end

  defmodule AppBuild do
    @moduledoc false
    def app_engine?, do: true
  end

  defmodule NeverInstalled do
    @moduledoc false
    def installed?(_scope), do: false
    def start(_scope), do: :ok
    def stop(_scope), do: :ok
    def install(_scope), do: :ok
    def uninstall(_scope), do: :ok
  end

  describe "when a daemon answers" do
    test "its hello decides and the marker is never read" do
      opts = [
        hello: fn -> {:ok, %{"engine" => %{"distribution_identity" => "macos_app"}}} end,
        marker?: fn _opts -> flunk("the marker was read while a daemon answered") end
      ]

      assert HomeOwner.app_managed?(opts)
    end

    test "a standalone daemon means the home is not app managed" do
      opts = [
        hello: fn -> {:ok, %{"engine" => %{"distribution_identity" => "standalone"}}} end,
        marker?: fn _opts -> flunk("the marker was read while a daemon answered") end
      ]

      refute HomeOwner.app_managed?(opts)
    end
  end

  describe "when no daemon answers" do
    test "the marker decides" do
      assert HomeOwner.app_managed?(no_daemon(true))
      refute HomeOwner.app_managed?(no_daemon(false))
    end

    # Fails open: a machine with no app, no daemon and no marker behaves exactly
    # as it does today for every verb.
    test "a machine with nothing at all is not app managed" do
      refute HomeOwner.app_managed?(
               hello: fn -> {:error, :not_running} end,
               marker?: fn _opts -> false end
             )
    end
  end

  describe "the three refused verbs" do
    test "fermix start refuses on an app-managed home and names the app" do
      output = capture_io(:stderr, fn -> assert StartCommand.run([], refused_deps()) == 1 end)

      assert output =~ "fermix start"
      assert output =~ "Fermix.app"
    end

    test "fermix stop refuses on an app-managed home" do
      output = capture_io(:stderr, fn -> assert StopCommand.run([], refused_deps()) == 1 end)

      assert output =~ "fermix stop"
    end

    test "fermix service install refuses on an app-managed home" do
      output =
        capture_io(:stderr, fn ->
          assert ServiceCommand.run(["install"], refused_deps()) == 1
        end)

      assert output =~ "fermix service install"
    end

    # `service uninstall` is the supported remedy for exactly the condition the
    # `legacy_service_unit` row reports, and it targets a unit the app does not
    # own, so refusing it would leave that row with no command behind it.
    test "fermix service uninstall is not refused by the home-owner check" do
      output =
        capture_io(fn ->
          assert ServiceCommand.run(["uninstall"], refused_deps()) == 0
        end)

      refute output =~ "managed by Fermix.app"
    end
  end

  # The ordering rule: the app's own binary keeps its existing refusal, which
  # keys on the binary, and never consults the home-owner check.
  test "the app's own binary refuses through its existing branch, not this check" do
    deps = [
      build_info: AppBuild,
      service: NeverInstalled,
      home_owner: __MODULE__.NeverConsulted
    ]

    output = capture_io(:stderr, fn -> assert StartCommand.run([], deps) == 1 end)
    assert output =~ "Fermix.app"
  end

  defmodule NeverConsulted do
    @moduledoc false
    def app_managed?(_opts), do: raise("the home-owner check ran on the app's own binary")
  end

  test "a home with no app leaves every verb alone" do
    deps = [
      build_info: FormulaBuild,
      service: NeverInstalled,
      home_owner: __MODULE__.NotManaged
    ]

    output = capture_io(:stderr, fn -> assert StartCommand.run([], deps) == 1 end)
    refute output =~ "managed by Fermix.app"
  end

  defmodule NotManaged do
    @moduledoc false
    def app_managed?(_opts), do: false
  end

  defmodule Managed do
    @moduledoc false
    def app_managed?(_opts), do: true
  end

  defp refused_deps do
    [build_info: FormulaBuild, service: NeverInstalled, home_owner: __MODULE__.Managed]
  end

  defp no_daemon(marker?) do
    [hello: fn -> {:error, :not_running} end, marker?: fn _opts -> marker? end]
  end
end
