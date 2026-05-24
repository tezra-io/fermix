defmodule FermixCore.Setup.Wizard do
  @moduledoc """
  Shared setup/readiness surface for CLI and web onboarding.
  """

  alias FermixCore.Memory.CompactionConfig
  alias FermixCore.Prompt.SetupSeeder
  alias FermixCore.Providers.ModelCatalog
  alias FermixCore.Providers.ReasoningEffort
  alias FermixCore.Readiness
  alias FermixCore.Realtime.Config, as: RealtimeConfig
  alias FermixCore.Sandbox.Config, as: SandboxConfig
  alias FermixCore.Setup.BootReport
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.SecretPaths
  alias FermixCore.Setup.SecretWriter
  alias FermixCore.Setup.WizardState

  require Logger

  @type provider :: ModelCatalog.provider()
  @type reasoning_effort :: :none | :low | :medium | :high | :xhigh | :max

  @type answer ::
          {:openai_api_key, String.t()}
          | {:provider, provider() | String.t()}
          | {:default_model, String.t()}
          | {:reasoning_effort, reasoning_effort() | String.t()}
          | {:compaction_threshold, float() | String.t()}
          | {:extraction_timeout_ms, pos_integer() | String.t()}
          | {:realtime_enabled, boolean() | String.t()}
          | {:realtime_api_key, String.t()}
          | {:realtime_voice, String.t()}
          | {:realtime_max_session_minutes, pos_integer() | String.t()}
          | {:realtime_max_cost_cents, pos_integer() | String.t()}
          | {:realtime_persist_transcripts, boolean() | String.t()}
          | {:web_search_backend, atom() | String.t()}
          | {:tavily_api_key, String.t()}
          | {:exa_api_key, String.t()}
          | {:parallel_api_key, String.t()}
          | {:brave_api_key, String.t()}
          | {:perplexity_api_key, String.t()}
          | {:telegram_bot_token, String.t()}
          | {:telegram_owner_user_id, String.t()}
          | {:whatsapp_access_token, String.t()}
          | {:whatsapp_phone_number_id, String.t()}
          | {:whatsapp_verify_token, String.t()}
          | {:whatsapp_app_secret, String.t()}
          | {:whatsapp_owner_user_id, String.t()}
          | {:discord_bot_token, String.t()}
          | {:discord_bot_user_id, String.t()}
          | {:discord_owner_user_id, String.t()}
          | {:slack_bot_token, String.t()}
          | {:slack_signing_secret, String.t()}
          | {:slack_owner_user_id, String.t()}
          | {:signal_account, String.t()}
          | {:signal_owner_user_id, String.t()}
          | {:user_name, String.t()}
          | {:timezone, String.t()}
          | {:communication_style, String.t()}

  @setup_secret_paths SecretPaths.by_answer_key()

  @realtime_true_values ~w(true yes y 1)
  @realtime_false_values ~w(false no n 0)
  @realtime_followup_prompt_keys [
    :realtime_api_key,
    :realtime_voice,
    :realtime_max_session_minutes,
    :realtime_max_cost_cents
  ]
  @realtime_advanced_prompt_keys [
    :realtime_persist_transcripts
  ]
  @reconfigure_prompt_keys [
    :provider,
    :default_model,
    :reasoning_effort,
    :realtime_enabled
  ]

  @channel_owner_reconfigure_keys %{
    telegram_owner_user_id: :telegram,
    whatsapp_owner_user_id: :whatsapp,
    discord_owner_user_id: :discord,
    slack_owner_user_id: :slack,
    signal_owner_user_id: :signal
  }

  @type seeding_result :: %{
          name: :identity | :fermix | :soul | :realtime | :user | :memory,
          path: String.t(),
          outcome: :seeded | :skipped_exists | :seeded_uncommitted
        }

  @type report :: %{
          status: Readiness.status(),
          failures: [Readiness.failure()],
          wizard: WizardState.t(),
          config_path: String.t(),
          restart_required?: boolean(),
          seeding_results: [seeding_result()]
        }

  @spec report() :: report()
  def report, do: report([])

  @spec report([seeding_result()]) :: report()
  def report(seeding_results) when is_list(seeding_results) do
    readiness = Readiness.report()
    snapshot = ConfigStore.current_snapshot()

    %{
      status: readiness.status,
      failures: readiness.failures,
      wizard: build_state(snapshot, readiness),
      config_path: ConfigStore.path(),
      restart_required?: restart_required?(snapshot),
      seeding_results: seeding_results
    }
  end

  @spec prompts(WizardState.t()) :: [map()]
  def prompts(%WizardState{} = state), do: prompts(state, [])

  @spec prompts(WizardState.t(), [answer()]) :: [map()]
  def prompts(%WizardState{} = state, answers) when is_list(answers) do
    specs = prompt_specs(state)

    Enum.filter(specs, fn prompt ->
      cond do
        prompt.key in @realtime_followup_prompt_keys ->
          realtime_setup_followup?(prompt, specs, answers)

        prompt.key in @realtime_advanced_prompt_keys ->
          false

        true ->
          prompt.required?
      end
    end)
  end

  @spec reconfigure_prompts(WizardState.t()) :: [map()]
  def reconfigure_prompts(%WizardState{} = state), do: reconfigure_prompts(state, [])

  @spec reconfigure_prompts(WizardState.t(), [answer()]) :: [map()]
  def reconfigure_prompts(%WizardState{} = state, answers) when is_list(answers) do
    specs = prompt_specs(state)
    persisted = persisted_snapshot()

    specs
    |> Enum.filter(fn prompt ->
      (prompt.key in @reconfigure_prompt_keys and reconfigure_offered?(prompt, persisted)) or
        realtime_reconfigure_followup?(prompt, answers) or
        channel_owner_reconfigure?(prompt, persisted)
    end)
    |> Enum.map(&Map.put(&1, :required?, true))
  end

  # reasoning_effort is only wired for OpenAI/Codex (`put_reasoning_effort/2`
  # rejects other providers and the Anthropic adapter doesn't send it yet), so
  # don't offer it on reconfigure for a provider that can't persist or use it.
  defp reconfigure_offered?(%{key: :reasoning_effort}, persisted) do
    persisted_provider(persisted) in [:openai, :openai_codex]
  end

  defp reconfigure_offered?(_prompt, _persisted), do: true

  defp prompt_specs(%WizardState{} = state) do
    # Channel-secret prompts read from the persisted TOML snapshot rather than
    # the merged Application env. A token surfaced only via env vars (e.g. the
    # operator's shell) would satisfy readiness during `fermix setup` but
    # vanish in the launchd-spawned daemon, which inherits no shell env. Asking
    # for the token whenever it is unpersisted forces it onto disk where the
    # daemon will see it.
    persisted = persisted_snapshot()
    persisted_provider = persisted_provider(persisted)

    prompt_provider =
      persisted_provider || valid_provider(configured_provider(state.config_snapshot)) || :openai

    context = prompt_context(state, persisted, persisted_provider, prompt_provider)

    provider_prompts(context) ++
      compaction_prompts(context) ++
      realtime_prompts(context) ++
      channel_prompts(context) ++
      personalization_prompts(context)
  end

  defp prompt_context(state, persisted, persisted_provider, prompt_provider) do
    provider_unset? = persisted_provider == nil
    provider_block = provider_config(persisted, prompt_provider)
    model_unset? = provider_unset? or blank?(Keyword.get(provider_block, :default_model))
    effort_unset? = provider_unset? or blank?(Keyword.get(provider_block, :reasoning_effort))
    openai_api_key_unset? = openai_api_key_unpersisted?(persisted, persisted_provider)
    realtime_api_key_unset? = canonical_openai_api_key_unpersisted?(persisted)
    default_model = ModelCatalog.default_model_for(prompt_provider)

    %{
      state: state,
      persisted: persisted,
      prompt_provider: prompt_provider,
      provider_unset?: provider_unset?,
      model_unset?: model_unset?,
      effort_unset?: effort_unset?,
      openai_api_key_unset?: openai_api_key_unset?,
      realtime_api_key_unset?: realtime_api_key_unset?,
      realtime_unconfigured?: not ConfigStore.realtime_configured?(),
      default_model: default_model
    }
  end

  defp provider_prompts(context) do
    [
      %{
        key: :provider,
        label:
          "Provider (#{Enum.map_join(ModelCatalog.providers(), "/", &Atom.to_string/1)}; blank = #{context.prompt_provider})",
        default: context.prompt_provider,
        required?: context.provider_unset?
      },
      %{
        key: :openai_api_key,
        label: "OpenAI API key",
        required?:
          missing_component?(context.state, "provider:openai") or context.openai_api_key_unset?
      },
      %{
        key: :default_model,
        label: "Default model (blank = #{context.default_model})",
        default: context.default_model,
        required?: context.model_unset?
      },
      %{
        key: :reasoning_effort,
        label:
          "Reasoning effort (#{Enum.map_join(ReasoningEffort.levels_for(context.prompt_provider), "/", &Atom.to_string/1)}; blank = high)",
        default: :high,
        required?:
          (context.provider_unset? or context.prompt_provider in [:openai, :openai_codex]) and
            context.effort_unset?
      }
    ]
  end

  defp channel_prompts(%{persisted: persisted}) do
    [
      %{
        key: :telegram_bot_token,
        label: "Telegram bot token",
        required?: channel_field_unpersisted?(persisted, :telegram, :bot_token, true)
      },
      %{
        key: :telegram_owner_user_id,
        label: "Telegram command owner user ID",
        required?: channel_field_unpersisted?(persisted, :telegram, :owner_user_id, true)
      },
      %{
        key: :whatsapp_access_token,
        label: "WhatsApp access token",
        required?: channel_field_unpersisted?(persisted, :whatsapp, :access_token, false)
      },
      %{
        key: :whatsapp_phone_number_id,
        label: "WhatsApp phone number ID",
        required?: channel_field_unpersisted?(persisted, :whatsapp, :phone_number_id, false)
      },
      %{
        key: :whatsapp_verify_token,
        label: "WhatsApp verify token",
        required?: channel_field_unpersisted?(persisted, :whatsapp, :verify_token, false)
      },
      %{
        key: :whatsapp_app_secret,
        label: "WhatsApp app secret",
        required?: channel_field_unpersisted?(persisted, :whatsapp, :app_secret, false)
      },
      %{
        key: :whatsapp_owner_user_id,
        label: "WhatsApp command owner user ID",
        required?: channel_field_unpersisted?(persisted, :whatsapp, :owner_user_id, false)
      },
      %{
        key: :discord_bot_token,
        label: "Discord bot token",
        required?: channel_field_unpersisted?(persisted, :discord, :bot_token, false)
      },
      %{
        key: :discord_bot_user_id,
        label: "Discord bot user ID",
        required?: channel_field_unpersisted?(persisted, :discord, :bot_user_id, false)
      },
      %{
        key: :discord_owner_user_id,
        label: "Discord command owner user ID",
        required?: channel_field_unpersisted?(persisted, :discord, :owner_user_id, false)
      },
      %{
        key: :slack_bot_token,
        label: "Slack bot token",
        required?: channel_field_unpersisted?(persisted, :slack, :bot_token, false)
      },
      %{
        key: :slack_signing_secret,
        label: "Slack signing secret",
        required?: channel_field_unpersisted?(persisted, :slack, :signing_secret, false)
      },
      %{
        key: :slack_owner_user_id,
        label: "Slack command owner user ID",
        required?: channel_field_unpersisted?(persisted, :slack, :owner_user_id, false)
      },
      %{
        key: :signal_account,
        label: "Signal account",
        required?: channel_field_unpersisted?(persisted, :signal, :account, false)
      },
      %{
        key: :signal_owner_user_id,
        label: "Signal command owner user ID",
        required?: channel_field_unpersisted?(persisted, :signal, :owner_user_id, false)
      }
    ]
  end

  defp compaction_prompts(_context) do
    [
      %{
        key: :compaction_threshold,
        label: "Compaction threshold (blank = 0.85)",
        default: 0.85,
        required?: false
      },
      %{
        key: :extraction_timeout_ms,
        label: "Background extraction timeout in milliseconds (blank = 90000)",
        default: 90_000,
        required?: false
      }
    ]
  end

  defp realtime_prompts(%{
         persisted: persisted,
         realtime_api_key_unset?: realtime_api_key_unset?,
         realtime_unconfigured?: realtime_unconfigured?
       }) do
    config =
      persisted
      |> Map.get(:fermix_core, [])
      |> Keyword.get(:realtime, [])
      |> RealtimeConfig.normalize()

    [
      %{
        key: :realtime_enabled,
        label: "Enable local voice companion? (yes/no; blank = #{yes_no(config.enabled?)})",
        default: config.enabled?,
        required?: realtime_unconfigured?
      },
      %{
        key: :realtime_api_key,
        label: realtime_api_key_label(realtime_api_key_unset?),
        required?: realtime_api_key_unset?
      },
      %{
        key: :realtime_voice,
        label: "Realtime voice (blank = #{config.voice})",
        default: config.voice,
        required?: false
      },
      %{
        key: :realtime_max_session_minutes,
        label: "Realtime max session minutes (blank = #{config.max_session_minutes})",
        default: config.max_session_minutes,
        required?: false
      },
      %{
        key: :realtime_max_cost_cents,
        label:
          "Realtime max estimated cost cents per session (blank = #{config.max_estimated_cost_cents_per_session})",
        default: config.max_estimated_cost_cents_per_session,
        required?: false
      },
      %{
        key: :realtime_persist_transcripts,
        label:
          "Save voice transcripts locally? (yes/no; blank = #{yes_no(config.persist_transcripts?)})",
        default: config.persist_transcripts?,
        required?: false
      }
    ]
  end

  defp yes_no(true), do: "yes"
  defp yes_no(false), do: "no"

  defp realtime_api_key_label(true),
    do: "OpenAI API key for Realtime (only OpenAI is supported in V1)"

  defp realtime_api_key_label(false),
    do: "OpenAI API key for Realtime (blank = use the existing OpenAI provider key)"

  defp realtime_setup_followup?(%{key: :realtime_api_key, required?: required?}, specs, answers) do
    required? and realtime_resolves_enabled?(specs, answers)
  end

  defp realtime_setup_followup?(%{key: key}, _specs, answers)
       when key in [:realtime_voice, :realtime_max_session_minutes, :realtime_max_cost_cents] do
    realtime_enabled_answer(answers) == true
  end

  defp realtime_setup_followup?(_prompt, _specs, _answers), do: false

  defp realtime_reconfigure_followup?(%{key: :realtime_api_key, required?: required?}, answers) do
    required? and realtime_enabled_answer(answers) == true
  end

  defp realtime_reconfigure_followup?(%{key: key}, answers)
       when key in [:realtime_voice, :realtime_max_session_minutes, :realtime_max_cost_cents] do
    realtime_enabled_answer(answers) == true
  end

  defp realtime_reconfigure_followup?(_prompt, _answers), do: false

  defp channel_owner_reconfigure?(%{key: key}, persisted) do
    case Map.fetch(@channel_owner_reconfigure_keys, key) do
      {:ok, channel} -> channel_enabled_in_persisted?(persisted, channel)
      :error -> false
    end
  end

  defp channel_enabled_in_persisted?(persisted, channel) do
    config =
      persisted
      |> Map.get(:fermix_channels, [])
      |> Keyword.get(channel, [])

    Keyword.get(config, :enabled, default_channel_enabled?(channel)) == true
  end

  defp default_channel_enabled?(:telegram), do: true
  defp default_channel_enabled?(_other), do: false

  defp realtime_resolves_enabled?(specs, answers) do
    case realtime_enabled_answer(answers) do
      value when is_boolean(value) ->
        value

      nil ->
        specs
        |> Enum.find(&(&1.key == :realtime_enabled))
        |> case do
          %{default: value} when is_boolean(value) -> value
          _prompt -> false
        end
    end
  end

  defp realtime_enabled_answer(answers) do
    case Keyword.get(answers, :realtime_enabled) do
      value when is_boolean(value) ->
        value

      value when is_binary(value) ->
        normalized = value |> String.trim() |> String.downcase()

        cond do
          normalized in @realtime_true_values -> true
          normalized in @realtime_false_values -> false
          true -> nil
        end

      _value ->
        nil
    end
  end

  defp personalization_prompts(%{state: state}) do
    [
      %{
        key: :user_name,
        label: "Your name",
        required?: missing_component?(state, "personalization")
      },
      %{
        key: :timezone,
        label: "Your timezone (e.g. America/Los_Angeles)",
        required?: missing_component?(state, "personalization")
      },
      %{
        key: :communication_style,
        label: "Preferred communication style (e.g. concise and direct)",
        required?: missing_component?(state, "personalization")
      }
    ]
  end

  @spec save_answers(WizardState.t(), [answer()]) :: {:ok, report()} | {:error, term()}
  def save_answers(%WizardState{} = state, answers) do
    snapshot =
      state.config_snapshot
      |> drop_unanswered_env_only_secrets(answers)
      |> put_openai_api_key(Keyword.get(answers, :openai_api_key))
      |> put_openai_api_key(Keyword.get(answers, :realtime_api_key))
      |> put_provider_selection(Keyword.get(answers, :provider))
      |> put_default_model(Keyword.get(answers, :default_model))
      |> put_reasoning_effort(Keyword.get(answers, :reasoning_effort))
      |> put_compaction_config(answers)
      |> put_memory_config(answers)
      |> put_realtime_config(answers)
      |> put_web_search_config(answers)
      |> put_telegram_bot_token(Keyword.get(answers, :telegram_bot_token))
      |> put_whatsapp_config(answers)
      |> put_discord_config(answers)
      |> put_slack_config(answers)
      |> put_signal_config(answers)
      |> put_channel_owner_user_ids(answers)
      |> put_personalization(answers)
      |> ensure_sandbox_env_sources(answers)

    commit_snapshot(snapshot)
  end

  @type sandbox_mode :: :strict | :standard | :open
  @type sandbox_profile :: :bare | :assistant | :extended

  @doc """
  Mutates sandbox mode, command profile, and env allowlist without going
  through the prompt-driven `save_answers/2` path. Each argument is
  optional — pass `nil` to leave the existing value untouched.

  Used by the LiveView Sandbox tab so a per-tab save persists only the
  sandbox keys. Routes through the same save → apply → seed → report
  cycle as `save_answers/2`.
  """
  @spec set_sandbox_overrides(
          sandbox_mode() | nil,
          sandbox_profile() | nil,
          [String.t()] | nil
        ) :: {:ok, report()} | {:error, term()}
  def set_sandbox_overrides(mode, profile, allow)
      when mode in [nil, :strict, :standard, :open] and
             profile in [nil, :bare, :assistant, :extended] and
             (is_nil(allow) or is_list(allow)) do
    snapshot = ConfigStore.current_snapshot()

    sandbox =
      snapshot
      |> Map.get(:sandbox)
      |> SandboxConfig.normalize()
      |> maybe_put_sandbox_mode(mode)
      |> maybe_put_sandbox_profile(profile)
      |> maybe_put_sandbox_allow(allow)

    # Strip env-only secrets so a sandbox-only update does not persist
    # OS-env-overlaid values (e.g. OPENAI_API_KEY from the shell) to TOML
    # as plaintext. Anything already in the persisted TOML stays put.
    snapshot
    |> Map.put(:sandbox, sandbox)
    |> drop_unanswered_env_only_secrets([])
    |> commit_snapshot()
  end

  defp commit_snapshot(snapshot) do
    with :ok <- ConfigStore.save_snapshot(snapshot),
         :ok <- ConfigStore.apply_snapshot(snapshot),
         {:ok, seeding_results} <- maybe_seed_prompt_files(snapshot) do
      {:ok, BootReport.refresh_if_started(seeding_results) || report(seeding_results)}
    end
  end

  defp maybe_put_sandbox_mode(sandbox, nil), do: sandbox
  defp maybe_put_sandbox_mode(sandbox, mode), do: %{sandbox | mode: mode}

  defp maybe_put_sandbox_profile(sandbox, nil), do: sandbox

  defp maybe_put_sandbox_profile(sandbox, profile) do
    %{sandbox | commands: Map.put(sandbox.commands, :profile, profile)}
  end

  defp maybe_put_sandbox_allow(sandbox, nil), do: sandbox

  defp maybe_put_sandbox_allow(sandbox, allow) do
    %{sandbox | env: Map.put(sandbox.env, :allow, Enum.uniq(allow))}
  end

  defp ensure_sandbox_env_sources(snapshot, answers) do
    SecretPaths.sandbox_env_eligible()
    |> Enum.reduce(snapshot, fn secret, acc ->
      if SecretWriter.available?() and answered?(answers, secret.key) do
        add_sandbox_env_source(acc, secret.env)
      else
        acc
      end
    end)
  end

  defp add_sandbox_env_source(snapshot, env_name) do
    sandbox = SandboxConfig.normalize(Map.get(snapshot, :sandbox))

    allow = add_if_missing(sandbox.env.allow, env_name)
    sources = Map.put_new(sandbox.env.sources, env_name, security_keychain_source(env_name))

    updated_env = %{sandbox.env | allow: allow, sources: sources}
    Map.put(snapshot, :sandbox, %{sandbox | env: updated_env})
  end

  defp security_keychain_source(env_name) do
    %{
      source: :command,
      command: "/usr/bin/security",
      args: ["find-generic-password", "-a", current_user(), "-s", env_name, "-w"],
      timeout_ms: 3000
    }
  end

  defp current_user do
    System.get_env("USER") || Path.basename(System.user_home!())
  end

  defp add_if_missing(list, item) when is_list(list) do
    if item in list, do: list, else: list ++ [item]
  end

  defp drop_unanswered_env_only_secrets(snapshot, answers) do
    persisted = persisted_snapshot()

    Enum.reduce(@setup_secret_paths, snapshot, fn {answer_key, path}, acc ->
      cond do
        answered?(answers, answer_key) ->
          acc

        not blank?(get_snapshot_value(persisted, path)) ->
          acc

        true ->
          delete_snapshot_value(acc, path)
      end
    end)
  end

  defp answered?(answers, key), do: not blank?(Keyword.get(answers, key))

  @doc """
  Re-runs prompt-file seeding against the current persisted snapshot.

  Used by the CLI re-run path: when setup is already ready and the operator
  re-runs `mix fermix.setup` (e.g., after deleting `SOUL.md`), this recreates
  any missing files without requiring new answers. Idempotent — files that
  already exist are skipped by `SetupSeeder`.
  """
  @spec seed_now() :: {:ok, [seeding_result()]} | {:error, term()}
  def seed_now do
    maybe_seed_prompt_files(ConfigStore.current_snapshot())
  end

  defp build_state(snapshot, readiness) do
    %WizardState{
      step: step_for(readiness.failures, snapshot),
      config_snapshot: snapshot,
      enabled_channels: enabled_channels(snapshot),
      validation_errors: readiness.failures,
      dirty?: false
    }
  end

  @channel_components ~w(channel:telegram channel:whatsapp channel:discord channel:slack channel:signal)

  defp step_for(failures, snapshot) do
    components = Enum.map(failures, & &1.component) |> MapSet.new()

    cond do
      Enum.any?(components, &String.starts_with?(&1, "provider:")) -> :provider
      persisted_provider(snapshot) == nil -> :model
      Enum.any?(@channel_components, &MapSet.member?(components, &1)) -> :channel
      MapSet.member?(components, "personalization") -> :personalization
      true -> :review
    end
  end

  defp persisted_provider(snapshot) do
    snapshot
    |> Map.get(:fermix_core, [])
    |> Keyword.get(:agent, [])
    |> Keyword.get(:provider)
  end

  defp configured_provider(snapshot) do
    snapshot
    |> Map.get(:fermix_core, [])
    |> Keyword.get(:agent, [])
    |> Keyword.get(:provider)
  end

  defp valid_provider(provider) when provider in [:openai, :openai_codex, :anthropic],
    do: provider

  defp valid_provider(_provider), do: nil

  defp provider_config(snapshot, provider) do
    snapshot
    |> Map.get(:fermix_core, [])
    |> Keyword.get(:providers, [])
    |> Keyword.get(provider, [])
  end

  defp openai_api_key_unpersisted?(persisted, :openai) do
    persisted
    |> provider_config(:openai)
    |> Keyword.get(:api_key)
    |> blank?()
  end

  defp openai_api_key_unpersisted?(_persisted, _provider), do: false

  defp canonical_openai_api_key_unpersisted?(persisted) do
    persisted
    |> provider_config(:openai)
    |> Keyword.get(:api_key)
    |> blank?()
  end

  defp enabled_channels(snapshot) do
    channels = Map.get(snapshot, :fermix_channels, [])

    []
    |> put_enabled_channel(:telegram, Keyword.get(channels, :telegram, []), true)
    |> put_enabled_channel(:whatsapp, Keyword.get(channels, :whatsapp, []), false)
    |> put_enabled_channel(:discord, Keyword.get(channels, :discord, []), false)
    |> put_enabled_channel(:slack, Keyword.get(channels, :slack, []), false)
    |> put_enabled_channel(:signal, Keyword.get(channels, :signal, []), false)
    |> Enum.reverse()
  end

  defp put_enabled_channel(channels, name, config, default) do
    if Keyword.get(config, :enabled, default) == true do
      [name | channels]
    else
      channels
    end
  end

  defp missing_component?(state, component) do
    Enum.any?(state.validation_errors, &(&1.component == component))
  end

  defp persisted_snapshot do
    case ConfigStore.load_runtime_config() do
      {:ok, snapshot} -> ConfigStore.persistable_snapshot(snapshot)
      {:error, _reason} -> ConfigStore.persistable_snapshot(%{})
    end
  end

  defp channel_field_unpersisted?(persisted, channel, field, default_enabled?) do
    config =
      persisted
      |> Map.get(:fermix_channels, [])
      |> Keyword.get(channel, [])

    enabled? = Keyword.get(config, :enabled, default_enabled?) == true
    enabled? and blank?(Keyword.get(config, field))
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  defp get_snapshot_value(%{} = snapshot, [key | rest]) do
    snapshot
    |> Map.get(key, [])
    |> get_snapshot_value(rest)
  end

  defp get_snapshot_value(keyword, [key]) when is_list(keyword), do: Keyword.get(keyword, key)

  defp get_snapshot_value(keyword, [key | rest]) when is_list(keyword) do
    keyword
    |> Keyword.get(key, [])
    |> get_snapshot_value(rest)
  end

  defp get_snapshot_value(_value, _path), do: nil

  defp delete_snapshot_value(%{} = snapshot, [key | rest]) do
    Map.update(snapshot, key, [], &delete_snapshot_value(&1, rest))
  end

  defp delete_snapshot_value(keyword, [key]) when is_list(keyword),
    do: Keyword.delete(keyword, key)

  defp delete_snapshot_value(keyword, [key | rest]) when is_list(keyword) do
    Keyword.update(keyword, key, [], &delete_snapshot_value(&1, rest))
  end

  defp delete_snapshot_value(value, _path), do: value

  defp restart_required?(snapshot) do
    case ConfigStore.load_runtime_config() do
      {:ok, persisted} ->
        ConfigStore.persistable_snapshot(snapshot) != ConfigStore.persistable_snapshot(persisted)

      {:error, _reason} ->
        true
    end
  end

  defp put_openai_api_key(snapshot, nil), do: snapshot
  defp put_openai_api_key(snapshot, ""), do: snapshot

  defp put_openai_api_key(snapshot, api_key) do
    sentinel = secret_snapshot_value(:openai_api_key, api_key)
    if is_nil(sentinel), do: snapshot, else: put_openai_secret(snapshot, sentinel)
  end

  defp put_openai_secret(snapshot, sentinel) do
    providers = snapshot |> Map.get(:fermix_core, []) |> Keyword.get(:providers, [])

    openai =
      providers
      |> Keyword.get(:openai, [])
      |> Keyword.put(:api_key, sentinel)

    Map.put(snapshot, :fermix_core, providers: Keyword.put(providers, :openai, openai))
  end

  defp put_provider_selection(snapshot, nil), do: snapshot
  defp put_provider_selection(snapshot, ""), do: snapshot

  defp put_provider_selection(snapshot, value) do
    provider = parse_provider!(value)
    fermix_core = Map.get(snapshot, :fermix_core, [])
    agent = Keyword.get(fermix_core, :agent, [])

    Map.put(
      snapshot,
      :fermix_core,
      Keyword.put(fermix_core, :agent, Keyword.put(agent, :provider, provider))
    )
  end

  defp put_default_model(snapshot, nil), do: snapshot
  defp put_default_model(snapshot, ""), do: snapshot

  defp put_default_model(snapshot, value) when is_binary(value) do
    case String.trim(value) do
      "" -> raise ArgumentError, "default_model cannot be blank"
      trimmed -> update_active_provider_block(snapshot, :default_model, trimmed)
    end
  end

  defp put_reasoning_effort(snapshot, nil), do: snapshot
  defp put_reasoning_effort(snapshot, ""), do: snapshot

  defp put_reasoning_effort(snapshot, value) do
    effort = parse_reasoning_effort!(value)
    provider = active_provider(snapshot)

    if provider in [:openai, :openai_codex] do
      update_active_provider_block(snapshot, :reasoning_effort, effort)
    else
      raise ArgumentError,
            "reasoning_effort applies to :openai or :openai_codex providers only; selected provider is #{inspect(provider)}"
    end
  end

  defp parse_provider!(value) when is_atom(value) do
    if value in ModelCatalog.providers() do
      value
    else
      raise ArgumentError,
            "unknown provider #{inspect(value)}; expected one of #{inspect(ModelCatalog.providers())}"
    end
  end

  defp parse_provider!(value) when is_binary(value) do
    trimmed = value |> String.trim() |> String.downcase()

    Enum.find(ModelCatalog.providers(), fn p -> Atom.to_string(p) == trimmed end) ||
      raise ArgumentError,
            "unknown provider #{inspect(value)}; expected one of #{Enum.map_join(ModelCatalog.providers(), ", ", &Atom.to_string/1)}"
  end

  defp parse_reasoning_effort!(value) do
    case ReasoningEffort.parse(value) do
      {:ok, level} ->
        level

      :error ->
        raise ArgumentError,
              "invalid reasoning_effort #{inspect(value)}; " <>
                "expected one of #{Enum.map_join(ReasoningEffort.levels(), ", ", &Atom.to_string/1)}"
    end
  end

  defp active_provider(snapshot) do
    snapshot
    |> Map.get(:fermix_core, [])
    |> Keyword.get(:agent, [])
    |> Keyword.get(:provider)
    |> case do
      nil -> :openai
      provider -> provider
    end
  end

  defp update_active_provider_block(snapshot, key, value) do
    provider = active_provider(snapshot)
    fermix_core = Map.get(snapshot, :fermix_core, [])
    providers = Keyword.get(fermix_core, :providers, [])
    block = providers |> Keyword.get(provider, []) |> Keyword.put(key, value)

    Map.put(
      snapshot,
      :fermix_core,
      Keyword.put(fermix_core, :providers, Keyword.put(providers, provider, block))
    )
  end

  defp put_telegram_bot_token(snapshot, nil), do: snapshot
  defp put_telegram_bot_token(snapshot, ""), do: snapshot

  defp put_telegram_bot_token(snapshot, bot_token) do
    sentinel = secret_snapshot_value(:telegram_bot_token, bot_token)
    if is_nil(sentinel), do: snapshot, else: put_telegram_secret(snapshot, sentinel)
  end

  defp put_telegram_secret(snapshot, sentinel) do
    channels = Map.get(snapshot, :fermix_channels, [])

    telegram =
      snapshot
      |> Map.get(:fermix_channels, [])
      |> Keyword.get(:telegram, [])
      |> Keyword.put(:enabled, true)
      |> Keyword.put_new(:mode, :webhook)
      |> Keyword.put(:bot_token, sentinel)

    Map.put(snapshot, :fermix_channels, Keyword.put(channels, :telegram, telegram))
  end

  defp put_compaction_config(snapshot, answers) do
    case normalize_compaction_threshold(Keyword.get(answers, :compaction_threshold)) do
      nil ->
        snapshot

      threshold ->
        fermix_core = Map.get(snapshot, :fermix_core, [])
        existing = Keyword.get(fermix_core, :compaction, [])
        compaction = CompactionConfig.normalize(Keyword.put(existing, :threshold, threshold))
        Map.put(snapshot, :fermix_core, Keyword.put(fermix_core, :compaction, compaction))
    end
  end

  defp normalize_compaction_threshold(nil), do: nil
  defp normalize_compaction_threshold(""), do: nil

  defp normalize_compaction_threshold(value) when is_float(value), do: value

  defp normalize_compaction_threshold(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {threshold, ""} -> threshold
      _invalid -> raise ArgumentError, "invalid compaction threshold #{inspect(value)}"
    end
  end

  defp put_memory_config(snapshot, answers) do
    case normalize_extraction_timeout_ms(Keyword.get(answers, :extraction_timeout_ms)) do
      nil ->
        snapshot

      timeout_ms ->
        fermix_core = Map.get(snapshot, :fermix_core, [])
        existing = Keyword.get(fermix_core, :memory, [])
        memory = Keyword.put(existing, :extraction_timeout_ms, timeout_ms)
        Map.put(snapshot, :fermix_core, Keyword.put(fermix_core, :memory, memory))
    end
  end

  defp put_realtime_config(snapshot, answers) do
    values =
      [
        enabled:
          normalize_realtime_bool(Keyword.get(answers, :realtime_enabled), :realtime_enabled),
        voice: normalize_realtime_string(Keyword.get(answers, :realtime_voice), :realtime_voice),
        max_session_minutes:
          normalize_realtime_positive_int(
            Keyword.get(answers, :realtime_max_session_minutes),
            :realtime_max_session_minutes
          ),
        max_estimated_cost_cents_per_session:
          normalize_realtime_positive_int(
            Keyword.get(answers, :realtime_max_cost_cents),
            :realtime_max_cost_cents
          ),
        persist_transcripts:
          normalize_realtime_bool(
            Keyword.get(answers, :realtime_persist_transcripts),
            :realtime_persist_transcripts
          )
      ]
      |> reject_nil_values()

    if values == [] do
      snapshot
    else
      fermix_core = Map.get(snapshot, :fermix_core, [])
      existing = Keyword.get(fermix_core, :realtime, [])

      realtime =
        existing
        |> Keyword.merge(values)
        |> RealtimeConfig.normalize()
        |> RealtimeConfig.to_keyword()

      Map.put(snapshot, :fermix_core, Keyword.put(fermix_core, :realtime, realtime))
    end
  end

  defp normalize_extraction_timeout_ms(nil), do: nil
  defp normalize_extraction_timeout_ms(""), do: nil

  defp normalize_extraction_timeout_ms(value) when is_integer(value) and value > 0, do: value

  defp normalize_extraction_timeout_ms(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {timeout_ms, ""} when timeout_ms > 0 ->
        timeout_ms

      _invalid ->
        raise ArgumentError,
              "invalid extraction_timeout_ms #{inspect(value)}; expected positive integer milliseconds"
    end
  end

  defp normalize_extraction_timeout_ms(value) do
    raise ArgumentError,
          "invalid extraction_timeout_ms #{inspect(value)}; expected positive integer milliseconds"
  end

  defp normalize_realtime_bool(nil, _key), do: nil
  defp normalize_realtime_bool("", _key), do: nil
  defp normalize_realtime_bool(value, _key) when is_boolean(value), do: value

  defp normalize_realtime_bool(value, key) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()

    cond do
      normalized in @realtime_true_values ->
        true

      normalized in @realtime_false_values ->
        false

      true ->
        raise ArgumentError, "invalid #{key} #{inspect(value)}; expected yes/no"
    end
  end

  defp normalize_realtime_bool(value, key) do
    raise ArgumentError, "invalid #{key} #{inspect(value)}; expected yes/no"
  end

  defp normalize_realtime_string(nil, _key), do: nil
  defp normalize_realtime_string("", _key), do: nil

  defp normalize_realtime_string(value, _key) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_realtime_string(value, key) do
    raise ArgumentError, "invalid #{key} #{inspect(value)}; expected non-empty string"
  end

  defp normalize_realtime_positive_int(nil, _key), do: nil
  defp normalize_realtime_positive_int("", _key), do: nil

  defp normalize_realtime_positive_int(value, _key) when is_integer(value) and value > 0,
    do: value

  defp normalize_realtime_positive_int(value, key) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} when integer > 0 ->
        integer

      _invalid ->
        raise ArgumentError, "invalid #{key} #{inspect(value)}; expected positive integer"
    end
  end

  defp normalize_realtime_positive_int(value, key) do
    raise ArgumentError, "invalid #{key} #{inspect(value)}; expected positive integer"
  end

  defp put_web_search_config(snapshot, answers) do
    values =
      [
        backend: normalize_web_search_backend(Keyword.get(answers, :web_search_backend)),
        tavily_api_key:
          secret_snapshot_value(:tavily_api_key, Keyword.get(answers, :tavily_api_key)),
        exa_api_key: secret_snapshot_value(:exa_api_key, Keyword.get(answers, :exa_api_key)),
        parallel_api_key:
          secret_snapshot_value(:parallel_api_key, Keyword.get(answers, :parallel_api_key)),
        brave_api_key:
          secret_snapshot_value(:brave_api_key, Keyword.get(answers, :brave_api_key)),
        perplexity_api_key:
          secret_snapshot_value(:perplexity_api_key, Keyword.get(answers, :perplexity_api_key))
      ]
      |> reject_nil_values()

    if values == [] do
      snapshot
    else
      update_web_search_config(snapshot, values)
    end
  end

  defp normalize_web_search_backend(nil), do: nil
  defp normalize_web_search_backend(""), do: nil
  defp normalize_web_search_backend(:duckduckgo), do: :duckduckgo
  defp normalize_web_search_backend(:tavily), do: :tavily
  defp normalize_web_search_backend(:exa), do: :exa
  defp normalize_web_search_backend(:parallel), do: :parallel
  defp normalize_web_search_backend(:brave), do: :brave
  defp normalize_web_search_backend(:perplexity), do: :perplexity

  defp normalize_web_search_backend(value) when is_binary(value) do
    case String.trim(value) |> String.downcase() do
      "duckduckgo" -> :duckduckgo
      "tavily" -> :tavily
      "exa" -> :exa
      "parallel" -> :parallel
      "brave" -> :brave
      "perplexity" -> :perplexity
      invalid -> raise ArgumentError, "invalid web_search_backend #{inspect(invalid)}"
    end
  end

  defp normalize_web_search_backend(value) do
    raise ArgumentError, "invalid web_search_backend #{inspect(value)}"
  end

  defp update_web_search_config(snapshot, values) do
    fermix_core = Map.get(snapshot, :fermix_core, [])
    tools = Keyword.get(fermix_core, :tools, [])

    web_search =
      tools
      |> Keyword.get(:web_search, [])
      |> Keyword.merge(values)

    Map.put(
      snapshot,
      :fermix_core,
      Keyword.put(fermix_core, :tools, Keyword.put(tools, :web_search, web_search))
    )
  end

  defp put_whatsapp_config(snapshot, answers) do
    values =
      [
        access_token:
          secret_snapshot_value(
            :whatsapp_access_token,
            Keyword.get(answers, :whatsapp_access_token)
          ),
        phone_number_id: Keyword.get(answers, :whatsapp_phone_number_id),
        verify_token:
          secret_snapshot_value(
            :whatsapp_verify_token,
            Keyword.get(answers, :whatsapp_verify_token)
          ),
        app_secret:
          secret_snapshot_value(:whatsapp_app_secret, Keyword.get(answers, :whatsapp_app_secret))
      ]
      |> reject_blank_values()

    put_channel_config(snapshot, :whatsapp, values, :webhook)
  end

  defp put_discord_config(snapshot, answers) do
    values =
      [
        bot_token:
          secret_snapshot_value(:discord_bot_token, Keyword.get(answers, :discord_bot_token)),
        bot_user_id: Keyword.get(answers, :discord_bot_user_id)
      ]
      |> reject_blank_values()

    put_channel_config(snapshot, :discord, values, :gateway)
  end

  defp put_slack_config(snapshot, answers) do
    values =
      [
        bot_token:
          secret_snapshot_value(:slack_bot_token, Keyword.get(answers, :slack_bot_token)),
        signing_secret:
          secret_snapshot_value(
            :slack_signing_secret,
            Keyword.get(answers, :slack_signing_secret)
          )
      ]
      |> reject_blank_values()

    put_channel_config(snapshot, :slack, values, :webhook)
  end

  defp put_signal_config(snapshot, answers) do
    values =
      [
        account: Keyword.get(answers, :signal_account)
      ]
      |> reject_blank_values()

    put_channel_config(snapshot, :signal, values, :subprocess)
  end

  defp put_channel_owner_user_ids(snapshot, answers) do
    [
      telegram: :telegram_owner_user_id,
      whatsapp: :whatsapp_owner_user_id,
      discord: :discord_owner_user_id,
      slack: :slack_owner_user_id,
      signal: :signal_owner_user_id
    ]
    |> Enum.reduce(snapshot, fn {channel, answer_key}, acc ->
      put_channel_owner_user_id(acc, channel, Keyword.get(answers, answer_key))
    end)
  end

  defp put_channel_owner_user_id(snapshot, _channel, nil), do: snapshot
  defp put_channel_owner_user_id(snapshot, _channel, ""), do: snapshot

  defp put_channel_owner_user_id(snapshot, channel, owner_user_id) do
    existing_channels = Map.get(snapshot, :fermix_channels, [])

    config =
      existing_channels
      |> Keyword.get(channel, [])
      |> Keyword.put(:owner_user_id, String.trim(to_string(owner_user_id)))

    Map.put(snapshot, :fermix_channels, Keyword.put(existing_channels, channel, config))
  end

  defp put_channel_config(snapshot, _channel, [], _mode), do: snapshot

  defp put_channel_config(snapshot, channel, values, mode) do
    existing_channels = Map.get(snapshot, :fermix_channels, [])

    config =
      existing_channels
      |> Keyword.get(channel, [])
      |> Keyword.put(:enabled, true)
      |> Keyword.put_new(:mode, mode)
      |> Keyword.merge(values)

    Map.put(snapshot, :fermix_channels, Keyword.put(existing_channels, channel, config))
  end

  defp secret_snapshot_value(_key, value) when value in [nil, ""], do: nil

  defp secret_snapshot_value(key, value) when is_atom(key) and is_binary(value) do
    if SecretWriter.available?() do
      write_secret_sentinel!(key, value)
    else
      log_manual_secret_fallback(key)
      nil
    end
  end

  defp write_secret_sentinel!(key, value) do
    case SecretWriter.put(key, value) do
      :ok -> SecretWriter.sentinel()
      {:error, reason} -> raise ArgumentError, SecretWriter.format_error(key, reason)
    end
  end

  defp log_manual_secret_fallback(key) do
    secret = SecretPaths.fetch!(key)

    Logger.warning(
      "No OS secret writer available for #{secret.env}; set it in shell rc, systemd unit, or launchd plist"
    )
  end

  defp put_personalization(snapshot, answers) do
    values =
      [
        user_name: Keyword.get(answers, :user_name),
        timezone: Keyword.get(answers, :timezone),
        communication_style: Keyword.get(answers, :communication_style)
      ]
      |> reject_blank_values()

    if values == [] do
      snapshot
    else
      fermix_core = Map.get(snapshot, :fermix_core, [])
      existing = Keyword.get(fermix_core, :personalization, [])
      merged = Keyword.merge(existing, values)
      Map.put(snapshot, :fermix_core, Keyword.put(fermix_core, :personalization, merged))
    end
  end

  defp maybe_seed_prompt_files(snapshot) do
    if seeding_ready?() do
      personalization = personalization_map(snapshot)

      case SetupSeeder.seed(personalization) do
        {:ok, results} ->
          {:ok, results}

        {:error, reason} = error ->
          Logger.warning("setup wizard prompt seed failed: #{inspect(reason)}")
          error
      end
    else
      {:ok, []}
    end
  end

  defp seeding_ready? do
    Readiness.report().status == :ready
  end

  defp personalization_map(snapshot) do
    snapshot
    |> Map.get(:fermix_core, [])
    |> Keyword.get(:personalization, [])
    |> Enum.into(%{})
  end

  defp reject_blank_values(values) do
    Enum.reject(values, fn {_key, value} ->
      value in [nil, ""]
    end)
  end

  defp reject_nil_values(values) do
    Enum.reject(values, fn {_key, value} -> is_nil(value) end)
  end
end
