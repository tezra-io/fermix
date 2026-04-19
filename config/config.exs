import Config

config :fermix_web,
  generators: [timestamp_type: :utc_datetime]

config :fermix_web, FermixWebWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: FermixWebWeb.ErrorHTML, json: FermixWebWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: FermixWeb.PubSub,
  live_view: [signing_salt: "W1N1pyZP"]

config :esbuild,
  version: "0.25.4",
  fermix_web: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../apps/fermix_web/assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

config :tailwind,
  version: "4.1.12",
  fermix_web: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("../apps/fermix_web", __DIR__)
  ]

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :fermix_core,
  providers: [
    openai: [
      auth_mode: :oauth,
      base_url: "https://api.openai.com/v1",
      default_model: "gpt-5.4-mini",
      default_temperature: 0.7
    ]
  ],
  max_conversation_history: 50,
  context_window_limit: 120_000

config :fermix_core, :transcription,
  backend: FermixCore.Transcription.OpenAI,
  model: "whisper-1"

config :fermix_channels,
  telegram: [
    enabled: true,
    mode: :webhook,
    webhook_path: "/webhook/telegram",
    allowed_user_ids: []
  ],
  whatsapp: [
    enabled: false,
    mode: :webhook,
    webhook_path: "/webhook/whatsapp",
    # WhatsApp allowlists sender phone numbers only; it does not use allowed_user_ids.
    allowed_sender_ids: []
  ],
  discord: [
    enabled: false,
    mode: :gateway,
    allowed_user_ids: []
  ],
  slack: [
    enabled: false,
    mode: :webhook,
    allowed_user_ids: []
  ],
  signal: [
    enabled: false,
    mode: :subprocess,
    # Signal allowlists sender phone numbers only; it does not use allowed_user_ids.
    allowed_sender_ids: []
  ]

config :fermix_core, :trace, base_dir: Path.expand("~/.fermix/traces")

config :fermix_core, :log,
  file: Path.expand("~/.fermix/logs/fermix.log"),
  max_no_bytes: 10_485_760,
  max_no_files: 5

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
