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
    telegram_bot_token: :string,
    whatsapp_access_token: :string,
    whatsapp_phone_number_id: :string,
    whatsapp_verify_token: :string,
    whatsapp_app_secret: :string,
    discord_bot_token: :string,
    discord_bot_user_id: :string,
    slack_bot_token: :string,
    slack_signing_secret: :string,
    signal_account: :string,
    print_state: :boolean
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
