defmodule FermixCore.Auth.CodexLogin do
  @moduledoc """
  Native ChatGPT OAuth login for the `openai_codex` provider.

  Runs Fermix's loopback OAuth flow and persists the resulting token entry
  into the Fermix-owned auth store. This is the shared write path for
  `fermix auth login` and interactive setup.
  """

  alias FermixCore.Auth.OAuthFlow
  alias FermixCore.Auth.Store

  @type opts :: [
          fermix_auth_path: Path.t(),
          no_browser: boolean(),
          oauth_opener: (String.t() -> :ok | {:error, term()}),
          oauth_port: :inet.port_number(),
          port: :inet.port_number(),
          oauth_req_options: keyword(),
          oauth_timeout_ms: pos_integer(),
          timeout: pos_integer(),
          puts: (String.t() -> any())
        ]

  @spec login(opts()) :: {:ok, Store.entry()} | {:error, term()}
  def login(opts \\ []) when is_list(opts) do
    path = Keyword.get(opts, :fermix_auth_path, Store.path())

    with {:ok, tokens} <- OAuthFlow.start_loopback(flow_opts(opts)),
         entry <- entry_from_tokens(tokens) do
      case Store.write(:openai_codex, entry, path) do
        :ok -> {:ok, entry}
        {:error, reason} -> {:error, {:persist_failed, reason}}
      end
    end
  end

  defp flow_opts(opts) do
    []
    |> maybe_put(:port, Keyword.get(opts, :oauth_port) || Keyword.get(opts, :port))
    |> maybe_put(:timeout_ms, Keyword.get(opts, :oauth_timeout_ms) || timeout_ms(opts))
    |> maybe_put(:req_options, Keyword.get(opts, :oauth_req_options))
    |> maybe_put(:puts, Keyword.get(opts, :puts))
    |> maybe_put_opener(opts)
  end

  defp maybe_put_opener(flow_opts, opts) do
    cond do
      Keyword.get(opts, :no_browser, false) ->
        Keyword.put(flow_opts, :opener, nil)

      Keyword.has_key?(opts, :oauth_opener) ->
        Keyword.put(flow_opts, :opener, Keyword.get(opts, :oauth_opener))

      true ->
        flow_opts
    end
  end

  defp timeout_ms(opts) do
    case Keyword.get(opts, :timeout) do
      seconds when is_integer(seconds) and seconds > 0 -> seconds * 1_000
      _value -> nil
    end
  end

  defp entry_from_tokens(tokens) do
    %{
      auth_mode: "chatgpt",
      tokens: %{access_token: tokens.access_token, refresh_token: tokens.refresh_token},
      expires_at: tokens.expires_at,
      last_refresh: DateTime.utc_now()
    }
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
