defmodule FermixCore.Setup.Wizard do
  @moduledoc """
  Shared setup/readiness surface for CLI and web onboarding.
  """

  alias FermixCore.Memory.CompactionConfig
  alias FermixCore.Prompt.SetupSeeder
  alias FermixCore.Providers.ModelCatalog
  alias FermixCore.Providers.OpenAI.ResponsesShared
  alias FermixCore.Readiness
  alias FermixCore.Setup.BootReport
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.WizardState

  require Logger

  @type provider :: ModelCatalog.provider()
  @type reasoning_effort :: :none | :minimal | :low | :medium | :high | :xhigh

  @type answer ::
          {:openai_api_key, String.t()}
          | {:provider, provider() | String.t()}
          | {:default_model, String.t()}
          | {:reasoning_effort, reasoning_effort() | String.t()}
          | {:compaction_threshold, float() | String.t()}
          | {:extraction_timeout_ms, pos_integer() | String.t()}
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

  @setup_secret_paths [
    openai_api_key: [:fermix_core, :providers, :openai, :api_key],
    telegram_bot_token: [:fermix_channels, :telegram, :bot_token],
    whatsapp_access_token: [:fermix_channels, :whatsapp, :access_token],
    whatsapp_verify_token: [:fermix_channels, :whatsapp, :verify_token],
    whatsapp_app_secret: [:fermix_channels, :whatsapp, :app_secret],
    discord_bot_token: [:fermix_channels, :discord, :bot_token],
    slack_bot_token: [:fermix_channels, :slack, :bot_token],
    slack_signing_secret: [:fermix_channels, :slack, :signing_secret]
  ]

  @type seeding_result :: %{
          name: :identity | :agents | :soul | :user | :memory,
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
  def prompts(%WizardState{} = state) do
    state
    |> prompt_specs()
    |> Enum.filter(& &1.required?)
  end

  @spec reconfigure_prompts(WizardState.t()) :: [map()]
  def reconfigure_prompts(%WizardState{} = state) do
    state
    |> prompt_specs()
    |> Enum.filter(&(&1.key in [:provider, :default_model, :reasoning_effort]))
    |> Enum.map(&Map.put(&1, :required?, true))
  end

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
      channel_prompts(context) ++
      personalization_prompts(context)
  end

  defp prompt_context(state, persisted, persisted_provider, prompt_provider) do
    provider_unset? = persisted_provider == nil
    provider_block = provider_config(persisted, prompt_provider)
    model_unset? = provider_unset? or blank?(Keyword.get(provider_block, :default_model))
    effort_unset? = provider_unset? or blank?(Keyword.get(provider_block, :reasoning_effort))
    openai_api_key_unset? = openai_api_key_unpersisted?(persisted, persisted_provider)
    default_model = ModelCatalog.default_model_for(prompt_provider)

    %{
      state: state,
      persisted: persisted,
      prompt_provider: prompt_provider,
      provider_unset?: provider_unset?,
      model_unset?: model_unset?,
      effort_unset?: effort_unset?,
      openai_api_key_unset?: openai_api_key_unset?,
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
          "Reasoning effort (#{Enum.map_join(ResponsesShared.valid_reasoning_efforts(), "/", &Atom.to_string/1)}; blank = high)",
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
        required?: false
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
        required?: false
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
        required?: false
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
        required?: false
      },
      %{
        key: :signal_account,
        label: "Signal account",
        required?: channel_field_unpersisted?(persisted, :signal, :account, false)
      },
      %{
        key: :signal_owner_user_id,
        label: "Signal command owner user ID",
        required?: false
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
      |> put_provider_selection(Keyword.get(answers, :provider))
      |> put_default_model(Keyword.get(answers, :default_model))
      |> put_reasoning_effort(Keyword.get(answers, :reasoning_effort))
      |> put_compaction_config(answers)
      |> put_memory_config(answers)
      |> put_telegram_bot_token(Keyword.get(answers, :telegram_bot_token))
      |> put_whatsapp_config(answers)
      |> put_discord_config(answers)
      |> put_slack_config(answers)
      |> put_signal_config(answers)
      |> put_channel_owner_user_ids(answers)
      |> put_personalization(answers)

    with :ok <- ConfigStore.save_snapshot(snapshot),
         :ok <- ConfigStore.apply_snapshot(snapshot),
         {:ok, seeding_results} <- maybe_seed_prompt_files(snapshot) do
      {:ok, BootReport.refresh_if_started(seeding_results) || report(seeding_results)}
    end
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
    providers = snapshot |> Map.get(:fermix_core, []) |> Keyword.get(:providers, [])

    openai =
      providers
      |> Keyword.get(:openai, [])
      |> Keyword.put(:api_key, api_key)

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

  defp parse_reasoning_effort!(value) when is_atom(value) do
    valid = ResponsesShared.valid_reasoning_efforts()

    if value in valid do
      value
    else
      raise ArgumentError,
            "invalid reasoning_effort #{inspect(value)}; expected one of #{inspect(valid)}"
    end
  end

  defp parse_reasoning_effort!(value) when is_binary(value) do
    trimmed = value |> String.trim() |> String.downcase()
    valid = ResponsesShared.valid_reasoning_efforts()

    Enum.find(valid, fn atom -> Atom.to_string(atom) == trimmed end) ||
      raise ArgumentError,
            "invalid reasoning_effort #{inspect(value)}; expected one of #{Enum.map_join(valid, ", ", &Atom.to_string/1)}"
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
    channels = Map.get(snapshot, :fermix_channels, [])

    telegram =
      snapshot
      |> Map.get(:fermix_channels, [])
      |> Keyword.get(:telegram, [])
      |> Keyword.put(:enabled, true)
      |> Keyword.put_new(:mode, :webhook)
      |> Keyword.put(:bot_token, bot_token)

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

  defp put_whatsapp_config(snapshot, answers) do
    values =
      [
        access_token: Keyword.get(answers, :whatsapp_access_token),
        phone_number_id: Keyword.get(answers, :whatsapp_phone_number_id),
        verify_token: Keyword.get(answers, :whatsapp_verify_token),
        app_secret: Keyword.get(answers, :whatsapp_app_secret)
      ]
      |> reject_blank_values()

    put_channel_config(snapshot, :whatsapp, values, :webhook)
  end

  defp put_discord_config(snapshot, answers) do
    values =
      [
        bot_token: Keyword.get(answers, :discord_bot_token),
        bot_user_id: Keyword.get(answers, :discord_bot_user_id)
      ]
      |> reject_blank_values()

    put_channel_config(snapshot, :discord, values, :gateway)
  end

  defp put_slack_config(snapshot, answers) do
    values =
      [
        bot_token: Keyword.get(answers, :slack_bot_token),
        signing_secret: Keyword.get(answers, :slack_signing_secret)
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
end
