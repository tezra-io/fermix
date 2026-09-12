defmodule FermixCore.ComputerHistory.ConfigTest do
  @moduledoc "MILESTONE_32 §9.4 — config normalization + accessors."
  use ExUnit.Case, async: false

  alias FermixCore.ComputerHistory.Config

  setup do
    original = Application.get_env(:fermix_core, :computer_history)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:fermix_core, :computer_history)
        value -> Application.put_env(:fermix_core, :computer_history, value)
      end
    end)

    :ok
  end

  defp configure(kw), do: Application.put_env(:fermix_core, :computer_history, kw)

  describe "defaults (key absent)" do
    test "everything is off / empty; summarizer defaults to the default provider" do
      Application.delete_env(:fermix_core, :computer_history)

      refute Config.enabled?()
      assert Config.apps() == []
      assert Config.sites() == []
      assert Config.remote_summaries() == []
      assert Config.granted_providers() == MapSet.new()
      # §22.1 — default summarization runs on the configured default provider,
      # not on-device (which is DOA without a local model).
      assert Config.summarizer() == :default_provider
    end
  end

  describe "accessors read normalized app env" do
    test "enabled/allowlists/tier/summarizer" do
      configure(
        enabled: true,
        apps: ["com.apple.Safari"],
        sites: ["github.com"],
        remote_summaries: [:anthropic],
        summarizer: :anthropic
      )

      assert Config.enabled?()
      assert Config.apps() == ["com.apple.Safari"]
      assert Config.sites() == ["github.com"]
      assert Config.granted_providers() == MapSet.new([:anthropic])
      assert Config.summarizer() == {:provider, :anthropic}
    end

    test "summarizer :local parses to :local" do
      configure(summarizer: :local)
      assert Config.summarizer() == :local
    end
  end

  describe "default summarizer provider/model (§22.1 — the subagent tier)" do
    setup do
      prev_p = Application.get_env(:fermix_core, :providers)
      prev_r = Application.get_env(:fermix_core, :routing)

      Application.put_env(:fermix_core, :providers,
        openai: [primary: true, default_model: "gpt-5.4"],
        anthropic: [primary: false, default_model: "claude-opus-4-8"]
      )

      on_exit(fn ->
        restore(:providers, prev_p)
        restore(:routing, prev_r)
      end)

      :ok
    end

    defp restore(key, nil), do: Application.delete_env(:fermix_core, key)
    defp restore(key, value), do: Application.put_env(:fermix_core, key, value)

    test "no subagent config → the primary provider, no model override" do
      Application.put_env(:fermix_core, :routing, [])
      assert Config.default_summarizer_provider() == {:ok, :openai}
      assert Config.default_summarizer_route_opts() == []
    end

    test "a subagent model (no provider) → primary provider + that model" do
      Application.put_env(:fermix_core, :routing, subagent_model: "gpt-5.4-mini")
      assert Config.default_summarizer_provider() == {:ok, :openai}
      assert Config.default_summarizer_route_opts() == [model: "gpt-5.4-mini"]
    end

    test "a subagent provider + model → that provider + model" do
      Application.put_env(:fermix_core, :routing,
        subagent_provider: "anthropic",
        subagent_model: "claude-haiku-4-5"
      )

      assert Config.default_summarizer_provider() == {:ok, :anthropic}
      assert Config.default_summarizer_route_opts() == [model: "claude-haiku-4-5"]
    end
  end

  describe "normalize/1 — present keys only, values validated" do
    test "accepts a valid TOML-shaped map and coerces provider strings to atoms" do
      normalized =
        Config.normalize(%{
          "enabled" => true,
          "apps" => ["com.apple.Safari"],
          "sites" => ["github.com"],
          "remote_summaries" => ["anthropic"],
          "summarizer" => "anthropic"
        })

      assert Keyword.get(normalized, :enabled) == true
      assert Keyword.get(normalized, :apps) == ["com.apple.Safari"]
      assert Keyword.get(normalized, :remote_summaries) == [:anthropic]
      assert Keyword.get(normalized, :summarizer) == :anthropic
    end

    test "\"local\" summarizer normalizes to :local" do
      assert Config.normalize(%{"summarizer" => "local"}) == [summarizer: :local]
    end

    test "nil and empty produce empty config" do
      assert Config.normalize(nil) == []
      assert Config.normalize(%{}) == []
    end

    test "omits absent keys (no defaults injected)" do
      normalized = Config.normalize(%{"enabled" => true})
      assert normalized == [enabled: true]
      refute Keyword.has_key?(normalized, :apps)
    end
  end

  describe "to_keyword/1 — normalized env atoms back to TOML spellings (the persist half)" do
    test "maps every summarizer shape to its config vocabulary" do
      assert Config.to_keyword(summarizer: :default_provider) == [summarizer: "default"]
      assert Config.to_keyword(summarizer: :local) == [summarizer: "local"]
      assert Config.to_keyword(summarizer: :anthropic) == [summarizer: "anthropic"]
    end

    test "maps remote_summaries atoms to strings; passes bools and string lists through" do
      assert Config.to_keyword(
               enabled: true,
               apps: ["com.apple.Safari"],
               sites: [],
               remote_summaries: [:anthropic],
               summarizer: :default_provider
             ) == [
               enabled: true,
               apps: ["com.apple.Safari"],
               sites: [],
               remote_summaries: ["anthropic"],
               summarizer: "default"
             ]
    end

    test "present keys only" do
      assert Config.to_keyword([]) == []
      assert Config.to_keyword(enabled: false) == [enabled: false]
    end
  end

  describe "normalize/1 is idempotent over its own output (apply re-normalizes both shapes)" do
    test "atom summarizer shapes and atom remote_summaries survive a second pass" do
      normalized =
        Config.normalize(%{
          "enabled" => true,
          "remote_summaries" => ["anthropic"],
          "summarizer" => "default"
        })

      assert Config.normalize(normalized) == normalized

      tier3 = Config.normalize(%{"summarizer" => "anthropic"})
      assert Config.normalize(tier3) == tier3
    end

    test "normalize accepts its own to_keyword output (the full save→apply loop)" do
      normalized =
        Config.normalize(%{
          "enabled" => true,
          "apps" => ["com.apple.Safari"],
          "remote_summaries" => ["anthropic"],
          "summarizer" => "default"
        })

      assert normalized |> Config.to_keyword() |> Config.normalize() == normalized
    end
  end

  describe "normalize/1 — fail loud on invalid values" do
    test "non-boolean enabled" do
      assert_raise ArgumentError, ~r/computer_history.enabled/, fn ->
        Config.normalize(%{"enabled" => "yes"})
      end
    end

    test "unknown provider in remote_summaries" do
      assert_raise ArgumentError, ~r/unknown provider/, fn ->
        Config.normalize(%{"remote_summaries" => ["not_a_provider"]})
      end
    end

    test "a local provider in remote_summaries (a no-op grant that hides a mistake)" do
      assert_raise ArgumentError, ~r/expected a remote provider/, fn ->
        Config.normalize(%{"remote_summaries" => ["ollama"]})
      end
    end

    test ~s(unknown summarizer names the FULL vocabulary — "default" and "local" included) do
      # The refusal is what a user with a typo'd (or legacy-poisoned) config sees;
      # a message listing only provider ids omits the two most likely fixes.
      assert_raise ArgumentError, ~r/expected "default", "local", or one of/, fn ->
        Config.normalize(%{"summarizer" => "not_a_provider"})
      end

      assert_raise ArgumentError, ~r/expected "default", "local", or one of/, fn ->
        Config.normalize(%{"summarizer" => "default_provider"})
      end
    end

    test "non-string allowlist entry" do
      assert_raise ArgumentError, ~r/computer_history.apps/, fn ->
        Config.normalize(%{"apps" => [123]})
      end
    end

    test "an empty-string allowlist entry" do
      assert_raise ArgumentError, ~r/computer_history.sites/, fn ->
        Config.normalize(%{"sites" => [""]})
      end
    end
  end

  describe "accessors fail closed on a malformed app-env value (hot-path defense)" do
    test "a non-atom summarizer value defaults to :local (stays on-device)" do
      # A value that somehow bypassed normalize/1 — the Gate snapshot must not
      # crash the turn; it fails closed to on-device summarization.
      configure(summarizer: "anthropic")
      assert Config.summarizer() == :local
    end

    test "a non-list remote_summaries yields an empty grant set" do
      configure(remote_summaries: "anthropic")
      assert Config.granted_providers() == MapSet.new()
    end
  end

  test "config_keys/0 is the canonical allowlist" do
    assert Config.config_keys() == [:enabled, :apps, :sites, :remote_summaries, :summarizer]
  end

  describe "timezone/0,1 (the one resolver both surfaces use)" do
    setup do
      original = Application.get_env(:fermix_core, :personalization)

      on_exit(fn ->
        case original do
          nil -> Application.delete_env(:fermix_core, :personalization)
          value -> Application.put_env(:fermix_core, :personalization, value)
        end
      end)

      :ok
    end

    test "an unset personalization timezone is UTC" do
      Application.delete_env(:fermix_core, :personalization)
      assert Config.timezone() == "Etc/UTC"
    end

    test "a configured zone is returned; an unusable one falls back to UTC" do
      Application.put_env(:fermix_core, :personalization, timezone: "America/New_York")
      assert Config.timezone() == "America/New_York"

      Application.put_env(:fermix_core, :personalization, timezone: "America/New York")
      assert Config.timezone() == "Etc/UTC"
    end

    test "a nil or blank :timezone opt behaves as absent, never a raise" do
      Application.put_env(:fermix_core, :personalization, timezone: "America/New_York")

      assert Config.timezone(timezone: nil) == "America/New_York"
      assert Config.timezone(timezone: "") == "America/New_York"
      assert Config.timezone(timezone: :not_a_zone) == "America/New_York"
      assert Config.timezone([]) == "America/New_York"

      Application.delete_env(:fermix_core, :personalization)
      assert Config.timezone(timezone: nil) == "Etc/UTC"
      assert Config.timezone(timezone: "") == "Etc/UTC"
    end

    test "a given zone wins over the configured one" do
      Application.put_env(:fermix_core, :personalization, timezone: "America/New_York")
      assert Config.timezone(timezone: "Europe/Berlin") == "Europe/Berlin"
    end
  end
end
