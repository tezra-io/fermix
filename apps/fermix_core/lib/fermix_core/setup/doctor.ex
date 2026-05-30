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
  alias FermixCore.Auth.TokenManager
  alias FermixCore.Memory.CompactionConfig
  alias FermixCore.Providers.ModelCatalog
  alias FermixCore.Tools.WebSearch

  @type provider :: :openai | :openai_codex | :anthropic
  @type probe_ok :: %{provider: provider(), model: String.t(), latency_ms: non_neg_integer()}
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
  @command_channels [:telegram, :whatsapp, :discord, :slack, :signal]
  @web_search_probe_query "fermix web search health check"

  @spec probe_provider(provider(), keyword()) :: {:ok, probe_ok()} | {:error, probe_error()}
  def probe_provider(provider, opts \\ [])
  def probe_provider(:openai, opts), do: probe_openai(opts)
  def probe_provider(:openai_codex, opts), do: probe_codex(opts)
  def probe_provider(:anthropic, opts), do: probe_anthropic(opts)

  def probe_provider(other, _opts) do
    raise ArgumentError,
          "unknown provider #{inspect(other)}; expected one of :openai, :openai_codex, :anthropic"
  end

  @spec probe_active(keyword()) :: {:ok, probe_ok()} | {:error, probe_error()}
  def probe_active(opts \\ []) do
    provider = active_provider()
    probe_provider(provider, opts)
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

  @spec active_provider() :: provider()
  def active_provider do
    case Application.get_env(:fermix_core, :agent, []) |> Keyword.get(:provider) do
      nil ->
        :openai

      provider when provider in [:openai, :openai_codex, :anthropic] ->
        provider

      other ->
        raise ArgumentError,
              "unknown provider #{inspect(other)} in :fermix_core, :agent, :provider; " <>
                "expected one of :openai, :openai_codex, :anthropic"
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

  defp probe_anthropic(opts) do
    config = provider_config(:anthropic)
    api_key = Keyword.get(config, :api_key)

    case anthropic_api_key(api_key) do
      {:error, _} = err ->
        err

      {:ok, key} ->
        url = base_url(config, :anthropic, @anthropic_default_url)
        model = effective_model(config, :anthropic)

        body = %{
          model: model,
          max_tokens: 1,
          messages: [%{role: "user", content: "."}]
        }

        headers = [
          {"x-api-key", key},
          {"anthropic-version", "2023-06-01"},
          {"content-type", "application/json"}
        ]

        do_post(:anthropic, url, body, headers, model, "api.anthropic.com API key", opts)
    end
  end

  defp anthropic_api_key(value) when value in [nil, ""] do
    {:error, {:misconfigured, "anthropic provider has no api_key configured"}}
  end

  defp anthropic_api_key(value), do: {:ok, value}

  defp do_post(provider, url, body, headers, model, surface, opts) do
    req_options = Keyword.get(opts, :req_options, [])
    start = System.monotonic_time(:millisecond)

    Req.new(url: url, method: :post, json: body, headers: headers, retry: false)
    |> Req.merge(req_options)
    |> Req.request()
    |> classify(provider, model, surface, start)
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

  defp hint_for(surface) do
    cond do
      String.contains?(surface, "api.openai.com") ->
        "API key is missing the api.responses.write scope or has been revoked"

      String.contains?(surface, "Codex") ->
        "Codex OAuth token rejected — re-import via `fermix setup --import-codex`"

      String.contains?(surface, "anthropic") ->
        "Anthropic API key rejected — verify it in the Anthropic console"

      true ->
        "auth rejected"
    end
  end

  defp provider_config(provider) do
    Application.get_env(:fermix_core, :providers, []) |> Keyword.get(provider, [])
  end

  defp effective_model(config, provider) do
    Keyword.get(config, :default_model) || ModelCatalog.default_model_for(provider)
  end

  defp catalog_windows do
    for provider <- ModelCatalog.providers(),
        {model, _label, context_window} <- ModelCatalog.models_for(provider) do
      %{provider: provider, model: model, context_window: context_window}
    end
  end

  defp base_url(config, _provider, default) do
    Keyword.get(config, :base_url, default)
  end

  defp require_codex_token(opts) do
    case Process.whereis(TokenManager) do
      nil -> CodexToken.get_token(opts)
      _pid -> TokenManager.get_token(TokenManager)
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
