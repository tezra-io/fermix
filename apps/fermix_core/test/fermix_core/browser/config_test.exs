defmodule FermixCore.Browser.ConfigTest do
  use ExUnit.Case, async: false

  alias FermixCore.Browser.Config

  setup do
    original = Application.get_env(:fermix_core, :browser)
    on_exit(fn -> restore(original) end)
    :ok
  end

  test "defaults include bounded live profiles and managed profiles" do
    Application.delete_env(:fermix_core, :browser)

    assert {:ok, config} = Config.current()
    assert config.default_profile == "fermix"
    assert config.max_live_profiles > 0
    assert config.idle_profile_ttl_ms > 0
    assert config.cdp_port_range == 18_900..18_999
    assert Map.fetch!(config.profiles, "fermix").headless == :auto
    assert Map.fetch!(config.profiles, "fermix_headless").headless == true
  end

  test "test config pins smoke CDP ports away from agent ports" do
    assert {:ok, config} = Config.current()
    assert config.cdp_port_range == 19_100..19_199
  end

  test "rejects invalid max_live_profiles" do
    Application.put_env(:fermix_core, :browser, max_live_profiles: 0)

    assert {:error, error} = Config.current()
    assert error.code == "invalid_config"
    assert error.message =~ "max_live_profiles"
  end

  test "requires existing-session profiles to provide cdp_url" do
    Application.put_env(:fermix_core, :browser,
      profiles: %{user: %{mode: :existing_session, headless: :auto, cdp_port: :auto}}
    )

    assert {:error, error} = Config.current()
    assert error.code == "invalid_config"
    assert error.message =~ "cdp_url"
  end

  test "rejects launch-mode overrides for existing-session profiles" do
    Application.put_env(:fermix_core, :browser,
      profiles: %{
        user: %{
          mode: :existing_session,
          cdp_url: "ws://127.0.0.1:9222/devtools/browser/test",
          headless: true,
          cdp_port: :auto
        }
      }
    )

    assert {:error, error} = Config.current()
    assert error.code == "invalid_config"
    assert error.message =~ "headless"
  end

  test "snapshot defaults are compact and bounded" do
    assert {:ok, defaults} = Config.snapshot_options(%{})
    assert defaults.interactive == true
    assert defaults.compact == true
    assert defaults.depth == 5
    assert defaults.include_urls == false
    assert defaults.max_children > 0
    assert defaults.max_chars > 0
  end

  test "centralizes every browser timeout and bound with positive defaults" do
    Application.delete_env(:fermix_core, :browser)
    assert {:ok, config} = Config.current()

    timeouts = [
      :action_timeout_ms,
      :navigation_timeout_ms,
      :cdp_keepalive_ms,
      :cdp_response_grace_ms,
      :launch_timeout_ms,
      :cdp_ready_poll_interval_ms,
      :cdp_version_probe_timeout_ms,
      :stop_grace_ms,
      :kill_grace_ms,
      :start_failure_threshold,
      :start_cooldown_ms,
      :start_cooldown_max_ms,
      :start_retries,
      :shutdown_slack_ms,
      :wait_default_ms,
      :wait_max_ms,
      :wait_poll_interval_ms,
      :download_default_ms,
      :download_max_ms,
      :console_buffer_limit,
      :dialog_buffer_limit,
      :idle_profile_ttl_ms,
      :idle_sweep_interval_ms,
      :snapshot_max_chars,
      :screenshot_max_bytes,
      :screenshot_max_side_px
    ]

    for field <- timeouts do
      assert is_integer(Map.fetch!(config, field)) and Map.fetch!(config, field) > 0,
             "expected #{field} to be a positive integer default"
    end
  end

  test "rejects a non-positive teardown timeout" do
    Application.put_env(:fermix_core, :browser, stop_grace_ms: 0)

    assert {:error, error} = Config.current()
    assert error.code == "invalid_config"
    assert error.message =~ "stop_grace_ms"
  end

  test "honors overridden system timeouts" do
    Application.put_env(:fermix_core, :browser, action_timeout_ms: 1234, wait_max_ms: 9999)

    assert {:ok, config} = Config.current()
    assert config.action_timeout_ms == 1234
    assert config.wait_max_ms == 9999
  end

  defp restore(nil), do: Application.delete_env(:fermix_core, :browser)
  defp restore(value), do: Application.put_env(:fermix_core, :browser, value)
end
