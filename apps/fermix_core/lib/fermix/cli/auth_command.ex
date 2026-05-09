defmodule Fermix.CLI.AuthCommand do
  @moduledoc """
  `fermix auth` — manage Codex (ChatGPT Plus) OAuth credentials.

  Subcommands:

    * `login` — runs the native Authorization Code + PKCE flow against
      `auth.openai.com` via a local browser handoff, then persists the
      resulting tokens to `~/.fermix/auth.json` under the `openai_codex`
      provider scope.
    * `status` — prints what is currently stored.
    * `logout` — removes the stored Codex credentials.

  After `login` (or any change), restart the daemon so the running
  `TokenManager` reloads the new token state.
  """

  alias FermixCore.Auth.CodexLogin
  alias FermixCore.Auth.Store

  @login_switches [no_browser: :boolean, port: :integer, timeout: :integer]

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
      {opts, [], []} -> do_login(opts)
      {_opts, _args, invalid} -> invalid_options(invalid, "login")
    end
  end

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

  # `:no_browser` tells CodexLogin/OAuthFlow to print the URL instead of
  # launching a browser. Omitting it lets OAuthFlow use its OS default.
  defp maybe_set_no_browser(opts, true), do: Keyword.put(opts, :no_browser, true)
  defp maybe_set_no_browser(opts, false), do: opts

  defp persist(_entry) do
    IO.puts("Logged in. Tokens saved to #{Store.path()}.")
    IO.puts("Restart the daemon to pick up new credentials: `fermix restart`.")
    0
  end

  defp status(_argv) do
    case Store.read(:openai_codex) do
      {:ok, entry} ->
        IO.puts("provider: openai_codex")
        IO.puts("auth_mode: #{entry.auth_mode}")
        IO.puts("expires_at: #{format_dt(entry.expires_at)}")
        IO.puts("last_refresh: #{format_dt(entry.last_refresh)}")
        0

      {:error, {:provider_missing, :openai_codex}} ->
        IO.puts("not logged in (no openai_codex entry in #{Store.path()})")
        0

      {:error, :no_auth_file} ->
        IO.puts("not logged in (no auth file at #{Store.path()})")
        0

      {:error, reason} ->
        error("status read failed: #{inspect(reason)}")
    end
  end

  defp logout(_argv) do
    path = Store.path()

    case Store.delete_provider(:openai_codex, path) do
      :ok ->
        IO.puts("Logged out. Removed openai_codex entry from #{path}.")
        IO.puts("Restart the daemon: `fermix restart`.")
        0

      {:error, :no_auth_file} ->
        already_logged_out(path)

      {:error, {:provider_missing, :openai_codex}} ->
        already_logged_out(path)

      {:error, reason} ->
        error("logout failed: #{inspect(reason)}")
    end
  end

  defp already_logged_out(path) do
    IO.puts("Already logged out (no openai_codex entry in #{path}).")
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
    fermix auth — manage Codex (ChatGPT Plus) credentials

    Usage:
      fermix auth login   [--no-browser] [--port N] [--timeout SECONDS]
      fermix auth status
      fermix auth logout
    """)

    2
  end

  defp error(message) do
    IO.puts(:stderr, "fermix auth: #{message}")
    1
  end
end
