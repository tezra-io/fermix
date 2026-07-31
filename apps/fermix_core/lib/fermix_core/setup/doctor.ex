defmodule FermixCore.Setup.Doctor do
  @moduledoc """
  Live auth probes for configured providers.

  `probe_provider/2` sends a minimal API request to a provider and
  classifies the response into `{:ok, %{...}}` or
  `{:error, reason}`. Used by `fermix doctor --full` and the wizard
  finalize step to fail loud at config time instead of on the first
  user message.

  Probes cost ~$0.0001 (1 token) and exercise auth, model id, and
  endpoint URL. They do NOT exercise SSE function-call shape — that
  path is covered by recorded fixture tests (see
  `docs/MILESTONE_4_10_CODEX_PARITY.md` §7).

  Inject `req_options: [plug: ...]` to stub HTTP in tests.
  """

  alias FermixCore.Auth.CodexToken
  alias FermixCore.Auth.Redaction
  alias FermixCore.Auth.Store
  alias FermixCore.Auth.TokenExpiry
  alias FermixCore.Auth.TokenManager
  alias FermixCore.Auth.TokenSupervisor
  alias FermixCore.ComputerUse
  alias FermixCore.ComputerUse.Probe, as: ComputerUseProbe
  alias FermixCore.ComputerUse.SidecarInstaller
  alias FermixCore.Memory.CompactionConfig
  alias FermixCore.Providers.ModelCatalog
  alias FermixCore.Providers.PrimaryConfig
  alias FermixCore.Tools.Media.Registry, as: MediaRegistry
  alias FermixCore.Tools.WebSearch
  alias FermixCore.Transcription

  @type provider ::
          :openai | :openai_codex | :anthropic | :xai | :openrouter | :ollama | :mistral
  @type probe_ok :: %{provider: provider(), model: String.t(), latency_ms: non_neg_integer()}
  @type channel_probe :: %{
          required(:channel) => atom(),
          required(:name) => String.t(),
          required(:status) => :ok | :warn | :error,
          required(:detail) => String.t(),
          optional(:latency_ms) => non_neg_integer()
        }
  @type readiness_probe :: %{
          provider: {:ok, probe_ok()} | {:error, probe_error()},
          channels: [channel_probe()]
        }
  @type compaction_report :: %{
          enabled: boolean(),
          threshold: float(),
          provider: provider(),
          model: String.t(),
          context_window: pos_integer(),
          compact_at_tokens: non_neg_integer(),
          catalog: [model_window()]
        }
  @type command_owner_report :: %{
          channel: atom(),
          enabled: boolean(),
          owner_user_id: String.t() | nil,
          command_allowlist: [String.t()]
        }
  @type web_search_report :: %{
          :backend => atom(),
          :credential_present? => boolean(),
          optional(:probe_result) => atom(),
          optional(:result_count) => non_neg_integer()
        }
  @type image_report ::
          %{:status => :configured, :backend => atom(), :credential_present? => boolean()}
          | %{status: :unconfigured}
          | %{status: :error, error: String.t()}
  @type transcription_report ::
          %{:status => :configured, :backend => atom(), :credential_present? => boolean()}
          | %{status: :error, error: String.t()}
  @type model_window :: %{
          provider: provider(),
          model: String.t(),
          context_window: pos_integer()
        }
  @type probe_error ::
          {:misconfigured, reason :: String.t()}
          | {:auth_scope_mismatch, surface :: String.t(), hint :: String.t()}
          | {:server_error, status :: pos_integer(), body :: term()}
          | {:network, reason :: term()}

  @openai_default_url "https://api.openai.com/v1/responses"
  @codex_default_url "https://chatgpt.com/backend-api/codex/responses"
  @anthropic_default_url "https://api.anthropic.com/v1/messages"
  # xAI base_url is a ROOT (the adapter appends /responses); the probe must
  # do the same so a configured/overlaid root base_url hits the same URL the
  # runtime does. Codex/OpenAI/Anthropic keep full default URLs because their
  # blocks don't persist a base_url through setup.
  @xai_default_base_url "https://api.x.ai/v1"
  @openrouter_default_base_url "https://openrouter.ai/api/v1"
  @mistral_default_base_url "https://api.mistral.ai/v1"
  @command_channels [:telegram, :whatsapp, :discord, :slack, :signal]
  @web_search_probe_query "fermix web search health check"
  @default_probe_timeout_ms 5_000

  @spec probe_provider(provider(), keyword()) :: {:ok, probe_ok()} | {:error, probe_error()}
  def probe_provider(provider, opts \\ [])
  def probe_provider(:openai, opts), do: probe_openai(opts)
  def probe_provider(:openai_codex, opts), do: probe_codex(opts)
  def probe_provider(:anthropic, opts), do: probe_anthropic(opts)
  def probe_provider(:xai, opts), do: probe_xai(opts)
  def probe_provider(:openrouter, opts), do: probe_openrouter(opts)
  def probe_provider(:ollama, opts), do: probe_ollama(opts)
  def probe_provider(:mistral, opts), do: probe_mistral(opts)

  def probe_provider(other, _opts) do
    raise ArgumentError,
          "unknown provider #{inspect(other)}; expected one of " <>
            Enum.map_join(ModelCatalog.providers(), ", ", &inspect/1)
  end

  @spec probe_active(keyword()) :: {:ok, probe_ok()} | {:error, probe_error()}
  def probe_active(opts \\ []) do
    provider = active_provider()
    probe_provider(provider, opts)
  end

  @doc """
  Offline freshness sweep over the auth store: the sorted profile names whose
  access token is stale (well past expiry — `TokenExpiry.stale?/1`), i.e. dormant
  and likely needing re-auth. No network. Shared by `fermix doctor` and the web
  setup doctor pane so both define "stale" the same way.
  """
  @spec stale_token_profiles() :: {:ok, [String.t()]} | {:error, term()}
  def stale_token_profiles do
    with {:ok, profiles} <- Store.list_profiles() do
      {:ok, profiles |> Enum.filter(&stale_profile?/1) |> Enum.map(&elem(&1, 0)) |> Enum.sort()}
    end
  end

  defp stale_profile?({_profile, entry}), do: TokenExpiry.stale?(entry.expires_at)

  @doc """
  Computer-use OS-permission state for the operator surfaces (`fermix doctor` and
  the web setup card), so both define readiness the same way. Returns one structured
  result:

    * `%{state: :disabled}`      — the feature is off (nothing to check).
    * `%{state: :not_installed}` — enabled, but the native sidecar isn't installed.
    * `%{state: :probed, ...}`   — the live grant breakdown (`screen_capture`,
      `input_control`, `display_server`, `platform`) from a non-prompting sidecar
      probe.

  `{:error, reason}` only when an installed sidecar could not be probed. The probe
  is the only path that spawns the sidecar, so the disabled/not-installed cases stay
  cheap.
  """
  @spec computer_use_permissions() :: {:ok, map()} | {:error, term()}
  def computer_use_permissions do
    cond do
      not ComputerUse.enabled?() -> {:ok, %{state: :disabled}}
      not SidecarInstaller.installed?() -> {:ok, %{state: :not_installed}}
      true -> probe_computer_use()
    end
  end

  defp probe_computer_use do
    case ComputerUseProbe.run() do
      {:ok, result} -> {:ok, Map.put(result, :state, :probed)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec probe_readiness(keyword()) :: readiness_probe()
  def probe_readiness(opts \\ []) do
    %{
      provider: probe_active(opts),
      channels: probe_channels(opts)
    }
  end

  @spec probe_channels(keyword()) :: [channel_probe()]
  def probe_channels(opts \\ []) do
    channel_probe_specs()
    |> Enum.map(&probe_channel(&1, opts))
  end

  @spec channel_probe_specs() :: [map()]
  def channel_probe_specs do
    channel_registry()
    |> Enum.filter(&enabled_probe_channel?/1)
  end

  @spec compaction_report() :: compaction_report()
  def compaction_report do
    config = Application.get_env(:fermix_core, :compaction, []) |> CompactionConfig.normalize()
    provider = active_provider()
    config_for_provider = provider_config(provider)
    model = effective_model(config_for_provider, provider)
    context_window = ModelCatalog.context_window_for(provider, model)
    threshold = CompactionConfig.threshold(config)

    %{
      enabled: CompactionConfig.enabled?(config),
      threshold: threshold,
      provider: provider,
      model: model,
      context_window: context_window,
      compact_at_tokens: trunc(threshold * context_window),
      catalog: catalog_windows()
    }
  end

  @spec command_owner_report() :: [command_owner_report()]
  def command_owner_report do
    Enum.map(@command_channels, fn channel ->
      config = Application.get_env(:fermix_channels, channel, [])

      %{
        channel: channel,
        enabled: Keyword.get(config, :enabled, false) == true,
        owner_user_id: FermixCore.Config.channel_command_owner_user_id(channel),
        command_allowlist: FermixCore.Config.channel_command_allowlist(channel)
      }
    end)
  end

  @type streaming_report :: %{
          channel: atom(),
          name: String.t(),
          streaming: String.t(),
          capability: :draft_edit | :none
        }

  @doc """
  Per-channel draft-streaming opt-in vs channel capability
  (docs/design/CHANNEL_STREAMING.md §7). Config + module introspection only —
  no network. A channel opted into `streaming = "draft"` without the
  `:draft_edit` capability is the misconfiguration doctor warns about.
  """
  @spec streaming_config_report() :: [streaming_report()]
  def streaming_config_report do
    channel_registry()
    |> Enum.flat_map(&streaming_channel_report/1)
  end

  defp streaming_channel_report(%{config_key: nil}), do: []

  defp streaming_channel_report(%{config_key: key, name: name, adapter: adapter})
       when is_atom(key) do
    case FermixCore.Config.channel(key) do
      {:ok, config} ->
        [
          %{
            channel: key,
            name: name,
            # Mirrors the gateway default (a configured channel streams).
            streaming: Keyword.get(config, :streaming, "block"),
            capability: adapter_stream_capability(adapter)
          }
        ]

      {:error, :not_configured} ->
        []
    end
  end

  defp adapter_stream_capability(adapter) when is_atom(adapter) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :stream_capability, 0) do
      adapter.stream_capability()
    else
      :none
    end
  end

  @doc """
  Reports the active `web_search` backend and whether its credential is present.

  Offline by default (no network). With `full: true` and a configured
  credential, runs a one-result live probe through the backend and adds
  `:probe_result` / `:result_count`. Inject `req_options`/`net_resolver`
  to stub the probe in tests.
  """
  @spec web_search_report(keyword()) :: web_search_report()
  def web_search_report(opts \\ []) do
    full? = Keyword.get(opts, :full, false)
    config = WebSearch.config()
    {backend, module} = WebSearch.active_backend(config)
    present? = module.configured?(config)
    base = %{backend: backend, credential_present?: present?}

    if full? and present? do
      Map.merge(base, web_search_probe(module, config, opts))
    else
      base
    end
  end

  defp web_search_probe(module, config, opts) do
    probe_opts = Keyword.put(config, :context, web_search_probe_context(opts))

    case module.search(@web_search_probe_query, probe_opts) do
      {:ok, results, _trace} -> %{probe_result: :ok, result_count: length(results)}
      {:error, reason, _trace} -> %{probe_result: web_search_probe_tag(reason), result_count: 0}
    end
  end

  defp web_search_probe_context(opts) do
    Enum.reduce([:req_options, :net_resolver], %{}, fn key, acc ->
      case Keyword.get(opts, key) do
        nil -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end

  defp web_search_probe_tag(reason) do
    cond do
      String.starts_with?(reason, "auth_failed") -> :auth_failed
      String.starts_with?(reason, "rate_limited") -> :rate_limited
      String.starts_with?(reason, "provider_error") -> :provider_error
      String.starts_with?(reason, "parser_changed") -> :parser_changed
      true -> :network
    end
  end

  @doc """
  Reports the active `generate_image` backend and whether its credential is
  present.

  Offline only — unlike `web_search_report/1` there is no `full:` live probe,
  because an image-generation call costs real money (not a 1-token ping). The
  doctor checks credential presence, never bills the operator.
  """
  @spec image_report(keyword()) :: image_report()
  def image_report(_opts \\ []) do
    case FermixCore.Config.tool(:generate_image) do
      {:ok, config} -> image_report_for(config)
      {:error, :not_configured} -> %{status: :unconfigured}
    end
  end

  defp image_report_for(config) do
    case MediaRegistry.active_backend(:image, config) do
      {:ok, module} ->
        %{
          status: :configured,
          backend: module.name(),
          credential_present?: module.configured?(config)
        }

      {:error, reason} ->
        %{status: :error, error: reason}
    end
  end

  @doc """
  Reports the active transcription backend and whether its credential resolves.

  Offline only — like `image_report/1`, it never opens a network call. Resolves
  the configured backend through the registry (fail-loud on an unknown name) and
  asks the backend module whether a credential is present (`configured?/1`), so
  the doctor surfaces the invisible-key-coupling case (a backend selected with no
  key) without transcribing anything. Unlike `image_report/1` there is no
  `:unconfigured` state: `[fermix_core.transcription]` always carries a
  compile-time default backend, so an absent/unknown backend is an `:error`.
  """
  @spec transcription_report(keyword()) :: transcription_report()
  def transcription_report(_opts \\ []) do
    case Transcription.active_backend() do
      {:ok, {name, module}} ->
        %{status: :configured, backend: name, credential_present?: credential_present?(module)}

      {:error, message} ->
        %{status: :error, error: message}
    end
  end

  defp credential_present?(module) do
    case module.configured?([]) do
      :ok -> true
      {:error, _reason} -> false
    end
  end

  defp channel_registry do
    registry = FermixChannels.Gateway.ChannelRegistry

    if Code.ensure_loaded?(registry) do
      apply(registry, :channels, [])
    else
      []
    end
  end

  defp enabled_probe_channel?(%{config_key: nil}), do: false

  defp enabled_probe_channel?(%{config_key: key} = channel) when is_atom(key) do
    case FermixCore.Config.channel(key) do
      {:ok, config} -> Keyword.get(config, :enabled, channel_default_enabled(channel)) == true
      {:error, :not_configured} -> false
    end
  end

  defp channel_default_enabled(%{config_key: :telegram}), do: true
  defp channel_default_enabled(_channel), do: false

  @spec probe_channel(map(), keyword()) :: channel_probe()
  def probe_channel(%{adapter: adapter, config_key: key, name: name}, opts)
      when is_atom(adapter) and is_atom(key) and is_binary(name) and is_list(opts) do
    base = %{channel: key, name: name}

    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :health_check, 1) do
      adapter
      |> apply(:health_check, [opts])
      |> normalize_channel_probe(base)
    else
      Map.merge(base, %{
        status: :warn,
        detail: "#{name} is enabled but has no live health probe"
      })
    end
  end

  def probe_channel(channel, _opts) do
    raise ArgumentError, "invalid channel probe spec: #{inspect(channel)}"
  end

  defp normalize_channel_probe({:ok, %{detail: detail} = result}, base) do
    base
    |> Map.merge(%{status: :ok, detail: detail})
    |> maybe_put_latency(result)
  end

  defp normalize_channel_probe({:ok, detail}, base) when is_binary(detail) do
    Map.merge(base, %{status: :ok, detail: detail})
  end

  defp normalize_channel_probe({:error, reason}, base) do
    Map.merge(base, %{status: :error, detail: channel_error_detail(reason)})
  end

  defp maybe_put_latency(probe, %{latency_ms: ms}) when is_integer(ms) and ms >= 0 do
    Map.put(probe, :latency_ms, ms)
  end

  defp maybe_put_latency(probe, _result), do: probe

  defp channel_error_detail({:misconfigured, detail}), do: detail
  defp channel_error_detail({:auth_failed, detail}), do: "auth failed: #{detail}"
  defp channel_error_detail({:server_error, status, _body}), do: "HTTP #{status}"
  defp channel_error_detail({:network, reason}), do: "network error: #{Redaction.format(reason)}"
  defp channel_error_detail(reason), do: Redaction.format(reason)

  @spec active_provider() :: provider()
  def active_provider do
    case PrimaryConfig.primary() do
      {:ok, provider} ->
        validate_active_provider!(provider)

      {:error, :multiple_primary} ->
        raise ArgumentError,
              "more than one provider has primary = true in config.toml; " <>
                "mark exactly one provider primary"
    end
  end

  defp validate_active_provider!(provider) do
    if provider in ModelCatalog.providers() do
      provider
    else
      raise ArgumentError,
            "unknown provider #{inspect(provider)} in :fermix_core, :agent, :provider; " <>
              "expected one of #{Enum.map_join(ModelCatalog.providers(), ", ", &inspect/1)}"
    end
  end

  defp probe_openai(opts) do
    config = provider_config(:openai)

    case openai_bearer(config) do
      {:error, _} = err ->
        err

      {:ok, bearer} ->
        url = base_url(config, :openai, @openai_default_url)
        model = effective_model(config, :openai)

        body = %{
          model: model,
          input: [
            %{type: "message", role: "user", content: [%{type: "input_text", text: "."}]}
          ],
          max_output_tokens: 1,
          store: false
        }

        headers = [
          {"authorization", "Bearer #{bearer}"},
          {"content-type", "application/json"}
        ]

        do_post(:openai, url, body, headers, model, "api.openai.com api.responses.write", opts)
    end
  end

  defp openai_bearer(config), do: bearer_from_api_key(Keyword.get(config, :api_key))

  defp bearer_from_api_key(value) when value in [nil, ""] do
    {:error, {:misconfigured, "openai provider has no api_key configured"}}
  end

  defp bearer_from_api_key(value), do: {:ok, value}

  defp probe_codex(opts) do
    config = provider_config(:openai_codex)

    case require_codex_token(opts) do
      {:error, _} = err ->
        err

      {:ok, token} ->
        url = base_url(config, :openai_codex, @codex_default_url)
        model = effective_model(config, :openai_codex)

        body = %{
          model: model,
          input: [
            %{type: "message", role: "user", content: [%{type: "input_text", text: "."}]}
          ],
          instructions: "ping",
          store: false,
          stream: true
        }

        headers = [
          {"authorization", "Bearer #{token}"},
          {"openai-beta", "responses=experimental"},
          {"originator", "pi"},
          {"content-type", "application/json"}
        ]

        do_post(:openai_codex, url, body, headers, model, "chatgpt.com Codex OAuth", opts)
    end
  end

  defp probe_xai(opts) do
    config = provider_config(:xai)

    case Keyword.get(config, :auth_mode, :api_key) do
      mode when mode in [:api_key, "api_key"] ->
        probe_xai_bearer(config, xai_bearer(config), "api.x.ai API key", opts)

      mode when mode in [:oauth, "oauth"] ->
        probe_xai_bearer(
          config,
          require_oauth_token("xai_oauth", "xai", opts),
          "Grok subscription OAuth",
          opts
        )

      other ->
        {:error, {:misconfigured, "xai auth_mode #{inspect(other)} is not api_key|oauth"}}
    end
  end

  defp probe_xai_bearer(_config, {:error, _} = err, _surface, _opts), do: err

  defp probe_xai_bearer(config, {:ok, bearer}, surface, opts) do
    url = "#{base_url(config, :xai, @xai_default_base_url)}/responses"
    model = effective_model(config, :xai)

    body = %{
      model: model,
      input: [
        %{type: "message", role: "user", content: [%{type: "input_text", text: "."}]}
      ],
      max_output_tokens: 1,
      store: false
    }

    headers = [
      {"authorization", "Bearer #{bearer}"},
      {"content-type", "application/json"}
    ]

    do_post(:xai, url, body, headers, model, surface, opts)
  end

  defp xai_bearer(config) do
    case Keyword.get(config, :api_key) do
      value when value in [nil, ""] ->
        {:error, {:misconfigured, "xai provider has no api_key configured"}}

      value ->
        {:ok, value}
    end
  end

  # Mirrors the runtime adapter shape: a 1-token chat completion through
  # the same URL join ChatCompletions uses (probe-green => runtime-green).
  defp probe_openrouter(opts) do
    config = provider_config(:openrouter)

    case chat_completions_bearer(config, :openrouter) do
      {:error, _} = err ->
        err

      {:ok, bearer} ->
        url = "#{base_url(config, :openrouter, @openrouter_default_base_url)}/chat/completions"
        model = effective_model(config, :openrouter)

        body = %{
          model: model,
          messages: [%{role: "user", content: "."}],
          max_tokens: 1
        }

        headers = [
          {"authorization", "Bearer #{bearer}"},
          {"http-referer", "https://fermix.sh"},
          {"x-title", "Fermix"},
          {"content-type", "application/json"}
        ]

        do_post(:openrouter, url, body, headers, model, "openrouter.ai API key", opts)
    end
  end

  # Mirrors the runtime adapter shape (probe-green => runtime-green for the
  # request path). Mistral is a plain Bearer Chat Completions provider — no
  # attribution headers — and uses `max_tokens` (not `max_completion_tokens`).
  defp probe_mistral(opts) do
    config = provider_config(:mistral)

    case chat_completions_bearer(config, :mistral) do
      {:error, _} = err ->
        err

      {:ok, bearer} ->
        url = "#{base_url(config, :mistral, @mistral_default_base_url)}/chat/completions"
        model = effective_model(config, :mistral)

        body = %{
          model: model,
          messages: [%{role: "user", content: "."}],
          max_tokens: 1
        }

        headers = [
          {"authorization", "Bearer #{bearer}"},
          {"content-type", "application/json"}
        ]

        do_post(:mistral, url, body, headers, model, "mistral.ai API key", opts)
    end
  end

  # Keyless local provider: 1-token chat completion through the same /v1
  # path the adapter uses, then a native /api/show check that the SERVED
  # context window is not silently below the catalog window (Ollama
  # truncates instead of erroring — M12 §3.2). A missing/odd /api/show
  # response is inconclusive and does not fail the probe: the chat call
  # already proved the serving path (e.g. proxies exposing only /v1).
  defp probe_ollama(opts) do
    config = provider_config(:ollama)

    case Keyword.get(config, :base_url) do
      value when value in [nil, ""] ->
        {:error,
         {:misconfigured,
          "ollama provider has no base_url configured; set [fermix_core.providers.ollama] base_url"}}

      base_url ->
        model = effective_model(config, :ollama)
        probe_ollama_chat(base_url, model, opts)
    end
  end

  defp probe_ollama_chat(base_url, model, opts) do
    body = %{model: model, messages: [%{role: "user", content: "."}], max_tokens: 1}
    headers = [{"content-type", "application/json"}]

    :ollama
    |> do_post("#{base_url}/chat/completions", body, headers, model, "local Ollama server", opts)
    |> classify_ollama_probe(base_url, model, opts)
  end

  defp classify_ollama_probe({:ok, probe}, base_url, model, opts) do
    check_ollama_num_ctx(probe, base_url, model, opts)
  end

  defp classify_ollama_probe({:error, {:server_error, 404, _body}}, _base_url, model, _opts) do
    {:error, {:misconfigured, "model #{inspect(model)} not found — run `ollama pull #{model}`"}}
  end

  defp classify_ollama_probe(
         {:error, {:network, %Req.TransportError{reason: :econnrefused}}},
         base_url,
         _model,
         _opts
       ) do
    {:error,
     {:misconfigured, "no Ollama server at #{base_url} — is it running? (`ollama serve`)"}}
  end

  defp classify_ollama_probe(result, _base_url, _model, _opts), do: result

  defp check_ollama_num_ctx(probe, base_url, model, opts) do
    native_root = String.trim_trailing(base_url, "/v1")

    case fetch_ollama_num_ctx(native_root, model, opts) do
      {:ok, num_ctx} ->
        compare_ollama_window(probe, model, num_ctx)

      :inconclusive ->
        {:ok, probe}
    end
  end

  defp compare_ollama_window(probe, model, num_ctx) do
    catalog_window = ModelCatalog.context_window_for(:ollama, model)

    if num_ctx < catalog_window do
      {:error,
       {:misconfigured,
        "Ollama serves #{model} with num_ctx=#{num_ctx} but Fermix budgets " <>
          "#{catalog_window} tokens — context would truncate silently. Raise it via " <>
          "OLLAMA_CONTEXT_LENGTH or a Modelfile `num_ctx` parameter."}}
    else
      {:ok, probe}
    end
  end

  defp fetch_ollama_num_ctx(native_root, model, opts) do
    Req.new(url: "#{native_root}/api/show", method: :post, json: %{model: model}, retry: false)
    |> Req.merge(probe_req_options(opts))
    |> Req.request()
    |> case do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
        parse_ollama_num_ctx(body)

      _unreachable_or_error ->
        :inconclusive
    end
  end

  # Modelfile `num_ctx` parameter wins; else the GGUF context_length from
  # model_info; else inconclusive (mirrors the Hermes resolution order).
  defp parse_ollama_num_ctx(body) do
    with :inconclusive <- parse_ollama_parameters(Map.get(body, "parameters")) do
      parse_ollama_model_info(Map.get(body, "model_info"))
    end
  end

  defp parse_ollama_parameters(parameters) when is_binary(parameters) do
    case Regex.run(~r/num_ctx\s+(\d+)/, parameters) do
      [_match, digits] -> {:ok, String.to_integer(digits)}
      nil -> :inconclusive
    end
  end

  defp parse_ollama_parameters(_parameters), do: :inconclusive

  defp parse_ollama_model_info(model_info) when is_map(model_info) do
    model_info
    |> Enum.find_value(fn {key, value} ->
      if String.ends_with?(key, ".context_length") and is_integer(value), do: value
    end)
    |> case do
      nil -> :inconclusive
      context_length -> {:ok, context_length}
    end
  end

  defp parse_ollama_model_info(_model_info), do: :inconclusive

  defp chat_completions_bearer(config, provider) do
    case Keyword.get(config, :api_key) do
      value when value in [nil, ""] ->
        {:error, {:misconfigured, "#{provider} provider has no api_key configured"}}

      value ->
        {:ok, value}
    end
  end

  defp probe_anthropic(opts) do
    config = provider_config(:anthropic)

    case Keyword.get(config, :auth_mode, :api_key) do
      mode when mode in [:api_key, "api_key"] ->
        probe_anthropic_api_key(config, opts)

      mode when mode in [:oauth, "oauth"] ->
        probe_anthropic_oauth(config, opts)

      other ->
        {:error, {:misconfigured, "anthropic auth_mode #{inspect(other)} is not api_key|oauth"}}
    end
  end

  defp probe_anthropic_api_key(config, opts) do
    case anthropic_api_key(Keyword.get(config, :api_key)) do
      {:error, _} = err ->
        err

      {:ok, key} ->
        headers = [{"x-api-key", key} | anthropic_base_headers()]
        post_anthropic_probe(config, %{}, headers, "api.anthropic.com API key", opts)
    end
  end

  # Mirrors the adapter's Claude Code emulation (beta/UA/x-app headers plus
  # the identity system block) so a green probe means the subscription
  # route the runtime actually uses works — not a lookalike.
  defp probe_anthropic_oauth(config, opts) do
    case require_anthropic_oauth_token(opts) do
      {:error, _} = err ->
        err

      {:ok, token} ->
        headers = [
          {"authorization", "Bearer #{token}"},
          {"anthropic-beta", "claude-code-20250219,oauth-2025-04-20"},
          {"user-agent", "claude-cli/2.1.74 (external, cli)"},
          {"x-app", "cli"}
          | anthropic_base_headers()
        ]

        body_extra = %{
          system: [
            %{type: "text", text: "You are Claude Code, Anthropic's official CLI for Claude."}
          ]
        }

        post_anthropic_probe(config, body_extra, headers, "claude.ai subscription OAuth", opts)
    end
  end

  defp post_anthropic_probe(config, body_extra, headers, surface, opts) do
    url = base_url(config, :anthropic, @anthropic_default_url)
    model = effective_model(config, :anthropic)

    body =
      Map.merge(
        %{model: model, max_tokens: 1, messages: [%{role: "user", content: "."}]},
        body_extra
      )

    do_post(:anthropic, url, body, headers, model, surface, opts)
  end

  defp require_anthropic_oauth_token(opts),
    do: require_oauth_token("anthropic_oauth", "anthropic", opts)

  defp require_oauth_token(profile, label, opts) do
    cond do
      token = Keyword.get(opts, :access_token) ->
        {:ok, token}

      Keyword.has_key?(opts, :fermix_auth_path) ->
        read_oauth_entry(profile, label, Keyword.fetch!(opts, :fermix_auth_path))

      true ->
        case TokenSupervisor.get_token(profile) do
          {:ok, token} ->
            {:ok, token}

          {:error, reason} ->
            {:error,
             {:misconfigured, "#{label} oauth credentials unavailable: #{inspect(reason)}"}}
        end
    end
  rescue
    # Store.read raises on a malformed entry (e.g. empty access_token);
    # the doctor reports it instead of crashing (Readiness does the same).
    e in ArgumentError ->
      {:error, {:misconfigured, "#{label} oauth entry malformed: #{Exception.message(e)}"}}
  end

  defp read_oauth_entry(profile, label, path) do
    case Store.read(profile, path) do
      {:ok, %{tokens: %{access_token: token}}} when is_binary(token) and token != "" ->
        {:ok, token}

      {:ok, _entry} ->
        {:error, {:misconfigured, "#{label} oauth entry has no access token"}}

      {:error, reason} ->
        {:error, {:misconfigured, "#{label} oauth credentials unavailable: #{inspect(reason)}"}}
    end
  end

  defp anthropic_base_headers do
    [{"anthropic-version", "2023-06-01"}, {"content-type", "application/json"}]
  end

  defp anthropic_api_key(value) when value in [nil, ""] do
    {:error, {:misconfigured, "anthropic provider has no api_key configured"}}
  end

  defp anthropic_api_key(value), do: {:ok, value}

  defp do_post(provider, url, body, headers, model, surface, opts) do
    start = System.monotonic_time(:millisecond)

    Req.new(url: url, method: :post, json: body, headers: headers, retry: false)
    |> Req.merge(probe_req_options(opts))
    |> Req.request()
    |> classify(provider, model, surface, start)
  end

  defp probe_req_options(opts) do
    opts
    |> Keyword.get(:req_options, [])
    |> Keyword.put(:receive_timeout, probe_timeout_ms(opts))
    |> Keyword.put(:retry, false)
  end

  defp probe_timeout_ms(opts) do
    case Keyword.get(opts, :timeout_ms, @default_probe_timeout_ms) do
      timeout_ms when is_integer(timeout_ms) and timeout_ms > 0 -> timeout_ms
      other -> raise ArgumentError, "invalid probe timeout: #{inspect(other)}"
    end
  end

  defp classify({:ok, %Req.Response{status: status}}, provider, model, _surface, start)
       when status in 200..299 do
    {:ok, %{provider: provider, model: model, latency_ms: elapsed_ms(start)}}
  end

  defp classify(
         {:ok, %Req.Response{status: status, body: _body}},
         _provider,
         _model,
         surface,
         _start
       )
       when status in [401, 403] do
    {:error, {:auth_scope_mismatch, surface, hint_for(surface)}}
  end

  defp classify(
         {:ok, %Req.Response{status: status, body: body}},
         _provider,
         _model,
         _surface,
         _start
       ) do
    {:error, {:server_error, status, body}}
  end

  defp classify({:error, reason}, _provider, _model, _surface, _start) do
    {:error, {:network, reason}}
  end

  # Ordered: first matching surface substring wins ("Grok subscription"
  # must shadow the generic "subscription" entry).
  @auth_hints [
    {"api.openai.com", "API key is missing the api.responses.write scope or has been revoked"},
    {"Codex", "Codex OAuth token rejected — re-import via `fermix setup --import-codex`"},
    {"Grok subscription",
     "SpaceXAI subscription token rejected — reconnect via `fermix auth login --provider xai` " <>
       "(a 403 can mean the Grok plan lacks API access)"},
    {"subscription",
     "Claude subscription token rejected — reconnect via `fermix auth login --provider anthropic`"},
    {"anthropic", "Anthropic API key rejected — verify it in the Anthropic console"},
    {"api.x.ai", "SpaceXAI API key rejected — verify it in the SpaceXAI console"},
    {"openrouter.ai", "OpenRouter API key rejected — verify it at openrouter.ai/settings/keys"},
    {"mistral.ai", "Mistral API key rejected — verify it at console.mistral.ai/api-keys"},
    {"Ollama", "the Ollama server rejected the request — check its auth/proxy configuration"}
  ]

  defp hint_for(surface) do
    Enum.find_value(@auth_hints, "auth rejected", fn {marker, hint} ->
      if String.contains?(surface, marker), do: hint
    end)
  end

  defp provider_config(provider) do
    Application.get_env(:fermix_core, :providers, []) |> Keyword.get(provider, [])
  end

  defp effective_model(config, provider) do
    Keyword.get(config, :default_model) || ModelCatalog.default_model_for(provider)
  end

  defp catalog_windows do
    for provider <- ModelCatalog.providers(),
        entry <- ModelCatalog.models_for(provider) do
      %{provider: provider, model: entry.id, context_window: entry.context_window}
    end
  end

  defp base_url(config, _provider, default) do
    Keyword.get(config, :base_url, default)
  end

  defp require_codex_token(opts) do
    cond do
      manager = Keyword.get(opts, :token_manager) ->
        TokenManager.get_token(manager)

      Keyword.has_key?(opts, :fermix_auth_path) ->
        CodexToken.get_token(opts)

      Process.whereis(TokenManager) ->
        TokenManager.get_token(TokenManager)

      true ->
        CodexToken.get_token(opts)
    end
    |> classify_token()
  end

  defp classify_token({:ok, token}) when is_binary(token) and token != "", do: {:ok, token}
  defp classify_token({:ok, _}), do: {:error, {:misconfigured, "Codex token is empty"}}

  defp classify_token({:error, :no_auth_file}),
    do:
      {:error,
       {:misconfigured, "Codex token missing; run `fermix auth login`, then restart the daemon."}}

  defp classify_token({:error, {:provider_missing, :openai_codex}}),
    do:
      {:error,
       {:misconfigured, "Codex token missing; run `fermix auth login`, then restart the daemon."}}

  defp classify_token({:error, :no_token}),
    do:
      {:error,
       {:misconfigured,
        "TokenManager has no Codex token loaded; run `fermix auth login`, then restart the daemon."}}

  defp classify_token({:error, :auth_invalidated}),
    do:
      {:error,
       {:misconfigured,
        "Codex OAuth token was invalidated; run `fermix auth login`, then restart the daemon."}}

  defp classify_token({:error, reason}),
    do: {:error, {:misconfigured, "Codex token unavailable: #{inspect(reason)}"}}

  defp elapsed_ms(start), do: System.monotonic_time(:millisecond) - start
end
