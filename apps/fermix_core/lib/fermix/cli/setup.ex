defmodule Fermix.CLI.Setup do
  @moduledoc """
  Release-safe `fermix setup` command.

  Parses argv with `OptionParser` and delegates to
  `FermixCore.Setup.Runtime.run/2` using stdio-backed IO.
  """

  alias FermixCore.Setup.Runtime

  @switches [
    openai_api_key: :string,
    provider: :string,
    default_model: :string,
    reasoning_effort: :string,
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
    print_state: :boolean,
    import_codex: :boolean
  ]

  @spec run([String.t()]) :: non_neg_integer()
  def run(argv) when is_list(argv) do
    case OptionParser.parse(argv, strict: @switches) do
      {opts, _argv, []} -> dispatch(opts)
      {_opts, _argv, invalid} -> invalid_options(invalid)
    end
  end

  defp dispatch(opts) do
    case Runtime.run(opts) do
      :ok -> 0
      {:error, reason} -> abort(reason)
    end
  end

  defp invalid_options(invalid) do
    abort("invalid options: #{inspect(invalid)}")
  end

  defp abort(message) do
    IO.puts(:stderr, "fermix setup: #{message}")
    1
  end
end
