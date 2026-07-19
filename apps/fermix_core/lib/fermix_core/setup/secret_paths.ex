defmodule FermixCore.Setup.SecretPaths do
  @moduledoc """
  Canonical registry for setup-managed secret fields.
  """

  @type secret :: %{
          :key => atom(),
          :env => String.t(),
          :path => [atom() | String.t()],
          optional(:functionality) => String.t(),
          optional(:optional?) => boolean(),
          optional(:sandbox_env) => boolean(),
          optional(:plugin) => String.t()
        }

  @secrets [
    %{
      key: :openai_api_key,
      env: "OPENAI_API_KEY",
      path: [:fermix_core, :providers, :openai, :api_key],
      sandbox_env: true
    },
    %{
      key: :anthropic_api_key,
      env: "ANTHROPIC_API_KEY",
      path: [:fermix_core, :providers, :anthropic, :api_key],
      sandbox_env: true
    },
    %{
      key: :xai_api_key,
      env: "XAI_API_KEY",
      path: [:fermix_core, :providers, :xai, :api_key],
      sandbox_env: true
    },
    %{
      key: :openrouter_api_key,
      env: "OPENROUTER_API_KEY",
      path: [:fermix_core, :providers, :openrouter, :api_key],
      sandbox_env: true
    },
    %{
      key: :mistral_api_key,
      env: "MISTRAL_API_KEY",
      path: [:fermix_core, :providers, :mistral, :api_key],
      sandbox_env: true
    },
    %{
      key: :tavily_api_key,
      env: "TAVILY_API_KEY",
      path: [:fermix_core, :tools, :web_search, :tavily_api_key],
      functionality: "Tavily web_search backend",
      optional?: true,
      sandbox_env: true
    },
    %{
      key: :exa_api_key,
      env: "EXA_API_KEY",
      path: [:fermix_core, :tools, :web_search, :exa_api_key],
      functionality: "Exa web_search backend",
      optional?: true,
      sandbox_env: true
    },
    %{
      key: :parallel_api_key,
      env: "PARALLEL_API_KEY",
      path: [:fermix_core, :tools, :web_search, :parallel_api_key],
      functionality: "Parallel web_search backend",
      optional?: true,
      sandbox_env: true
    },
    %{
      key: :brave_api_key,
      env: "BRAVE_API_KEY",
      path: [:fermix_core, :tools, :web_search, :brave_api_key],
      functionality: "Brave web_search backend",
      optional?: true,
      sandbox_env: true
    },
    %{
      key: :perplexity_api_key,
      env: "PERPLEXITY_API_KEY",
      path: [:fermix_core, :tools, :web_search, :perplexity_api_key],
      functionality: "Perplexity web_search backend",
      optional?: true,
      sandbox_env: true
    },
    %{
      key: :firecrawl_api_key,
      env: "FIRECRAWL_API_KEY",
      path: [:fermix_core, :tools, :web_search, :firecrawl_api_key],
      functionality: "Firecrawl web_search backend",
      optional?: true,
      sandbox_env: true
    },
    %{
      key: :google_api_key,
      env: "GEMINI_API_KEY",
      path: [:fermix_core, :tools, :generate_image, :google_api_key],
      functionality: "Google (Gemini) generate_image backend",
      optional?: true,
      # BEAM-internal HTTP (no subprocess), so it is not exposed via [sandbox.env].
      sandbox_env: false
    },
    %{
      key: :transcription_openai_api_key,
      env: "TRANSCRIPTION_OPENAI_API_KEY",
      path: [:fermix_core, :transcription, :openai_api_key],
      functionality: "OpenAI transcription backend (override for the chat key)",
      optional?: true,
      # BEAM-internal HTTP (no subprocess), so it is not exposed via [sandbox.env].
      sandbox_env: false
    },
    %{
      key: :transcription_xai_api_key,
      env: "TRANSCRIPTION_XAI_API_KEY",
      path: [:fermix_core, :transcription, :xai_api_key],
      functionality: "SpaceXAI transcription backend (override for the chat key)",
      optional?: true,
      # BEAM-internal HTTP (no subprocess), so it is not exposed via [sandbox.env].
      sandbox_env: false
    },
    %{
      key: :deepgram_api_key,
      env: "DEEPGRAM_API_KEY",
      path: [:fermix_core, :transcription, :deepgram_api_key],
      functionality: "Deepgram transcription backend",
      optional?: true,
      # BEAM-internal HTTP (no subprocess), so it is not exposed via [sandbox.env].
      sandbox_env: false
    },
    %{
      key: :google_oauth_client_secret,
      env: "GOOGLE_OAUTH_CLIENT_SECRET",
      path: [:fermix_core, :oauth, "google", :client_secret]
    },
    %{
      key: :github_oauth_client_secret,
      env: "GITHUB_OAUTH_CLIENT_SECRET",
      path: [:fermix_core, :oauth, "github", :client_secret]
    },
    %{
      key: :notion_oauth_client_secret,
      env: "NOTION_OAUTH_CLIENT_SECRET",
      path: [:fermix_core, :oauth, "notion", :client_secret]
    },
    %{
      key: :x_oauth_client_secret,
      env: "X_OAUTH_CLIENT_SECRET",
      path: [:fermix_core, :oauth, "x", :client_secret]
    },
    %{
      key: :slack_oauth_client_secret,
      env: "SLACK_OAUTH_CLIENT_SECRET",
      path: [:fermix_core, :oauth, "slack", :client_secret]
    },
    %{
      key: :telegram_bot_token,
      env: "TELEGRAM_BOT_TOKEN",
      path: [:fermix_channels, :telegram, :bot_token]
    },
    %{
      key: :whatsapp_access_token,
      env: "WHATSAPP_ACCESS_TOKEN",
      path: [:fermix_channels, :whatsapp, :access_token]
    },
    %{
      key: :whatsapp_verify_token,
      env: "WHATSAPP_VERIFY_TOKEN",
      path: [:fermix_channels, :whatsapp, :verify_token]
    },
    %{
      key: :whatsapp_app_secret,
      env: "WHATSAPP_APP_SECRET",
      path: [:fermix_channels, :whatsapp, :app_secret]
    },
    %{
      key: :discord_bot_token,
      env: "DISCORD_BOT_TOKEN",
      path: [:fermix_channels, :discord, :bot_token]
    },
    %{
      key: :slack_bot_token,
      env: "SLACK_BOT_TOKEN",
      path: [:fermix_channels, :slack, :bot_token]
    },
    %{
      key: :slack_signing_secret,
      env: "SLACK_SIGNING_SECRET",
      path: [:fermix_channels, :slack, :signing_secret]
    },
    # api_key-plugin secrets (M16): the static credential an `auth: api_key`
    # plugin authenticates with (e.g. a Discord bot token). Plugin-namespaced
    # env + a per-plugin config path so they never collide with the channel
    # tokens above (e.g. the channel `DISCORD_BOT_TOKEN`). `optional?` so a
    # locked/missing keychain warns and surfaces `:needs_secret` rather than
    # crashing boot for one plugin. The `plugin` tag maps a plugin name to its
    # secret entry (`fetch_plugin/1`).
    %{
      key: :discord_plugin_secret,
      env: "FERMIX_PLUGIN_DISCORD",
      path: [:fermix_core, :plugin_secrets, "discord"],
      plugin: "discord",
      functionality: "Discord plugin",
      optional?: true
    },
    %{
      key: :agentmail_plugin_secret,
      env: "FERMIX_PLUGIN_AGENTMAIL",
      path: [:fermix_core, :plugin_secrets, "agentmail"],
      plugin: "agentmail",
      functionality: "AgentMail plugin",
      optional?: true
    },
    %{
      key: :slack_plugin_secret,
      env: "FERMIX_PLUGIN_SLACK",
      path: [:fermix_core, :plugin_secrets, "slack"],
      plugin: "slack",
      functionality: "Slack plugin",
      optional?: true
    }
  ]

  @spec all() :: [secret()]
  def all, do: @secrets

  @spec fetch!(atom()) :: secret()
  def fetch!(key) when is_atom(key) do
    Enum.find(@secrets, &(&1.key == key)) ||
      raise ArgumentError, "unknown setup secret key #{inspect(key)}"
  end

  @doc "The secret entry for an `api_key` plugin by name, or `nil` if it has none."
  @spec fetch_plugin(String.t()) :: secret() | nil
  def fetch_plugin(name) when is_binary(name) do
    Enum.find(@secrets, &(Map.get(&1, :plugin) == name))
  end

  @spec by_answer_key() :: keyword([atom()])
  def by_answer_key do
    Enum.map(@secrets, &{&1.key, &1.path})
  end

  @doc """
  Returns secrets whose env name should be exposed to child processes via
  `[sandbox.env.<NAME>]`. AI provider keys only; channel tokens stay
  Fermix-internal because they are consumed by BEAM-side channel modules,
  not spawned subprocesses.
  """
  @spec sandbox_env_eligible() :: [secret()]
  def sandbox_env_eligible do
    Enum.filter(@secrets, &Map.get(&1, :sandbox_env, false))
  end
end
