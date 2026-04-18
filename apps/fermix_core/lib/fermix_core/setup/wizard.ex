defmodule FermixCore.Setup.Wizard do
  @moduledoc """
  Shared setup/readiness surface for CLI and web onboarding.
  """

  alias FermixCore.Readiness
  alias FermixCore.Setup.BootReport
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.WizardState

  @type answer ::
          {:openai_api_key, String.t()}
          | {:telegram_bot_token, String.t()}
          | {:whatsapp_access_token, String.t()}
          | {:whatsapp_phone_number_id, String.t()}
          | {:whatsapp_verify_token, String.t()}
          | {:whatsapp_app_secret, String.t()}
          | {:discord_bot_token, String.t()}
          | {:discord_bot_user_id, String.t()}
  @type report :: %{
          status: Readiness.status(),
          failures: [Readiness.failure()],
          wizard: WizardState.t(),
          config_path: String.t(),
          restart_required?: boolean()
        }

  @spec report() :: report()
  def report do
    readiness = Readiness.report()
    snapshot = ConfigStore.current_snapshot()

    %{
      status: readiness.status,
      failures: readiness.failures,
      wizard: build_state(snapshot, readiness),
      config_path: ConfigStore.path(),
      restart_required?: restart_required?(snapshot)
    }
  end

  @spec prompts(WizardState.t()) :: [map()]
  def prompts(%WizardState{} = state) do
    [
      %{
        key: :openai_api_key,
        label: "OpenAI API key",
        required?: missing_component?(state, "provider:openai")
      },
      %{
        key: :telegram_bot_token,
        label: "Telegram bot token",
        required?: missing_component?(state, "channel:telegram")
      },
      %{
        key: :whatsapp_access_token,
        label: "WhatsApp access token",
        required?: missing_component?(state, "channel:whatsapp")
      },
      %{
        key: :whatsapp_phone_number_id,
        label: "WhatsApp phone number ID",
        required?: missing_component?(state, "channel:whatsapp")
      },
      %{
        key: :whatsapp_verify_token,
        label: "WhatsApp verify token",
        required?: missing_component?(state, "channel:whatsapp")
      },
      %{
        key: :whatsapp_app_secret,
        label: "WhatsApp app secret",
        required?: missing_component?(state, "channel:whatsapp")
      },
      %{
        key: :discord_bot_token,
        label: "Discord bot token",
        required?: missing_component?(state, "channel:discord")
      },
      %{
        key: :discord_bot_user_id,
        label: "Discord bot user ID",
        required?: missing_component?(state, "channel:discord")
      }
    ]
    |> Enum.filter(& &1.required?)
  end

  @spec save_answers(WizardState.t(), [answer()]) :: {:ok, report()} | {:error, term()}
  def save_answers(%WizardState{} = state, answers) do
    snapshot =
      state.config_snapshot
      |> put_openai_api_key(Keyword.get(answers, :openai_api_key))
      |> put_telegram_bot_token(Keyword.get(answers, :telegram_bot_token))
      |> put_whatsapp_config(answers)
      |> put_discord_config(answers)

    with :ok <- ConfigStore.save_snapshot(snapshot),
         :ok <- ConfigStore.apply_snapshot(snapshot) do
      {:ok, BootReport.refresh_if_started() || report()}
    end
  end

  defp build_state(snapshot, readiness) do
    %WizardState{
      step: step_for(readiness.failures),
      config_snapshot: snapshot,
      enabled_channels: enabled_channels(snapshot),
      validation_errors: readiness.failures,
      dirty?: false
    }
  end

  defp step_for(failures) do
    cond do
      Enum.any?(failures, &(&1.component == "provider:openai")) -> :provider
      Enum.any?(failures, &(&1.component == "channel:telegram")) -> :channel
      Enum.any?(failures, &(&1.component == "channel:whatsapp")) -> :channel
      Enum.any?(failures, &(&1.component == "channel:discord")) -> :channel
      true -> :review
    end
  end

  defp enabled_channels(snapshot) do
    channels = Map.get(snapshot, :fermix_channels, [])

    []
    |> put_enabled_channel(:telegram, Keyword.get(channels, :telegram, []), true)
    |> put_enabled_channel(:whatsapp, Keyword.get(channels, :whatsapp, []), false)
    |> put_enabled_channel(:discord, Keyword.get(channels, :discord, []), false)
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

  defp restart_required?(snapshot) do
    case ConfigStore.load_runtime_config() do
      {:ok, persisted} ->
        ConfigStore.persistable_snapshot(snapshot) != ConfigStore.persistable_snapshot(persisted)

      {:error, _reason} ->
        false
    end
  end

  defp put_openai_api_key(snapshot, nil), do: snapshot
  defp put_openai_api_key(snapshot, ""), do: snapshot

  defp put_openai_api_key(snapshot, api_key) do
    providers = snapshot |> Map.get(:fermix_core, []) |> Keyword.get(:providers, [])

    openai =
      providers
      |> Keyword.get(:openai, [])
      |> Keyword.put(:auth_mode, :api_key)
      |> Keyword.put(:api_key, api_key)

    Map.put(snapshot, :fermix_core, providers: Keyword.put(providers, :openai, openai))
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
      |> Keyword.put_new(:allowed_user_ids, [])

    Map.put(snapshot, :fermix_channels, Keyword.put(channels, :telegram, telegram))
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

  defp reject_blank_values(values) do
    Enum.reject(values, fn {_key, value} ->
      value in [nil, ""]
    end)
  end
end
