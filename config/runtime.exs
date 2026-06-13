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
  http: [port: String.to_integer(System.get_env("PORT", "4030"))]

# Hydrate Application env from the persisted ConfigStore snapshot. This is
# the single source of truth for "what was set during setup". Any key added
# to ConfigStore.persistable_snapshot/1 + apply_snapshot/1 lands in env
# automatically — runtime.exs only needs to apply env-var overlays below.
if Code.ensure_loaded?(FermixCore.Setup.ConfigStore) and
     function_exported?(FermixCore.Setup.ConfigStore, :bootstrap_runtime_config, 0) do
  case FermixCore.Setup.ConfigStore.bootstrap_runtime_config() do
    :ok ->
      :ok

    {:error, reason} ->
      raise "FermixCore.Setup.ConfigStore.bootstrap_runtime_config failed: " <>
              inspect(reason)
  end
end

workspace_paths =
  if Code.ensure_loaded?(FermixCore.Setup.ConfigStore) and
       function_exported?(FermixCore.Setup.ConfigStore, :workspace_paths, 0) do
    FermixCore.Setup.ConfigStore.workspace_paths()
  else
    # Mirror ConfigStore.fermix_home/0: a blank FERMIX_HOME ("") is truthy, so
    # `|| default` would not fall back and workspace paths would go cwd-relative
    # (e.g. ./skills). Treat blank as unset.
    fermix_home =
      case System.get_env("FERMIX_HOME") do
        home when is_binary(home) and home != "" -> home
        _ -> Path.join(System.user_home!(), ".fermix")
      end

    %{
      bootstrap: Path.join(fermix_home, "bootstrap"),
      skills: Path.join(fermix_home, "skills"),
      plugins: Path.join(fermix_home, "plugins"),
      journals: Path.join(fermix_home, "journals"),
      traces: Path.join(fermix_home, "traces"),
      logs: Path.join(fermix_home, "logs")
    }
  end

# Env-var overlays: layered on top of whatever ConfigStore hydrated above.

existing_providers = Application.get_env(:fermix_core, :providers, [])
existing_openai = Keyword.get(existing_providers, :openai, [])
existing_openai_codex = Keyword.get(existing_providers, :openai_codex, [])
existing_anthropic = Keyword.get(existing_providers, :anthropic, [])
existing_xai = Keyword.get(existing_providers, :xai, [])
existing_openrouter = Keyword.get(existing_providers, :openrouter, [])
existing_ollama = Keyword.get(existing_providers, :ollama, [])

openai_api_key = System.get_env("OPENAI_API_KEY") || Keyword.get(existing_openai, :api_key, "")

# Provider, model, and reasoning effort are config-only (set via the wizard /
# web setup), never env overlays. An env var that silently re-points the active
# provider could desync it from its model, and an env-set primary would fight the
# `primary = true` flag that PrimaryConfig actually routes on. Only credentials
# (API keys, auth modes) are read from the environment below.
merged_openai =
  existing_openai
  |> Keyword.delete(:auth_mode)
  |> Keyword.merge(api_key: openai_api_key)

merged_openai_codex = existing_openai_codex

# Optional env overlays for API keys and auth modes; empty/absent vars
# leave the TOML-hydrated values untouched.
put_env_overlay = fn config, key, env_name ->
  case System.get_env(env_name) do
    nil -> config
    "" -> config
    value -> Keyword.put(config, key, value)
  end
end

merged_anthropic =
  existing_anthropic
  |> put_env_overlay.(:api_key, "ANTHROPIC_API_KEY")
  |> put_env_overlay.(:auth_mode, "FERMIX_ANTHROPIC_AUTH_MODE")

merged_xai =
  existing_xai
  |> put_env_overlay.(:api_key, "XAI_API_KEY")
  |> put_env_overlay.(:base_url, "XAI_BASE_URL")
  |> put_env_overlay.(:auth_mode, "FERMIX_XAI_AUTH_MODE")

merged_openrouter =
  existing_openrouter
  |> put_env_overlay.(:api_key, "OPENROUTER_API_KEY")

merged_ollama =
  existing_ollama
  |> put_env_overlay.(:base_url, "OLLAMA_BASE_URL")

merged_providers =
  existing_providers
  |> Keyword.put(:openai, merged_openai)
  |> Keyword.put(:openai_codex, merged_openai_codex)
  |> Keyword.put(:anthropic, merged_anthropic)
  |> Keyword.put(:xai, merged_xai)
  |> Keyword.put(:openrouter, merged_openrouter)
  |> Keyword.put(:ollama, merged_ollama)

config :fermix_core, providers: merged_providers

existing_trace = Application.get_env(:fermix_core, :trace, [])
existing_log = Application.get_env(:fermix_core, :log, [])
existing_memory = Application.get_env(:fermix_core, :memory, [])
existing_prompt_bootstrap = Application.get_env(:fermix_core, :prompt_bootstrap, [])
existing_realtime = Application.get_env(:fermix_core, :realtime, [])

env_bool = fn name ->
  case System.get_env(name) do
    nil -> :__unset__
    "" -> :__unset__
    value when value in ["1", "true", "TRUE", "yes", "YES", "y", "Y"] -> true
    value when value in ["0", "false", "FALSE", "no", "NO", "n", "N"] -> false
    value -> raise ArgumentError, "#{name}=#{inspect(value)} must be a boolean"
  end
end

env_positive_int = fn name ->
  case System.get_env(name) do
    nil ->
      :__unset__

    "" ->
      :__unset__

    value ->
      case Integer.parse(value) do
        {integer, ""} when integer > 0 ->
          integer

        _invalid ->
          raise ArgumentError, "#{name}=#{inspect(value)} must be a positive integer"
      end
  end
end

env_string = fn name ->
  case System.get_env(name) do
    nil -> :__unset__
    "" -> :__unset__
    value -> value
  end
end

put_overlay = fn config, key, value ->
  case value do
    :__unset__ -> config
    value -> Keyword.put(config, key, value)
  end
end

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

memory_paths = FermixCore.Setup.ConfigStore.memory_paths()

memory_database_path =
  System.get_env("FERMIX_MEMORY_DB_PATH") || memory_paths.database_path

memory_prompt_base_dir =
  System.get_env("FERMIX_MEMORY_PROMPT_DIR") || memory_paths.prompt_base_dir

config :fermix_core,
       :memory,
       Keyword.merge(existing_memory,
         enabled: memory_enabled,
         database_path: memory_database_path,
         prompt_base_dir: memory_prompt_base_dir
       )

realtime_env =
  existing_realtime
  |> put_overlay.(:enabled, env_bool.("FERMIX_REALTIME_ENABLED"))
  |> put_overlay.(:provider, env_string.("FERMIX_REALTIME_PROVIDER"))
  |> put_overlay.(:model, env_string.("FERMIX_REALTIME_MODEL"))
  |> put_overlay.(:voice, env_string.("FERMIX_REALTIME_VOICE"))
  |> put_overlay.(:max_session_minutes, env_positive_int.("FERMIX_REALTIME_MAX_SESSION_MINUTES"))
  |> put_overlay.(
    :max_estimated_cost_cents_per_session,
    case env_positive_int.("FERMIX_REALTIME_MAX_COST_CENTS") do
      :__unset__ -> env_positive_int.("FERMIX_REALTIME_MAX_ESTIMATED_COST_CENTS_PER_SESSION")
      value -> value
    end
  )
  |> put_overlay.(:persist_transcripts, env_bool.("FERMIX_REALTIME_PERSIST_TRANSCRIPTS"))
  |> FermixCore.Realtime.Config.normalize()
  |> FermixCore.Realtime.Config.to_keyword()

config :fermix_core, :realtime, realtime_env

config :fermix_core,
       :prompt_bootstrap,
       Keyword.merge(existing_prompt_bootstrap,
         bootstrap_dir:
           System.get_env("FERMIX_BOOTSTRAP_DIR") ||
             workspace_paths.bootstrap
       )

config :fermix_core,
       :trace,
       Keyword.merge(existing_trace,
         base_dir: System.get_env("FERMIX_TRACE_DIR") || workspace_paths.traces
       )

existing_telemetry = Application.get_env(:fermix_core, :telemetry, [])

# Content capture (prompt/response/tool bodies in traces). One knob for the
# common case: exporting to Opik turns content ON by default — if you're
# observing, you want to see everything. FERMIX_TRACE_CONTENT is the explicit
# override (e.g. "=0" for Opik-without-bodies, or "=1" for content in the local
# JSONL with no Opik).
capture_content =
  case env_bool.("FERMIX_TRACE_CONTENT") do
    :__unset__ -> env_bool.("FERMIX_OPIK_ENABLED") == true
    explicit -> explicit
  end

config :fermix_core,
       :telemetry,
       Keyword.put(existing_telemetry, :capture_content, capture_content)

config :fermix_core,
       :log,
       Keyword.merge(existing_log,
         file: System.get_env("FERMIX_LOG_FILE") || Path.join(workspace_paths.logs, "fermix.log")
       )

existing_telegram = Application.get_env(:fermix_channels, :telegram, [])

telegram_overrides = [
  bot_token:
    System.get_env("TELEGRAM_BOT_TOKEN") || Keyword.get(existing_telegram, :bot_token, "")
]

telegram_overrides =
  case System.get_env("TELEGRAM_ALLOWED_USER_IDS") do
    nil ->
      telegram_overrides

    "" ->
      Keyword.put(telegram_overrides, :allowed_user_ids, [])

    ids ->
      Keyword.put(
        telegram_overrides,
        :allowed_user_ids,
        ids |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.map(&String.to_integer/1)
      )
  end

merged_telegram = Keyword.merge(existing_telegram, telegram_overrides)

config :fermix_channels, telegram: merged_telegram

existing_whatsapp = Application.get_env(:fermix_channels, :whatsapp, [])

whatsapp_mode =
  case System.get_env("WHATSAPP_MODE") do
    "webhook" -> :webhook
    _ -> Keyword.get(existing_whatsapp, :mode, :webhook)
  end

whatsapp_overrides = [
  access_token:
    System.get_env("WHATSAPP_ACCESS_TOKEN") || Keyword.get(existing_whatsapp, :access_token, ""),
  phone_number_id:
    System.get_env("WHATSAPP_PHONE_NUMBER_ID") ||
      Keyword.get(existing_whatsapp, :phone_number_id, ""),
  verify_token:
    System.get_env("WHATSAPP_VERIFY_TOKEN") || Keyword.get(existing_whatsapp, :verify_token, ""),
  app_secret:
    System.get_env("WHATSAPP_APP_SECRET") || Keyword.get(existing_whatsapp, :app_secret, ""),
  mode: whatsapp_mode
]

whatsapp_overrides =
  case System.get_env("WHATSAPP_ALLOWED_SENDER_IDS") do
    nil ->
      whatsapp_overrides

    "" ->
      Keyword.put(whatsapp_overrides, :allowed_sender_ids, [])

    ids ->
      Keyword.put(
        whatsapp_overrides,
        :allowed_sender_ids,
        ids |> String.split(",") |> Enum.map(&String.trim/1)
      )
  end

merged_whatsapp = Keyword.merge(existing_whatsapp, whatsapp_overrides)

config :fermix_channels, whatsapp: merged_whatsapp

existing_discord = Application.get_env(:fermix_channels, :discord, [])

discord_mode =
  case System.get_env("DISCORD_MODE") do
    "gateway" -> :gateway
    _ -> Keyword.get(existing_discord, :mode, :gateway)
  end

discord_overrides = [
  bot_token: System.get_env("DISCORD_BOT_TOKEN") || Keyword.get(existing_discord, :bot_token, ""),
  bot_user_id:
    System.get_env("DISCORD_BOT_USER_ID") || Keyword.get(existing_discord, :bot_user_id, ""),
  mode: discord_mode
]

discord_overrides =
  case System.get_env("DISCORD_ALLOWED_USER_IDS") do
    nil ->
      discord_overrides

    "" ->
      Keyword.put(discord_overrides, :allowed_user_ids, [])

    ids ->
      Keyword.put(
        discord_overrides,
        :allowed_user_ids,
        ids |> String.split(",") |> Enum.map(&String.trim/1)
      )
  end

merged_discord = Keyword.merge(existing_discord, discord_overrides)

config :fermix_channels, discord: merged_discord

existing_slack = Application.get_env(:fermix_channels, :slack, [])

slack_mode =
  case System.get_env("SLACK_MODE") do
    "webhook" -> :webhook
    _ -> Keyword.get(existing_slack, :mode, :webhook)
  end

slack_overrides = [
  bot_token: System.get_env("SLACK_BOT_TOKEN") || Keyword.get(existing_slack, :bot_token, ""),
  signing_secret:
    System.get_env("SLACK_SIGNING_SECRET") ||
      Keyword.get(existing_slack, :signing_secret, ""),
  mode: slack_mode
]

slack_overrides =
  case System.get_env("SLACK_ALLOWED_USER_IDS") do
    nil ->
      slack_overrides

    "" ->
      Keyword.put(slack_overrides, :allowed_user_ids, [])

    ids ->
      Keyword.put(
        slack_overrides,
        :allowed_user_ids,
        ids |> String.split(",") |> Enum.map(&String.trim/1)
      )
  end

merged_slack = Keyword.merge(existing_slack, slack_overrides)

config :fermix_channels, slack: merged_slack

existing_signal = Application.get_env(:fermix_channels, :signal, [])

signal_mode =
  case System.get_env("SIGNAL_MODE") do
    "subprocess" -> :subprocess
    _ -> Keyword.get(existing_signal, :mode, :subprocess)
  end

signal_overrides = [
  account: System.get_env("SIGNAL_ACCOUNT") || Keyword.get(existing_signal, :account, ""),
  cli_path: System.get_env("SIGNAL_CLI_PATH") || Keyword.get(existing_signal, :cli_path, ""),
  mode: signal_mode
]

signal_overrides =
  case System.get_env("SIGNAL_ALLOWED_SENDER_IDS") do
    nil ->
      signal_overrides

    "" ->
      Keyword.put(signal_overrides, :allowed_sender_ids, [])

    ids ->
      Keyword.put(
        signal_overrides,
        :allowed_sender_ids,
        ids |> String.split(",") |> Enum.map(&String.trim/1)
      )
  end

merged_signal = Keyword.merge(existing_signal, signal_overrides)

config :fermix_channels, signal: merged_signal

if config_env() == :prod do
  # The secret key base signs Phoenix session cookies. The daemon restarts
  # itself (service KeepAlive, and the setup UI's restart button), so the key
  # MUST stay stable across restarts — a per-boot key invalidates the in-flight
  # setup session cookie and locks the browser out with a 403. Persist it under
  # FERMIX_HOME (this ships in the release, so brew installs get it too);
  # operators may override with SECRET_KEY_BASE.
  secret_key_base =
    cond do
      env = System.get_env("SECRET_KEY_BASE") ->
        env

      Code.ensure_loaded?(FermixCore.Setup.SecretKeyBase) ->
        secret_home = System.get_env("FERMIX_HOME") || Path.join(System.user_home!(), ".fermix")
        FermixCore.Setup.SecretKeyBase.read_or_create!(secret_home)

      true ->
        # Build-time tooling evaluates runtime.exs without the app loaded; this
        # ephemeral key is never used to sign a served session.
        Base.encode64(:crypto.strong_rand_bytes(48))
    end

  host = System.get_env("PHX_HOST") || "localhost"

  config :fermix_web, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # Default to loopback so a fresh local install does not expose the
  # endpoint to the LAN. Operators serving the daemon across a network
  # opt in explicitly via FERMIX_HTTP_BIND (e.g. `0.0.0.0` for IPv4 any,
  # `::` for IPv6 any, or a specific interface IP).
  bind_str = System.get_env("FERMIX_HTTP_BIND") || "127.0.0.1"

  http_bind =
    case :inet.parse_address(String.to_charlist(bind_str)) do
      {:ok, address} ->
        address

      {:error, _} ->
        raise "FERMIX_HTTP_BIND must be a valid IP address; got: #{inspect(bind_str)}"
    end

  config :fermix_web, FermixWebWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: http_bind],
    # The daemon serves its web UI on loopback; allow both loopback origins
    # (and the configured PHX_HOST) so the LiveView socket isn't rejected when
    # the browser uses 127.0.0.1 instead of localhost.
    check_origin: ["//localhost", "//127.0.0.1", "//#{host}"],
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
