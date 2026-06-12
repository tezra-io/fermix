defmodule FermixCore.Providers.Selection do
  @moduledoc """
  Single source of truth for provider eligibility and the ordered provider
  route list (docs/design/MULTI_PROVIDER_FAILOVER.md §3).

  A provider is eligible for routing when its selected auth mode has usable
  credentials. `configured?/2` is the one block-level definition of
  "configured" — readiness, doctor, and the wizard's newly-configured diff
  all consume it instead of re-deriving api-key/oauth presence. Checks are
  pure reads of already-hydrated config/auth state — no network calls, no
  token refresh.

  `ordered_providers/1` returns `[primary | configured fallbacks]`,
  fallbacks in `ModelCatalog.providers/0` order. An unconfigured primary is
  skipped with a loud warning when at least one configured fallback exists
  (§6 — fall back rather than fail every turn); with no fallbacks the
  primary is kept so the turn fails with today's clear auth error and
  readiness points at the fix.

  Route-resolution failures never crash readiness or doctor: a primary that
  fails to resolve returns a tagged error; a fallback that fails to resolve
  is excluded with a loud warning (readiness reports fallback health).
  """

  require Logger

  alias FermixCore.Auth.Store
  alias FermixCore.Providers.Adapter
  alias FermixCore.Providers.Descriptor
  alias FermixCore.Providers.ModelCatalog
  alias FermixCore.Providers.PrimaryConfig
  alias FermixCore.Providers.RouteResolver

  @type route :: {Adapter.route_key(), keyword()}

  @spec primary_provider(keyword()) ::
          {:ok, ModelCatalog.provider()} | {:error, :multiple_primary}
  def primary_provider(_opts \\ []), do: PrimaryConfig.primary()

  @spec fallback_providers(keyword()) :: {:ok, [ModelCatalog.provider()]} | {:error, term()}
  def fallback_providers(opts \\ []) do
    with {:ok, primary} <- primary_provider(opts),
         :ok <- validate_known(primary) do
      {:ok, configured_non_primary(primary)}
    end
  end

  @spec ordered_providers(keyword()) :: {:ok, [ModelCatalog.provider()]} | {:error, term()}
  def ordered_providers(opts \\ []) do
    with {:ok, primary} <- primary_provider(opts),
         :ok <- validate_known(primary) do
      {:ok, order(primary, configured_non_primary(primary))}
    end
  end

  # A hand-edited unknown legacy provider must surface as a tagged error
  # (readiness/doctor report it), not crash route building.
  defp validate_known(provider) do
    if provider in ModelCatalog.providers() do
      :ok
    else
      {:error, {:unknown_provider, provider}}
    end
  end

  @spec ordered_routes(keyword()) :: {:ok, [route()]} | {:error, term()}
  def ordered_routes(opts \\ []) do
    with {:ok, [lead | rest]} <- ordered_providers(opts),
         {:ok, lead_route} <- resolve_route(lead, opts) do
      {:ok, [lead_route | resolve_fallback_routes(rest, opts)]}
    end
  end

  @doc """
  Whether `provider` has usable credentials in the current Application env.
  """
  @spec configured?(ModelCatalog.provider()) :: boolean()
  def configured?(provider) when is_atom(provider) do
    configured?(provider, env_block(provider))
  end

  @doc """
  Block-level eligibility — the single definition of "configured".

  Takes the provider's config block (from Application env or a setup
  snapshot) so setup's pre/post diff and runtime routing agree. OAuth
  profile presence is read from the auth store.
  """
  @spec configured?(ModelCatalog.provider(), keyword()) :: boolean()
  def configured?(:openai, block), do: present?(Keyword.get(block, :api_key))
  def configured?(:openai_codex, _block), do: codex_profile_usable?()
  def configured?(:anthropic, block), do: key_or_oauth_configured?(block, "anthropic_oauth")
  def configured?(:xai, block), do: key_or_oauth_configured?(block, "xai_oauth")

  # Descriptor providers without bespoke OAuth handling: configured? keys on
  # the credential their single auth mode needs — api_key presence for
  # `:api_key`, an explicit base_url for keyless `:none` (M12 §5.3). Unknown
  # atoms fail loud with a clear message instead of a FunctionClauseError.
  def configured?(provider, block) when is_atom(provider) do
    case Descriptor.fetch(provider) do
      {:ok, descriptor} ->
        descriptor_configured?(descriptor, block)

      :error ->
        raise ArgumentError,
              "unknown provider #{inspect(provider)}; " <>
                "expected one of #{Enum.map_join(Descriptor.ids(), ", ", &inspect/1)}"
    end
  end

  defp descriptor_configured?(descriptor, block) do
    case Descriptor.default_auth_mode(descriptor) do
      :api_key -> present?(Keyword.get(block, :api_key))
      :none -> present?(Keyword.get(block, :base_url))
      :oauth -> false
    end
  end

  defp order(primary, fallbacks) do
    cond do
      configured?(primary) -> [primary | fallbacks]
      fallbacks == [] -> [primary]
      true -> warn_unconfigured_primary(primary, fallbacks)
    end
  end

  defp warn_unconfigured_primary(primary, fallbacks) do
    Logger.warning(
      "Selection: primary provider #{primary} is not configured; " <>
        "routing to configured fallbacks #{inspect(fallbacks)}"
    )

    fallbacks
  end

  defp configured_non_primary(primary) do
    ModelCatalog.providers()
    |> Enum.reject(&(&1 == primary))
    |> Enum.filter(&configured?/1)
  end

  defp resolve_route(provider, opts) do
    {:ok, RouteResolver.resolve!(Keyword.put(opts, :provider, provider))}
  rescue
    error -> {:error, {:route_resolution_failed, provider, Exception.message(error)}}
  end

  defp resolve_fallback_routes(providers, opts) do
    Enum.flat_map(providers, fn provider ->
      case resolve_route(provider, opts) do
        {:ok, route} ->
          [route]

        {:error, {:route_resolution_failed, ^provider, message}} ->
          Logger.warning(
            "Selection: excluding fallback #{provider} (route resolution failed: #{message})"
          )

          []
      end
    end)
  end

  defp env_block(provider) do
    :fermix_core
    |> Application.get_env(:providers, [])
    |> Keyword.get(provider, [])
  end

  defp key_or_oauth_configured?(block, profile) do
    case Keyword.get(block, :auth_mode) do
      mode when mode in [:oauth, "oauth"] -> oauth_profile_usable?(profile)
      mode when mode in [nil, :api_key, "api_key"] -> present?(Keyword.get(block, :api_key))
      _invalid -> false
    end
  end

  defp oauth_profile_usable?(profile) do
    case Store.read(profile) do
      {:ok, entry} ->
        present?(entry.tokens.access_token) and
          Map.get(entry, :status) != "reauthorization_required"

      {:error, _reason} ->
        false
    end
  end

  defp codex_profile_usable? do
    case Store.read(:openai_codex) do
      {:ok, entry} -> present?(entry.tokens.access_token)
      {:error, _reason} -> false
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(nil), do: false
  defp present?(_value), do: true
end
