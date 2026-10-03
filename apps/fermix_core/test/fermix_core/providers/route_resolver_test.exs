defmodule FermixCore.Providers.RouteResolverTest do
  use ExUnit.Case, async: false

  alias FermixCore.Auth.ChatGPT
  alias FermixCore.Providers.Adapter
  alias FermixCore.Providers.Anthropic.Messages, as: AnthropicMessages
  alias FermixCore.Providers.ModelCatalog
  alias FermixCore.Providers.OpenAI.ChatCompletions
  alias FermixCore.Providers.OpenAI.ChatGPTPlan
  alias FermixCore.Providers.OpenAI.Codex
  alias FermixCore.Providers.OpenAI.Responses
  alias FermixCore.Providers.RouteResolver

  # The "sane defaults" cases assert what RouteResolver produces when nothing is
  # configured. RouteResolver reads global app env (Config.provider/1), so a leak
  # from any earlier async:false module (e.g. an anthropic auth_mode = "oauth"
  # config left in :providers) would flip these defaults. Force a clean baseline
  # per test and restore it, so the file is neither a victim nor a source of leaks.
  setup do
    providers = Application.get_env(:fermix_core, :providers, [])
    agent = Application.get_env(:fermix_core, :agent, [])

    Application.put_env(:fermix_core, :providers, [])
    Application.put_env(:fermix_core, :agent, [])

    on_exit(fn ->
      Application.put_env(:fermix_core, :providers, providers)
      Application.put_env(:fermix_core, :agent, agent)
    end)

    :ok
  end

  describe "resolve!/1" do
    test "nil provider falls back to OpenAI Chat Completions when api_key + non-eligible model" do
      {route_key, opts} =
        RouteResolver.resolve!(
          provider: nil,
          model: "babbage-002",
          api_key: "sk-test",
          base_url: "https://api.openai.com/v1",
          auth_mode: :api_key
        )

      assert route_key.provider == :openai
      assert route_key.model == "babbage-002"
      assert opts[:model] == "babbage-002"
      assert opts[:api_key] == "sk-test"
      assert Adapter.for_route(route_key) == ChatCompletions
    end

    test ":openai_codex provider forces oauth and routes to Codex" do
      {route_key, _opts} =
        RouteResolver.resolve!(
          provider: :openai_codex,
          model: "gpt-5",
          base_url: "https://chatgpt.com/backend-api/codex/responses"
        )

      assert route_key.provider == :openai_codex
      assert route_key.auth_mode == :oauth
      assert Adapter.for_route(route_key) == Codex
    end

    test ":openai_codex defaults to gpt-6-astra when no model is configured" do
      {route_key, opts} =
        RouteResolver.resolve!(
          provider: :openai_codex,
          access_token: "tok"
        )

      assert route_key.model == "gpt-6-astra"
      assert opts[:model] == "gpt-6-astra"
    end

    test "caps :max to gpt-5.5's :xhigh ceiling but keeps :max for gpt-5.6-sol" do
      {_key, gpt55} =
        RouteResolver.resolve!(
          provider: :openai_codex,
          model: "gpt-5.5",
          reasoning_effort: :max,
          access_token: "tok"
        )

      assert gpt55[:reasoning_effort] == :xhigh

      {_key, sol} =
        RouteResolver.resolve!(
          provider: :openai_codex,
          model: "gpt-5.6-sol",
          reasoning_effort: :max,
          access_token: "tok"
        )

      assert sol[:reasoning_effort] == :max

      {_key, api} =
        RouteResolver.resolve!(
          provider: :openai,
          model: "gpt-5.5",
          reasoning_effort: :max,
          api_key: "sk-test"
        )

      assert api[:reasoning_effort] == :xhigh
    end

    # The route, Doctor's probe and the published rows read one resolver, so a
    # provider with no chosen model runs on the catalog default everywhere.
    test ":openai with no chosen model routes to the catalog default" do
      Application.put_env(:fermix_core, :providers, openai: [api_key: "sk-test"])

      {route_key, opts} = RouteResolver.resolve!(provider: :openai)

      assert route_key.model == ModelCatalog.default_model_for(:openai)
      assert opts[:model] == ModelCatalog.default_model_for(:openai)
    end

    test ":openai rejects auth_mode :oauth; Codex OAuth is a separate provider" do
      assert_raise ArgumentError, ~r/use provider: :openai_codex/, fn ->
        RouteResolver.resolve!(
          provider: :openai,
          model: "gpt-4o",
          auth_mode: :oauth,
          access_token: "oauth-bearer-token",
          base_url: "https://api.openai.com/v1"
        )
      end
    end

    test "default OpenAI rejects auth_mode :oauth" do
      assert_raise ArgumentError, ~r/use provider: :openai_codex/, fn ->
        RouteResolver.resolve!(
          model: "gpt-4o",
          auth_mode: :oauth,
          access_token: "tok",
          base_url: "https://api.openai.com/v1"
        )
      end
    end

    test ":openai with eligible model on api.openai.com routes to Responses" do
      {route_key, _opts} =
        RouteResolver.resolve!(
          provider: :openai,
          model: "gpt-4o",
          api_key: "sk-test",
          base_url: "https://api.openai.com/v1",
          auth_mode: :api_key
        )

      assert Adapter.for_route(route_key) == Responses
    end

    test ":anthropic produces an Anthropic route_key with sane defaults" do
      {route_key, opts} =
        RouteResolver.resolve!(
          provider: :anthropic,
          api_key: "sk-ant-test"
        )

      assert route_key.provider == :anthropic
      assert route_key.auth_mode == :api_key
      assert route_key.base_url == "https://api.anthropic.com/v1"
      assert is_binary(route_key.model) and route_key.model != ""

      assert opts[:api_key] == "sk-ant-test"
      assert opts[:base_url] == "https://api.anthropic.com/v1"

      assert Adapter.for_route(route_key) == AnthropicMessages
    end

    test ":anthropic respects explicit model and base_url" do
      {route_key, opts} =
        RouteResolver.resolve!(
          provider: :anthropic,
          model: "claude-opus-4-8",
          base_url: "https://anthropic.example/v1"
        )

      assert route_key.model == "claude-opus-4-8"
      assert route_key.base_url == "https://anthropic.example/v1"
      assert opts[:model] == "claude-opus-4-8"
      assert opts[:base_url] == "https://anthropic.example/v1"
    end

    test ":anthropic sources api_key, default_model, and base_url from the provider config block" do
      original_providers = Application.get_env(:fermix_core, :providers, [])

      try do
        Application.put_env(:fermix_core, :providers,
          anthropic: [
            api_key: "sk-ant-config",
            default_model: "claude-haiku-4-5",
            base_url: "https://anthropic-proxy.example/v1"
          ]
        )

        {route_key, opts} = RouteResolver.resolve!(provider: :anthropic)

        assert route_key.model == "claude-haiku-4-5"
        assert route_key.base_url == "https://anthropic-proxy.example/v1"
        assert opts[:api_key] == "sk-ant-config"
        assert opts[:model] == "claude-haiku-4-5"
        assert opts[:base_url] == "https://anthropic-proxy.example/v1"
      after
        Application.put_env(:fermix_core, :providers, original_providers)
      end
    end

    test ":anthropic explicit opts override the provider config block" do
      original_providers = Application.get_env(:fermix_core, :providers, [])

      try do
        Application.put_env(:fermix_core, :providers,
          anthropic: [api_key: "sk-ant-config", default_model: "claude-haiku-4-5"]
        )

        {route_key, opts} =
          RouteResolver.resolve!(
            provider: :anthropic,
            model: "claude-sonnet-4-6",
            api_key: "sk-ant-explicit"
          )

        assert route_key.model == "claude-sonnet-4-6"
        assert opts[:api_key] == "sk-ant-explicit"
      after
        Application.put_env(:fermix_core, :providers, original_providers)
      end
    end

    test ":anthropic auth_mode :oauth produces an oauth route bound to the anthropic_oauth profile" do
      {route_key, opts} = RouteResolver.resolve!(provider: :anthropic, auth_mode: :oauth)

      assert route_key.auth_mode == :oauth
      assert route_key.base_url == "https://api.anthropic.com/v1"
      assert opts[:auth_profile] == "anthropic_oauth"
      assert opts[:token_server] == FermixCore.Auth.TokenSupervisor
      refute Keyword.has_key?(opts, :api_key)
    end

    test ":anthropic auth_mode from the config block selects oauth and drops the configured api_key" do
      original_providers = Application.get_env(:fermix_core, :providers, [])

      try do
        Application.put_env(:fermix_core, :providers,
          anthropic: [auth_mode: "oauth", api_key: "sk-ant-config"]
        )

        {route_key, opts} = RouteResolver.resolve!(provider: :anthropic)

        assert route_key.auth_mode == :oauth
        assert opts[:auth_profile] == "anthropic_oauth"
        refute Keyword.has_key?(opts, :api_key)
      after
        Application.put_env(:fermix_core, :providers, original_providers)
      end
    end

    test ":anthropic explicit access_token flows into the oauth route" do
      {_route_key, opts} =
        RouteResolver.resolve!(provider: :anthropic, auth_mode: :oauth, access_token: "tok")

      assert opts[:access_token] == "tok"
    end

    test ":anthropic api_key mode never carries oauth artifacts (billing-flip guard)" do
      original_providers = Application.get_env(:fermix_core, :providers, [])

      try do
        # No api_key configured at all — the route must NOT degrade into
        # oauth or sneak any credential in from another source.
        Application.put_env(:fermix_core, :providers, anthropic: [auth_mode: "api_key"])

        {route_key, opts} = RouteResolver.resolve!(provider: :anthropic)

        assert route_key.auth_mode == :api_key
        refute Keyword.has_key?(opts, :auth_profile)
        refute Keyword.has_key?(opts, :access_token)
        refute Keyword.has_key?(opts, :token_server)
        refute Keyword.has_key?(opts, :api_key)
      after
        Application.put_env(:fermix_core, :providers, original_providers)
      end
    end

    test ":anthropic rejects an unknown auth_mode" do
      assert_raise ArgumentError, ~r/auth_mode/, fn ->
        RouteResolver.resolve!(provider: :anthropic, auth_mode: :strange)
      end
    end

    test ":xai produces an xAI route_key with sane defaults" do
      {route_key, opts} = RouteResolver.resolve!(provider: :xai, api_key: "xai-key")

      assert route_key.provider == :xai
      assert route_key.auth_mode == :api_key
      assert route_key.base_url == "https://api.x.ai/v1"
      assert is_binary(route_key.model) and route_key.model != ""

      assert opts[:api_key] == "xai-key"
      assert Adapter.for_route(route_key) == FermixCore.Providers.XAI.Responses
    end

    test ":xai sources api_key, default_model, base_url, and effort from the config block" do
      original_providers = Application.get_env(:fermix_core, :providers, [])

      try do
        Application.put_env(:fermix_core, :providers,
          xai: [
            api_key: "xai-config",
            default_model: "grok-code-fast-1",
            base_url: "https://xai-proxy.example/v1",
            reasoning_effort: :high
          ]
        )

        {route_key, opts} = RouteResolver.resolve!(provider: :xai)

        assert route_key.model == "grok-code-fast-1"
        assert route_key.base_url == "https://xai-proxy.example/v1"
        assert opts[:api_key] == "xai-config"
        assert opts[:reasoning_effort] == :high
      after
        Application.put_env(:fermix_core, :providers, original_providers)
      end
    end

    test ":xai auth_mode :oauth produces an oauth route bound to the xai_oauth profile" do
      {route_key, opts} =
        RouteResolver.resolve!(provider: :xai, auth_mode: :oauth, reasoning_effort: :low)

      assert route_key.auth_mode == :oauth
      assert opts[:auth_profile] == "xai_oauth"
      assert opts[:token_server] == FermixCore.Auth.TokenSupervisor
      assert opts[:reasoning_effort] == :low
      refute Keyword.has_key?(opts, :api_key)
    end

    test "openrouter resolves via the generic descriptor resolver" do
      {route_key, opts} =
        RouteResolver.resolve!(provider: :openrouter, api_key: "sk-or-test")

      assert route_key == %{
               provider: :openrouter,
               model: "anthropic/claude-sonnet-4.6",
               auth_mode: :api_key,
               base_url: "https://openrouter.ai/api/v1"
             }

      assert opts[:provider] == :openrouter
      assert opts[:auth] == :api_key
      assert opts[:api_key] == "sk-or-test"
      assert opts[:model] == "anthropic/claude-sonnet-4.6"
      # effort?: false providers never carry a reasoning_effort opt (M12 §5.2).
      refute Keyword.has_key?(opts, :reasoning_effort)
    end

    test "openrouter honors config block model/base_url/api_key" do
      original = Application.get_env(:fermix_core, :providers, [])

      try do
        Application.put_env(:fermix_core, :providers,
          openrouter: [
            api_key: "sk-or-config",
            base_url: "https://proxy.example/api/v1",
            default_model: "z-ai/glm-5.1"
          ]
        )

        {route_key, opts} = RouteResolver.resolve!(provider: :openrouter)

        assert route_key.model == "z-ai/glm-5.1"
        assert route_key.base_url == "https://proxy.example/api/v1"
        assert opts[:api_key] == "sk-or-config"
      after
        Application.put_env(:fermix_core, :providers, original)
      end
    end

    test "ollama resolves keyless with the descriptor timeout default" do
      original = Application.get_env(:fermix_core, :providers, [])

      try do
        Application.put_env(:fermix_core, :providers,
          ollama: [base_url: "http://tail.example:11434/v1"]
        )

        {route_key, opts} = RouteResolver.resolve!(provider: :ollama)

        assert route_key == %{
                 provider: :ollama,
                 model: "qwen3:32b",
                 auth_mode: :none,
                 base_url: "http://tail.example:11434/v1"
               }

        assert opts[:provider] == :ollama
        assert opts[:auth] == :none
        refute Keyword.has_key?(opts, :api_key)
        refute Keyword.has_key?(opts, :reasoning_effort)
        # Descriptor default under explicit req_options (plain Keyword.merge).
        assert opts[:req_options][:receive_timeout] == 300_000

        {_route_key, opts} =
          RouteResolver.resolve!(provider: :ollama, req_options: [receive_timeout: 5_000])

        assert opts[:req_options][:receive_timeout] == 5_000
      after
        Application.put_env(:fermix_core, :providers, original)
      end
    end

    test "unknown provider raises ArgumentError" do
      assert_raise ArgumentError, ~r/no resolver for provider/, fn ->
        RouteResolver.resolve!(provider: :mystery)
      end
    end

    test "switching the configured provider re-resolves the next route (§2.1)" do
      original_agent = Application.get_env(:fermix_core, :agent, [])
      original_providers = Application.get_env(:fermix_core, :providers, [])

      try do
        Application.put_env(:fermix_core, :providers,
          anthropic: [api_key: "sk-ant"],
          xai: [api_key: "xai-key"]
        )

        Application.put_env(:fermix_core, :agent, provider: :anthropic)
        {route_key, _opts} = RouteResolver.resolve!()
        assert route_key.provider == :anthropic
        assert Adapter.for_route(route_key) == AnthropicMessages

        # Setup flips the active provider — the very next resolution must
        # follow, with no stale route or adapter reuse.
        Application.put_env(:fermix_core, :agent, provider: :xai)
        {route_key, opts} = RouteResolver.resolve!()
        assert route_key.provider == :xai
        assert opts[:api_key] == "xai-key"
        assert Adapter.for_route(route_key) == FermixCore.Providers.XAI.Responses
      after
        Application.put_env(:fermix_core, :agent, original_agent)
        Application.put_env(:fermix_core, :providers, original_providers)
      end
    end

    test "configured provider in :fermix_core, :agent is used when opts omit it" do
      original_agent = Application.get_env(:fermix_core, :agent, [])
      original_providers = Application.get_env(:fermix_core, :providers, [])

      try do
        Application.put_env(:fermix_core, :agent, provider: :openai_codex)
        Application.put_env(:fermix_core, :providers, openai: [])

        # Opts omit :provider — must pick up :openai_codex from agent app env.
        {route_key, _opts} =
          RouteResolver.resolve!(model: "gpt-5", access_token: "tok")

        assert route_key.provider == :openai_codex
        assert Adapter.for_route(route_key) == Codex
      after
        Application.put_env(:fermix_core, :agent, original_agent)
        Application.put_env(:fermix_core, :providers, original_providers)
      end
    end

    test "explicit opts :provider overrides configured provider" do
      original_agent = Application.get_env(:fermix_core, :agent, [])
      original_providers = Application.get_env(:fermix_core, :providers, [])

      try do
        Application.put_env(:fermix_core, :agent, provider: :openai_codex)
        Application.put_env(:fermix_core, :providers, openai: [api_key: "sk-test"])

        {route_key, _opts} =
          RouteResolver.resolve!(
            provider: :openai,
            model: "gpt-4o",
            api_key: "sk-test",
            base_url: "https://api.openai.com/v1"
          )

        assert route_key.provider == :openai
        assert Adapter.for_route(route_key) == Responses
      after
        Application.put_env(:fermix_core, :agent, original_agent)
        Application.put_env(:fermix_core, :providers, original_providers)
      end
    end

    test "old c4f02a4 schema location is ignored (provider must live under :agent)" do
      original_agent = Application.get_env(:fermix_core, :agent, [])
      original_providers = Application.get_env(:fermix_core, :providers, [])

      try do
        # Old layout: provider under [:providers, :openai] (the c4f02a4 hotpatch shape).
        # The dispatcher must NOT pick it up from there.
        Application.put_env(:fermix_core, :agent, [])

        Application.put_env(:fermix_core, :providers,
          openai: [provider: :openai_codex, auth_mode: :api_key, api_key: "sk-test"]
        )

        {route_key, _opts} =
          RouteResolver.resolve!(model: "gpt-4o")

        # Falls through to :openai (the default), NOT :openai_codex.
        assert route_key.provider == :openai
      after
        Application.put_env(:fermix_core, :agent, original_agent)
        Application.put_env(:fermix_core, :providers, original_providers)
      end
    end

    test "reasoning_effort from opts overrides the per-provider config block" do
      original_providers = Application.get_env(:fermix_core, :providers, [])

      try do
        Application.put_env(:fermix_core, :providers,
          openai: [auth_mode: :api_key, api_key: "sk-test", reasoning_effort: :low]
        )

        {_route_key, opts} =
          RouteResolver.resolve!(
            provider: :openai,
            model: "gpt-5",
            base_url: "https://api.openai.com/v1",
            reasoning_effort: :high
          )

        assert opts[:reasoning_effort] == :high
      after
        Application.put_env(:fermix_core, :providers, original_providers)
      end
    end

    test "reasoning_effort falls through to the per-provider config block when opts omit it" do
      original_providers = Application.get_env(:fermix_core, :providers, [])

      try do
        Application.put_env(:fermix_core, :providers,
          openai: [auth_mode: :api_key, api_key: "sk-test", reasoning_effort: :medium]
        )

        {_route_key, opts} =
          RouteResolver.resolve!(
            provider: :openai,
            model: "gpt-5",
            base_url: "https://api.openai.com/v1"
          )

        assert opts[:reasoning_effort] == :medium
      after
        Application.put_env(:fermix_core, :providers, original_providers)
      end
    end

    test "reasoning_effort is omitted from adapter_opts when neither opts nor config set it" do
      original_providers = Application.get_env(:fermix_core, :providers, [])

      try do
        Application.put_env(:fermix_core, :providers,
          openai: [auth_mode: :api_key, api_key: "sk-test"]
        )

        {_route_key, opts} =
          RouteResolver.resolve!(
            provider: :openai,
            model: "gpt-5",
            base_url: "https://api.openai.com/v1"
          )

        refute Keyword.has_key?(opts, :reasoning_effort)
      after
        Application.put_env(:fermix_core, :providers, original_providers)
      end
    end

    test "raises ArgumentError when reasoning_effort in config is invalid (boundary validation)" do
      original_providers = Application.get_env(:fermix_core, :providers, [])

      try do
        Application.put_env(:fermix_core, :providers,
          openai: [auth_mode: :api_key, api_key: "sk-test", reasoning_effort: :absurd]
        )

        assert_raise ArgumentError, ~r/invalid reasoning_effort: :absurd/, fn ->
          RouteResolver.resolve!(
            provider: :openai,
            model: "gpt-5",
            base_url: "https://api.openai.com/v1"
          )
        end
      after
        Application.put_env(:fermix_core, :providers, original_providers)
      end
    end

    test "Codex resolver reads reasoning_effort from the openai_codex config block" do
      original_providers = Application.get_env(:fermix_core, :providers, [])

      try do
        Application.put_env(:fermix_core, :providers,
          openai: [],
          openai_codex: [reasoning_effort: :xhigh]
        )

        {_route_key, opts} =
          RouteResolver.resolve!(provider: :openai_codex, model: "gpt-5")

        assert opts[:reasoning_effort] == :xhigh
      after
        Application.put_env(:fermix_core, :providers, original_providers)
      end
    end

    test "Codex resolver reads fast mode from the openai_codex config block" do
      original_providers = Application.get_env(:fermix_core, :providers, [])

      try do
        Application.put_env(:fermix_core, :providers,
          openai: [],
          openai_codex: [fast: true]
        )

        {_route_key, opts} =
          RouteResolver.resolve!(provider: :openai_codex, model: "gpt-5")

        assert opts[:fast] == true
      after
        Application.put_env(:fermix_core, :providers, original_providers)
      end
    end

    test "explicit Codex fast mode overrides the openai_codex config block" do
      original_providers = Application.get_env(:fermix_core, :providers, [])

      try do
        Application.put_env(:fermix_core, :providers,
          openai: [],
          openai_codex: [fast: true]
        )

        {_route_key, opts} =
          RouteResolver.resolve!(provider: :openai_codex, model: "gpt-5", fast: false)

        assert opts[:fast] == false
      after
        Application.put_env(:fermix_core, :providers, original_providers)
      end
    end

    test "Codex resolver does not expose a store override because Codex requires store=false" do
      original_providers = Application.get_env(:fermix_core, :providers, [])

      try do
        Application.put_env(:fermix_core, :providers,
          openai: [],
          openai_codex: [store: true]
        )

        {_route_key, opts} =
          RouteResolver.resolve!(provider: :openai_codex, model: "gpt-5")

        refute Keyword.has_key?(opts, :store)
      after
        Application.put_env(:fermix_core, :providers, original_providers)
      end
    end
  end

  # M57 §4.5/D7: the route asks the sign-in where it stands first, and refuses
  # with the facade's own sentence. The status check is injected so these
  # tests never read an auth store.
  defp signed_in(_opts), do: :ok

  describe "resolve!/1 — chatgpt" do
    test "a usable sign-in routes to ChatGPTPlan through the chatgpt token profile" do
      Application.put_env(:fermix_core, :providers,
        chatgpt: [default_model: "gpt-6.1-sol", reasoning_effort: "high"]
      )

      {route_key, opts} =
        RouteResolver.resolve!(provider: :chatgpt, chatgpt_route_status: &signed_in/1)

      assert route_key == %{
               provider: :chatgpt,
               model: "gpt-6.1-sol",
               auth_mode: :oauth,
               base_url: "https://api.openai.com/v1"
             }

      assert Adapter.for_route(route_key) == ChatGPTPlan
      assert opts[:token_server] == FermixCore.Auth.TokenSupervisor
      assert opts[:auth_profile] == "chatgpt"
      assert opts[:model] == "gpt-6.1-sol"
      assert opts[:reasoning_effort] == "high"
      refute Keyword.has_key?(opts, :api_key)
      refute Keyword.has_key?(opts, :fast)
    end

    test "an explicit model and access token flow into the route" do
      {route_key, opts} =
        RouteResolver.resolve!(
          provider: :chatgpt,
          model: "gpt-6-luna",
          access_token: "plan-token",
          chatgpt_route_status: &signed_in/1
        )

      assert route_key.model == "gpt-6-luna"
      assert opts[:access_token] == "plan-token"
    end

    for reason <- [:not_signed_in, :plan_usage_off, :reconnect_needed] do
      test "#{reason} refuses with the sign-in's own sentence" do
        reason = unquote(reason)
        expected = ChatGPT.failure_sentence(reason)

        error =
          assert_raise ArgumentError, fn ->
            RouteResolver.resolve!(
              provider: :chatgpt,
              model: "gpt-6.1-sol",
              chatgpt_route_status: fn [] -> {:error, reason} end
            )
          end

        assert Exception.message(error) == expected
      end
    end

    test "no chosen model refuses instead of guessing a slug" do
      assert_raise ArgumentError, ~r/No ChatGPT model is chosen yet/, fn ->
        RouteResolver.resolve!(provider: :chatgpt, chatgpt_route_status: &signed_in/1)
      end
    end

    test "the standing is checked before the model, so an unsigned home names the sign-in" do
      error =
        assert_raise ArgumentError, fn ->
          RouteResolver.resolve!(
            provider: :chatgpt,
            chatgpt_route_status: fn [] -> {:error, :not_signed_in} end
          )
        end

      assert Exception.message(error) ==
               ChatGPT.failure_sentence(:not_signed_in)
    end

    test "openai with auth_mode :oauth is still refused" do
      assert_raise ArgumentError, ~r/api_key auth only/, fn ->
        RouteResolver.resolve!(provider: :openai, auth_mode: :oauth)
      end
    end
  end

  describe "primary flag selection" do
    setup do
      providers = Application.get_env(:fermix_core, :providers, [])
      agent = Application.get_env(:fermix_core, :agent, [])

      on_exit(fn ->
        Application.put_env(:fermix_core, :providers, providers)
        Application.put_env(:fermix_core, :agent, agent)
      end)

      :ok
    end

    test "resolve!() honors a provider block primary flag over the legacy agent provider" do
      Application.put_env(:fermix_core, :providers,
        openai: [api_key: "sk-x"],
        anthropic: [primary: true, api_key: "sk-ant"]
      )

      Application.put_env(:fermix_core, :agent, provider: :openai)

      {route_key, _opts} = RouteResolver.resolve!()

      assert route_key.provider == :anthropic
    end

    test "resolve!() fails loud when more than one provider is primary" do
      Application.put_env(:fermix_core, :providers,
        openai: [primary: true, api_key: "sk-x"],
        xai: [primary: true, api_key: "xai-key"]
      )

      Application.put_env(:fermix_core, :agent, [])

      assert_raise ArgumentError, ~r/exactly one provider/, fn ->
        RouteResolver.resolve!()
      end
    end
  end
end
