import Config

config :fermix_web, FermixWebWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "YDnpptp4K0UxFcin6weNPAEf3ZnJC1T6DE1rJnZpCuS4xglVQJPy/Y6ptsMwcG6+",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:fermix_web, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:fermix_web, ~w(--watch)]}
  ]

config :fermix_web, FermixWebWeb.Endpoint,
  live_reload: [
    web_console_logger: true,
    patterns: [
      ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
      ~r"priv/gettext/.*\.po$"E,
      ~r"lib/fermix_web_web/router\.ex$"E,
      ~r"lib/fermix_web_web/(controllers|live|components)/.*\.(ex|heex)$"E
    ]
  ]

config :fermix_web, dev_routes: true

# Opik traces from a dev instance land in their own project, so dev and prod
# don't share one messy trace stream. Compile-env gated (dev.exs only applies
# to MIX_ENV=dev, e.g. `mix fermix.dev`); prod releases keep the "fermix"
# default. `FERMIX_OPIK_PROJECT` still overrides this for one-off runs.
config :fermix_opik, project_name: "fermix-dev"

config :logger, :default_formatter, format: "[$level] $message\n"
config :logger, level: :debug

config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  debug_heex_annotations: true,
  debug_attributes: true,
  enable_expensive_runtime_checks: true
