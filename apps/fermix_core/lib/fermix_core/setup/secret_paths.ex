defmodule FermixCore.Setup.SecretPaths do
  @moduledoc """
  Canonical registry for setup-managed secret fields.
  """

  @type secret :: %{
          key: atom(),
          env: String.t(),
          path: [atom()]
        }

  @secrets [
    %{key: :openai_api_key, env: "OPENAI_API_KEY", path: [:fermix_core, :providers, :openai, :api_key]},
    %{key: :telegram_bot_token, env: "TELEGRAM_BOT_TOKEN", path: [:fermix_channels, :telegram, :bot_token]},
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
    %{key: :discord_bot_token, env: "DISCORD_BOT_TOKEN", path: [:fermix_channels, :discord, :bot_token]},
    %{key: :slack_bot_token, env: "SLACK_BOT_TOKEN", path: [:fermix_channels, :slack, :bot_token]},
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
end
