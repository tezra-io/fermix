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
  alias FermixCore.Auth.CodexLogin
  alias FermixCore.Auth.CodexToken
  alias FermixCore.Auth.TokenManager
  alias FermixCore.Providers.Descriptor
  alias FermixCore.Providers.ModelCatalog
  alias FermixCore.Providers.PrimaryConfig
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.Doctor
  alias FermixCore.Setup.SecretMigration
  alias FermixCore.Setup.Wizard

  # answer key -> owning provider, derived from the descriptor registry —
  # drives both the provided-answer allowlist and prompt-relevance
  # filtering (M12 §6.1).
  @provider_field_owners FermixCore.Providers.Descriptor.all()
                         |> Enum.flat_map(fn descriptor ->
                           Enum.map(descriptor.setup_fields, &{&1.key, descriptor.id})
                         end)
                         |> Map.new()

  @answer_keys Map.keys(@provider_field_owners) ++
                 [
                   :provider,
                   :default_model,
                   :reasoning_effort,
                   :fast,
                   :realtime_enabled,
                   :realtime_api_key,
                   :realtime_voice,
                   :realtime_max_session_minutes,
                   :realtime_max_cost_cents,
                   :realtime_persist_transcripts,
                   :image_backend,
                   :image_model,
                   :google_api_key,
                   :transcription_backend,
                   :transcription_model,
                   :transcription_api_key,
                   :telegram_bot_token,
                   :telegram_owner_user_id,
                   :whatsapp_access_token,
                   :whatsapp_phone_number_id,
                   :whatsapp_verify_token,
                   :whatsapp_app_secret,
                   :whatsapp_owner_user_id,
                   :discord_bot_token,
                   :discord_bot_user_id,
                   :discord_owner_user_id,
                   :slack_bot_token,
                   :slack_signing_secret,
                   :slack_owner_user_id,
                   :signal_account,
                   :signal_owner_user_id
                 ]

  @type puts_fun :: (String.t() -> any())
  @type prompt_fun :: (String.t() -> String.t())
  @type io_opts :: [puts: puts_fun(), prompt: prompt_fun()]

  @spec run(keyword(), io_opts()) :: :ok | {:error, String.t()}
  def run(opts, io_opts \\ []) when is_list(opts) and is_list(io_opts) do
    puts = Keyword.get(io_opts, :puts, &IO.puts/1)
    prompt = Keyword.get(io_opts, :prompt, &default_prompt/1)

    if Keyword.get(opts, :migrate_secrets, false) do
      SecretMigration.run(opts, puts: puts, prompt: prompt)
    else
      with {:ok, report} <- load_report() do
        dispatch(report, opts, puts, prompt)
      end
    end
  end

  defp dispatch(report, opts, puts, prompt) do
    cond do
      Keyword.get(opts, :print_state) ->
        print_report(report, puts)
        :ok

      report.status == :ready and provided_answers(opts) == [] and
        Wizard.prompts(report.wizard) == [] and
        not Keyword.get(opts, :reconfigure, false) and
          not Keyword.get(opts, :import_codex, false) ->
        seed_and_print(report, puts)

      true ->
        with {:ok, extras} <- maybe_import_codex(report, opts, puts, prompt) do
          # Re-fetch the report — the codex import may have satisfied
          # the active provider check, leaving fewer required answers.
          {:ok, refreshed} = load_report()
          save_and_print(refreshed, opts ++ extras, puts, prompt)
        end
    end
  end

  defp maybe_import_codex(report, opts, puts, prompt) do
    cond do
      Keyword.get(opts, :import_codex, false) ->
        run_codex_import(opts, puts)

      not provider_missing?(report) ->
        {:ok, []}

      Keyword.get(opts, :openai_api_key) not in [nil, ""] ->
        {:ok, []}

      selected_provider(opts) not in [nil, :openai_codex] ->
        # The user explicitly chose a non-codex provider (e.g. xai, anthropic).
        # Importing ChatGPT tokens from the Codex CLI is only relevant to
        # `openai_codex`, so don't probe ~/.codex or prompt for it — mirror the
        # `openai_api_key` guard above. (`nil` = no explicit selection yet, e.g.
        # a bare interactive setup or `--import-codex`, which still offers it.)
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
        {:ok, [provider: "openai_codex"]}

      {:error, reason} ->
        {:error, "codex import failed: #{inspect(reason)}"}
    end
  end

  defp provider_missing?(%{failures: failures}) do
    Enum.any?(failures, &(&1.component in ["provider:openai", "provider:openai_codex"]))
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

        with {:ok, authed_report} <- ensure_codex_auth(updated_report, opts, puts) do
          print_report(authed_report, puts)
          run_finalize_probe(authed_report, opts, puts, prompt)
        end

      {:error, reason} ->
        {:error, "failed to save setup snapshot: #{inspect(reason)}"}
    end
  end

  defp ensure_codex_auth(report, opts, puts) do
    cond do
      Keyword.get(opts, :skip_probe, false) ->
        {:ok, report}

      selected_codex_provider?(Keyword.get(opts, :provider)) or active_provider() == :openai_codex ->
        ensure_codex_token(report, opts, puts)

      true ->
        {:ok, report}
    end
  end

  defp ensure_codex_token(report, opts, puts) do
    token_opts =
      []
      |> maybe_put(:fermix_auth_path, Keyword.get(opts, :fermix_auth_path))
      |> maybe_put(:refresh_req_options, Keyword.get(opts, :refresh_req_options))

    case CodexToken.get_token(token_opts) do
      {:ok, _token} ->
        {:ok, report}

      {:error, reason} when reason in [:no_auth_file] ->
        run_codex_login(opts, puts)

      {:error, {:provider_missing, :openai_codex}} ->
        run_codex_login(opts, puts)

      {:error, reason} ->
        {:error, "codex token unavailable: #{inspect(reason)}"}
    end
  end

  defp run_finalize_probe(%{status: :ready}, opts, puts, prompt) do
    if Keyword.get(opts, :skip_probe, false) do
      :ok
    else
      probe_opts = Keyword.take(opts, [:fermix_auth_path, :refresh_req_options, :req_options])

      probe_opts
      |> Doctor.probe_active()
      |> handle_probe_result(probe_opts, opts, puts, prompt)
    end
  end

  defp run_finalize_probe(_report, _opts, _puts, _prompt), do: :ok

  defp handle_probe_result(
         {:ok, %{provider: provider, model: model, latency_ms: ms}},
         _probe_opts,
         _opts,
         puts,
         _prompt
       ) do
    puts.("auth probe: #{provider}/#{model} responded in #{ms}ms")
    :ok
  end

  defp handle_probe_result(
         {:error, {:auth_scope_mismatch, surface, hint}},
         probe_opts,
         opts,
         puts,
         prompt
       ) do
    recover_codex_probe(surface, hint, probe_opts, opts, puts, prompt)
  end

  defp handle_probe_result({:error, {:misconfigured, message}}, _probe_opts, _opts, puts, _prompt) do
    handle_misconfigured_probe(message, puts)
  end

  defp handle_probe_result(
         {:error, {:server_error, status, _body}},
         _probe_opts,
         _opts,
         puts,
         _prompt
       ) do
    puts.("auth probe inconclusive: provider returned HTTP #{status}")
    :ok
  end

  defp handle_probe_result({:error, {:network, reason}}, _probe_opts, _opts, puts, _prompt) do
    puts.("auth probe inconclusive: network error #{inspect(reason)}")
    :ok
  end

  defp handle_misconfigured_probe(message, puts) do
    case active_provider() do
      :openai_codex ->
        {:error, "auth probe failed: #{message}"}

      _provider ->
        puts.("auth probe skipped: #{message}")
        :ok
    end
  end

  defp recover_codex_probe(surface, hint, probe_opts, opts, puts, prompt) do
    case active_provider() do
      :openai_codex ->
        prompt
        |> ask_codex_recovery?()
        |> continue_codex_recovery(surface, hint, probe_opts, opts, puts)

      _provider ->
        {:error, "auth probe failed for #{surface}: #{hint}"}
    end
  end

  defp ask_codex_recovery?(prompt) do
    ask_yes_no(prompt, "Codex OAuth token rejected. Start ChatGPT OAuth login now? [Y/n]: ", true)
  end

  defp continue_codex_recovery(true, surface, hint, probe_opts, opts, puts) do
    puts.("Codex OAuth token rejected; starting ChatGPT OAuth login.")

    with {:ok, _report} <- run_codex_login(opts, puts) do
      rerun_codex_probe(probe_opts, surface, hint, puts)
    end
  end

  defp continue_codex_recovery(false, surface, hint, _probe_opts, _opts, _puts) do
    {:error, "auth probe failed for #{surface}: #{hint}"}
  end

  defp rerun_codex_probe(probe_opts, surface, hint, puts) do
    case Doctor.probe_active(probe_opts) do
      {:ok, %{provider: provider, model: model, latency_ms: ms}} ->
        puts.("auth probe: #{provider}/#{model} responded in #{ms}ms")
        :ok

      {:error, {:auth_scope_mismatch, _surface, _hint}} ->
        {:error, "auth probe failed for #{surface}: #{hint}"}

      {:error, reason} ->
        {:error, "auth probe failed after Codex OAuth login: #{inspect(reason)}"}
    end
  end

  defp run_codex_login(opts, puts) do
    puts.("Opening ChatGPT OAuth login for openai_codex.")

    login_opts =
      []
      |> maybe_put(:fermix_auth_path, Keyword.get(opts, :fermix_auth_path))
      |> maybe_put(:no_browser, Keyword.get(opts, :no_browser))
      |> maybe_put(:oauth_opener, Keyword.get(opts, :oauth_opener))
      |> maybe_put(:oauth_port, Keyword.get(opts, :oauth_port) || Keyword.get(opts, :port))
      |> maybe_put(:oauth_timeout_ms, Keyword.get(opts, :oauth_timeout_ms))
      |> maybe_put(:timeout, Keyword.get(opts, :timeout))
      |> maybe_put(:oauth_req_options, Keyword.get(opts, :oauth_req_options))
      |> Keyword.put(:puts, puts)

    case CodexLogin.login(login_opts) do
      {:ok, _entry} ->
        puts.("Stored ChatGPT OAuth credentials for openai_codex.")

        with :ok <- reload_token_manager_if_running() do
          load_report()
        end

      {:error, reason} ->
        {:error, "codex oauth login failed: #{inspect(reason)}"}
    end
  end

  # The supervised TokenManager (started when provider is :openai_codex)
  # caches the loaded access token in memory. After a fresh OAuth login
  # writes new tokens to disk, push them into the GenServer so the
  # finalize probe — and any subsequent provider call — sees the new
  # credentials instead of the rejected ones.
  defp reload_token_manager_if_running do
    case Process.whereis(TokenManager) do
      nil ->
        :ok

      _pid ->
        case TokenManager.reload(TokenManager) do
          {:ok, _token} -> :ok
          {:error, reason} -> {:error, "token manager reload failed: #{inspect(reason)}"}
        end
    end
  end

  defp selected_codex_provider?(:openai_codex), do: true
  defp selected_codex_provider?("openai_codex"), do: true
  defp selected_codex_provider?(_provider), do: false

  # Reads the chosen provider through PrimaryConfig (primary flag, else the
  # legacy agent.provider migration input). Multiple primaries fall through
  # to :openai here — setup is the repair surface and must keep running;
  # routing and readiness fail loud on it.
  defp active_provider do
    case PrimaryConfig.primary() do
      {:ok, provider} -> provider
      {:error, :multiple_primary} -> :openai
    end
  end

  defp collect_answers(report, opts, prompt) do
    provided = opts |> provided_answers() |> default_codex_fast()

    collect_answers(report, opts, prompt, provided, MapSet.new())
  end

  defp default_codex_fast(answers) do
    if Keyword.get(answers, :fast) == nil and selected_provider(answers) == :openai_codex do
      Keyword.put(answers, :fast, false)
    else
      answers
    end
  end

  defp collect_answers(report, opts, prompt, answers, seen_keys) do
    {answers, seen_keys, asked?} =
      Enum.reduce(prompt_plan(report, opts, answers), {answers, seen_keys, false}, fn
        prompt_info, {answers, seen_keys, false} ->
          prompt_info = prompt_for_answers(prompt_info, answers)

          cond do
            MapSet.member?(seen_keys, prompt_info.key) ->
              {answers, seen_keys, false}

            answered?(answers, prompt_info.key) ->
              {answers, MapSet.put(seen_keys, prompt_info.key), false}

            irrelevant_prompt?(prompt_info, answers) ->
              {answers, MapSet.put(seen_keys, prompt_info.key), false}

            true ->
              {answers ++ interactive_answer(prompt_info, prompt),
               MapSet.put(seen_keys, prompt_info.key), true}
          end

        _prompt_info, acc ->
          acc
      end)

    if asked? do
      collect_answers(report, opts, prompt, answers, seen_keys)
    else
      answers
    end
  end

  defp prompt_plan(report, opts, answers) do
    if Keyword.get(opts, :reconfigure, false) do
      Wizard.reconfigure_prompts(report.wizard, answers)
    else
      Wizard.prompts(report.wizard, answers)
    end
  end

  defp interactive_answer(%{key: key, label: label, default: default}, prompt) do
    value = label |> prompt.() |> to_string() |> String.trim()
    if value == "", do: [{key, default}], else: [{key, value}]
  end

  defp interactive_answer(%{key: key, label: label}, prompt) do
    value = label |> prompt.() |> to_string() |> String.trim()
    if value == "", do: [], else: [{key, value}]
  end

  defp answered?(answers, key), do: Keyword.get(answers, key) not in [nil, ""]

  defp irrelevant_prompt?(%{key: :reasoning_effort}, answers) do
    case selected_provider(answers) do
      nil ->
        false

      provider ->
        case Descriptor.fetch(provider) do
          {:ok, descriptor} -> descriptor.effort? == false
          :error -> false
        end
    end
  end

  defp irrelevant_prompt?(%{key: :fast}, answers) do
    selected_provider(answers) not in [nil, :openai_codex]
  end

  defp irrelevant_prompt?(%{key: :realtime_api_key}, answers) do
    realtime_enabled_answer(answers) == false or selected_provider(answers) == :openai
  end

  defp irrelevant_prompt?(%{key: key}, answers)
       when key in [
              :realtime_voice,
              :realtime_max_session_minutes,
              :realtime_max_cost_cents,
              :realtime_persist_transcripts
            ] do
    realtime_enabled_answer(answers) == false
  end

  # A provider field prompt is relevant only while its provider is the
  # selection (or no provider was chosen yet) — one clause instead of the
  # old N×(N−1) exclusion matrix ("the eighth list", M12 §6.1).
  defp irrelevant_prompt?(%{key: key}, answers) do
    case Map.fetch(@provider_field_owners, key) do
      {:ok, owner} -> selected_provider(answers) not in [nil, owner]
      :error -> false
    end
  end

  defp prompt_for_answers(%{key: :default_model} = prompt_info, answers) do
    case selected_provider(answers) do
      nil ->
        prompt_info

      provider ->
        default = ModelCatalog.default_model_for(provider)
        %{prompt_info | label: "Default model (blank = #{default})", default: default}
    end
  end

  defp prompt_for_answers(prompt_info, _answers), do: prompt_info

  defp selected_provider(answers) do
    case Keyword.get(answers, :provider) do
      provider when is_atom(provider) and not is_nil(provider) ->
        if provider in Descriptor.ids(), do: provider

      provider when is_binary(provider) ->
        Enum.find(Descriptor.ids(), &(Atom.to_string(&1) == provider))

      _value ->
        nil
    end
  end

  defp realtime_enabled_answer(answers) do
    case Keyword.get(answers, :realtime_enabled) do
      value when value in [true, "true", "TRUE", "1", "yes", "y"] -> true
      value when value in [false, "false", "FALSE", "0", "no", "n"] -> false
      _value -> nil
    end
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
