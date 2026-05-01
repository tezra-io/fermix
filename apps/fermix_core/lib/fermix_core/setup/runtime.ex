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

  alias FermixCore.Auth.CodexImport
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.Doctor
  alias FermixCore.Setup.Wizard

  @answer_keys [
    :openai_api_key,
    :openai_auth_oauth,
    :provider,
    :default_model,
    :reasoning_effort,
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

      report.status == :ready and provided_answers(opts) == [] and
        Wizard.prompts(report.wizard) == [] and
          not Keyword.get(opts, :import_codex, false) ->
        seed_and_print(report, puts)

      true ->
        with {:ok, extras} <- maybe_import_codex(report, opts, puts, prompt) do
          # Re-fetch the report — the codex import may have satisfied
          # the openai provider check, leaving fewer required answers.
          {:ok, refreshed} = load_report()
          save_and_print(refreshed, opts ++ extras, puts, prompt)
        end
    end
  end

  defp maybe_import_codex(report, opts, puts, prompt) do
    cond do
      not openai_missing?(report) ->
        {:ok, []}

      Keyword.get(opts, :import_codex, false) ->
        run_codex_import(opts, puts)

      Keyword.get(opts, :openai_api_key) not in [nil, ""] ->
        {:ok, []}

      not CodexImport.codex_available?(codex_path(opts)) ->
        {:ok, []}

      true ->
        case ask_yes_no(prompt, "Import OpenAI tokens from existing Codex CLI? [Y/n]: ", true) do
          true -> run_codex_import(opts, puts)
          false -> {:ok, []}
        end
    end
  end

  defp run_codex_import(opts, puts) do
    import_opts =
      []
      |> maybe_put(:codex_path, Keyword.get(opts, :codex_auth_path))
      |> maybe_put(:fermix_path, Keyword.get(opts, :fermix_auth_path))
      |> maybe_put(:req_options, Keyword.get(opts, :req_options))

    case CodexImport.import_tokens(import_opts) do
      {:ok, _entry} ->
        puts.("Imported OpenAI tokens from Codex CLI.")
        {:ok, [openai_auth_oauth: true]}

      {:error, reason} ->
        {:error, "codex import failed: #{inspect(reason)}"}
    end
  end

  defp openai_missing?(%{failures: failures}) do
    Enum.any?(failures, &(&1.component == "provider:openai"))
  end

  defp codex_path(opts) do
    Keyword.get(opts, :codex_auth_path, Path.join(System.user_home!(), ".codex/auth.json"))
  end

  defp ask_yes_no(prompt, label, default_yes) do
    case prompt.(label) |> to_string() |> String.trim() |> String.downcase() do
      "" -> default_yes
      "y" -> true
      "yes" -> true
      _ -> false
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

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
        run_finalize_probe(updated_report, opts, puts)

      {:error, reason} ->
        {:error, "failed to save setup snapshot: #{inspect(reason)}"}
    end
  end

  defp run_finalize_probe(%{status: :ready}, opts, puts) do
    if Keyword.get(opts, :skip_probe, false) do
      :ok
    else
      probe_opts = Keyword.take(opts, [:req_options, :token_server])

      case Doctor.probe_active(probe_opts) do
        {:ok, %{provider: provider, model: model, latency_ms: ms}} ->
          puts.("auth probe: #{provider}/#{model} responded in #{ms}ms")
          :ok

        {:error, {:auth_scope_mismatch, surface, hint}} ->
          {:error, "auth probe failed for #{surface}: #{hint}"}

        {:error, {:misconfigured, message}} ->
          puts.("auth probe skipped: #{message}")
          :ok

        {:error, {:server_error, status, _body}} ->
          puts.("auth probe inconclusive: provider returned HTTP #{status}")
          :ok

        {:error, {:network, reason}} ->
          puts.("auth probe inconclusive: network error #{inspect(reason)}")
          :ok
      end
    end
  end

  defp run_finalize_probe(_report, _opts, _puts), do: :ok

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
