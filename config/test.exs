import Config

config :fermix_web, FermixWebWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "IDEc2P19ECF1+hwm0K0GriUalzvJ87GqV3JBCplMvtFgX1lnZw5n3iimO0n2KpXd",
  server: false

config :logger, level: :warning

config :fermix_core, :log, enabled: false

config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  enable_expensive_runtime_checks: true

config :phoenix,
  sort_verified_routes_query_params: true
