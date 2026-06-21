defmodule FermixCore.ComputerUse.ConfigTest do
  use ExUnit.Case, async: true

  alias FermixCore.ComputerUse.Config
  alias FermixCore.Sandbox.Config, as: SandboxConfig

  describe "normalize/1 defaults" do
    test "empty config is disabled, browser mode, standard access, with safe defaults" do
      config = Config.normalize([])

      assert config.enabled? == false
      assert config.mode == :browser
      assert config.access == :standard
      assert config.display == 0
      assert config.display_width_px == 1280
      assert config.display_height_px == 800
      assert config.screenshot_after? == true
      assert config.max_actions == 40
      assert config.max_retained_screenshots == 3
    end

    test "nil normalizes to defaults" do
      assert Config.normalize(nil) == Config.normalize([])
    end
  end

  describe "normalize/1 overrides" do
    test "reads a keyword list with atom keys" do
      config =
        Config.normalize(
          enabled: true,
          mode: :host,
          display: 1,
          max_actions: 10
        )

      assert config.enabled? == true
      assert config.mode == :host
      assert config.display == 1
      assert config.max_actions == 10
      # access is NOT read from the computer_use config — it's derived from the
      # sandbox mode at current/0 (see the derivation describe block below).
    end

    test "reads a map with string keys (TOML shape) and string booleans/mode" do
      config =
        Config.normalize(%{
          "enabled" => "true",
          "mode" => "host",
          "screenshot_after" => "false"
        })

      assert config.enabled? == true
      assert config.mode == :host
      assert config.screenshot_after? == false
    end
  end

  describe "normalize/1 fail-loud validation" do
    test "rejects an unknown mode" do
      assert_raise ArgumentError, ~r/computer_use.mode must be one of/, fn ->
        Config.normalize(mode: :vm)
      end
    end

    test "rejects a non-boolean enabled" do
      assert_raise ArgumentError, ~r/computer_use.enabled must be a boolean/, fn ->
        Config.normalize(enabled: "yes")
      end
    end

    test "rejects a non-positive max_actions" do
      assert_raise ArgumentError, ~r/computer_use.max_actions must be a positive integer/, fn ->
        Config.normalize(max_actions: 0)
      end
    end

    test "rejects a display dimension over the long-edge cap" do
      assert_raise ArgumentError, ~r/computer_use.display_width_px must be between/, fn ->
        Config.normalize(display_width_px: 4000)
      end
    end

    test "rejects a display dimension under the floor" do
      assert_raise ArgumentError, ~r/computer_use.display_height_px must be between/, fn ->
        Config.normalize(display_height_px: 100)
      end
    end

    test "rejects a negative display index" do
      assert_raise ArgumentError, ~r/computer_use.display must be a non-negative integer/, fn ->
        Config.normalize(display: -1)
      end
    end
  end

  describe "current/0 and enabled?/0" do
    setup do
      prev = Application.get_env(:fermix_core, :computer_use)
      prev_sandbox = Application.get_env(:fermix_core, :sandbox)

      on_exit(fn ->
        restore(prev)
        restore_sandbox(prev_sandbox)
      end)

      :ok
    end

    test "current/0 reads :computer_use app env through normalize/1" do
      Application.put_env(:fermix_core, :computer_use, enabled: true, mode: :host)
      config = Config.current()
      assert config.enabled? == true
      assert config.mode == :host
    end

    test "current/0 DERIVES access 1:1 from the live [sandbox] mode" do
      Application.put_env(:fermix_core, :computer_use, enabled: true)

      for mode <- [:strict, :standard, :open] do
        Application.put_env(:fermix_core, :sandbox, %{SandboxConfig.default() | mode: mode})
        assert Config.current().access == mode
      end
    end

    test "enabled?/0 is false when unconfigured" do
      Application.delete_env(:fermix_core, :computer_use)
      refute Config.enabled?()
    end
  end

  defp restore(nil), do: Application.delete_env(:fermix_core, :computer_use)
  defp restore(prev), do: Application.put_env(:fermix_core, :computer_use, prev)
  defp restore_sandbox(nil), do: Application.delete_env(:fermix_core, :sandbox)
  defp restore_sandbox(prev), do: Application.put_env(:fermix_core, :sandbox, prev)
end
