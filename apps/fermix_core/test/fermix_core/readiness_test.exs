defmodule FermixCore.ReadinessTest do
  use ExUnit.Case, async: false

  alias FermixCore.Auth.Store
  alias FermixCore.Readiness

  setup do
    providers = Application.get_env(:fermix_core, :providers, [])
    personalization = Application.get_env(:fermix_core, :personalization, [])
    agent = Application.get_env(:fermix_core, :agent, [])
    realtime = Application.get_env(:fermix_core, :realtime, [])
    telegram = Application.get_env(:fermix_channels, :telegram, [])
    fermix_home = System.get_env("FERMIX_HOME")

    on_exit(fn ->
      Application.put_env(:fermix_core, :providers, providers)
      Application.put_env(:fermix_core, :personalization, personalization)
      Application.put_env(:fermix_core, :agent, agent)
      Application.put_env(:fermix_core, :realtime, realtime)
      Application.put_env(:fermix_channels, :telegram, telegram)

      case fermix_home do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end
    end)

    :ok
  end

  describe "personalization_failure/0" do
    test "returns failure when any personalization key is blank" do
      Application.put_env(:fermix_core, :personalization,
        user_name: "Sujeeth",
        timezone: "Asia/Singapore",
        communication_style: nil
      )

      assert %{component: "personalization", action: action} = Readiness.personalization_failure()
      assert action =~ "mix fermix.setup"
    end

    test "returns failure when personalization is empty" do
      Application.put_env(:fermix_core, :personalization, [])
      assert %{component: "personalization"} = Readiness.personalization_failure()
    end

    test "treats whitespace-only strings as blank" do
      Application.put_env(:fermix_core, :personalization,
        user_name: "Sujeeth",
        timezone: "",
        communication_style: "blunt"
      )

      assert %{component: "personalization"} = Readiness.personalization_failure()
    end

    test "returns nil when all three keys are populated" do
      Application.put_env(:fermix_core, :personalization,
        user_name: "Sujeeth",
        timezone: "Asia/Singapore",
        communication_style: "blunt"
      )

      assert is_nil(Readiness.personalization_failure())
    end
  end

  describe "primary/fallback reporting" do
    setup do
      tmp_home =
        Path.join(System.tmp_dir!(), "fermix-readiness-#{System.unique_integer([:positive])}")

      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
      System.put_env("FERMIX_HOME", tmp_home)

      Application.put_env(:fermix_core, :personalization,
        user_name: "Sujeeth",
        timezone: "America/New_York",
        communication_style: "direct"
      )

      Application.put_env(:fermix_channels, :telegram, enabled: false)
      Application.put_env(:fermix_core, :agent, name: "fermix")
      :ok
    end

    test "a primary flag drives the readiness provider check" do
      Application.put_env(:fermix_core, :providers, anthropic: [primary: true])

      report = Readiness.report()

      assert Enum.any?(report.failures, &(&1.component == "provider:anthropic"))
    end

    test "an unconfigured primary names the configured fallbacks that serve meanwhile" do
      Application.put_env(:fermix_core, :providers,
        anthropic: [primary: true],
        openai: [api_key: "sk-x"]
      )

      report = Readiness.report()

      assert Enum.any?(report.failures, fn failure ->
               failure.component == "provider:anthropic" and
                 failure.action =~ "fallback providers (openai)"
             end)
    end

    # M12 §2.3-2: an unknown configured provider used to be silently
    # coerced to :openai; it is now a visible setup failure.
    test "an unknown legacy agent provider is a visible failure, never coerced" do
      Application.put_env(:fermix_core, :providers, [])
      Application.put_env(:fermix_core, :agent, provider: :bogus_provider)

      report = Readiness.report()

      assert Enum.any?(report.failures, fn failure ->
               failure.component == "provider:config" and
                 failure.action =~ "Unknown provider :bogus_provider"
             end)
    end

    test "multiple primary flags are a configuration error, never silently resolved" do
      Application.put_env(:fermix_core, :providers,
        anthropic: [primary: true, api_key: "sk-ant"],
        openai: [primary: true, api_key: "sk-x"]
      )

      report = Readiness.report()

      assert Enum.any?(report.failures, fn failure ->
               failure.component == "provider:config" and
                 failure.action =~ "exactly one provider primary"
             end)
    end
  end

  describe "report/0" do
    test "includes personalization failure alongside other failures" do
      Application.put_env(:fermix_core, :personalization, [])

      report = Readiness.report()

      assert report.status == :setup_required
      assert Enum.any?(report.failures, &(&1.component == "personalization"))
    end

    test "openai_codex readiness uses Codex auth and does not require an OpenAI API key" do
      tmp_home =
        Path.join(System.tmp_dir!(), "fermix-readiness-#{System.unique_integer([:positive])}")

      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
      System.put_env("FERMIX_HOME", tmp_home)

      Application.put_env(:fermix_core, :providers, openai: [], openai_codex: [])
      Application.put_env(:fermix_core, :agent, name: "fermix", provider: :openai_codex)

      Application.put_env(:fermix_core, :personalization,
        user_name: "Sujeeth",
        timezone: "America/New_York",
        communication_style: "direct"
      )

      Application.put_env(:fermix_channels, :telegram, enabled: false)

      assert :ok =
               Store.write(:openai_codex, %{
                 auth_mode: "chatgpt",
                 tokens: %{access_token: "codex-at", refresh_token: "codex-rt"},
                 expires_at: DateTime.utc_now() |> DateTime.add(3600),
                 last_refresh: nil
               })

      report = Readiness.report()

      refute Enum.any?(report.failures, &(&1.component == "provider:openai"))
      refute Enum.any?(report.failures, &(&1.component == "provider:openai_codex"))
    end

    test "anthropic oauth readiness requires a stored anthropic_oauth profile" do
      tmp_home =
        Path.join(System.tmp_dir!(), "fermix-readiness-#{System.unique_integer([:positive])}")

      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
      System.put_env("FERMIX_HOME", tmp_home)

      Application.put_env(:fermix_core, :providers, anthropic: [auth_mode: "oauth"])
      Application.put_env(:fermix_core, :agent, name: "fermix", provider: :anthropic)

      Application.put_env(:fermix_core, :personalization,
        user_name: "Sujeeth",
        timezone: "America/New_York",
        communication_style: "direct"
      )

      Application.put_env(:fermix_channels, :telegram, enabled: false)

      report = Readiness.report()

      assert Enum.any?(report.failures, fn failure ->
               failure.component == "provider:anthropic" and
                 failure.action =~ "fermix auth login --provider anthropic"
             end)

      assert :ok =
               Store.write("anthropic_oauth", %{
                 auth_mode: "setup_token",
                 provider: "anthropic",
                 tokens: %{access_token: "sub-at", refresh_token: nil},
                 expires_at: nil,
                 last_refresh: nil
               })

      report = Readiness.report()
      refute Enum.any?(report.failures, &(&1.component == "provider:anthropic"))
    end

    test "anthropic invalid auth_mode is reported, not treated as api-key-ready" do
      tmp_home =
        Path.join(System.tmp_dir!(), "fermix-readiness-#{System.unique_integer([:positive])}")

      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
      System.put_env("FERMIX_HOME", tmp_home)

      # A typo'd auth_mode with an api_key present must NOT report ready —
      # RouteResolver.parse_auth_mode!/2 raises on it at the first turn.
      Application.put_env(:fermix_core, :providers,
        anthropic: [auth_mode: "oauthh", api_key: "sk-ant-x"]
      )

      Application.put_env(:fermix_core, :agent, name: "fermix", provider: :anthropic)
      Application.put_env(:fermix_channels, :telegram, enabled: false)

      report = Readiness.report()

      assert Enum.any?(report.failures, fn failure ->
               failure.component == "provider:anthropic" and failure.action =~ "Invalid auth_mode"
             end)
    end

    test "xai invalid auth_mode is reported, not treated as api-key-ready" do
      tmp_home =
        Path.join(System.tmp_dir!(), "fermix-readiness-#{System.unique_integer([:positive])}")

      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
      System.put_env("FERMIX_HOME", tmp_home)

      Application.put_env(:fermix_core, :providers, xai: [auth_mode: "oauthh", api_key: "xai-x"])
      Application.put_env(:fermix_core, :agent, name: "fermix", provider: :xai)
      Application.put_env(:fermix_channels, :telegram, enabled: false)

      report = Readiness.report()

      assert Enum.any?(report.failures, fn failure ->
               failure.component == "provider:xai" and failure.action =~ "Invalid auth_mode"
             end)
    end

    test "xai oauth readiness requires a stored xai_oauth profile" do
      tmp_home =
        Path.join(System.tmp_dir!(), "fermix-readiness-#{System.unique_integer([:positive])}")

      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
      System.put_env("FERMIX_HOME", tmp_home)

      Application.put_env(:fermix_core, :providers, xai: [auth_mode: "oauth"])
      Application.put_env(:fermix_core, :agent, name: "fermix", provider: :xai)

      Application.put_env(:fermix_core, :personalization,
        user_name: "Sujeeth",
        timezone: "America/New_York",
        communication_style: "direct"
      )

      Application.put_env(:fermix_channels, :telegram, enabled: false)

      report = Readiness.report()

      assert Enum.any?(report.failures, fn failure ->
               failure.component == "provider:xai" and
                 failure.action =~ "fermix auth login --provider xai"
             end)

      assert :ok =
               Store.write("xai_oauth", %{
                 auth_mode: "oauth_pkce",
                 provider: "xai",
                 tokens: %{access_token: "xai-at", refresh_token: "xai-rt"},
                 expires_at: nil,
                 last_refresh: nil
               })

      report = Readiness.report()
      refute Enum.any?(report.failures, &(&1.component == "provider:xai"))

      # A quarantined profile is NOT ready, even with a token present.
      assert :ok =
               Store.write("xai_oauth", %{
                 auth_mode: "oauth_pkce",
                 provider: "xai",
                 tokens: %{access_token: "xai-at", refresh_token: "xai-rt"},
                 expires_at: nil,
                 last_refresh: nil,
                 status: "reauthorization_required"
               })

      report = Readiness.report()

      assert Enum.any?(report.failures, fn failure ->
               failure.component == "provider:xai" and
                 failure.action =~ "fermix auth login --provider xai"
             end)
    end

    test "xai readiness keys on the api key" do
      Application.put_env(:fermix_core, :providers, xai: [])
      Application.put_env(:fermix_core, :agent, name: "fermix", provider: :xai)

      Application.put_env(:fermix_core, :personalization,
        user_name: "Sujeeth",
        timezone: "America/New_York",
        communication_style: "direct"
      )

      Application.put_env(:fermix_channels, :telegram, enabled: false)

      report = Readiness.report()

      assert Enum.any?(report.failures, fn failure ->
               failure.component == "provider:xai" and failure.action =~ "XAI_API_KEY"
             end)

      Application.put_env(:fermix_core, :providers, xai: [api_key: "xai-key"])
      report = Readiness.report()
      refute Enum.any?(report.failures, &(&1.component == "provider:xai"))
    end

    test "anthropic api_key mode still keys readiness on the api key" do
      Application.put_env(:fermix_core, :providers, anthropic: [])
      Application.put_env(:fermix_core, :agent, name: "fermix", provider: :anthropic)

      Application.put_env(:fermix_core, :personalization,
        user_name: "Sujeeth",
        timezone: "America/New_York",
        communication_style: "direct"
      )

      Application.put_env(:fermix_channels, :telegram, enabled: false)

      report = Readiness.report()

      assert Enum.any?(report.failures, fn failure ->
               failure.component == "provider:anthropic" and
                 failure.action =~ "ANTHROPIC_API_KEY"
             end)
    end

    test "openai provider auth does not satisfy openai_codex readiness" do
      tmp_home =
        Path.join(System.tmp_dir!(), "fermix-readiness-#{System.unique_integer([:positive])}")

      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
      System.put_env("FERMIX_HOME", tmp_home)

      Application.put_env(:fermix_core, :providers, openai: [], openai_codex: [])
      Application.put_env(:fermix_core, :agent, name: "fermix", provider: :openai_codex)

      Application.put_env(:fermix_core, :personalization,
        user_name: "Sujeeth",
        timezone: "America/New_York",
        communication_style: "direct"
      )

      Application.put_env(:fermix_channels, :telegram, enabled: false)

      assert :ok =
               Store.write(:openai, %{
                 auth_mode: "chatgpt",
                 tokens: %{access_token: "stale-openai-at", refresh_token: "stale-openai-rt"},
                 expires_at: DateTime.utc_now() |> DateTime.add(3600),
                 last_refresh: nil
               })

      report = Readiness.report()

      assert Enum.any?(report.failures, &(&1.component == "provider:openai_codex"))
    end

    test "disabled realtime does not add a readiness failure" do
      Application.put_env(:fermix_core, :providers, openai: [])
      Application.put_env(:fermix_core, :agent, name: "fermix", provider: :openai)
      Application.put_env(:fermix_core, :realtime, enabled: false)

      Application.put_env(:fermix_core, :personalization,
        user_name: "Sujeeth",
        timezone: "America/New_York",
        communication_style: "direct"
      )

      Application.put_env(:fermix_channels, :telegram, enabled: false)

      report = Readiness.report()

      refute Enum.any?(report.failures, &(&1.component == "realtime:openai"))
    end

    test "enabled realtime requires regular OpenAI API key even when chat provider is openai_codex" do
      tmp_home =
        Path.join(System.tmp_dir!(), "fermix-readiness-#{System.unique_integer([:positive])}")

      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
      System.put_env("FERMIX_HOME", tmp_home)

      Application.put_env(:fermix_core, :providers, openai: [], openai_codex: [])
      Application.put_env(:fermix_core, :agent, name: "fermix", provider: :openai_codex)
      Application.put_env(:fermix_core, :realtime, enabled: true, provider: "openai")

      Application.put_env(:fermix_core, :personalization,
        user_name: "Sujeeth",
        timezone: "America/New_York",
        communication_style: "direct"
      )

      Application.put_env(:fermix_channels, :telegram, enabled: false)

      assert :ok =
               Store.write(:openai_codex, %{
                 auth_mode: "chatgpt",
                 tokens: %{access_token: "codex-at", refresh_token: "codex-rt"},
                 expires_at: DateTime.utc_now() |> DateTime.add(3600),
                 last_refresh: nil
               })

      report = Readiness.report()

      assert Enum.any?(report.failures, fn failure ->
               failure.component == "realtime:openai" and failure.action =~ "OPENAI_API_KEY"
             end)
    end
  end
end
