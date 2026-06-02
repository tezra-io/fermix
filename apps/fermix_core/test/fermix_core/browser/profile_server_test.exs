defmodule FermixCore.Browser.ProfileServerTest do
  use ExUnit.Case, async: true

  alias FermixCore.Browser.Config
  alias FermixCore.Browser.Error
  alias FermixCore.Browser.ProfileServer

  # Injected launcher: never touches real Chrome. Behavior is driven by fields
  # stuffed into the profile map (which ProfileServer passes through to start/4),
  # and teardown is observable because stop/2 messages the test pid carried on
  # the runtime it returns.
  defmodule FakeLauncher do
    alias FermixCore.Browser.Error

    # No pre-existing Chrome to re-attach to in these tests.
    def attach(_config, _profile, _owner, _name), do: :none

    def start(_config, %{behavior: :fail, test_pid: pid}, _owner, _name) do
      send(pid, :launch_attempt)
      {:error, Error.new("chrome_missing", "no chrome in test")}
    end

    def start(_config, %{behavior: :spawn_unreachable, test_pid: pid}, _owner, _name) do
      send(pid, :launch_attempt)
      # Valid-looking runtime, but ws_url points at a closed port so the CDP
      # connect fails after the (fake) spawn — exercising the orphan-teardown path.
      {:ok,
       %{
         ws_url: "ws://127.0.0.1:1/devtools/browser/test",
         os_pid: 4242,
         port_ref: nil,
         headless: false,
         port: 1,
         test_pid: pid
       }}
    end

    def stop(%{test_pid: pid} = runtime, _config) do
      send(pid, {:stopped, Map.get(runtime, :os_pid)})
      :ok
    end

    def stop(_runtime, _config), do: :ok
  end

  defp start_server(profile, config, now_fn) do
    start_supervised!(
      {ProfileServer,
       owner_key: "owner-test",
       profile_name: "fermix",
       profile: profile,
       config: config,
       launcher: FakeLauncher,
       now_fn: now_fn}
    )
  end

  defp request(pid, action) do
    ProfileServer.request(pid, %{action: action, args: %{}, context: %{agent_name: "t"}})
  end

  test "enters cooldown after the failure threshold and stops attempting launches" do
    {:ok, config} = Config.current(start_failure_threshold: 2, start_cooldown_ms: 50_000)
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    now_fn = fn -> Agent.get(clock, & &1) end

    pid = start_server(%{mode: :managed, behavior: :fail, test_pid: self()}, config, now_fn)

    # Two real launch attempts fail (threshold = 2) and arm the cooldown.
    assert {:error, %Error{code: "chrome_missing"}} = request(pid, "start")
    assert {:error, %Error{code: "chrome_missing"}} = request(pid, "start")
    assert_received :launch_attempt
    assert_received :launch_attempt

    # While in cooldown, the next request fails fast WITHOUT another launch.
    assert {:error, %Error{code: "browser_cooldown"}} = request(pid, "start")
    refute_received :launch_attempt
  end

  test "tears down the spawned browser when CDP connect fails after launch" do
    {:ok, config} = Config.current(action_timeout_ms: 500)
    now_fn = fn -> System.monotonic_time(:millisecond) end

    pid =
      start_server(
        %{mode: :managed, behavior: :spawn_unreachable, test_pid: self()},
        config,
        now_fn
      )

    # connect/1 fails (closed port) -> finish_runtime must reap the spawned runtime.
    assert {:error, %Error{code: "cdp_connect_failed"}} = request(pid, "start")
    assert_received :launch_attempt
    assert_receive {:stopped, 4242}, 1_000
  end
end
