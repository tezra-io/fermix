defmodule FermixCore.ComputerUse.ConfigTest do
  # async: false — the `current/0` block writes the global `:fermix_core,
  # :computer_use` and `:fermix_core, :sandbox` app env (and deletes the former),
  # which async siblings read live through `Sandbox.Config.current/0`,
  # `MCP.Supervisor` and `Harness.Run` (the leaked-app-env pitfall class).
  use ExUnit.Case, async: false

  alias FermixCore.ComputerUse.Config
  alias FermixCore.Sandbox.Config, as: SandboxConfig

  describe "normalize/1 defaults" do
    test "empty config is disabled, standard access, with safe defaults" do
      config = Config.normalize([])

      assert config.enabled? == false
      assert config.access == :standard
      assert config.display == 0
      assert config.screenshot_after? == true
      assert config.max_actions == 80
      assert config.max_retained_screenshots == 3
      # Coexistence (V3 R0): courtesy is ON by default so the agent yields to a
      # present human out of the box; the idle threshold defaults to 1s.
      assert config.courtesy == :yield
      assert config.courtesy_idle_ms == 1_000
      # M42 slice 5: the experimental bound-window surface stays off until the
      # owner's live check qualifies it.
      assert config.background? == false
    end

    test "nil normalizes to defaults" do
      assert Config.normalize(nil) == Config.normalize([])
    end
  end

  describe "courtesy (coexistence)" do
    test "reads an atom or string courtesy and the idle threshold" do
      assert Config.normalize(courtesy: :off).courtesy == :off
      assert Config.normalize(courtesy: "off").courtesy == :off
      assert Config.normalize(courtesy: "yield").courtesy == :yield
      assert Config.normalize(courtesy_idle_ms: 2_500).courtesy_idle_ms == 2_500
    end

    test "an unknown courtesy value fails loud" do
      assert_raise ArgumentError, ~r/computer_use.courtesy must be :off or :yield/, fn ->
        Config.normalize(courtesy: "sometimes")
      end
    end

    test "a non-positive idle threshold fails loud" do
      assert_raise ArgumentError,
                   ~r/computer_use.courtesy_idle_ms must be a positive integer/,
                   fn ->
                     Config.normalize(courtesy_idle_ms: 0)
                   end
    end

    test "to_keyword round-trips courtesy (as a TOML-safe string) and the threshold" do
      kw = Config.to_keyword(Config.normalize(courtesy: :off, courtesy_idle_ms: 1_500))
      assert kw[:courtesy] == "off"
      assert kw[:courtesy_idle_ms] == 1_500
      # and it re-normalizes back to the same struct fields
      round = Config.normalize(kw)
      assert round.courtesy == :off
      assert round.courtesy_idle_ms == 1_500
    end
  end

  describe "background (the experimental bound-window surface)" do
    test "reads a boolean or its TOML string, and defaults off" do
      assert Config.normalize(background: true).background? == true
      assert Config.normalize(%{"background" => "true"}).background? == true
      assert Config.normalize(background: false).background? == false
      assert Config.normalize([]).background? == false
    end

    test "a value that is not a boolean fails loud" do
      assert_raise ArgumentError, ~r/computer_use.background must be a boolean/, fn ->
        Config.normalize(background: "sometimes")
      end
    end

    # `normalize/1` is one-way, so the persist path needs its inverse and the
    # proof is a round trip seeded with the shape setup actually writes: the
    # NORMALIZED app-env keyword, not a TOML string (the 2026-08-19 lesson).
    test "save then load is a fixed point over the normalized app-env shape" do
      persisted = Config.to_keyword(Config.normalize(enabled: true, background: true))

      assert Keyword.get(persisted, :background) == true
      assert Config.normalize(persisted).background? == true
      assert Config.to_keyword(Config.normalize(persisted)) == persisted
    end

    test "to_keyword writes exactly the keys this section honors" do
      assert Keyword.keys(Config.to_keyword(Config.normalize([]))) == Config.config_keys()
    end

    # Nothing refuses a key outside that list: a host's config.toml still carries
    # keys this section retired, and `brew upgrade` never rewrites it.
    test "a section full of retired keys normalizes rather than raising" do
      config =
        Config.normalize(
          enabled: true,
          background: true,
          mode: "browser",
          display_width_px: 1366,
          allowed_apps: ["Safari"],
          confirm_consequential: true
        )

      assert config.enabled? == true
      assert config.background? == true
      refute Keyword.has_key?(Config.to_keyword(config), :mode)
    end
  end

  describe "normalize/1 overrides" do
    test "reads a keyword list with atom keys" do
      config =
        Config.normalize(
          enabled: true,
          display: 1,
          max_actions: 10
        )

      assert config.enabled? == true
      assert config.display == 1
      assert config.max_actions == 10
      # access is NOT read from the computer_use config — it's derived from the
      # sandbox mode at current/0 (see the derivation describe block below).
    end

    test "reads a map with string keys (TOML shape) and string booleans" do
      config =
        Config.normalize(%{
          "enabled" => "true",
          "screenshot_after" => "false"
        })

      assert config.enabled? == true
      assert config.screenshot_after? == false
    end

    test "an explicit atom-key false on a map is honored, not discarded for the default" do
      config = Config.normalize(%{screenshot_after: false})

      assert config.screenshot_after? == false
    end

    test "an explicit atom-key false on a map keeps enabled? false" do
      config = Config.normalize(%{enabled: false})

      assert config.enabled? == false
    end

    test "a map string-key value resolves when the atom key is absent" do
      config = Config.normalize(%{"display" => 2})

      assert config.display == 2
    end

    test "a lingering removed `mode` key is ignored (host-only; self-heals on save)" do
      assert Config.normalize(mode: :browser) == Config.normalize([])
      assert Config.normalize(%{"mode" => "host"}) == Config.normalize([])
    end
  end

  describe "normalize/1 fail-loud validation" do
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
      Application.put_env(:fermix_core, :computer_use, enabled: true)
      config = Config.current()
      assert config.enabled? == true
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
