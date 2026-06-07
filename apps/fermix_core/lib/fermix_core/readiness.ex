defmodule FermixCore.Readiness do
  @moduledoc """
  Minimal readiness checks for externally configured integrations.

  This stage of the readiness foundation reports whether required initial setup is
  complete. `:setup_required` means one or more required integrations are not yet
  configured.

  The `:degraded` readiness state is intentionally part of the public type because
  TEZ-326 establishes it as a supported readiness-state foundation. It is reserved
  for future runtime degradation checks and is not emitted by these setup-focused
  checks yet.
  """

  alias FermixCore.Config
  alias FermixCore.Providers.PrimaryConfig
  alias FermixCore.Providers.Selection
  alias FermixCore.Realtime.Config, as: RealtimeConfig

  @typedoc """
  Public readiness state.

  `:ready` means required setup is present.
  `:setup_required` means required initial setup is missing.
  `:degraded` is reserved for future runtime degradation checks and is not returned
  by this module's current setup validation.
  """
  @type status :: :ready | :setup_required | :degraded
  @type failure :: %{component: String.t(), action: String.t()}
  @type report :: %{status: status(), failures: [failure()]}

  @spec report() :: report()
  def report do
    failures =
      Enum.reject(
        [
          provider_failure(),
          telegram_failure(),
          whatsapp_failure(),
          discord_failure(),
          slack_failure(),
          signal_failure(),
          realtime_failure(),
          personalization_failure()
        ],
        &is_nil/1
      )

    %{
      status: status_for(failures),
      failures: failures
    }
  end

  @spec personalization_failure() :: failure() | nil
  def personalization_failure do
    config = Application.get_env(:fermix_core, :personalization, [])

    if Enum.all?(
         [:user_name, :timezone, :communication_style],
         &present?(Keyword.get(config, &1))
       ) do
      nil
    else
      %{
        component: "personalization",
        action: "Run mix fermix.setup to provide your name, timezone, and communication style."
      }
    end
  end

  # Eligibility (credential presence) is owned by Selection — readiness only
  # maps "not configured" to its actionable setup message. The primary comes
  # from PrimaryConfig (flag first, legacy agent.provider as migration input).
  defp provider_failure do
    case PrimaryConfig.primary() do
      {:ok, provider} -> primary_provider_failure(known_provider(provider))
      {:error, :multiple_primary} -> multiple_primary_action()
    end
  end

  defp known_provider(provider) do
    if provider in [:openai, :openai_codex, :anthropic, :xai], do: provider, else: :openai
  end

  defp primary_provider_failure(provider) do
    block = provider_block(provider)

    cond do
      invalid_auth_mode?(provider, block) ->
        invalid_auth_mode_action("provider:#{provider}", Keyword.get(block, :auth_mode))

      Selection.configured?(provider, block) ->
        nil

      true ->
        provider |> missing_credentials_action(block) |> note_available_fallbacks()
    end
  end

  # Primary unavailable but fallbacks configured: the failure stays (setup is
  # still needed) and names the fallbacks that serve turns meanwhile (§8).
  # fallback_providers/0 never includes the primary itself.
  defp note_available_fallbacks(failure) do
    case Selection.fallback_providers() do
      {:ok, [_ | _] = fallbacks} ->
        %{
          failure
          | action:
              failure.action <>
                " Configured fallback providers (#{Enum.map_join(fallbacks, ", ", &to_string/1)}) serve turns meanwhile."
        }

      _none_or_error ->
        failure
    end
  end

  defp provider_block(provider) do
    case Config.provider(provider) do
      {:ok, config} when is_list(config) -> config
      _not_configured -> []
    end
  end

  defp invalid_auth_mode?(provider, block) when provider in [:anthropic, :xai] do
    case Keyword.get(block, :auth_mode) do
      nil -> false
      mode when mode in [:oauth, "oauth", :api_key, "api_key"] -> false
      _other -> true
    end
  end

  defp invalid_auth_mode?(_provider, _block), do: false

  defp missing_credentials_action(:openai, _block) do
    %{component: "provider:openai", action: "Set OPENAI_API_KEY."}
  end

  defp missing_credentials_action(:openai_codex, _block) do
    %{
      component: "provider:openai_codex",
      action: "Run mix fermix.setup --import-codex to import Codex OAuth tokens."
    }
  end

  defp missing_credentials_action(:anthropic, block) do
    if oauth_mode?(block) do
      %{
        component: "provider:anthropic",
        action: "Connect the Claude subscription: `fermix auth login --provider anthropic`."
      }
    else
      %{component: "provider:anthropic", action: "Set ANTHROPIC_API_KEY."}
    end
  end

  defp missing_credentials_action(:xai, block) do
    if oauth_mode?(block) do
      %{
        component: "provider:xai",
        action: "Connect xAI Grok: `fermix auth login --provider xai`."
      }
    else
      %{component: "provider:xai", action: "Set XAI_API_KEY."}
    end
  end

  defp oauth_mode?(block), do: Keyword.get(block, :auth_mode) in [:oauth, "oauth"]

  defp multiple_primary_action do
    %{
      component: "provider:config",
      action:
        "More than one provider has primary = true in config.toml — mark exactly one provider primary."
    }
  end

  # An unrecognized auth_mode (e.g. a typo) must NOT report ready just because an
  # api_key happens to be set — RouteResolver.parse_auth_mode!/2 raises on it at
  # the first turn, so surface it as a setup failure instead.
  defp invalid_auth_mode_action(component, mode) do
    %{
      component: component,
      action: "Invalid auth_mode #{inspect(mode)} — set it to \"api_key\" or \"oauth\"."
    }
  end

  defp telegram_failure do
    case Config.channel(:telegram) do
      {:ok, config} when is_list(config) ->
        cond do
          not telegram_enabled?(config) ->
            nil

          present?(Keyword.get(config, :bot_token)) ->
            nil

          true ->
            %{
              component: "channel:telegram",
              action: "Set TELEGRAM_BOT_TOKEN."
            }
        end

      _ ->
        %{
          component: "channel:telegram",
          action: "Set TELEGRAM_BOT_TOKEN."
        }
    end
  end

  defp whatsapp_failure do
    case Config.channel(:whatsapp) do
      {:ok, config} when is_list(config) ->
        cond do
          not channel_enabled?(config, false) ->
            nil

          configured?(config, [:access_token, :phone_number_id, :verify_token, :app_secret]) ->
            nil

          true ->
            %{
              component: "channel:whatsapp",
              action:
                "Set WHATSAPP_ACCESS_TOKEN, WHATSAPP_PHONE_NUMBER_ID, WHATSAPP_VERIFY_TOKEN, and WHATSAPP_APP_SECRET."
            }
        end

      _ ->
        nil
    end
  end

  defp discord_failure do
    case Config.channel(:discord) do
      {:ok, config} when is_list(config) ->
        cond do
          not channel_enabled?(config, false) ->
            nil

          configured?(config, [:bot_token, :bot_user_id]) ->
            nil

          true ->
            %{
              component: "channel:discord",
              action: "Set DISCORD_BOT_TOKEN and DISCORD_BOT_USER_ID."
            }
        end

      _ ->
        nil
    end
  end

  defp slack_failure do
    case Config.channel(:slack) do
      {:ok, config} when is_list(config) ->
        cond do
          not channel_enabled?(config, false) ->
            nil

          configured?(config, [:bot_token, :signing_secret]) ->
            nil

          true ->
            %{
              component: "channel:slack",
              action: "Set SLACK_BOT_TOKEN and SLACK_SIGNING_SECRET."
            }
        end

      _ ->
        nil
    end
  end

  defp signal_failure do
    case Config.channel(:signal) do
      {:ok, config} when is_list(config) ->
        cond do
          not channel_enabled?(config, false) ->
            nil

          configured?(config, [:account]) ->
            nil

          true ->
            %{
              component: "channel:signal",
              action: "Set SIGNAL_ACCOUNT."
            }
        end

      _ ->
        nil
    end
  end

  defp realtime_failure do
    config = RealtimeConfig.current()

    cond do
      not config.enabled? ->
        nil

      config.provider != "openai" ->
        %{
          component: "realtime:openai",
          action: "Set [fermix_core.realtime].provider to \"openai\" or disable realtime."
        }

      regular_openai_api_key?() ->
        nil

      true ->
        %{
          component: "realtime:openai",
          action: "Set OPENAI_API_KEY for OpenAI Realtime or disable realtime."
        }
    end
  end

  defp telegram_enabled?(config) do
    channel_enabled?(config, true)
  end

  defp regular_openai_api_key? do
    Selection.configured?(:openai, provider_block(:openai))
  end

  defp configured?(config, keys) do
    Enum.all?(keys, &present?(Keyword.get(config, &1)))
  end

  defp channel_enabled?(config, default) do
    Keyword.get(config, :enabled, default) == true
  end

  defp present?(value) when is_binary(value), do: value != ""
  defp present?(value) when is_map(value), do: map_size(value) > 0
  defp present?(value) when is_list(value), do: value != []
  defp present?(nil), do: false
  defp present?(_value), do: true

  defp status_for([]), do: :ready
  defp status_for(failures) when is_list(failures), do: :setup_required
end
