defmodule Mix.Tasks.Fermix.Setup do
  @moduledoc """
  Dev wrapper around `FermixCore.Setup.Runtime`.

  Bootstraps Mix-only concerns (loadpaths, app.config, application start),
  parses argv, and delegates the actual workflow to the release-safe
  runtime so the same code path serves the packaged CLI binary.
  """

  use Mix.Task

  alias FermixCore.Setup.Runtime

  @shortdoc "Shared Fermix setup entrypoint"

  @switches [
    openai_api_key: :string,
    anthropic_api_key: :string,
    provider: :string,
    default_model: :string,
    reasoning_effort: :string,
    fast: :boolean,
    realtime_enabled: :boolean,
    realtime_api_key: :string,
    realtime_voice: :string,
    realtime_max_session_minutes: :integer,
    realtime_max_cost_cents: :integer,
    realtime_persist_transcripts: :boolean,
    telegram_bot_token: :string,
    telegram_owner_user_id: :string,
    whatsapp_access_token: :string,
    whatsapp_phone_number_id: :string,
    whatsapp_verify_token: :string,
    whatsapp_app_secret: :string,
    whatsapp_owner_user_id: :string,
    discord_bot_token: :string,
    discord_bot_user_id: :string,
    discord_owner_user_id: :string,
    slack_bot_token: :string,
    slack_signing_secret: :string,
    slack_owner_user_id: :string,
    signal_account: :string,
    signal_owner_user_id: :string,
    print_state: :boolean,
    reconfigure: :boolean,
    migrate_secrets: :boolean,
    import_codex: :boolean,
    no_browser: :boolean,
    skip_probe: :boolean,
    port: :integer,
    timeout: :integer
  ]

  @impl true
  def run(args) do
    Mix.Task.run("loadpaths")
    Mix.Task.run("app.config")
    {:ok, _started} = Application.ensure_all_started(:fermix_core)

    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("invalid options: #{inspect(invalid)}")
    end

    io = [
      puts: fn msg -> Mix.shell().info(msg) end,
      prompt: fn label -> Mix.shell().prompt(label) end
    ]

    case Runtime.run(opts, io) do
      :ok -> :ok
      {:error, reason} -> Mix.raise(reason)
    end
  end
end
