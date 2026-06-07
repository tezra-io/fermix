defmodule FermixCore.Setup.SecretPaths do
  @moduledoc """
  Canonical registry for setup-managed secret fields.
  """

  @type secret :: %{
          :key => atom(),
          :env => String.t(),
          :path => [atom() | String.t()],
          optional(:sandbox_env) => boolean()
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
      key: :tavily_api_key,
      env: "TAVILY_API_KEY",
      path: [:fermix_core, :tools, :web_search, :tavily_api_key],
      sandbox_env: true
    },
    %{
      key: :exa_api_key,
      env: "EXA_API_KEY",
      path: [:fermix_core, :tools, :web_search, :exa_api_key],
      sandbox_env: true
    },
    %{
      key: :parallel_api_key,
      env: "PARALLEL_API_KEY",
      path: [:fermix_core, :tools, :web_search, :parallel_api_key],
      sandbox_env: true
    },
    %{
      key: :brave_api_key,
      env: "BRAVE_API_KEY",
      path: [:fermix_core, :tools, :web_search, :brave_api_key],
      sandbox_env: true
    },
    %{
      key: :perplexity_api_key,
      env: "PERPLEXITY_API_KEY",
      path: [:fermix_core, :tools, :web_search, :perplexity_api_key],
      sandbox_env: true
    },
    %{
      key: :google_oauth_client_secret,
      env: "GOOGLE_OAUTH_CLIENT_SECRET",
      path: [:fermix_core, :oauth, "google", :client_secret]
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
    }
  ]

  @spec all() :: [secret()]
  def all, do: @secrets

  @spec fetch!(atom()) :: secret()
  def fetch!(key) when is_atom(key) do
    Enum.find(@secrets, &(&1.key == key)) ||
      raise ArgumentError, "unknown setup secret key #{inspect(key)}"
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
