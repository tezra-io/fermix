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
  alias FermixCore.Management.Settings.Channels.Inventory
  alias FermixCore.Providers.Descriptor
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

  @typedoc """
  One readiness failure.

    * `:component` — the historical open-string identity, kept for `Health`
    * `:action` — the operator-facing sentence
    * `:gating` — whether this failure alone means setup is incomplete
    * `:pane` — the settings pane (or assistant stage) that can clear it
    * `:detail_key` — the closed-set copy key, minted by the failure
      constructor so a reader can look one sentence up per cause rather than
      collapsing three causes into one open `component`
  """
  @type failure :: %{
          component: String.t(),
          action: String.t(),
          gating: boolean(),
          pane: String.t(),
          detail_key: String.t()
        }
  @type report :: %{status: status(), failures: [failure()]}

  # Every pane slug a failure may name. Kept beside the constructors so a new
  # failure cannot invent a pane no surface routes to.
  @panes ~w(providers personality channels voice)

  # Credentials each channel needs, DERIVED from `Channels.Inventory` — the one
  # channel table — rather than repeated here. The two copies had already
  # drifted in shape, and a channel added to one would have been invisible to
  # the other.
  @channel_credentials Enum.map(Inventory.channels(), fn channel ->
                         {channel, Inventory.credential_keys(channel)}
                       end)
  @channel_defaults [
    telegram: true,
    whatsapp: false,
    discord: false,
    slack: false,
    signal: false
  ]
  # Each sentence names the CONTROL that fixes it, not the environment variable
  # behind it: every failure carries the `pane` that owns the fix, and a native
  # attention row renders this text verbatim beside a field the operator can
  # type into. Naming a shell variable there tells them to leave the app.
  @channel_actions [
    telegram: "Add the Telegram bot token in Channels settings.",
    whatsapp:
      "Add the WhatsApp access token, phone number ID, verify token, and app secret in Channels settings.",
    discord: "Add the Discord bot token and bot user ID in Channels settings.",
    slack: "Add the Slack bot token and signing secret in Channels settings.",
    signal: "Add the Signal account in Channels settings."
  ]

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

  @doc "Every pane slug a readiness failure can name."
  @spec panes() :: [String.t()]
  def panes, do: @panes

  @doc """
  Every operator-facing sentence this module can publish, keyed by detail key.

  A native Doctor row and a Settings pane render these verbatim, so they are
  held to the daemon copy rules (`FermixCore.Management.Copy`) exactly as a
  descriptor row is. The gate reads this rather than a list beside it: each
  sentence is built by the same constructor `report/0` calls, over the same
  tables, so a channel or a provider added to those tables joins the gate on
  the day it lands.
  """
  @spec published_actions() :: [{String.t(), String.t()}]
  def published_actions do
    channels =
      Enum.map(@channel_credentials, fn {channel, _keys} ->
        channel_failure(channel, Keyword.fetch!(@channel_actions, channel))
      end)

    providers = Enum.map(Descriptor.ids(), &missing_credentials_action(&1, []))

    Enum.map(
      channels ++
        providers ++
        [
          personalization_row(),
          unknown_provider_action(:not_a_provider),
          multiple_primary_action(),
          invalid_auth_mode_action("provider:anthropic", "subscription"),
          realtime_provider_row(),
          realtime_key_row()
        ],
      &{&1.detail_key, &1.action}
    )
  end

  @doc """
  The failures that alone mean setup is incomplete.

  One configured provider plus the three personalization values. An enabled but
  half-configured channel, and realtime without an OpenAI key, are real failures
  the operator should see and are not reasons to call setup unfinished: the
  shipped `telegram: [enabled: true]` default fires on every fresh install, and
  realtime-without-a-key fires on every companion install.
  """
  @spec gating_failures([failure()]) :: [failure()]
  def gating_failures(failures) when is_list(failures),
    do: Enum.filter(failures, &(Map.get(&1, :gating, true) == true))

  @doc "Whether no gating failure remains. The one definition of ready."
  @spec ready?() :: boolean()
  def ready?, do: report().status == :ready

  @doc "The five messaging channels readiness knows about, in publication order."
  @spec channels() :: [atom()]
  def channels, do: Keyword.keys(@channel_credentials)

  @doc """
  The shipped `enabled` default per channel.

  Published because the settings descriptor renders the same toggle readiness
  reads, and a second copy of these defaults would let a channel readiness
  treats as on render as off.
  """
  @spec channel_defaults() :: keyword(boolean())
  def channel_defaults, do: @channel_defaults

  @doc """
  Whether `channel` is switched on, honouring the shipped default.

  Telegram ships enabled, which is why a fresh install has an advisory Telegram
  failure and not a gating one.
  """
  @spec channel_enabled?(atom()) :: boolean()
  def channel_enabled?(channel) when is_atom(channel) do
    channel
    |> channel_block()
    |> Keyword.get(:enabled, Keyword.fetch!(@channel_defaults, channel)) == true
  end

  @doc "Whether every credential `channel` needs is present."
  @spec channel_configured?(atom()) :: boolean()
  def channel_configured?(channel) when is_atom(channel) do
    block = channel_block(channel)
    Enum.all?(Keyword.fetch!(@channel_credentials, channel), &present?(Keyword.get(block, &1)))
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
      personalization_row()
    end
  end

  defp personalization_row do
    gating(
      %{
        component: "personalization",
        action:
          "Add your name, time zone, and communication style in Personality settings, " <>
            "or run `fermix setup`."
      },
      "personality",
      "personalization"
    )
  end

  # Eligibility (credential presence) is owned by Selection — readiness only
  # maps "not configured" to its actionable setup message. The primary comes
  # from PrimaryConfig (flag first, legacy agent.provider as migration input).
  defp provider_failure do
    case PrimaryConfig.primary() do
      {:ok, provider} ->
        if provider in Descriptor.ids() do
          primary_provider_failure(provider)
        else
          unknown_provider_action(provider)
        end

      {:error, :multiple_primary} ->
        multiple_primary_action()
    end
  end

  # An unknown configured provider is a visible setup failure, never a
  # silent coercion to :openai (M12 §2.3-2 — same family as the
  # ConfigStore unknown-provider raise).
  defp unknown_provider_action(provider) do
    gating(
      %{
        component: "provider:config",
        action:
          "The configured provider `#{provider}` is not one Fermix knows. Set it to one of " <>
            "#{Enum.map_join(Descriptor.ids(), ", ", &"`#{&1}`")}."
      },
      "providers",
      "provider:unknown_configured"
    )
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
                " Configured fallback providers (#{Enum.map_join(fallbacks, ", ", &"`#{&1}`")}) serve turns meanwhile."
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

  defp invalid_auth_mode?(provider, block) do
    if Descriptor.multi_auth_mode?(Descriptor.fetch!(provider)) do
      case Keyword.get(block, :auth_mode) do
        nil -> false
        mode when mode in [:oauth, "oauth", :api_key, "api_key"] -> false
        _other -> true
      end
    else
      false
    end
  end

  defp missing_credentials_action(:openai, _block) do
    missing_credentials(:openai, "Add the OpenAI API key in Providers settings.")
  end

  defp missing_credentials_action(:openai_codex, _block) do
    missing_credentials(
      :openai_codex,
      "Import your Codex sign-in: run `fermix setup --import-codex`."
    )
  end

  defp missing_credentials_action(:anthropic, block) do
    if oauth_mode?(block) do
      missing_credentials(
        :anthropic,
        "Connect the Claude subscription: `fermix auth login --provider anthropic`."
      )
    else
      missing_credentials(:anthropic, "Add the Anthropic API key in Providers settings.")
    end
  end

  defp missing_credentials_action(:xai, block) do
    if oauth_mode?(block) do
      missing_credentials(:xai, "Connect SpaceXAI Grok: `fermix auth login --provider xai`.")
    else
      missing_credentials(:xai, "Add the SpaceXAI API key in Providers settings.")
    end
  end

  # Descriptor providers without bespoke flows. The action names the CONTROL
  # that fixes it, not the environment variable behind it: the failure already
  # carries the pane that owns the fix, and naming a shell variable in a native
  # attention row tells the operator to leave the app.
  defp missing_credentials_action(provider, _block) do
    descriptor = Descriptor.fetch!(provider)

    action =
      case {Descriptor.default_auth_mode(descriptor), descriptor.secrets} do
        {:api_key, [_secret | _rest]} ->
          "Add the #{descriptor.label} API key in Providers settings."

        {:none, _secrets} ->
          "Set `base_url` for the #{descriptor.label} provider in config.toml."

        _other ->
          "Configure the #{descriptor.label} provider in Providers settings."
      end

    missing_credentials(provider, action)
  end

  defp oauth_mode?(block), do: Keyword.get(block, :auth_mode) in [:oauth, "oauth"]

  defp multiple_primary_action do
    gating(
      %{
        component: "provider:config",
        action:
          "More than one provider is marked primary in config.toml. Mark exactly one primary."
      },
      "providers",
      "provider:multiple_primary"
    )
  end

  # An unrecognized auth_mode (e.g. a typo) must NOT report ready just because an
  # api_key happens to be set — RouteResolver.parse_auth_mode!/2 raises on it at
  # the first turn, so surface it as a setup failure instead.
  defp invalid_auth_mode_action(component, mode) do
    gating(
      %{component: component, action: invalid_auth_mode_sentence(mode)},
      "providers",
      "provider:invalid_auth_mode"
    )
  end

  # The value is the operator's own word, echoed as a backticked literal they
  # can search the file for. `inspect/1` is never used here: this sentence
  # crosses the management socket, and an inspected term reads as a typo to
  # everyone who has not read the source. A value that is not a word is not
  # echoed at all rather than rendered.
  defp invalid_auth_mode_sentence(mode)
       when (is_binary(mode) or is_atom(mode)) and mode not in [nil, true, false] do
    "The sign-in mode `#{mode}` is not one Fermix knows. " <>
      "Set `auth_mode` to `api_key` or `oauth`."
  end

  defp invalid_auth_mode_sentence(_mode) do
    "The sign-in mode set for this provider is not one Fermix knows. " <>
      "Set `auth_mode` to `api_key` or `oauth`."
  end

  # One table for the five channels, because three surfaces ask the same two
  # questions about them (is it on, are its credentials present) and a second
  # copy of this list is how a channel added later gets a readiness row and no
  # setup row, or the reverse.
  defp telegram_failure, do: channel_credentials_failure(:telegram)
  defp whatsapp_failure, do: channel_credentials_failure(:whatsapp)
  defp discord_failure, do: channel_credentials_failure(:discord)
  defp slack_failure, do: channel_credentials_failure(:slack)
  defp signal_failure, do: channel_credentials_failure(:signal)

  defp channel_credentials_failure(channel) do
    cond do
      not channel_enabled?(channel) -> nil
      channel_configured?(channel) -> nil
      true -> channel_failure(channel, Keyword.fetch!(@channel_actions, channel))
    end
  end

  defp realtime_failure do
    config = RealtimeConfig.current()

    cond do
      not config.enabled? ->
        nil

      config.provider != "openai" ->
        realtime_provider_row()

      regular_openai_api_key?() ->
        nil

      true ->
        realtime_key_row()
    end
  end

  defp realtime_provider_row do
    realtime_failure_row("Set the voice provider to `openai` in config.toml, or turn voice off.")
  end

  defp realtime_key_row do
    realtime_failure_row("Add the OpenAI API key in Providers settings, or turn voice off.")
  end

  defp channel_block(channel) do
    case Config.channel(channel) do
      {:ok, config} when is_list(config) -> config
      _not_configured -> []
    end
  end

  defp regular_openai_api_key? do
    Selection.configured?(:openai, provider_block(:openai))
  end

  defp present?(value) when is_binary(value), do: value != ""
  defp present?(value) when is_map(value), do: map_size(value) > 0
  defp present?(value) when is_list(value), do: value != []
  defp present?(nil), do: false
  defp present?(_value), do: true

  # One constructor per class, so `gating`, `pane` and `detail_key` are minted
  # where the cause is known rather than inferred later from the open
  # `component` string, which collapses three provider causes into one value.
  defp gating(failure, pane, detail_key) when pane in @panes,
    do: Map.merge(failure, %{gating: true, pane: pane, detail_key: detail_key})

  defp advisory(failure, pane, detail_key) when pane in @panes,
    do: Map.merge(failure, %{gating: false, pane: pane, detail_key: detail_key})

  # Two causes share `provider:missing_credentials:anthropic` and two share the
  # `:xai` key (api_key versus oauth), so each entry's sentence has to cover
  # both. That collapse is deliberate and bounded; it is not the open-component
  # collapse this key replaces.
  defp missing_credentials(provider, action) when is_atom(provider) do
    gating(
      %{component: "provider:#{provider}", action: action},
      "providers",
      "provider:missing_credentials:#{provider}"
    )
  end

  defp channel_failure(channel, action) when is_atom(channel) do
    advisory(%{component: "channel:#{channel}", action: action}, "channels", "channel:#{channel}")
  end

  defp realtime_failure_row(action) do
    advisory(%{component: "realtime:openai", action: action}, "voice", "realtime:openai")
  end

  # Ready is "no gating failure remains", never "no failure at all". Advisory
  # failures stay in the list so every surface can render them; they simply do
  # not mean setup is unfinished.
  defp status_for(failures) when is_list(failures) do
    case gating_failures(failures) do
      [] -> :ready
      [_ | _] -> :setup_required
    end
  end
end
