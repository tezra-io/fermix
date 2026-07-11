defmodule FermixCore.Providers.RouteResolver do
  @moduledoc """
  Translates Fermix configuration into a `{route_key, adapter_opts}` pair
  for `AgentLoop`. Keeps callers (AgentServer, MainAgent) out of the
  business of knowing which adapter wires up which auth mode.

  `resolve!/1` dispatches on the `:provider` opt:

    * `nil` / `:openai` — standard OpenAI provider using API-key auth.
      Routes to `OpenAI.Responses` (or `OpenAI.ChatCompletions` for
      non-eligible models / proxy URLs).
    * `:openai_codex` — explicit Codex (ChatGPT Plus) surface. Uses a
      different URL, body, and streaming shape.
    * `:anthropic` — Anthropic Messages route key.

  Codex OAuth is **only** selected via explicit `provider: :openai_codex`.
  """

  alias FermixCore.Auth.TokenManager
  alias FermixCore.Auth.TokenSupervisor
  alias FermixCore.Config
  alias FermixCore.Providers.Adapter
  alias FermixCore.Providers.Descriptor
  alias FermixCore.Providers.ModelCatalog
  alias FermixCore.Providers.PrimaryConfig
  alias FermixCore.Providers.ReasoningEffort

  @default_openai_base_url "https://api.openai.com/v1"
  @default_codex_base_url "https://chatgpt.com/backend-api/codex/responses"
  @default_anthropic_base_url "https://api.anthropic.com/v1"
  @default_anthropic_model "claude-sonnet-4-6"
  @default_xai_base_url "https://api.x.ai/v1"

  @type resolution :: {Adapter.route_key(), keyword()}

  @spec resolve!(keyword()) :: resolution()
  def resolve!(opts \\ []) do
    {route_key, adapter_opts} =
      case Keyword.get(opts, :provider) || configured_provider() do
        nil -> resolve_openai!(opts)
        :openai -> resolve_openai!(opts)
        :openai_codex -> resolve_codex!(opts)
        :anthropic -> resolve_anthropic!(opts)
        :xai -> resolve_xai!(opts)
        other -> resolve_descriptor!(other, opts)
      end

    {route_key, cap_effort_to_model(route_key, adapter_opts)}
  end

  # A provider's effort vocabulary can permit a level (e.g. `:max` on OpenAI)
  # that only some of its models accept. Cap the resolved effort to the route
  # model's catalog ceiling so an over-reaching config/default self-heals to the
  # model's top instead of 400-ing at the provider. Routes whose model has no
  # ceiling (every provider except the older OpenAI models) pass through
  # untouched — provider-level clamping stays in the adapter.
  defp cap_effort_to_model(%{provider: provider, model: model}, adapter_opts) do
    with {:ok, value} <- Keyword.fetch(adapter_opts, :reasoning_effort),
         ceiling when not is_nil(ceiling) <- ModelCatalog.model_effort_ceiling(provider, model),
         {:ok, level} <- ReasoningEffort.parse(value) do
      Keyword.put(adapter_opts, :reasoning_effort, ReasoningEffort.cap(level, ceiling))
    else
      _ -> adapter_opts
    end
  end

  # Generic resolver for descriptor providers without bespoke handling
  # (M12 §5.2): single auth mode, no OAuth branches. Unknown atoms keep
  # the loud gate. Effort is resolved only for `effort?` descriptors —
  # effort-less providers never carry :reasoning_effort in adapter_opts.
  defp resolve_descriptor!(provider, opts) do
    case Descriptor.fetch(provider) do
      {:ok, descriptor} -> resolve_from_descriptor(descriptor, opts)
      :error -> raise ArgumentError, "no resolver for provider #{inspect(provider)}"
    end
  end

  defp resolve_from_descriptor(descriptor, opts) do
    config = descriptor_config(descriptor.id)
    auth_mode = Descriptor.default_auth_mode(descriptor)

    model =
      Keyword.get(opts, :model) ||
        Keyword.get(config, :default_model, ModelCatalog.default_model_for(descriptor.id))

    base_url =
      Keyword.get(opts, :base_url) ||
        Keyword.get(config, :base_url, descriptor.default_base_url)

    route_key = %{provider: descriptor.id, model: model, auth_mode: auth_mode, base_url: base_url}

    adapter_opts =
      [model: model, base_url: base_url, provider: descriptor.id, auth: auth_mode]
      |> maybe_put_descriptor_api_key(descriptor, auth_mode, opts, config)
      |> maybe_put(:temperature, Keyword.get(opts, :temperature))
      |> maybe_put_descriptor_effort(descriptor, opts)
      |> put_descriptor_req_options(descriptor, opts)

    {route_key, adapter_opts}
  end

  defp descriptor_config(provider) do
    case Config.provider(provider) do
      {:ok, config} -> config
      {:error, :not_configured} -> []
    end
  end

  defp maybe_put_descriptor_api_key(adapter_opts, _descriptor, :api_key, opts, config) do
    maybe_put(
      adapter_opts,
      :api_key,
      Keyword.get(opts, :api_key) || Keyword.get(config, :api_key)
    )
  end

  defp maybe_put_descriptor_api_key(adapter_opts, _descriptor, _auth_mode, _opts, _config) do
    adapter_opts
  end

  defp maybe_put_descriptor_effort(adapter_opts, %{effort?: true} = descriptor, opts) do
    maybe_put(adapter_opts, :reasoning_effort, resolve_reasoning_effort(descriptor.id, opts))
  end

  defp maybe_put_descriptor_effort(adapter_opts, _descriptor, _opts), do: adapter_opts

  # Descriptor defaults under explicit per-route req_options — a plain
  # keyword merge here; Req.merge/2 applies the result in the adapter.
  defp put_descriptor_req_options(adapter_opts, descriptor, opts) do
    case Keyword.merge(descriptor.default_req_options, Keyword.get(opts, :req_options, [])) do
      [] -> adapter_opts
      merged -> Keyword.put(adapter_opts, :req_options, merged)
    end
  end

  # PrimaryConfig owns the primary-flag + legacy-`agent.provider` migration
  # rules, so bare `resolve!()` callers read the same primary as Selection.
  defp configured_provider do
    case PrimaryConfig.primary() do
      {:ok, provider} ->
        provider

      {:error, :multiple_primary} ->
        raise ArgumentError,
              "more than one provider has primary = true in config.toml; " <>
                "mark exactly one provider primary"
    end
  end

  @spec resolve_openai!(keyword()) :: resolution()
  def resolve_openai!(opts \\ []) do
    config =
      case Config.provider(:openai) do
        {:ok, cfg} -> cfg
        {:error, :not_configured} -> []
      end

    model = Keyword.get(opts, :model) || Keyword.get(config, :default_model, "gpt-4o")
    auth_mode = Keyword.get(opts, :auth_mode) || Keyword.get(config, :auth_mode, :api_key)

    base_url =
      Keyword.get(opts, :base_url) || Keyword.get(config, :base_url, @default_openai_base_url)

    case auth_mode do
      :api_key -> resolve_openai_api_key(model, base_url, opts, config)
      :oauth -> raise_openai_oauth!()
      other -> raise ArgumentError, "Unknown OpenAI auth_mode: #{inspect(other)}"
    end
  end

  @spec resolve_codex!(keyword()) :: resolution()
  def resolve_codex!(opts \\ []) do
    config =
      case Config.provider(:openai_codex) do
        {:ok, cfg} -> cfg
        {:error, :not_configured} -> []
      end

    model =
      Keyword.get(opts, :model) ||
        Keyword.get(config, :default_model, ModelCatalog.default_model_for(:openai_codex))

    base_url =
      Keyword.get(opts, :base_url) || @default_codex_base_url

    route_key = %{
      provider: :openai_codex,
      model: model,
      auth_mode: :oauth,
      base_url: base_url
    }

    adapter_opts =
      [
        model: model,
        base_url: base_url,
        token_server: Keyword.get(opts, :token_server, TokenManager)
      ]
      |> maybe_put(:access_token, Keyword.get(opts, :access_token))
      |> maybe_put(:reasoning_effort, resolve_reasoning_effort(:openai_codex, opts))
      |> maybe_put(:fast, resolve_codex_fast(opts))
      |> maybe_put(:req_options, Keyword.get(opts, :req_options))

    {route_key, adapter_opts}
  end

  defp resolve_openai_api_key(model, base_url, opts, config) do
    api_key = Keyword.get(opts, :api_key) || Keyword.get(config, :api_key)

    route_key = %{
      provider: :openai,
      model: model,
      auth_mode: :api_key,
      base_url: base_url
    }

    adapter_opts =
      [model: model, base_url: base_url, api_key: api_key, provider: :openai]
      |> maybe_put(:temperature, Keyword.get(opts, :temperature))
      |> maybe_put(:reasoning_effort, resolve_reasoning_effort(:openai, opts))
      |> maybe_put(:req_options, Keyword.get(opts, :req_options))

    {route_key, adapter_opts}
  end

  defp raise_openai_oauth! do
    raise ArgumentError,
          "openai provider supports api_key auth only; use provider: :openai_codex for Codex OAuth"
  end

  defp resolve_anthropic!(opts) do
    config =
      case Config.provider(:anthropic) do
        {:ok, cfg} -> cfg
        {:error, :not_configured} -> []
      end

    model =
      Keyword.get(opts, :model) ||
        Keyword.get(config, :default_model, @default_anthropic_model)

    base_url =
      Keyword.get(opts, :base_url) ||
        Keyword.get(config, :base_url, @default_anthropic_base_url)

    auth_mode =
      parse_anthropic_auth_mode!(
        Keyword.get(opts, :auth_mode) || Keyword.get(config, :auth_mode, :api_key)
      )

    route_key = %{provider: :anthropic, model: model, auth_mode: auth_mode, base_url: base_url}

    {route_key, anthropic_adapter_opts(auth_mode, model, base_url, opts, config)}
  end

  defp anthropic_adapter_opts(:api_key, model, base_url, opts, config) do
    [model: model, base_url: base_url]
    |> maybe_put(:api_key, Keyword.get(opts, :api_key) || Keyword.get(config, :api_key))
    |> maybe_put(:temperature, Keyword.get(opts, :temperature))
    |> maybe_put(:reasoning_effort, resolve_reasoning_effort(:anthropic, opts))
    |> maybe_put(:req_options, Keyword.get(opts, :req_options))
  end

  # The configured api_key never leaks into the oauth route — the selected
  # auth mode is the billing expectation (design doc §5.2, no fallbacks).
  defp anthropic_adapter_opts(:oauth, model, base_url, opts, _config) do
    [
      model: model,
      base_url: base_url,
      token_server: Keyword.get(opts, :token_server, TokenSupervisor),
      auth_profile: "anthropic_oauth"
    ]
    |> maybe_put(:access_token, Keyword.get(opts, :access_token))
    |> maybe_put(:temperature, Keyword.get(opts, :temperature))
    |> maybe_put(:reasoning_effort, resolve_reasoning_effort(:anthropic, opts))
    |> maybe_put(:req_options, Keyword.get(opts, :req_options))
  end

  defp resolve_xai!(opts) do
    config =
      case Config.provider(:xai) do
        {:ok, cfg} -> cfg
        {:error, :not_configured} -> []
      end

    model =
      Keyword.get(opts, :model) ||
        Keyword.get(config, :default_model, ModelCatalog.default_model_for(:xai))

    base_url =
      Keyword.get(opts, :base_url) || Keyword.get(config, :base_url, @default_xai_base_url)

    auth_mode =
      parse_auth_mode!(
        :xai,
        Keyword.get(opts, :auth_mode) || Keyword.get(config, :auth_mode, :api_key)
      )

    route_key = %{provider: :xai, model: model, auth_mode: auth_mode, base_url: base_url}

    {route_key, xai_adapter_opts(auth_mode, model, base_url, opts, config)}
  end

  defp xai_adapter_opts(:api_key, model, base_url, opts, config) do
    [model: model, base_url: base_url]
    |> maybe_put(:api_key, Keyword.get(opts, :api_key) || Keyword.get(config, :api_key))
    |> maybe_put(:temperature, Keyword.get(opts, :temperature))
    |> maybe_put(:reasoning_effort, resolve_reasoning_effort(:xai, opts))
    |> maybe_put(:req_options, Keyword.get(opts, :req_options))
  end

  # The configured api_key never leaks into the oauth route (§6.3 — the
  # selected auth mode is the billing expectation, no fallbacks).
  defp xai_adapter_opts(:oauth, model, base_url, opts, _config) do
    [
      model: model,
      base_url: base_url,
      token_server: Keyword.get(opts, :token_server, TokenSupervisor),
      auth_profile: "xai_oauth"
    ]
    |> maybe_put(:access_token, Keyword.get(opts, :access_token))
    |> maybe_put(:temperature, Keyword.get(opts, :temperature))
    |> maybe_put(:reasoning_effort, resolve_reasoning_effort(:xai, opts))
    |> maybe_put(:req_options, Keyword.get(opts, :req_options))
  end

  defp parse_anthropic_auth_mode!(mode), do: parse_auth_mode!(:anthropic, mode)

  defp parse_auth_mode!(_provider, mode) when mode in [:api_key, :oauth], do: mode
  defp parse_auth_mode!(_provider, "api_key"), do: :api_key
  defp parse_auth_mode!(_provider, "oauth"), do: :oauth

  defp parse_auth_mode!(provider, other) do
    raise ArgumentError,
          "invalid #{provider} auth_mode: #{inspect(other)}; expected api_key or oauth"
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  # Effort precedence: explicit opt > per-provider config block > nil (omitted).
  # The adapter omits the request body field when the result is nil or :none,
  # so omitted-here = "use the provider's server-side default".
  #
  # Validation happens here, at config-read time, not deep in the adapter
  # (CLAUDE.md #6 — fail loud at the public boundary). A hand-edited
  # config.toml with `reasoning_effort = "absurd"` raises here on the very
  # first call to `RouteResolver.resolve!/1`, not partway through a tool
  # loop. Wizard writes (Stage 4) are pre-validated, so legitimate flows
  # never trip this.
  defp resolve_reasoning_effort(provider, opts) do
    value =
      case Keyword.fetch(opts, :reasoning_effort) do
        {:ok, v} ->
          v

        :error ->
          case Config.provider(provider) do
            {:ok, cfg} -> Keyword.get(cfg, :reasoning_effort)
            {:error, :not_configured} -> nil
          end
      end

    validate_reasoning_effort!(value)
    value
  end

  defp validate_reasoning_effort!(nil), do: :ok

  defp validate_reasoning_effort!(value) do
    # ReasoningEffort owns the canonical enum — reuse it as the validator.
    # Per-provider supportedness (clamp/reject) is applied at request-build
    # time in the adapter, not here.
    case ReasoningEffort.parse(value) do
      {:ok, _level} ->
        :ok

      :error ->
        raise ArgumentError,
              "invalid reasoning_effort: #{inspect(value)}; " <>
                "expected one of #{inspect(ReasoningEffort.levels())}"
    end
  end

  defp resolve_codex_fast(opts) do
    value =
      case Keyword.fetch(opts, :fast) do
        {:ok, fast} ->
          fast

        :error ->
          case Config.provider(:openai_codex) do
            {:ok, cfg} -> Keyword.get(cfg, :fast)
            {:error, :not_configured} -> nil
          end
      end

    validate_fast!(value)
    value
  end

  defp validate_fast!(nil), do: :ok
  defp validate_fast!(value) when is_boolean(value), do: :ok

  defp validate_fast!(value) do
    raise ArgumentError, "invalid Codex fast mode: #{inspect(value)}; expected true or false"
  end
end
