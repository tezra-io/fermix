defmodule FermixCore.AppLauncherTest do
  @moduledoc """
  `AppLauncher` is the one owner of opening the Fermix app (M76 §4.4): the
  browser host and the native host open it through `launch/1`, under the one
  deadline and cooldown it names. `launch/1` itself is never run here, since
  it opens the app this engine runs inside.
  """

  use ExUnit.Case, async: true

  alias FermixCore.AppLauncher
  alias FermixCore.Browser.Config
  alias FermixCore.Browser.HostLauncher

  test "a launch is held to one deadline and one cooldown, which the browser host holds too" do
    assert AppLauncher.deadline_ms() == 3_000
    assert AppLauncher.cooldown_ms() == 300_000
    assert %Config{}.host_launch_timeout_ms == AppLauncher.deadline_ms()
    assert %Config{}.host_launch_cooldown_ms == AppLauncher.cooldown_ms()
  end

  test "opening the app has one owner" do
    assert Code.ensure_loaded?(HostLauncher)
    assert Code.ensure_loaded?(AppLauncher)
    assert function_exported?(AppLauncher, :launch, 1)
    refute function_exported?(HostLauncher, :launch, 1)
  end
end
