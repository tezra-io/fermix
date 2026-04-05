import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/fermix_web start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :fermix_web, FermixWebWeb.Endpoint, server: true
end

config :fermix_web, FermixWebWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# Merge runtime config with compile-time config to preserve base_url, default_model, etc.
existing_providers = Application.get_env(:fermix_core, :providers, [])
existing_openai = Keyword.get(existing_providers, :openai, [])

existing_telegram = Application.get_env(:fermix_channels, :telegram, [])

openai_auth_mode =
  if System.get_env("OPENAI_AUTH_MODE") == "api_key", do: :api_key, else: :oauth

if config_env() == :prod do
  merged_openai =
    Keyword.merge(existing_openai,
      auth_mode: openai_auth_mode,
      api_key: if(openai_auth_mode == :api_key, do: System.fetch_env!("OPENAI_API_KEY"), else: "")
    )

  config :fermix_core,
    providers: Keyword.put(existing_providers, :openai, merged_openai)

  telegram_mode =
    case System.get_env("TELEGRAM_MODE") do
      "polling" -> :polling
      _ -> :webhook
    end

  allowed_user_ids =
    case System.get_env("TELEGRAM_ALLOWED_USER_IDS") do
      nil -> []
      "" -> []
      ids -> ids |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.map(&String.to_integer/1)
    end

  merged_telegram =
    Keyword.merge(existing_telegram,
      bot_token: System.fetch_env!("TELEGRAM_BOT_TOKEN"),
      webhook_secret: System.get_env("TELEGRAM_WEBHOOK_SECRET"),
      allowed_user_ids: allowed_user_ids,
      mode: telegram_mode
    )

  config :fermix_channels, telegram: merged_telegram
else
  merged_openai =
    Keyword.merge(existing_openai,
      auth_mode: openai_auth_mode,
      api_key: System.get_env("OPENAI_API_KEY", "")
    )

  config :fermix_core,
    providers: Keyword.put(existing_providers, :openai, merged_openai)

  telegram_mode =
    case System.get_env("TELEGRAM_MODE") do
      "polling" -> :polling
      _ -> :webhook
    end

  allowed_user_ids =
    case System.get_env("TELEGRAM_ALLOWED_USER_IDS") do
      nil -> []
      "" -> []
      ids -> ids |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.map(&String.to_integer/1)
    end

  merged_telegram =
    Keyword.merge(existing_telegram,
      bot_token: System.get_env("TELEGRAM_BOT_TOKEN", ""),
      webhook_secret: System.get_env("TELEGRAM_WEBHOOK_SECRET"),
      allowed_user_ids: allowed_user_ids,
      mode: telegram_mode
    )

  config :fermix_channels, telegram: merged_telegram
end

if config_env() == :prod do
  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :fermix_web, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :fermix_web, FermixWebWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :fermix_web, FermixWebWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :fermix_web, FermixWebWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
