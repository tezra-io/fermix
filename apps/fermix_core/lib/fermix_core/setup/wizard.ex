defmodule FermixCore.Setup.Wizard do
  @moduledoc """
  Shared setup/readiness surface for CLI and web onboarding.
  """

  alias FermixCore.Readiness
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.WizardState

  @type answer :: {:openai_api_key, String.t()} | {:telegram_bot_token, String.t()}
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

    with :ok <- ConfigStore.save_snapshot(snapshot),
         :ok <- ConfigStore.apply_snapshot(snapshot) do
      {:ok, report()}
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
      true -> :review
    end
  end

  defp enabled_channels(snapshot) do
    telegram = snapshot |> Map.get(:fermix_channels, []) |> Keyword.get(:telegram, [])

    if Keyword.get(telegram, :enabled, false), do: [:telegram], else: []
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
    telegram =
      snapshot
      |> Map.get(:fermix_channels, [])
      |> Keyword.get(:telegram, [])
      |> Keyword.put(:enabled, true)
      |> Keyword.put_new(:mode, :webhook)
      |> Keyword.put(:bot_token, bot_token)
      |> Keyword.put_new(:allowed_user_ids, [])

    Map.put(snapshot, :fermix_channels, telegram: telegram)
  end
end
