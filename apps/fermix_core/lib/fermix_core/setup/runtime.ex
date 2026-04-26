defmodule FermixCore.Setup.Runtime do
  @moduledoc """
  Release-safe orchestrator for the setup wizard.

  Drives the same workflow that `Mix.Tasks.Fermix.Setup` previously
  performed inline: loads the persisted snapshot, applies it to
  Application env, and either prints readiness, seeds prompt files,
  or persists new answers. IO is injected via the `:puts` and
  `:prompt` keys so the same logic powers both the dev Mix task
  and the packaged CLI binary.
  """

  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.Wizard

  @answer_keys [
    :openai_api_key,
    :telegram_bot_token,
    :whatsapp_access_token,
    :whatsapp_phone_number_id,
    :whatsapp_verify_token,
    :whatsapp_app_secret,
    :discord_bot_token,
    :discord_bot_user_id,
    :slack_bot_token,
    :slack_signing_secret,
    :signal_account
  ]

  @type puts_fun :: (String.t() -> any())
  @type prompt_fun :: (String.t() -> String.t())
  @type io_opts :: [puts: puts_fun(), prompt: prompt_fun()]

  @spec run(keyword(), io_opts()) :: :ok | {:error, String.t()}
  def run(opts, io_opts \\ []) when is_list(opts) and is_list(io_opts) do
    puts = Keyword.get(io_opts, :puts, &IO.puts/1)
    prompt = Keyword.get(io_opts, :prompt, &default_prompt/1)

    with {:ok, report} <- load_report() do
      dispatch(report, opts, puts, prompt)
    end
  end

  defp dispatch(report, opts, puts, prompt) do
    cond do
      Keyword.get(opts, :print_state) ->
        print_report(report, puts)
        :ok

      report.status == :ready and provided_answers(opts) == [] ->
        seed_and_print(report, puts)

      true ->
        save_and_print(report, opts, puts, prompt)
    end
  end

  defp load_report do
    case ConfigStore.load_runtime_config() do
      {:ok, snapshot} ->
        :ok = ConfigStore.apply_snapshot(snapshot)
        {:ok, Wizard.report()}

      {:error, reason} ->
        {:error, "failed to load setup snapshot: #{inspect(reason)}"}
    end
  end

  defp seed_and_print(report, puts) do
    case Wizard.seed_now() do
      {:ok, results} ->
        print_report(%{report | seeding_results: results}, puts)
        :ok

      {:error, reason} ->
        {:error, "failed to seed prompt files: #{inspect(reason)}"}
    end
  end

  defp save_and_print(report, opts, puts, prompt) do
    answers = collect_answers(report, opts, prompt)

    case Wizard.save_answers(report.wizard, answers) do
      {:ok, updated_report} ->
        puts.("Saved setup snapshot to #{updated_report.config_path}")
        print_report(updated_report, puts)
        :ok

      {:error, reason} ->
        {:error, "failed to save setup snapshot: #{inspect(reason)}"}
    end
  end

  defp collect_answers(report, opts, prompt) do
    case provided_answers(opts) do
      [] -> Enum.flat_map(Wizard.prompts(report.wizard), &interactive_answer(&1, prompt))
      provided -> provided
    end
  end

  defp interactive_answer(%{key: key, label: label}, prompt) do
    value = label |> prompt.() |> to_string() |> String.trim()
    if value == "", do: [], else: [{key, value}]
  end

  @spec provided_answers(keyword()) :: keyword()
  def provided_answers(opts) do
    Enum.reduce(@answer_keys, [], fn key, acc ->
      case Keyword.get(opts, key) do
        value when value in [nil, ""] -> acc
        value -> Keyword.put(acc, key, value)
      end
    end)
  end

  defp print_report(report, puts) do
    puts.("status: #{report.status}")
    puts.("config path: #{report.config_path}")
    puts.("next step: #{report.wizard.step}")

    if report.failures == [] do
      puts.("All required setup checks are satisfied.")
    else
      Enum.each(report.failures, fn failure ->
        puts.("- #{failure.component}: #{failure.action}")
      end)
    end

    print_seeding_results(report.seeding_results, puts)
  end

  defp print_seeding_results([], _puts), do: :ok

  defp print_seeding_results(results, puts) do
    puts.("Prompt files:")

    Enum.each(results, fn %{name: name, outcome: outcome, path: path} ->
      puts.("- #{name} #{outcome}: #{path}")
    end)
  end

  defp default_prompt(label) do
    case IO.gets("#{label}: ") do
      :eof -> ""
      {:error, _reason} -> ""
      value -> value
    end
  end
end
