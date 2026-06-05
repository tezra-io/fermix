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

  alias FermixCore.Auth.Store
  alias FermixCore.Config
  alias FermixCore.Realtime.Config, as: RealtimeConfig

  require Logger

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

  defp provider_failure do
    case active_provider() do
      :openai -> openai_failure()
      :openai_codex -> openai_codex_failure()
      :anthropic -> anthropic_failure()
      :xai -> xai_failure()
      _other -> openai_failure()
    end
  end

  defp xai_failure do
    case Config.provider(:xai) do
      {:ok, config} when is_list(config) -> xai_config_failure(config)
      _ -> xai_api_key_action()
    end
  end

  defp xai_config_failure(config) do
    case Keyword.get(config, :auth_mode) do
      mode when mode in [:oauth, "oauth"] ->
        if oauth_profile_configured?("xai_oauth"), do: nil, else: xai_oauth_action()

      mode when mode in [nil, :api_key, "api_key"] ->
        if present?(Keyword.get(config, :api_key)), do: nil, else: xai_api_key_action()

      other ->
        invalid_auth_mode_action("provider:xai", other)
    end
  end

  defp xai_api_key_action do
    %{component: "provider:xai", action: "Set XAI_API_KEY."}
  end

  defp xai_oauth_action do
    %{
      component: "provider:xai",
      action: "Connect xAI Grok: `fermix auth login --provider xai`."
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

  defp active_provider do
    Application.get_env(:fermix_core, :agent, [])
    |> Keyword.get(:provider, :openai)
  end

  defp openai_failure do
    case Config.provider(:openai) do
      {:ok, config} when is_list(config) ->
        if openai_configured?(config) do
          nil
        else
          %{
            component: "provider:openai",
            action: "Set OPENAI_API_KEY."
          }
        end

      _ ->
        %{
          component: "provider:openai",
          action: "Set OPENAI_API_KEY."
        }
    end
  end

  defp openai_codex_failure do
    if codex_configured?() do
      nil
    else
      %{
        component: "provider:openai_codex",
        action: "Run mix fermix.setup --import-codex to import Codex OAuth tokens."
      }
    end
  end

  defp anthropic_failure do
    case Config.provider(:anthropic) do
      {:ok, config} when is_list(config) -> anthropic_config_failure(config)
      _ -> anthropic_api_key_action()
    end
  end

  defp anthropic_config_failure(config) do
    case Keyword.get(config, :auth_mode) do
      mode when mode in [:oauth, "oauth"] ->
        if oauth_profile_configured?("anthropic_oauth"), do: nil, else: anthropic_oauth_action()

      mode when mode in [nil, :api_key, "api_key"] ->
        if present?(Keyword.get(config, :api_key)), do: nil, else: anthropic_api_key_action()

      other ->
        invalid_auth_mode_action("provider:anthropic", other)
    end
  end

  defp anthropic_api_key_action do
    %{component: "provider:anthropic", action: "Set ANTHROPIC_API_KEY."}
  end

  defp anthropic_oauth_action do
    %{
      component: "provider:anthropic",
      action: "Connect the Claude subscription: `fermix auth login --provider anthropic`."
    }
  end

  defp oauth_profile_configured?(profile) do
    case Store.read(profile) do
      {:ok, entry} ->
        present?(entry.tokens.access_token) and
          Map.get(entry, :status) != "reauthorization_required"

      {:error, _reason} ->
        false
    end
  rescue
    e in ArgumentError ->
      Logger.warning(
        "Readiness: Auth.Store.read(#{profile}) raised — auth.json may be malformed: #{Exception.message(e)}"
      )

      false
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

  defp openai_configured?(config) do
    present?(Keyword.get(config, :api_key))
  end

  defp regular_openai_api_key? do
    case Config.provider(:openai) do
      {:ok, config} when is_list(config) -> openai_configured?(config)
      _ -> false
    end
  end

  defp codex_configured? do
    case Store.read(:openai_codex) do
      {:ok, entry} -> present?(entry.tokens.access_token)
      {:error, _reason} -> false
    end
  rescue
    e in ArgumentError ->
      Logger.warning(
        "Readiness: Auth.Store.read(:openai_codex) raised — auth.json may be malformed: #{Exception.message(e)}"
      )

      false
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
