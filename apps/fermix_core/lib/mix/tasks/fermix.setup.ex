defmodule Mix.Tasks.Fermix.Setup do
  @moduledoc """
  CLI setup entrypoint that reuses the shared onboarding state and persistence.
  """

  use Mix.Task

  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.Wizard

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

    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches)

    raise_on_invalid_options(invalid)

    report = load_report()
    maybe_save_answers(report, opts)
  end

  defp raise_on_invalid_options([]), do: :ok

  defp raise_on_invalid_options(invalid) do
    Mix.raise("invalid options: #{inspect(invalid)}")
  end

  defp load_report do
    case ConfigStore.load_runtime_config() do
      {:ok, snapshot} ->
        :ok = ConfigStore.apply_snapshot(snapshot)
        Wizard.report()

      {:error, reason} ->
        Mix.raise("failed to load setup snapshot: #{inspect(reason)}")
    end
  end

  defp maybe_save_answers(report, opts) do
    cond do
      opts[:print_state] ->
        print_report(report)

      report.status == :ready and provided_answers(opts) == [] ->
        print_report(report)

      true ->
        answers = collect_answers(report, opts)

        case Wizard.save_answers(report.wizard, answers) do
          {:ok, updated_report} ->
            Mix.shell().info("Saved setup snapshot to #{updated_report.config_path}")
            print_report(updated_report)

          {:error, reason} ->
            Mix.raise("failed to save setup snapshot: #{inspect(reason)}")
        end
    end
  end

  defp collect_answers(report, opts) do
    provided = provided_answers(opts)

    if provided != [] do
      provided
    else
      Enum.map(Wizard.prompts(report.wizard), fn prompt ->
        {prompt.key, prompt_value(prompt.label)}
      end)
      |> Enum.reject(fn {_key, value} -> String.trim(value) == "" end)
    end
  end

  defp provided_answers(opts) do
    []
    |> put_opt(:openai_api_key, opts[:openai_api_key])
    |> put_opt(:telegram_bot_token, opts[:telegram_bot_token])
    |> put_opt(:whatsapp_access_token, opts[:whatsapp_access_token])
    |> put_opt(:whatsapp_phone_number_id, opts[:whatsapp_phone_number_id])
    |> put_opt(:whatsapp_verify_token, opts[:whatsapp_verify_token])
    |> put_opt(:whatsapp_app_secret, opts[:whatsapp_app_secret])
    |> put_opt(:discord_bot_token, opts[:discord_bot_token])
    |> put_opt(:discord_bot_user_id, opts[:discord_bot_user_id])
    |> put_opt(:slack_bot_token, opts[:slack_bot_token])
    |> put_opt(:slack_signing_secret, opts[:slack_signing_secret])
    |> put_opt(:signal_account, opts[:signal_account])
  end

  defp put_opt(keyword, _key, nil), do: keyword
  defp put_opt(keyword, _key, ""), do: keyword
  defp put_opt(keyword, key, value), do: Keyword.put(keyword, key, value)

  defp prompt_value(label) do
    Mix.shell().prompt("#{label}: ")
    |> to_string()
    |> String.trim()
  end

  defp print_report(report) do
    Mix.shell().info("status: #{report.status}")
    Mix.shell().info("config path: #{report.config_path}")
    Mix.shell().info("next step: #{report.wizard.step}")

    if report.failures == [] do
      Mix.shell().info("All required setup checks are satisfied.")
    else
      Enum.each(report.failures, fn failure ->
        Mix.shell().info("- #{failure.component}: #{failure.action}")
      end)
    end
  end
end
