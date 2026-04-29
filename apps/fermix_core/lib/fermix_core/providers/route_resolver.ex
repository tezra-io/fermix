defmodule FermixCore.Providers.RouteResolver do
  @moduledoc """
  Translates Fermix configuration into a `{route_key, adapter_opts}` pair
  for `AgentLoop`. Keeps callers (AgentServer, MainAgent) out of the
  business of knowing which adapter wires up which auth mode.

  Today only OpenAI is configured; per-skill `provider:` overrides land
  in Stage 6.
  """

  alias FermixCore.Auth.TokenManager
  alias FermixCore.Config
  alias FermixCore.Providers.Adapter

  @default_openai_base_url "https://api.openai.com/v1"
  @default_codex_base_url "https://chatgpt.com/backend-api/codex/responses"

  @type resolution :: {Adapter.route_key(), keyword()}

  @spec resolve_openai!(keyword()) :: resolution()
  def resolve_openai!(opts \\ []) do
    config =
      case Config.provider(:openai) do
        {:ok, cfg} -> cfg
        {:error, :not_configured} -> []
      end

    model = Keyword.get(opts, :model) || Keyword.get(config, :default_model, "gpt-4o")
    auth_mode = Keyword.get(opts, :auth_mode) || Keyword.get(config, :auth_mode, :api_key)

    case auth_mode do
      :oauth -> resolve_codex(model, opts, config)
      :api_key -> resolve_api_key(model, opts, config)
      other -> raise ArgumentError, "Unknown OpenAI auth_mode: #{inspect(other)}"
    end
  end

  defp resolve_codex(model, opts, config) do
    base_url =
      Keyword.get(opts, :base_url) || Keyword.get(config, :responses_url, @default_codex_base_url)

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

  defp resolve_api_key(model, opts, config) do
    base_url =
      Keyword.get(opts, :base_url) || Keyword.get(config, :base_url, @default_openai_base_url)

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

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
