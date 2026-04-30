defmodule FermixCore.Providers.RouteResolver do
  @moduledoc """
  Translates Fermix configuration into a `{route_key, adapter_opts}` pair
  for `AgentLoop`. Keeps callers (AgentServer, MainAgent) out of the
  business of knowing which adapter wires up which auth mode.

  `resolve!/1` dispatches on the `:provider` opt:

    * `nil` / `:openai` — standard OpenAI provider. `auth_mode: :api_key`
      uses the API key Bearer; `auth_mode: :oauth` uses an OAuth Bearer
      pulled from `TokenManager`. Both route to `OpenAI.Responses` (or
      `OpenAI.ChatCompletions` for non-eligible models / proxy URLs).
    * `:openai_codex` — explicit Codex (ChatGPT Plus) surface. Uses a
      different URL, body, and streaming shape.
    * `:anthropic` — Anthropic Messages route key.

  Codex is **only** selected via explicit `provider: :openai_codex`. The
  default OpenAI OAuth user routes through Responses, which supports
  tool calls (Codex does not).
  """

  alias FermixCore.Auth.TokenManager
  alias FermixCore.Config
  alias FermixCore.Providers.Adapter

  @default_openai_base_url "https://api.openai.com/v1"
  @default_codex_base_url "https://chatgpt.com/backend-api/codex/responses"
  @default_anthropic_base_url "https://api.anthropic.com/v1"
  @default_anthropic_model "claude-sonnet-4-6"

  @type resolution :: {Adapter.route_key(), keyword()}

  @spec resolve!(keyword()) :: resolution()
  def resolve!(opts \\ []) do
    case Keyword.get(opts, :provider) || configured_provider() do
      nil -> resolve_openai!(opts)
      :openai -> resolve_openai!(opts)
      :openai_codex -> resolve_codex!(opts)
      :anthropic -> resolve_anthropic!(opts)
      other -> raise ArgumentError, "no resolver for provider #{inspect(other)}"
    end
  end

  defp configured_provider do
    case Config.provider(:openai) do
      {:ok, cfg} -> Keyword.get(cfg, :provider)
      _ -> nil
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
      :oauth -> resolve_openai_oauth(model, base_url, opts)
      :api_key -> resolve_openai_api_key(model, base_url, opts, config)
      other -> raise ArgumentError, "Unknown OpenAI auth_mode: #{inspect(other)}"
    end
  end

  @spec resolve_codex!(keyword()) :: resolution()
  def resolve_codex!(opts \\ []) do
    model = Keyword.get(opts, :model) || "gpt-5"

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
      |> maybe_put(:req_options, Keyword.get(opts, :req_options))

    {route_key, adapter_opts}
  end

  defp resolve_openai_oauth(model, base_url, opts) do
    route_key = %{
      provider: :openai,
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
      |> maybe_put(:temperature, Keyword.get(opts, :temperature))
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
      [model: model, base_url: base_url, api_key: api_key]
      |> maybe_put(:temperature, Keyword.get(opts, :temperature))
      |> maybe_put(:req_options, Keyword.get(opts, :req_options))

    {route_key, adapter_opts}
  end

  defp resolve_anthropic!(opts) do
    model = Keyword.get(opts, :model) || @default_anthropic_model
    base_url = Keyword.get(opts, :base_url, @default_anthropic_base_url)

    route_key = %{
      provider: :anthropic,
      model: model,
      auth_mode: Keyword.get(opts, :auth_mode, :api_key),
      base_url: base_url
    }

    adapter_opts =
      [model: model, base_url: base_url]
      |> maybe_put(:api_key, Keyword.get(opts, :api_key))
      |> maybe_put(:temperature, Keyword.get(opts, :temperature))
      |> maybe_put(:req_options, Keyword.get(opts, :req_options))

    {route_key, adapter_opts}
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
