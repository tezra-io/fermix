defmodule FermixCore.Providers.SelectionTest do
  use ExUnit.Case, async: false

  alias FermixCore.Auth.Store
  alias FermixCore.Providers.Selection

  setup do
    providers = Application.get_env(:fermix_core, :providers, [])
    agent = Application.get_env(:fermix_core, :agent, [])
    fermix_home = System.get_env("FERMIX_HOME")
    tmp_home = FermixTestSupport.SafeRm.make_tmp_dir!("selection")

    System.put_env("FERMIX_HOME", tmp_home)
    Application.put_env(:fermix_core, :agent, [])

    on_exit(fn ->
      Application.put_env(:fermix_core, :providers, providers)
      Application.put_env(:fermix_core, :agent, agent)

      case fermix_home do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end

      FermixTestSupport.SafeRm.rm_rf!(tmp_home)
    end)

    :ok
  end

  describe "ordered_providers/1" do
    test "returns [primary | configured fallbacks] in catalog order" do
      Application.put_env(:fermix_core, :providers,
        openai: [api_key: "sk-x"],
        anthropic: [primary: true, api_key: "sk-ant"],
        xai: [api_key: "xai-key"]
      )

      assert Selection.ordered_providers() == {:ok, [:anthropic, :openai, :xai]}
    end

    test "excludes unconfigured providers from the fallback list" do
      Application.put_env(:fermix_core, :providers,
        openai: [primary: true, api_key: "sk-x"],
        anthropic: [auth_mode: :api_key],
        xai: []
      )

      assert Selection.ordered_providers() == {:ok, [:openai]}
    end

    test "unconfigured primary falls back to configured providers with the primary excluded" do
      Application.put_env(:fermix_core, :providers,
        anthropic: [primary: true],
        openai: [api_key: "sk-x"]
      )

      assert Selection.ordered_providers() == {:ok, [:openai]}
    end

    test "unconfigured primary with no configured fallback keeps the primary" do
      Application.put_env(:fermix_core, :providers, anthropic: [primary: true])

      assert Selection.ordered_providers() == {:ok, [:anthropic]}
    end

    test "multiple primary flags return a tagged error" do
      Application.put_env(:fermix_core, :providers,
        openai: [primary: true, api_key: "sk-x"],
        xai: [primary: true, api_key: "xai-key"]
      )

      assert Selection.ordered_providers() == {:error, :multiple_primary}
    end
  end

  describe "fallback_providers/1" do
    test "returns the configured non-primary providers only" do
      Application.put_env(:fermix_core, :providers,
        openai: [api_key: "sk-x"],
        anthropic: [primary: true, api_key: "sk-ant"]
      )

      assert Selection.fallback_providers() == {:ok, [:openai]}
    end
  end

  describe "ordered_routes/1" do
    test "resolves each provider's own model from its config block, primary first" do
      Application.put_env(:fermix_core, :providers,
        openai: [api_key: "sk-x", default_model: "gpt-5.5"],
        anthropic: [primary: true, api_key: "sk-ant", default_model: "claude-sonnet-4-6"]
      )

      assert {:ok, [{anthropic_key, anthropic_opts}, {openai_key, _openai_opts}]} =
               Selection.ordered_routes()

      assert anthropic_key.provider == :anthropic
      assert anthropic_key.model == "claude-sonnet-4-6"
      assert anthropic_opts[:api_key] == "sk-ant"
      assert openai_key.provider == :openai
      assert openai_key.model == "gpt-5.5"
    end
  end

  describe "configured?/2" do
    test "openai needs an api key" do
      assert Selection.configured?(:openai, api_key: "sk-x")
      refute Selection.configured?(:openai, [])
    end

    test "anthropic api_key mode needs a key; oauth mode needs a stored profile" do
      assert Selection.configured?(:anthropic, api_key: "sk-ant")
      refute Selection.configured?(:anthropic, auth_mode: :oauth, api_key: "sk-ant")

      assert :ok =
               Store.write("anthropic_oauth", %{
                 auth_mode: "setup_token",
                 provider: "anthropic",
                 tokens: %{access_token: "sub-at", refresh_token: nil},
                 expires_at: nil,
                 last_refresh: nil
               })

      assert Selection.configured?(:anthropic, auth_mode: :oauth)
    end

    test "a reauthorization_required oauth profile is not usable" do
      assert :ok =
               Store.write("xai_oauth", %{
                 auth_mode: "oauth_pkce",
                 provider: "xai",
                 tokens: %{access_token: "xai-at", refresh_token: nil},
                 expires_at: nil,
                 last_refresh: nil,
                 status: "reauthorization_required"
               })

      refute Selection.configured?(:xai, auth_mode: :oauth)
    end

    test "openai_codex needs a stored codex profile" do
      refute Selection.configured?(:openai_codex, [])

      assert :ok =
               Store.write(:openai_codex, %{
                 auth_mode: "chatgpt",
                 tokens: %{access_token: "codex-at", refresh_token: "codex-rt"},
                 expires_at: DateTime.utc_now() |> DateTime.add(3600),
                 last_refresh: nil
               })

      assert Selection.configured?(:openai_codex, [])
    end

    test "an invalid auth_mode is not configured" do
      refute Selection.configured?(:xai, auth_mode: "oauthh", api_key: "xai-x")
    end
  end
end
