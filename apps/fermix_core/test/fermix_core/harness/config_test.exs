defmodule FermixCore.Harness.ConfigTest do
  # Pure module: no processes, no I/O, no global state — readers take an explicit
  # config so nothing touches Application env.
  use ExUnit.Case, async: true

  alias FermixCore.Harness.Config, as: HarnessConfig

  describe "normalize/1" do
    test "nil and empty input normalize to an empty keyword" do
      assert HarnessConfig.normalize(nil) == []
      assert HarnessConfig.normalize(%{}) == []
      assert HarnessConfig.normalize([]) == []
    end

    test "keeps a full valid config from a string-keyed map" do
      normalized =
        HarnessConfig.normalize(%{
          "enabled" => false,
          "default_vendor" => "codex",
          "max_active" => 4,
          "default_timeout_minutes" => 45,
          "inactivity_minutes" => 5,
          "prompt_argv_max_kb" => 100,
          "max_event_bytes" => 2_097_152,
          "max_framing_errors" => 10,
          "max_run_artifact_mb" => 128,
          "artifact_quota_gb" => 10,
          "min_free_gb" => 3,
          "artifact_retention_days" => 14,
          "delivery_max_attempts" => 30,
          "delivery_max_age_hours" => 48,
          "cloud_poll_seconds" => 60,
          "cloud_poll_max_minutes" => 45,
          "codex_home" => "/home/op/.codex",
          "claude_config_dir" => "/home/op/.claude"
        })

      assert Keyword.get(normalized, :enabled) == false
      assert Keyword.get(normalized, :default_vendor) == "codex"
      assert Keyword.get(normalized, :max_active) == 4
      assert Keyword.get(normalized, :default_timeout_minutes) == 45
      assert Keyword.get(normalized, :inactivity_minutes) == 5
      assert Keyword.get(normalized, :prompt_argv_max_kb) == 100
      assert Keyword.get(normalized, :max_event_bytes) == 2_097_152
      assert Keyword.get(normalized, :max_framing_errors) == 10
      assert Keyword.get(normalized, :max_run_artifact_mb) == 128
      assert Keyword.get(normalized, :artifact_quota_gb) == 10
      assert Keyword.get(normalized, :min_free_gb) == 3
      assert Keyword.get(normalized, :artifact_retention_days) == 14
      assert Keyword.get(normalized, :delivery_max_attempts) == 30
      assert Keyword.get(normalized, :delivery_max_age_hours) == 48
      assert Keyword.get(normalized, :cloud_poll_seconds) == 60
      assert Keyword.get(normalized, :cloud_poll_max_minutes) == 45
      assert Keyword.get(normalized, :codex_home) == "/home/op/.codex"
      assert Keyword.get(normalized, :claude_config_dir) == "/home/op/.claude"
    end

    test "keeps a keyword config with atom keys" do
      normalized = HarnessConfig.normalize(enabled: true, max_active: 2)
      assert Enum.sort(normalized) == [enabled: true, max_active: 2]
    end

    test "drops absent keys entirely" do
      normalized = HarnessConfig.normalize(%{"enabled" => true})
      assert normalized == [enabled: true]
      refute Keyword.has_key?(normalized, :default_vendor)
      refute Keyword.has_key?(normalized, :max_active)
    end

    test "approved round-trips a boolean and defaults false when unset" do
      assert HarnessConfig.normalize(approved: true)[:approved] == true
      assert HarnessConfig.normalize(%{"approved" => false})[:approved] == false
      # Absent → dropped, so the reader default (false) applies.
      refute Keyword.has_key?(HarnessConfig.normalize(enabled: true), :approved)
      assert HarnessConfig.approved?(HarnessConfig.normalize(enabled: true)) == false
    end

    test "cloud_enabled round-trips a boolean and defaults false when unset" do
      assert HarnessConfig.normalize(cloud_enabled: true)[:cloud_enabled] == true
      assert HarnessConfig.normalize(%{"cloud_enabled" => false})[:cloud_enabled] == false
      # Absent → dropped, so the reader default (false) applies.
      refute Keyword.has_key?(HarnessConfig.normalize(enabled: true), :cloud_enabled)
      assert HarnessConfig.cloud_enabled?(HarnessConfig.normalize(enabled: true)) == false
    end

    test "default_vendor accepts codex/claude as string or atom" do
      assert HarnessConfig.normalize(default_vendor: "codex")[:default_vendor] == "codex"
      assert HarnessConfig.normalize(default_vendor: "claude")[:default_vendor] == "claude"
      assert HarnessConfig.normalize(default_vendor: :codex)[:default_vendor] == "codex"
      assert HarnessConfig.normalize(default_vendor: :claude)[:default_vendor] == "claude"
    end

    test "blank codex_home/claude_config_dir collapse to nil and are dropped" do
      normalized = HarnessConfig.normalize(%{"codex_home" => "   ", "claude_config_dir" => ""})
      refute Keyword.has_key?(normalized, :codex_home)
      refute Keyword.has_key?(normalized, :claude_config_dir)
    end

    test "max_framing_errors and min_free_gb accept zero (non-negative)" do
      normalized = HarnessConfig.normalize(max_framing_errors: 0, min_free_gb: 0)
      assert Keyword.get(normalized, :max_framing_errors) == 0
      assert Keyword.get(normalized, :min_free_gb) == 0
    end
  end

  describe "normalize/1 fail-loud validation" do
    test "rejects a non-boolean enabled and names the key + value" do
      assert_raise ArgumentError, ~r/harness\.enabled "true"/, fn ->
        HarnessConfig.normalize(enabled: "true")
      end
    end

    test "rejects a non-boolean approved and names the key + value" do
      assert_raise ArgumentError, ~r/harness\.approved "yes"/, fn ->
        HarnessConfig.normalize(approved: "yes")
      end
    end

    test "rejects a non-boolean cloud_enabled and names the key + value" do
      assert_raise ArgumentError, ~r/harness\.cloud_enabled "on"/, fn ->
        HarnessConfig.normalize(cloud_enabled: "on")
      end
    end

    test "rejects an unknown default_vendor" do
      assert_raise ArgumentError, ~r/harness\.default_vendor "gemini"/, fn ->
        HarnessConfig.normalize(default_vendor: "gemini")
      end
    end

    test "rejects a non-positive positive-int key" do
      assert_raise ArgumentError, ~r/harness\.max_active 0.*positive integer/s, fn ->
        HarnessConfig.normalize(max_active: 0)
      end

      assert_raise ArgumentError,
                   ~r/harness\.default_timeout_minutes -1.*positive integer/s,
                   fn ->
                     HarnessConfig.normalize(default_timeout_minutes: -1)
                   end
    end

    test "rejects a non-integer numeric value" do
      assert_raise ArgumentError, ~r/harness\.max_event_bytes/, fn ->
        HarnessConfig.normalize(max_event_bytes: "1048576")
      end

      assert_raise ArgumentError, ~r/harness\.artifact_quota_gb/, fn ->
        HarnessConfig.normalize(artifact_quota_gb: 5.5)
      end
    end

    test "rejects a negative non-negative-int key" do
      assert_raise ArgumentError, ~r/harness\.max_framing_errors -1.*non-negative integer/s, fn ->
        HarnessConfig.normalize(max_framing_errors: -1)
      end

      assert_raise ArgumentError, ~r/harness\.min_free_gb -2.*non-negative integer/s, fn ->
        HarnessConfig.normalize(min_free_gb: -2)
      end
    end

    test "rejects a non-string path" do
      assert_raise ArgumentError, ~r/harness\.codex_home 42.*string path/s, fn ->
        HarnessConfig.normalize(codex_home: 42)
      end
    end
  end

  describe "config_keys/0" do
    test "lists every design §13 key exactly once" do
      keys = HarnessConfig.config_keys()

      assert Enum.sort(keys) ==
               Enum.sort([
                 :enabled,
                 :approved,
                 :cloud_enabled,
                 :default_vendor,
                 :max_active,
                 :default_timeout_minutes,
                 :inactivity_minutes,
                 :prompt_argv_max_kb,
                 :max_event_bytes,
                 :max_framing_errors,
                 :max_run_artifact_mb,
                 :artifact_quota_gb,
                 :min_free_gb,
                 :artifact_retention_days,
                 :delivery_max_attempts,
                 :delivery_max_age_hours,
                 :cloud_poll_seconds,
                 :cloud_poll_max_minutes,
                 :codex_home,
                 :claude_config_dir
               ])

      assert length(keys) == length(Enum.uniq(keys))
    end
  end

  describe "readers apply the design §13 defaults when unset" do
    test "every reader returns its documented default for an empty config" do
      assert HarnessConfig.enabled?([]) == true
      assert HarnessConfig.approved?([]) == false
      assert HarnessConfig.cloud_enabled?([]) == false
      assert HarnessConfig.default_vendor([]) == nil
      assert HarnessConfig.max_active([]) == 2
      assert HarnessConfig.default_timeout_minutes([]) == 30
      assert HarnessConfig.inactivity_minutes([]) == 10
      assert HarnessConfig.prompt_argv_max_kb([]) == 200
      assert HarnessConfig.max_event_bytes([]) == 1_048_576
      assert HarnessConfig.max_framing_errors([]) == 20
      assert HarnessConfig.max_run_artifact_mb([]) == 64
      assert HarnessConfig.artifact_quota_gb([]) == 5
      assert HarnessConfig.min_free_gb([]) == 2
      assert HarnessConfig.artifact_retention_days([]) == 30
      assert HarnessConfig.delivery_max_attempts([]) == 20
      assert HarnessConfig.delivery_max_age_hours([]) == 24
      assert HarnessConfig.cloud_poll_seconds([]) == 120
      assert HarnessConfig.cloud_poll_max_minutes([]) == 90
      assert HarnessConfig.codex_home([]) == nil
      assert HarnessConfig.claude_config_dir([]) == nil
    end

    test "each reader returns the configured value when present" do
      config = HarnessConfig.normalize(enabled: false, max_active: 7, default_vendor: "claude")

      assert HarnessConfig.enabled?(config) == false
      assert HarnessConfig.max_active(config) == 7
      assert HarnessConfig.default_vendor(config) == "claude"
      # Unset keys still fall back to their defaults.
      assert HarnessConfig.cloud_poll_seconds(config) == 120
    end
  end
end
