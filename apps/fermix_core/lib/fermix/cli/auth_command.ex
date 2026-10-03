defmodule Fermix.CLI.AuthCommand do
  @moduledoc """
  `fermix auth` — manage provider OAuth credentials.

  Subcommands (the default provider is codex, `openai_codex`, which signs in
  with ChatGPT; `--provider anthropic` targets the Claude subscription profile
  `anthropic_oauth`, `--provider xai` the Grok one):

    * `login` — codex: Sign in with ChatGPT in the browser. A computer with no
      browser prints the address; open it on another computer and paste back
      the address that browser ended on (`Auth.ChatGPT.TerminalLogin`).
      Anthropic: `--setup-token TOKEN`, `--import-claude-code`, or the
      `CLAUDE_CODE_OAUTH_TOKEN` env var. xai: the browser PKCE flow.
    * `status` — prints what is currently stored.
    * `logout` — removes the stored credentials (codex: revokes the ChatGPT
      session, clears its tokens and keeps the registration), then tells a
      running daemon to drop the tokens it still holds for them.

  After `login`, restart the daemon so its token manager reloads the new token
  state.

  `run/2` takes test seams: `:login`, `:read_line` and `:browser` for the
  ChatGPT sign-in (`TerminalLogin.run/1`), and `:logout` for its sign-out.
  """

  alias Fermix.CLI.Daemon.Client, as: DaemonClient
  alias FermixCore.Auth.AnthropicLogin
  alias FermixCore.Auth.ChatGPT
  alias FermixCore.Auth.ChatGPT.TerminalLogin
  alias FermixCore.Auth.Store
  alias FermixCore.Auth.XAILogin
  alias FermixCore.Setup.LiveModel
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
  @codex_profile Store.profile(:openai_codex)
  @seams [:login, :read_line, :browser, :logout, :live_model]

  @spec run([String.t()], keyword()) :: non_neg_integer()
  def run(argv, seams \\ []) when is_list(argv) and is_list(seams) do
    seams = Keyword.take(seams, @seams)

    case argv do
      [] -> usage()
      ["login" | rest] -> login(rest, seams)
      ["status" | rest] -> status(rest)
      ["logout" | rest] -> logout(rest, seams)
      [unknown | _] -> unknown_subcommand(unknown)
    end
  end

  defp login(argv, seams) do
    case OptionParser.parse(argv, strict: @login_switches) do
      {opts, [], []} -> dispatch_login(Keyword.get(opts, :provider), opts, seams)
      {_opts, _args, invalid} -> invalid_options(invalid, "login")
    end
  end

  defp dispatch_login(nil, opts, seams), do: chatgpt_login(opts, seams)
  defp dispatch_login("codex", opts, seams), do: chatgpt_login(opts, seams)
  defp dispatch_login("anthropic", opts, _seams), do: anthropic_login(opts)
  defp dispatch_login("xai", opts, _seams), do: xai_login(opts)

  defp dispatch_login(other, _opts, _seams),
    do: error("unknown login provider #{inspect(other)}; expected codex, anthropic, or xai")

  # codex signs in with ChatGPT. A grant without plan usage is stored but the
  # route refuses it, so it is reported as the failure it is.
  defp chatgpt_login(opts, seams) do
    login_opts =
      seams
      |> Keyword.take([:login, :read_line, :browser])
      |> Keyword.put(:no_browser, Keyword.get(opts, :no_browser, false))
      |> maybe_put(:port, Keyword.get(opts, :port))
      |> maybe_put(:timeout_ms, timeout_ms(Keyword.get(opts, :timeout)))

    case TerminalLogin.run(login_opts) do
      {:ok, %{plan_usage: :on, account: account}} -> signed_in(account, seams)
      {:ok, %{plan_usage: :off}} -> error(ChatGPT.failure_sentence(:plan_usage_off))
      {:error, reason} -> error("login failed: #{ChatGPT.failure_sentence(reason)}")
    end
  end

  defp signed_in(account, seams) do
    IO.puts("Signed in to ChatGPT#{account_suffix(account)}. Tokens saved to #{Store.path()}.")
    ensure_live_model(seams)
    IO.puts("Restart the daemon to pick up new credentials: `fermix restart`.")
    0
  end

  # The configured model must be one the account lists (`Setup.LiveModel`); a
  # listing that fails leaves the model as it is and says so, and the sign-in
  # stands.
  defp ensure_live_model(seams) do
    ensure = Keyword.get(seams, :live_model, &LiveModel.ensure/2)

    case ensure.(:openai_codex, []) do
      {:ok, %{model: model, changed?: true}} ->
        IO.puts("Default model set to #{model}, the first one your ChatGPT account lists.")

      {:ok, %{changed?: false}} ->
        :ok

      {:error, sentence} ->
        IO.puts("The default model was not checked against your ChatGPT account. #{sentence}")
    end
  end

  defp account_suffix(nil), do: ""
  defp account_suffix(account), do: " as #{account}"

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
    do: error("anthropic login failed: #{reason_text(reason)}")

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
        error("xai login failed: #{reason_text(reason)}")
    end
  end

  # Token write != route selection: RouteResolver keys on the config
  # [providers.<p>].auth_mode, so a stored OAuth token is inert until auth_mode
  # is "oauth". Keep them in sync here (and revert to api_key on logout).
  #
  # `fermix auth` runs tree-less (cli_dispatch's fall-through halts without a
  # supervision tree), so the save's keychain helpers must run inline.
  defp select_route(provider, mode) do
    case Wizard.set_provider_auth_mode(provider, mode, supervised: false) do
      {:ok, _report} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp revert_route(@anthropic_profile), do: select_route(:anthropic, :api_key)
  defp revert_route(@xai_profile), do: select_route(:xai, :api_key)
  defp revert_route(_profile), do: :no_route

  defp timeout_ms(nil), do: nil
  defp timeout_ms(seconds) when is_integer(seconds) and seconds > 0, do: seconds * 1_000
  defp timeout_ms(_other), do: nil

  # `:no_browser` tells XAILogin/OAuthFlow to print the URL instead of
  # launching a browser. Omitting it lets OAuthFlow use its OS default.
  defp maybe_set_no_browser(opts, true), do: Keyword.put(opts, :no_browser, true)
  defp maybe_set_no_browser(opts, false), do: opts

  defp status(argv) do
    case OptionParser.parse(argv, strict: @provider_switches) do
      {opts, [], []} -> do_status(profile_for(Keyword.get(opts, :provider)))
      {_opts, _args, invalid} -> invalid_options(invalid, "status")
    end
  end

  defp do_status({:error, message}), do: error(message)
  defp do_status({:ok, @codex_profile}), do: chatgpt_status()

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

  # The registration's state, never its tokens. Plan usage that is off and a
  # grant that needs renewing are signed in and still refused, so each says so.
  defp chatgpt_status do
    case ChatGPT.summary() do
      %{state: :not_connected} ->
        IO.puts("not logged in (no ChatGPT sign-in in #{Store.path()})")

      %{state: state, account: account} ->
        IO.puts("provider: openai_codex (Sign in with ChatGPT)")
        IO.puts("account: #{account || "n/a"}")
        IO.puts("state: #{state}")
        chatgpt_state_note(state)
    end

    0
  end

  defp chatgpt_state_note(:plan_off), do: IO.puts(ChatGPT.failure_sentence(:plan_usage_off))
  defp chatgpt_state_note(:reconnect), do: IO.puts(ChatGPT.failure_sentence(:reconnect_needed))
  defp chatgpt_state_note(:connected), do: :ok

  defp logout(argv, seams) do
    case OptionParser.parse(argv, strict: @provider_switches) do
      {opts, [], []} -> do_logout(profile_for(Keyword.get(opts, :provider)), seams)
      {_opts, _args, invalid} -> invalid_options(invalid, "logout")
    end
  end

  defp do_logout({:error, message}, _seams), do: error(message)
  defp do_logout({:ok, @codex_profile}, seams), do: chatgpt_logout(seams)
  defp do_logout({:ok, profile}, _seams), do: delete_logout(profile)

  # ChatGPT's own sign-out revokes the session upstream, clears the tokens and
  # keeps the registration, so the next sign-in reuses it; a revoke OpenAI did
  # not confirm still signs this computer out, and says where to finish.
  defp chatgpt_logout(seams) do
    path = Store.path()
    logout = Keyword.get(seams, :logout, &ChatGPT.logout/1)

    case ChatGPT.summary() do
      %{state: :not_connected} ->
        IO.puts("Already logged out (no ChatGPT sign-in in #{path}).")
        tell_daemon(0, @codex_profile, "no ChatGPT sign-in was stored in #{path}")

      %{state: _signed_in} ->
        logout.([])
        |> chatgpt_logged_out(path)
    end
  end

  defp chatgpt_logged_out({:ok, %{revoked: true}}, path) do
    IO.puts("Logged out of ChatGPT. Cleared its tokens in #{path}.")
    tell_daemon(0, @codex_profile, "cleared the ChatGPT tokens in #{path}")
  end

  defp chatgpt_logged_out({:ok, %{revoked: false}}, path) do
    IO.puts(ChatGPT.failure_sentence(:revoke_not_confirmed))
    tell_daemon(0, @codex_profile, "cleared the ChatGPT tokens in #{path}")
  end

  defp chatgpt_logged_out({:error, reason}, _path),
    do: error("logout failed: #{ChatGPT.failure_sentence(reason)}")

  # The logout is the same whether or not a daemon runs: the entry is deleted
  # here. A running daemon still holds the account's tokens in memory, so it is
  # then told to let go of them, the way the plugin verbs ask it to re-apply
  # their config. With no daemon there is nothing to tell and nothing more is
  # printed.
  defp delete_logout(profile) do
    path = Store.path()

    case Store.delete_provider(profile, path) do
      :ok ->
        profile
        |> logged_out(path)
        |> tell_daemon(profile, "removed the #{profile} entry from #{path}")

      {:error, :no_auth_file} ->
        already_logged_out(profile, path)

      {:error, {:provider_missing, _provider}} ->
        already_logged_out(profile, path)

      {:error, reason} ->
        error("logout failed: #{reason_text(reason)}")
    end
  end

  # Only anthropic and xai have an auth-mode route to revert, and that config
  # change is read by the daemon at start, so only they mention a restart. The
  # daemon's live tokens are dropped by the notice that follows, not by it.
  defp logged_out(profile, path) do
    case revert_route(profile) do
      :ok ->
        IO.puts("Logged out. Removed #{profile} entry from #{path}.")
        IO.puts("The auth_mode change reaches the daemon on its next restart.")
        0

      :no_route ->
        IO.puts("Logged out. Removed #{profile} entry from #{path}.")
        0

      {:error, reason} ->
        error(
          "removed credentials, but failed to revert auth_mode to api_key: #{inspect(reason)}"
        )
    end
  end

  # `status` is the local logout's own exit status; the daemon's answer can only
  # make it worse. A daemon that cannot let go is a failed logout, because it
  # keeps calling as the account until it restarts.
  defp tell_daemon(status, profile, local) do
    case DaemonClient.forget_auth_profile(to_string(profile)) do
      :ok ->
        IO.puts(:stderr, "The running daemon dropped any tokens it held for #{profile}.")
        status

      :not_running ->
        status

      {:error, reason} ->
        error(
          "#{local}, but the running daemon could not drop its #{profile} tokens: #{reason}. " <>
            "Restart the daemon (from the Fermix app, or `fermix restart` for a daemon you " <>
            "run yourself)."
        )
    end
  end

  defp profile_for(nil), do: {:ok, @codex_profile}
  defp profile_for("codex"), do: {:ok, @codex_profile}
  defp profile_for("anthropic"), do: {:ok, @anthropic_profile}
  defp profile_for("xai"), do: {:ok, @xai_profile}

  defp profile_for(other),
    do: {:error, "unknown provider #{inspect(other)}; expected codex, anthropic, or xai"}

  # Still tells a running daemon: a logout whose notice failed leaves the entry
  # gone and the tokens live, and running it again is how the operator retries.
  defp already_logged_out(profile, path) do
    IO.puts("Already logged out (no #{profile} entry in #{path}).")
    tell_daemon(0, profile, "no #{profile} entry was stored in #{path}")
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  # Another Fermix process held the account's profile lock past the wait, and
  # nothing was spent or removed: the one reason with a sentence of its own.
  defp reason_text(:profile_busy), do: Store.busy_sentence()
  defp reason_text(reason), do: inspect(reason)

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

    The default provider is codex (OpenAI Codex), which signs in with
    ChatGPT. With no browser on this computer, open the printed address on
    another one and paste back the address that browser ended on. Anthropic
    login also accepts a CLAUDE_CODE_OAUTH_TOKEN environment variable; xai
    opens a browser for the Grok Build subscription PKCE flow.
    """)

    2
  end

  defp error(message) do
    IO.puts(:stderr, "fermix auth: #{message}")
    1
  end
end
