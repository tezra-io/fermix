defmodule Fermix.CLI.AuthCommand do
  @moduledoc """
  `fermix auth` — manage provider OAuth credentials.

  Subcommands (default provider is Codex; `--provider anthropic` targets
  the Claude subscription profile `anthropic_oauth`):

    * `login` — Codex: native Authorization Code + PKCE flow against
      `auth.openai.com`. Anthropic: `--setup-token TOKEN`,
      `--import-claude-code`, or the `CLAUDE_CODE_OAUTH_TOKEN` env var.
    * `status` — prints what is currently stored.
    * `logout` — removes the stored credentials.

  After `login` (or any change), restart the daemon so the running
  `TokenManager` reloads the new token state.
  """

  alias FermixCore.Auth.AnthropicLogin
  alias FermixCore.Auth.CodexLogin
  alias FermixCore.Auth.Store
  alias FermixCore.Auth.XAILogin
  alias FermixCore.Setup.Wizard

  @login_switches [
    no_browser: :boolean,
    port: :integer,
    timeout: :integer,
    provider: :string,
    setup_token: :string,
    import_claude_code: :boolean
  ]
  @provider_switches [provider: :string]
  # `Auth.Store.profile/1` is the one provider-to-profile resolver; these are
  # its answers, not a second table.
  @anthropic_profile Store.profile(:anthropic)
  @xai_profile Store.profile(:xai)

  @spec run([String.t()]) :: non_neg_integer()
  def run(argv) when is_list(argv) do
    case argv do
      [] -> usage()
      ["login" | rest] -> login(rest)
      ["status" | rest] -> status(rest)
      ["logout" | rest] -> logout(rest)
      [unknown | _] -> unknown_subcommand(unknown)
    end
  end

  defp login(argv) do
    case OptionParser.parse(argv, strict: @login_switches) do
      {opts, [], []} -> dispatch_login(Keyword.get(opts, :provider), opts)
      {_opts, _args, invalid} -> invalid_options(invalid, "login")
    end
  end

  defp dispatch_login(nil, opts), do: do_login(opts)
  defp dispatch_login("codex", opts), do: do_login(opts)
  defp dispatch_login("anthropic", opts), do: anthropic_login(opts)
  defp dispatch_login("xai", opts), do: xai_login(opts)

  defp dispatch_login(other, _opts),
    do: error("unknown login provider #{inspect(other)}; expected codex, anthropic, or xai")

  defp do_login(opts) do
    login_opts =
      []
      |> maybe_set_no_browser(Keyword.get(opts, :no_browser, false))
      |> maybe_put(:port, Keyword.get(opts, :port))
      |> maybe_put(:timeout, Keyword.get(opts, :timeout))

    case CodexLogin.login(login_opts) do
      {:ok, tokens} -> persist(tokens)
      {:error, reason} -> error("login failed: #{inspect(reason)}")
    end
  end

  defp anthropic_login(opts) do
    cond do
      token = Keyword.get(opts, :setup_token) ->
        anthropic_result(AnthropicLogin.store_setup_token(token))

      Keyword.get(opts, :import_claude_code, false) ->
        anthropic_result(AnthropicLogin.import_claude_code())

      token = System.get_env("CLAUDE_CODE_OAUTH_TOKEN") ->
        anthropic_result(AnthropicLogin.store_setup_token(token))

      true ->
        error(
          "anthropic login needs --setup-token TOKEN, --import-claude-code, " <>
            "or CLAUDE_CODE_OAUTH_TOKEN in the environment"
        )
    end
  end

  defp anthropic_result({:ok, entry}) do
    case select_route(:anthropic, :oauth) do
      :ok ->
        IO.puts(
          "Connected Claude subscription (#{entry.auth_mode}); set anthropic auth_mode = oauth. " <>
            "Tokens saved to #{Store.path()}."
        )

        IO.puts("Restart the daemon to pick up new credentials: `fermix restart`.")
        0

      {:error, reason} ->
        error("connected, but failed to set anthropic auth_mode = oauth: #{inspect(reason)}")
    end
  end

  defp anthropic_result({:error, reason}),
    do: error("anthropic login failed: #{inspect(reason)}")

  defp xai_login(opts) do
    login_opts =
      []
      |> maybe_set_no_browser(Keyword.get(opts, :no_browser, false))
      |> maybe_put(:port, Keyword.get(opts, :port))
      |> maybe_put(:timeout_ms, timeout_ms(Keyword.get(opts, :timeout)))

    case XAILogin.login(login_opts) do
      {:ok, _entry} ->
        case select_route(:xai, :oauth) do
          :ok ->
            IO.puts(
              "Connected SpaceXAI Grok (oauth_pkce); set xai auth_mode = oauth. " <>
                "Tokens saved to #{Store.path()}."
            )

            IO.puts("Restart the daemon to pick up new credentials: `fermix restart`.")
            0

          {:error, reason} ->
            error("connected, but failed to set xai auth_mode = oauth: #{inspect(reason)}")
        end

      {:error, reason} ->
        error("xai login failed: #{inspect(reason)}")
    end
  end

  # Token write != route selection: RouteResolver keys on the config
  # [providers.<p>].auth_mode, so a stored OAuth token is inert until auth_mode
  # is "oauth". Keep them in sync here (and revert to api_key on logout).
  defp select_route(provider, mode) do
    case Wizard.set_provider_auth_mode(provider, mode) do
      {:ok, _report} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp revert_route(@anthropic_profile), do: select_route(:anthropic, :api_key)
  defp revert_route(@xai_profile), do: select_route(:xai, :api_key)
  defp revert_route(_profile), do: :ok

  defp timeout_ms(nil), do: nil
  defp timeout_ms(seconds) when is_integer(seconds) and seconds > 0, do: seconds * 1_000
  defp timeout_ms(_other), do: nil

  # `:no_browser` tells CodexLogin/OAuthFlow to print the URL instead of
  # launching a browser. Omitting it lets OAuthFlow use its OS default.
  defp maybe_set_no_browser(opts, true), do: Keyword.put(opts, :no_browser, true)
  defp maybe_set_no_browser(opts, false), do: opts

  defp persist(_entry) do
    IO.puts("Logged in. Tokens saved to #{Store.path()}.")
    IO.puts("Restart the daemon to pick up new credentials: `fermix restart`.")
    0
  end

  defp status(argv) do
    case OptionParser.parse(argv, strict: @provider_switches) do
      {opts, [], []} -> do_status(profile_for(Keyword.get(opts, :provider)))
      {_opts, _args, invalid} -> invalid_options(invalid, "status")
    end
  end

  defp do_status({:error, message}), do: error(message)

  defp do_status({:ok, profile}) do
    case Store.read(profile) do
      {:ok, entry} ->
        IO.puts("provider: #{profile}")
        IO.puts("auth_mode: #{entry.auth_mode}")
        IO.puts("expires_at: #{format_dt(entry.expires_at)}")
        IO.puts("last_refresh: #{format_dt(entry.last_refresh)}")
        if entry[:status], do: IO.puts("status: #{entry[:status]}")
        0

      {:error, {:provider_missing, _provider}} ->
        IO.puts("not logged in (no #{profile} entry in #{Store.path()})")
        0

      {:error, :no_auth_file} ->
        IO.puts("not logged in (no auth file at #{Store.path()})")
        0

      {:error, reason} ->
        error("status read failed: #{inspect(reason)}")
    end
  end

  defp logout(argv) do
    case OptionParser.parse(argv, strict: @provider_switches) do
      {opts, [], []} -> do_logout(profile_for(Keyword.get(opts, :provider)))
      {_opts, _args, invalid} -> invalid_options(invalid, "logout")
    end
  end

  defp do_logout({:error, message}), do: error(message)

  defp do_logout({:ok, profile}) do
    path = Store.path()

    case Store.delete_provider(profile, path) do
      :ok ->
        case revert_route(profile) do
          :ok ->
            IO.puts("Logged out. Removed #{profile} entry from #{path}.")
            IO.puts("Restart the daemon: `fermix restart`.")
            0

          {:error, reason} ->
            error(
              "removed credentials, but failed to revert auth_mode to api_key: #{inspect(reason)}"
            )
        end

      {:error, :no_auth_file} ->
        already_logged_out(profile, path)

      {:error, {:provider_missing, _provider}} ->
        already_logged_out(profile, path)

      {:error, reason} ->
        error("logout failed: #{inspect(reason)}")
    end
  end

  defp profile_for(nil), do: {:ok, :openai_codex}
  defp profile_for("codex"), do: {:ok, :openai_codex}
  defp profile_for("anthropic"), do: {:ok, @anthropic_profile}
  defp profile_for("xai"), do: {:ok, @xai_profile}

  defp profile_for(other),
    do: {:error, "unknown provider #{inspect(other)}; expected codex, anthropic, or xai"}

  defp already_logged_out(profile, path) do
    IO.puts("Already logged out (no #{profile} entry in #{path}).")
    0
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp format_dt(nil), do: "n/a"
  defp format_dt(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp invalid_options(invalid, sub) do
    IO.puts(:stderr, "fermix auth #{sub}: invalid options #{inspect(invalid)}")
    2
  end

  defp unknown_subcommand(sub) do
    IO.puts(:stderr, "fermix auth: unknown subcommand: #{sub}")
    usage()
  end

  defp usage do
    IO.puts(:stderr, """
    fermix auth — manage provider OAuth credentials

    Usage:
      fermix auth login   [--no-browser] [--port N] [--timeout SECONDS]
      fermix auth login   --provider anthropic [--setup-token TOKEN | --import-claude-code]
      fermix auth login   --provider xai [--no-browser] [--port N] [--timeout SECONDS]
      fermix auth status  [--provider codex|anthropic|xai]
      fermix auth logout  [--provider codex|anthropic|xai]

    The default provider is codex (ChatGPT Plus). Anthropic login also
    accepts a CLAUDE_CODE_OAUTH_TOKEN environment variable; xai opens a
    browser for the Grok Build subscription PKCE flow.
    """)

    2
  end

  defp error(message) do
    IO.puts(:stderr, "fermix auth: #{message}")
    1
  end
end
