defmodule FermixCore.Management.SetupState do
  @moduledoc """
  The `setup.state.get` projection: everything a setup surface reads before it
  renders anything (M34 native setup §7.3).

  One request, one answer, no shell-outs and no metered call. Presence only:
  every credential is reported as a boolean or an account label, never as a
  value, so this result is safe to log, trace and export.

  It reads `Readiness`, `RestartState` and `Coexistence` **directly** rather
  than through the boot report. An out-of-process `config.toml` write, a reload
  or a reinstalled legacy unit changes the answer on the next call, with no save
  in between; a boot artifact would only change when someone happened to save.

  The one fact that cannot be measured on this path is the keychain ACL: reading
  a stored secret to find out whether it is readable costs a `security`
  subprocess per key and prompts on exactly the population it names. So
  `coexistence.secret_acl_restricted` publishes the last Doctor measurement out
  of `Setup.SecretAclState`, with `present: null` until one has run.
  """

  alias FermixCore.Auth.Store, as: AuthStore
  alias FermixCore.ComputerHistory
  alias FermixCore.ComputerUse
  alias FermixCore.ComputerUse.SidecarInstaller
  alias FermixCore.Config
  alias FermixCore.Meetings
  alias FermixCore.Providers.Descriptor
  alias FermixCore.Providers.PrimaryConfig
  alias FermixCore.Providers.Selection
  alias FermixCore.Readiness
  alias FermixCore.Realtime.Config, as: RealtimeConfig
  alias FermixCore.Setup.Coexistence
  alias FermixCore.Setup.RestartState
  alias FermixCore.Setup.SecretPaths
  alias FermixCore.Setup.SecretStore
  alias FermixCore.Transcription

  @personalization_keys [:user_name, :timezone, :communication_style]

  @doc """
  Builds the whole projection.

  Every source is injectable so the shape can be driven without a tree, a
  keychain or a home; each seam injects a *source*, never a rendered result.
  """
  @spec report(keyword()) :: map()
  def report(opts \\ []) when is_list(opts) do
    readiness = source(opts, :readiness, &Readiness.report/0)
    restart = source(opts, :restart, fn -> RestartState.restart() end)

    %{
      "readiness" => project_readiness(readiness),
      "restart" => project_restart(restart),
      "providers" => project_providers(opts),
      "channels" => project_channels(),
      "personalization" => project_personalization(),
      "features" => project_features(opts),
      "profile" => profile(),
      "coexistence" => project_coexistence(opts)
    }
  end

  defp project_readiness(readiness) do
    %{
      "status" => Atom.to_string(Map.fetch!(readiness, :status)),
      "failures" => Enum.map(Map.get(readiness, :failures, []), &project_failure/1)
    }
  end

  # `gating` is on the wire because the app routes on *which* failure gates and
  # `status` alone cannot say which. `detail_key` is the closed-set copy key,
  # deliberately not `component`, which is an open string that collapses three
  # distinct provider causes into one value.
  defp project_failure(failure) do
    %{
      "component" => failure.component,
      "gating" => failure.gating,
      "pane" => failure.pane,
      "detail_key" => failure.detail_key
    }
  end

  defp project_restart(restart) do
    reasons =
      Enum.map(Map.get(restart, :reasons, []), fn reason ->
        %{"section" => reason.section, "sentence" => reason.sentence}
      end)

    %{"required" => Map.get(restart, :required, false) == true, "reasons" => reasons}
  end

  defp project_providers(opts) do
    primary = primary_provider()
    accounts = source(opts, :accounts, &auth_accounts/0)

    Enum.map(Descriptor.all(), fn descriptor ->
      project_provider(descriptor, provider_block(descriptor.id), primary, accounts)
    end)
  end

  defp project_provider(descriptor, block, primary, accounts) do
    account = Map.get(accounts, descriptor.id)

    %{
      "id" => Atom.to_string(descriptor.id),
      "label" => descriptor.label,
      "auth_modes" => Enum.map(descriptor.auth_modes, &Atom.to_string/1),
      "auth_mode" => auth_mode(descriptor, block),
      "configured" => Selection.configured?(descriptor.id, block),
      "primary" => descriptor.id == primary,
      "present_key" => present_key?(descriptor),
      "default_model" => scalar(Keyword.get(block, :default_model)),
      "reasoning_effort" => scalar(Keyword.get(block, :reasoning_effort)),
      "fast" => boolean_or_nil(Keyword.get(block, :fast)),
      "account_label" => account && account.label,
      "token_state" => account && account.state
    }
  end

  defp auth_mode(descriptor, block) do
    case Keyword.get(block, :auth_mode) do
      nil -> Atom.to_string(Descriptor.default_auth_mode(descriptor))
      mode -> scalar(mode)
    end
  end

  # "Present" means a sentinel or a plaintext value sits at the key's own
  # `SecretPaths` path, never "the keychain holds an item": a key stored without
  # its sentinel is never read back, so reporting it present would describe a
  # credential the runtime cannot use.
  defp present_key?(descriptor) do
    Enum.any?(descriptor.secrets, fn key ->
      value = SecretStore.get_snapshot_value(live_snapshot(), SecretPaths.fetch!(key).path)
      is_binary(value) and value != ""
    end)
  end

  defp live_snapshot do
    %{
      fermix_core: [
        providers: Application.get_env(:fermix_core, :providers, []),
        tools: Application.get_env(:fermix_core, :tools, []),
        plugin_secrets: Application.get_env(:fermix_core, :plugin_secrets, %{})
      ],
      fermix_channels: [
        telegram: Application.get_env(:fermix_channels, :telegram, []),
        whatsapp: Application.get_env(:fermix_channels, :whatsapp, []),
        discord: Application.get_env(:fermix_channels, :discord, []),
        slack: Application.get_env(:fermix_channels, :slack, []),
        signal: Application.get_env(:fermix_channels, :signal, [])
      ]
    }
  end

  # The account label and token state come from the auth store, which is the one
  # place an OAuth identity lives. A provider with no entry answers nil for
  # both rather than inventing a state.
  defp auth_accounts do
    Descriptor.ids()
    |> Enum.flat_map(&account_row/1)
    |> Map.new()
  end

  # The profile name is not the provider id (anthropic and xai store their
  # entries under their own profile), so the one resolver in `Auth.Store` says
  # which key to read. A provider with no OAuth profile has no account row.
  defp account_row(id) do
    with profile when is_binary(profile) <- AuthStore.profile(id),
         {:ok, entry} <- AuthStore.read(profile) do
      [{id, %{label: AuthStore.account_label(entry), state: token_state(entry)}}]
    else
      _absent -> []
    end
  end

  defp token_state(entry) do
    case Map.get(entry, :expires_at) do
      %DateTime{} = expires_at -> expiry_word(DateTime.compare(expires_at, DateTime.utc_now()))
      _absent -> "valid"
    end
  end

  defp expiry_word(:gt), do: "valid"
  defp expiry_word(_past_or_now), do: "expired"

  defp project_channels do
    Enum.map(Readiness.channels(), fn channel ->
      enabled? = Readiness.channel_enabled?(channel)
      configured? = Readiness.channel_configured?(channel)

      %{
        "name" => Atom.to_string(channel),
        "enabled" => enabled?,
        "configured" => configured?,
        "status" => channel_status(enabled?, configured?),
        "mode" => channel_mode(channel, enabled?)
      }
    end)
  end

  # A channel that is off has no status and no mode: reporting one would make a
  # switched-off channel look like a broken one.
  defp channel_status(false, _configured?), do: nil
  defp channel_status(true, true), do: "ok"
  defp channel_status(true, false), do: "setup_required"

  defp channel_mode(_channel, false), do: nil

  defp channel_mode(channel, true) do
    case Config.channel(channel) do
      {:ok, config} when is_list(config) -> scalar(Keyword.get(config, :mode))
      _not_configured -> nil
    end
  end

  defp project_personalization do
    config = Application.get_env(:fermix_core, :personalization, [])

    present =
      Map.new(@personalization_keys, fn key ->
        {Atom.to_string(key), present?(Keyword.get(config, key))}
      end)

    %{"present" => present}
  end

  defp project_features(opts) do
    installed? = source(opts, :sidecar_installed?, &SidecarInstaller.installed?/0)
    history_enabled? = ComputerHistory.enabled?()

    %{
      "voice" => RealtimeConfig.enabled?(),
      "voice_notes" => match?({:ok, _active}, Transcription.active_backend()),
      "meetings" => Meetings.enabled?(),
      "computer_use" => ComputerUse.enabled?(),
      "computer_history" => %{
        "enabled" => history_enabled?,
        "installed" => installed?,
        "ready" => history_enabled? and installed? and ComputerHistory.macos?()
      }
    }
  end

  defp project_coexistence(opts) do
    unit = source(opts, :legacy_service_unit, fn -> Coexistence.legacy_service_unit() end)
    acl = source(opts, :secret_acl_restricted, fn -> Coexistence.last_secret_acl_restricted() end)
    state = source(opts, :config_state, fn -> Coexistence.config_state() end)

    %{
      "legacy_service_unit" => %{
        "present" => unit.present,
        "scope" => unit.scope && Atom.to_string(unit.scope),
        "path" => unit.path
      },
      "config_state" => Coexistence.config_state_word(state),
      "secret_acl_restricted" => %{"present" => acl.present, "keys" => acl.keys}
    }
  end

  defp profile, do: scalar(Application.get_env(:fermix_core, :profile, "general"))

  defp primary_provider do
    case PrimaryConfig.primary() do
      {:ok, provider} -> provider
      {:error, :multiple_primary} -> nil
    end
  end

  defp provider_block(provider) do
    case Config.provider(provider) do
      {:ok, config} when is_list(config) -> config
      _not_configured -> []
    end
  end

  defp present?(value) when is_binary(value), do: value != ""
  defp present?(nil), do: false
  defp present?(_value), do: true

  defp boolean_or_nil(value) when is_boolean(value), do: value
  defp boolean_or_nil(_value), do: nil

  defp scalar(value) when is_atom(value) and value not in [nil, true, false],
    do: Atom.to_string(value)

  defp scalar(value) when is_binary(value), do: value
  defp scalar(_value), do: nil

  defp source(opts, key, default) when is_atom(key) do
    opts |> Keyword.get(key, default) |> then(& &1.())
  end
end
