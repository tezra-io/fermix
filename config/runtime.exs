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

workspace_paths =
  if Code.ensure_loaded?(FermixCore.Setup.ConfigStore) and
       function_exported?(FermixCore.Setup.ConfigStore, :workspace_paths, 0) do
    FermixCore.Setup.ConfigStore.workspace_paths()
  else
    fermix_home = System.get_env("FERMIX_HOME") || Path.join(System.user_home!(), ".fermix")

    %{
      skills: Path.join(fermix_home, "skills"),
      journals: Path.join(fermix_home, "journals"),
      traces: Path.join(fermix_home, "traces"),
      logs: Path.join(fermix_home, "logs")
    }
  end

persisted_setup =
  if Code.ensure_loaded?(FermixCore.Setup.ConfigStore) and
       function_exported?(FermixCore.Setup.ConfigStore, :load_runtime_config, 0) do
    case FermixCore.Setup.ConfigStore.load_runtime_config() do
      {:ok, config} ->
        config

      {:error, _reason} ->
        %{
          fermix_core: [providers: [openai: []]],
          fermix_channels: [telegram: [], whatsapp: [], discord: [], slack: [], signal: []],
          fermix_web: []
        }
    end
  else
    %{
      fermix_core: [providers: [openai: []]],
      fermix_channels: [telegram: [], whatsapp: [], discord: [], slack: [], signal: []],
      fermix_web: []
    }
  end

# Merge runtime config with compile-time config to preserve base_url, default_model, etc.
existing_providers = Application.get_env(:fermix_core, :providers, [])

existing_openai =
  existing_providers
  |> Keyword.get(:openai, [])
  |> Keyword.merge(
    persisted_setup
    |> Map.get(:fermix_core, [])
    |> Keyword.get(:providers, [])
    |> Keyword.get(:openai, [])
  )

existing_telegram =
  Application.get_env(:fermix_channels, :telegram, [])
  |> Keyword.merge(
    persisted_setup
    |> Map.get(:fermix_channels, [])
    |> Keyword.get(:telegram, [])
  )

existing_whatsapp =
  Application.get_env(:fermix_channels, :whatsapp, [])
  |> Keyword.merge(
    persisted_setup
    |> Map.get(:fermix_channels, [])
    |> Keyword.get(:whatsapp, [])
  )

existing_discord =
  Application.get_env(:fermix_channels, :discord, [])
  |> Keyword.merge(
    persisted_setup
    |> Map.get(:fermix_channels, [])
    |> Keyword.get(:discord, [])
  )

existing_slack =
  Application.get_env(:fermix_channels, :slack, [])
  |> Keyword.merge(
    persisted_setup
    |> Map.get(:fermix_channels, [])
    |> Keyword.get(:slack, [])
  )

existing_signal =
  Application.get_env(:fermix_channels, :signal, [])
  |> Keyword.merge(
    persisted_setup
    |> Map.get(:fermix_channels, [])
    |> Keyword.get(:signal, [])
  )

openai_auth_mode =
  case System.get_env("OPENAI_AUTH_MODE") do
    "api_key" -> :api_key
    "oauth" -> :oauth
    _ -> Keyword.get(existing_openai, :auth_mode, :oauth)
  end

openai_api_key =
  if config_env() == :prod and openai_auth_mode != :api_key do
    ""
  else
    System.get_env("OPENAI_API_KEY") || Keyword.get(existing_openai, :api_key, "")
  end

merged_openai =
  Keyword.merge(existing_openai,
    auth_mode: openai_auth_mode,
    api_key: openai_api_key
  )

config :fermix_core,
  providers: Keyword.put(existing_providers, :openai, merged_openai)

existing_trace = Application.get_env(:fermix_core, :trace, [])
existing_log = Application.get_env(:fermix_core, :log, [])
existing_memory = Application.get_env(:fermix_core, :memory, [])

memory_enabled =
  case System.get_env("FERMIX_MEMORY_ENABLED") do
    "0" -> false
    "false" -> false
    "FALSE" -> false
    "1" -> true
    "true" -> true
    "TRUE" -> true
    _ -> Keyword.get(existing_memory, :enabled, true)
  end

memory_database_path =
  System.get_env("FERMIX_MEMORY_DB_PATH") ||
    Keyword.get(
      existing_memory,
      :database_path,
      Path.join(FermixCore.Setup.ConfigStore.fermix_home(), "memory.db")
    )

config :fermix_core,
       :memory,
       Keyword.merge(existing_memory,
         enabled: memory_enabled,
         database_path: memory_database_path
       )

config :fermix_core,
       :trace,
       Keyword.merge(existing_trace,
         base_dir: System.get_env("FERMIX_TRACE_DIR") || workspace_paths.traces
       )

config :fermix_core,
       :log,
       Keyword.merge(existing_log,
         file: System.get_env("FERMIX_LOG_FILE") || Path.join(workspace_paths.logs, "fermix.log")
       )

allowed_user_ids =
  case System.get_env("TELEGRAM_ALLOWED_USER_IDS") do
    nil -> Keyword.get(existing_telegram, :allowed_user_ids, [])
    "" -> []
    ids -> ids |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.map(&String.to_integer/1)
  end

merged_telegram =
  Keyword.merge(existing_telegram,
    bot_token:
      System.get_env("TELEGRAM_BOT_TOKEN") || Keyword.get(existing_telegram, :bot_token, ""),
    allowed_user_ids: allowed_user_ids
  )

config :fermix_channels, telegram: merged_telegram

whatsapp_mode =
  case System.get_env("WHATSAPP_MODE") do
    "webhook" -> :webhook
    _ -> Keyword.get(existing_whatsapp, :mode, :webhook)
  end

# WhatsApp keeps its own sender allowlist key. Do not fall back to allowed_user_ids.
whatsapp_allowed_sender_ids =
  case System.get_env("WHATSAPP_ALLOWED_SENDER_IDS") do
    nil -> Keyword.get(existing_whatsapp, :allowed_sender_ids, [])
    "" -> []
    ids -> ids |> String.split(",") |> Enum.map(&String.trim/1)
  end

merged_whatsapp =
  Keyword.merge(existing_whatsapp,
    access_token:
      System.get_env("WHATSAPP_ACCESS_TOKEN") || Keyword.get(existing_whatsapp, :access_token, ""),
    phone_number_id:
      System.get_env("WHATSAPP_PHONE_NUMBER_ID") ||
        Keyword.get(existing_whatsapp, :phone_number_id, ""),
    verify_token:
      System.get_env("WHATSAPP_VERIFY_TOKEN") || Keyword.get(existing_whatsapp, :verify_token, ""),
    app_secret:
      System.get_env("WHATSAPP_APP_SECRET") || Keyword.get(existing_whatsapp, :app_secret, ""),
    allowed_sender_ids: whatsapp_allowed_sender_ids,
    mode: whatsapp_mode
  )

config :fermix_channels, whatsapp: merged_whatsapp

discord_mode =
  case System.get_env("DISCORD_MODE") do
    "gateway" -> :gateway
    _ -> Keyword.get(existing_discord, :mode, :gateway)
  end

discord_allowed_user_ids =
  case System.get_env("DISCORD_ALLOWED_USER_IDS") do
    nil -> Keyword.get(existing_discord, :allowed_user_ids, [])
    "" -> []
    ids -> ids |> String.split(",") |> Enum.map(&String.trim/1)
  end

merged_discord =
  Keyword.merge(existing_discord,
    bot_token:
      System.get_env("DISCORD_BOT_TOKEN") || Keyword.get(existing_discord, :bot_token, ""),
    bot_user_id:
      System.get_env("DISCORD_BOT_USER_ID") || Keyword.get(existing_discord, :bot_user_id, ""),
    allowed_user_ids: discord_allowed_user_ids,
    mode: discord_mode
  )

config :fermix_channels, discord: merged_discord

slack_mode =
  case System.get_env("SLACK_MODE") do
    "webhook" -> :webhook
    _ -> Keyword.get(existing_slack, :mode, :webhook)
  end

slack_allowed_user_ids =
  case System.get_env("SLACK_ALLOWED_USER_IDS") do
    nil -> Keyword.get(existing_slack, :allowed_user_ids, [])
    "" -> []
    ids -> ids |> String.split(",") |> Enum.map(&String.trim/1)
  end

merged_slack =
  Keyword.merge(existing_slack,
    bot_token: System.get_env("SLACK_BOT_TOKEN") || Keyword.get(existing_slack, :bot_token, ""),
    signing_secret:
      System.get_env("SLACK_SIGNING_SECRET") ||
        Keyword.get(existing_slack, :signing_secret, ""),
    allowed_user_ids: slack_allowed_user_ids,
    mode: slack_mode
  )

config :fermix_channels, slack: merged_slack

signal_mode =
  case System.get_env("SIGNAL_MODE") do
    "subprocess" -> :subprocess
    _ -> Keyword.get(existing_signal, :mode, :subprocess)
  end

signal_allowed_sender_ids =
  case System.get_env("SIGNAL_ALLOWED_SENDER_IDS") do
    nil -> Keyword.get(existing_signal, :allowed_sender_ids, [])
    "" -> []
    ids -> ids |> String.split(",") |> Enum.map(&String.trim/1)
  end

merged_signal =
  Keyword.merge(existing_signal,
    account: System.get_env("SIGNAL_ACCOUNT") || Keyword.get(existing_signal, :account, ""),
    cli_path: System.get_env("SIGNAL_CLI_PATH") || Keyword.get(existing_signal, :cli_path, ""),
    allowed_sender_ids: signal_allowed_sender_ids,
    mode: signal_mode
  )

config :fermix_channels, signal: merged_signal

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
