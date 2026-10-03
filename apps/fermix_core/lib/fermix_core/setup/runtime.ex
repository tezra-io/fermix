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

  alias FermixCore.Auth.ChatGPT
  alias FermixCore.Auth.ChatGPT.TerminalLogin
  alias FermixCore.Providers.Descriptor
  alias FermixCore.Providers.ModelCatalog
  alias FermixCore.Providers.PrimaryConfig
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.Doctor
  alias FermixCore.Setup.LiveModel
  alias FermixCore.Setup.SecretMigration
  alias FermixCore.Setup.SecretWriter
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
                   :realtime_enabled,
                   :realtime_api_key,
                   :realtime_model,
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
                   :signal_owner_user_id,
                   :acp_enabled,
                   :proxy,
                   :proxy_bypass,
                   :secret_store
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
          not Keyword.get(opts, :reconfigure, false) ->
        seed_and_print(report, puts)

      true ->
        with {:ok, opts} <- maybe_choose_file_store(report, opts, puts, prompt) do
          # Re-fetch the report: choosing the file store may have saved an answer.
          {:ok, refreshed} = load_report()
          save_and_print(refreshed, opts, puts, prompt)
        end
    end
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

      # A save that could not store a credential already carries the daemon's
      # own sentence (design §7.4); the operator sees that rather than an
      # inspected tuple naming an internal key. When the keyring is what
      # refused, the terminal wizard is the place the file store is offered.
      {:error, {:secret_store_failed, _key, sentence}} when is_binary(sentence) ->
        offer_file_store(report, opts, answers, sentence, puts, prompt)

      {:error, reason} ->
        {:error, "failed to save setup snapshot: #{inspect(reason)}"}
    end
  end

  # The keyring cannot hold this save's secrets, and nothing chose the file
  # store yet: ask once, in the operator's terminal, and record the answer as
  # `[fermix_core] secret_store` before the same answers are saved again. A no
  # leaves the refusal exactly as the save gave it. A save that already named
  # a store, or a store other than the keyring, is not asked.
  defp offer_file_store(report, opts, answers, sentence, puts, prompt) do
    verdict = SecretWriter.probe()

    cond do
      Keyword.has_key?(opts, :secret_store) or verdict.store != :keyring ->
        {:error, sentence}

      SecretWriter.usable?(verdict) ->
        {:error, sentence}

      not consents_to_file_store?(prompt, puts, sentence) ->
        {:error, sentence}

      true ->
        save_in_file_store(report, opts, answers, puts, prompt)
    end
  end

  # The answers already collected ride back in as provided options, so the
  # second save asks nothing again; a second refusal is reported as itself.
  defp save_in_file_store(report, opts, answers, puts, prompt) do
    retry_opts = opts |> Keyword.put(:secret_store, "file") |> Keyword.merge(answers)

    with {:ok, _chosen} <- Wizard.save_answers(report.wizard, secret_store: "file"),
         {:ok, refreshed} <- load_report() do
      save_and_print(refreshed, retry_opts, puts, prompt)
    else
      {:error, {:secret_store_failed, _key, sentence}} when is_binary(sentence) ->
        {:error, sentence}

      {:error, reason} ->
        {:error, "failed to switch the secret store: #{inspect(reason)}"}
    end
  end

  defp consents_to_file_store?(prompt, puts, sentence) do
    puts.(sentence)
    puts.(file_store_explanation())
    ask_yes_no(prompt, "Store secrets in that folder from now on? [y/N]: ", false)
  end

  # A host with no display cannot unlock or create a keyring, so when the
  # keyring cannot be used the store is chosen before any answer it would
  # refuse, and the file store is the default (owner decision 2026-10-02). A
  # yes records `secret_store = "file"`; a no keeps the keyring, and the save's
  # refusal does not ask again. A desktop, an explicit `--secret-store`, a
  # store already set to file, or a keyring that answers asks nothing here.
  defp maybe_choose_file_store(report, opts, puts, prompt) do
    cond do
      Keyword.get(opts, :display?, true) -> {:ok, opts}
      Keyword.has_key?(opts, :secret_store) -> {:ok, opts}
      SecretWriter.store() != :keyring -> {:ok, opts}
      true -> choose_store_without_keyring(report, opts, SecretWriter.probe(), puts, prompt)
    end
  end

  defp choose_store_without_keyring(report, opts, verdict, puts, prompt) do
    cond do
      SecretWriter.usable?(verdict) ->
        {:ok, opts}

      consents_to_headless_file_store?(prompt, puts, verdict) ->
        record_file_store(report, opts, puts)

      true ->
        {:ok, Keyword.put(opts, :secret_store, "keyring")}
    end
  end

  defp consents_to_headless_file_store?(prompt, puts, verdict) do
    reason = String.trim_trailing(verdict.sentence, ".")
    puts.("This machine has no display, and its keyring cannot be used: #{reason}.")
    puts.(file_store_explanation())
    ask_yes_no(prompt, "Store secrets in that folder? [Y/n]", true)
  end

  defp record_file_store(report, opts, puts) do
    case Wizard.save_answers(report.wizard, secret_store: "file") do
      {:ok, saved} ->
        puts.(~s(Recorded secret_store = "file" in #{saved.config_path}.))
        {:ok, opts}

      {:error, {:secret_store_failed, _key, sentence}} when is_binary(sentence) ->
        {:error, sentence}

      {:error, reason} ->
        {:error, "failed to record the file store: #{inspect(reason)}"}
    end
  end

  defp file_store_explanation do
    "Fermix can keep secrets in files under #{ConfigStore.fermix_home()}/secrets instead: " <>
      "readable only by your account, not encrypted at rest, and named by `fermix doctor`."
  end

  defp ensure_codex_auth(report, opts, puts) do
    cond do
      Keyword.get(opts, :skip_probe, false) ->
        {:ok, report}

      selected_codex_provider?(Keyword.get(opts, :provider)) or active_provider() == :openai_codex ->
        ensure_chatgpt_sign_in(report, opts, puts)

      true ->
        {:ok, report}
    end
  end

  # `openai_codex` signs in with ChatGPT. A registration the route can use is
  # kept; every other standing (none, plan usage off, a grant to renew) is what
  # a sign-in fixes.
  defp ensure_chatgpt_sign_in(report, opts, puts) do
    status_opts = maybe_put([], :fermix_path, Keyword.get(opts, :fermix_auth_path))

    case ChatGPT.route_status(status_opts) do
      :ok -> {:ok, report}
      {:error, _not_usable} -> run_chatgpt_login(opts, puts)
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
    ask_yes_no(prompt, "The ChatGPT sign-in was rejected. Sign in again now? [Y/n]: ", true)
  end

  defp continue_codex_recovery(true, surface, hint, probe_opts, opts, puts) do
    puts.("The ChatGPT sign-in was rejected; signing in again.")

    with {:ok, _report} <- run_chatgpt_login(opts, puts) do
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
        {:error, "auth probe failed after the ChatGPT sign-in: #{inspect(reason)}"}
    end
  end

  # The terminal's ChatGPT sign-in, shared with `fermix auth login`: it also
  # takes the address a browser on another computer ended on, pasted here. A
  # sign-in stops the `chatgpt` token manager, so the probe after it loads the
  # new grant. A grant without plan usage is one the route refuses.
  defp run_chatgpt_login(opts, puts) do
    puts.("Signing in with ChatGPT for openai_codex.")

    case TerminalLogin.run(terminal_login_opts(opts, puts)) do
      {:ok, %{plan_usage: :on, account: account}} ->
        puts.("Signed in to ChatGPT#{if account, do: " as #{account}"}.")
        :ok = ensure_live_model(opts, puts)
        load_report()

      {:ok, %{plan_usage: :off}} ->
        {:error, ChatGPT.failure_sentence(:plan_usage_off)}

      {:error, reason} ->
        {:error, ChatGPT.failure_sentence(reason)}
    end
  end

  # `:chatgpt_login`, `:read_line` and `:browser` are test seams.
  defp terminal_login_opts(opts, puts) do
    []
    |> maybe_put(:fermix_path, Keyword.get(opts, :fermix_auth_path))
    |> maybe_put(:no_browser, Keyword.get(opts, :no_browser))
    |> maybe_put(:port, Keyword.get(opts, :port))
    |> maybe_put(:timeout_ms, timeout_ms(Keyword.get(opts, :timeout)))
    |> maybe_put(:login, Keyword.get(opts, :chatgpt_login))
    |> maybe_put(:read_line, Keyword.get(opts, :read_line))
    |> maybe_put(:browser, Keyword.get(opts, :browser))
    |> Keyword.put(:puts, puts)
  end

  defp timeout_ms(seconds) when is_integer(seconds) and seconds > 0, do: seconds * 1_000
  defp timeout_ms(_unset), do: nil

  # The configured model must be one the account lists (`Setup.LiveModel`). A
  # listing that fails leaves the model as it is and says so; the sign-in stands.
  defp ensure_live_model(opts, puts) do
    ensure = Keyword.get(opts, :live_model, &LiveModel.ensure/2)

    case ensure.(:openai_codex, []) do
      {:ok, %{model: model, changed?: true}} ->
        puts.("Default model set to #{model}, the first one your ChatGPT account lists.")

      {:ok, %{changed?: false}} ->
        :ok

      {:error, sentence} ->
        puts.("The default model was not checked against your ChatGPT account. #{sentence}")
    end

    :ok
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
    collect_answers(report, opts, prompt, provided_answers(opts), MapSet.new())
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
