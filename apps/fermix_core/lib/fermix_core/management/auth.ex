defmodule FermixCore.Management.Auth do
  @moduledoc """
  `auth.start`, `auth.import.start` and `auth.logout` (M34 native setup §7.3).

  A browser sign-in is a job because it waits for a person: the daemon binds the
  loopback listener, mints the authorize url, and hands it back once on the call
  that started the flow. The url is returned, never logged, and never repeated
  by a later read of the same job — the app opens it and then polls the job like
  any other.

  An import is a job for the same reason: reading Claude Code's credentials can
  raise the macOS keychain prompt, which waits for a human. Tokens never transit
  the app either way; only an account label ever crosses the wire.

  Signing out forgets the local session, drops the tokens the RUNNING daemon
  holds for it, and reverts the route that made it live. Deleting the stored
  entry alone is not a sign-out: the token manager keeps the access and refresh
  tokens in memory and would keep serving turns as that account until the token
  expired, while every surface reported the operator signed out. Nothing is
  revoked upstream.
  """

  alias FermixCore.Auth.AnthropicLogin
  alias FermixCore.Auth.CodexImport
  alias FermixCore.Auth.CodexLogin
  alias FermixCore.Auth.Redaction
  alias FermixCore.Auth.Store
  alias FermixCore.Auth.TokenManager
  alias FermixCore.Auth.TokenSupervisor
  alias FermixCore.Auth.XAILogin
  alias FermixCore.Management.Jobs
  alias FermixCore.Management.Settings
  alias FermixCore.Plugins.Auth, as: PluginAuth
  alias FermixCore.Plugins.Plugin
  alias FermixCore.Plugins.Registry, as: PluginRegistry
  alias FermixCore.Setup.Wizard

  require Logger

  # The two providers with a browser sign-in flow of their own. Anthropic is
  # deliberately absent: it has no loopback flow here, and its two ways in are
  # `auth.import.start` and a setup token through `secret.set`.
  @browser_flows ~w(openai_codex xai)
  @import_sources ~w(claude_code codex_cli)
  # A plugin signs in the same way, addressed by the one prefix the contract
  # publishes for it. The plugin's own OAuth client, scopes and loopback port
  # are the manifest's and the operator's; nothing about them is repeated here.
  @plugin_prefix "plugin:"
  # A provider whose route is auth-mode driven reverts to its key on sign-out;
  # a single-mode provider has no route to revert.
  @reverting_providers [:anthropic, :xai]

  @type error ::
          {:invalid_params, String.t(), String.t()}
          | {:busy, String.t()}
          | {:unavailable, String.t()}
          | {:external_change, [String.t()]}
          | {:config_unreadable, String.t()}

  @doc "Every provider `auth.start` can sign in through a browser, ordered."
  @spec browser_flows() :: [String.t()]
  def browser_flows, do: @browser_flows

  @doc "The `auth.start` provider prefix that addresses one plugin's own sign-in."
  @spec plugin_prefix() :: String.t()
  def plugin_prefix, do: @plugin_prefix

  @doc "Every source `auth.import.start` can adopt an existing sign-in from."
  @spec import_sources() :: [String.t()]
  def import_sources, do: @import_sources

  @doc """
  Starts a browser sign-in and answers once the daemon has an authorize url.

  The reply carries the job plus `authorize_url` and `expires_in_ms`. A flow
  that fails before it can mint a url answers with the job in its failed state,
  which is where the sentence lives.
  """
  @spec start(String.t(), keyword()) :: {:ok, map()} | {:error, error()}
  def start(provider, opts \\ [])

  def start(@plugin_prefix <> name, opts) when is_binary(name) and is_list(opts) do
    with {:ok, plugin} <- fetch_oauth_plugin(name) do
      start_flow(@plugin_prefix <> plugin.name, opts)
    end
  end

  def start(provider, opts) when is_binary(provider) and is_list(opts) do
    if provider in @browser_flows do
      start_flow(provider, opts)
    else
      {:error, {:invalid_params, "provider", "This provider has no browser sign-in."}}
    end
  end

  # A plugin whose credential is a typed token has no browser flow to start, and
  # one that needs none has nothing to sign in to. Both are named rather than
  # collapsed into the generic refusal: they are different fixes.
  defp fetch_oauth_plugin(name) do
    case PluginRegistry.find(name) do
      {:ok, %Plugin{auth: %{type: :oauth2}} = plugin} ->
        {:ok, plugin}

      {:ok, %Plugin{auth: %{type: :api_key}}} ->
        {:error,
         {:invalid_params, "provider", "This plugin signs in with a token, not a browser."}}

      {:ok, %Plugin{}} ->
        {:error, {:invalid_params, "provider", "This plugin needs no sign-in."}}

      :error ->
        {:error, {:invalid_params, "provider", "This daemon has no plugin by that name."}}

      {:error, reason} ->
        refuse("the plugin registry could not be read", reason)
    end
  end

  @doc "Adopts a sign-in this Mac already has, from Claude Code or the Codex CLI."
  @spec import_start(String.t(), keyword()) :: {:ok, map()} | {:error, error()}
  def import_start(source, opts \\ []) when is_binary(source) and is_list(opts) do
    if source in @import_sources do
      start_import(source, opts)
    else
      {:error, {:invalid_params, "source", "This daemon cannot import from that source."}}
    end
  end

  @doc """
  Forgets one provider's local session, drops its live tokens, and reverts the
  route it fed.
  """
  @spec logout(String.t(), keyword()) :: {:ok, map()} | {:error, error()}
  def logout(provider, opts \\ []) when is_binary(provider) and is_list(opts) do
    with {:ok, id, profile} <- fetch_signed_in(provider),
         :ok <- forget(profile, opts),
         :ok <- drop_live_tokens(provider, profile, opts),
         :ok <- revert_route(id, opts) do
      {:ok, %{"restart" => Settings.restart()}}
    end
  end

  defp start_flow(provider, opts) do
    started =
      Jobs.start(
        :auth,
        Keyword.merge(Keyword.get(opts, :jobs, []),
          name: provider,
          run: sign_in_run(provider, opts),
          await: true
        )
      )

    case started do
      {:ok, view} -> {:ok, view}
      {:error, :busy} -> {:error, {:busy, "auth"}}
      {:error, :await_timeout} -> {:error, {:unavailable, "auth"}}
    end
  end

  defp sign_in_run("openai_codex", opts) do
    login = Keyword.get(opts, :login, &CodexLogin.login/1)

    fn _job_id, report ->
      report.({:phase, "binding"})

      login.(oauth_opener: opener(report), puts: &silent/1)
      |> then(&finish_codex(&1, report, opts))
    end
  end

  defp sign_in_run(@plugin_prefix <> name, opts) do
    login = Keyword.get(opts, :plugin_login, &PluginAuth.login/2)

    fn _job_id, report ->
      report.({:phase, "binding"})

      name
      |> login.(opener: opener(report), puts: &silent/1)
      |> then(&finish_plugin(&1, report))
    end
  end

  defp sign_in_run("xai", opts) do
    login = Keyword.get(opts, :login, &XAILogin.login/1)

    fn _job_id, report ->
      report.({:phase, "binding"})

      login.(opener: opener(report), puts: &silent/1)
      |> then(&finish_xai(&1, report, opts))
    end
  end

  # The one place the authorize url exists. It goes to the waiting caller and
  # nowhere else: not to the logger, not to the trace, not to the job's own
  # retained view.
  defp opener(report) do
    fn url ->
      report.({:phase, "awaiting_browser"})
      report.({:ready, %{"authorize_url" => url, "expires_in_ms" => Jobs.budget_ms(:auth)}})
      :ok
    end
  end

  defp finish_codex({:ok, entry}, report, opts) do
    report.({:phase, "verifying"})

    with :ok <- complete_connection(:openai_codex, opts) do
      {:ok, %{"account_label" => Store.account_label(entry)}}
    end
  end

  defp finish_codex({:error, reason}, _report, _opts),
    do: {:error, {:unavailable, sign_in_sentence(reason)}}

  # A stored token is inert until the route selects it, so connecting and
  # switching the route are one operation: reporting success without the second
  # half would leave a signed-in provider the runtime never calls.
  defp finish_xai({:ok, entry}, report, opts) do
    report.({:phase, "verifying"})

    with :ok <- complete_connection(:xai, opts) do
      {:ok, %{"account_label" => Store.account_label(entry)}}
    end
  end

  defp finish_xai({:error, reason}, _report, _opts),
    do: {:error, {:unavailable, sign_in_sentence(reason)}}

  # A plugin sign-in enables the plugin as part of storing the session
  # (`Plugins.Auth.login/2`), so there is no second half to run here: the phase
  # names the verification the flow itself performs.
  defp finish_plugin({:ok, entry}, report) do
    report.({:phase, "verifying"})
    {:ok, %{"account_label" => Store.account_label(entry)}}
  end

  defp finish_plugin({:error, reason}, _report),
    do: {:error, {:unavailable, plugin_sentence(reason)}}

  defp set_auth_mode(opts),
    do: Keyword.get(opts, :set_auth_mode, &Wizard.set_provider_auth_mode/2)

  defp start_import(source, opts) do
    started =
      Jobs.start(
        :auth_import,
        Keyword.merge(Keyword.get(opts, :jobs, []),
          name: source,
          run: import_run(source, opts)
        )
      )

    case started do
      {:ok, view} -> {:ok, view}
      {:error, :busy} -> {:error, {:busy, "auth_import"}}
    end
  end

  # Claude Code's credentials live in the macOS keychain, and reading them can
  # raise the allow prompt, so that phase is named. The Codex CLI's live in a
  # file it wrote, so the import names no phase rather than borrowing a sentence
  # about a keychain it never touches.
  defp import_run("claude_code", opts) do
    importer = Keyword.get(opts, :importer, &AnthropicLogin.import_claude_code/0)

    fn _job_id, report ->
      report.({:phase, "reading_keychain"})
      finish_import(:anthropic, importer.(), report, opts)
    end
  end

  defp import_run("codex_cli", opts) do
    importer = Keyword.get(opts, :importer, &CodexImport.import_tokens/0)

    fn _job_id, report -> finish_import(:openai_codex, importer.(), report, opts) end
  end

  defp finish_import(provider, {:ok, entry}, report, opts) do
    report.({:phase, "verifying"})

    with :ok <- complete_connection(provider, opts) do
      {:ok,
       %{"provider" => Atom.to_string(provider), "account_label" => Store.account_label(entry)}}
    end
  end

  defp finish_import(_provider, {:error, reason}, _report, _opts),
    do: {:error, {:unavailable, import_sentence(reason)}}

  # Every provider connection activates the route and the manager that serves
  # it before promoting it. A persisted session alone is not a usable sign-in.
  defp complete_connection(provider, opts) do
    with :ok <- select_sign_in_route(provider, opts),
         :ok <- reload_credentials(provider, opts),
         :ok <- promote(provider, opts) do
      :ok
    else
      {:error, {:reload_failed, reason}} -> {:error, {:unavailable, reload_sentence(reason)}}
      {:error, reason} -> {:error, {:unavailable, route_sentence(reason)}}
    end
  end

  defp select_sign_in_route(provider, opts) when provider in @reverting_providers do
    with {:ok, _report} <- set_auth_mode(opts).(provider, :oauth), do: :ok
  end

  defp select_sign_in_route(_provider, _opts), do: :ok

  defp reload_credentials(provider, opts) do
    reload = Keyword.get(opts, :reload, fn -> reload_token_manager(provider) end)

    case reload.() do
      :ok -> :ok
      {:error, reason} -> {:error, {:reload_failed, reason}}
    end
  end

  # A sign-in is a connect, and on a fresh home the first provider connected is
  # the one Fermix should call. The browser door promotes it inside
  # `save_answers/2`; without the same call here, `setup.state.get` reported the
  # compiled-in `:openai` default as primary, readiness stayed gated on it, and
  # the operator was told to connect a provider they had just connected.
  defp promote(provider, opts) do
    promote = Keyword.get(opts, :promote, &Wizard.promote_if_first_configured/1)
    promote.(provider)
  end

  defp fetch_signed_in(provider) do
    with {:ok, id} <- provider_id(provider),
         profile when is_binary(profile) <- Store.profile(id) do
      {:ok, id, profile}
    else
      {:error, _reason} = error -> error
      nil -> {:error, {:invalid_params, "provider", "This provider has no stored sign-in."}}
    end
  end

  defp provider_id(provider) do
    case Enum.find(Store.profiled_providers(), &(Atom.to_string(&1) == provider)) do
      nil -> {:error, {:invalid_params, "provider", "This daemon has no such provider."}}
      id -> {:ok, id}
    end
  end

  # Forgetting a session that is already gone is the state the caller asked
  # for, not a failure: both "no auth file" and "no entry for this provider"
  # answer the same way the CLI's own sign-out does.
  defp forget(profile, opts) do
    delete = Keyword.get(opts, :forget, &Store.delete_provider/1)

    case delete.(profile) do
      :ok -> :ok
      {:error, :no_auth_file} -> :ok
      {:error, {:provider_missing, _profile}} -> :ok
      {:error, reason} -> refuse("the stored sign-in could not be removed", reason)
    end
  end

  # Two managers can hold one profile's tokens: the top-level `TokenManager`
  # started with the tree, which serves the Codex profile, and a per-profile
  # child under `TokenSupervisor` for anthropic and xai. A sign-out reaches the
  # one that serves the provider being signed out, and starts neither.
  defp drop_live_tokens(provider, profile, opts) do
    drop = Keyword.get(opts, :drop_live_tokens, &drop_tokens/2)
    drop.(provider, profile)
  end

  defp drop_tokens("openai_codex", _profile), do: forget_default_manager()
  defp drop_tokens(_provider, profile), do: TokenSupervisor.forget(profile)

  defp forget_default_manager do
    case Process.whereis(TokenManager) do
      nil -> :ok
      pid -> TokenManager.forget(pid)
    end
  end

  defp revert_route(id, opts) when id in @reverting_providers do
    case set_auth_mode(opts).(id, :api_key) do
      {:ok, _report} -> :ok
      {:error, {:external_change, sections}} -> {:error, {:external_change, sections}}
      {:error, {:config_unreadable, sentence}} -> {:error, {:config_unreadable, sentence}}
      {:error, reason} -> refuse("the sign-in route could not be reverted", reason)
    end
  end

  defp revert_route(_id, _opts), do: :ok

  # A request-path refusal names a capability, not a sentence, so the reason is
  # logged rather than dropped: the wire has nowhere to carry it and losing it
  # would leave the operator and the log both without the cause.
  defp refuse(what, reason) do
    Logger.error("management auth: #{what}: #{format(reason)}")
    {:error, {:unavailable, "auth"}}
  end

  defp reload_token_manager(:openai_codex) do
    case Process.whereis(TokenManager) do
      nil -> :ok
      pid -> reload_result(TokenManager.reload(pid))
    end
  end

  defp reload_token_manager(provider) do
    provider |> Store.profile() |> TokenSupervisor.reload() |> reload_result()
  end

  defp reload_result({:ok, _token}), do: :ok
  defp reload_result({:error, reason}), do: {:error, reason}

  defp plugin_sentence(:needs_client_config),
    do: "This plugin has no sign-in client yet, so the browser flow cannot start."

  defp plugin_sentence({:unsupported_oauth_provider, _provider}),
    do: "This daemon cannot sign in to that plugin's provider."

  defp plugin_sentence(reason), do: sign_in_sentence(reason)

  defp sign_in_sentence({:port_in_use, port}),
    do: "Port #{port} is already in use, so the sign-in reply could not be received."

  defp sign_in_sentence({:listen_failed, port, _reason}),
    do: "Port #{port} could not be opened to receive the sign-in reply."

  defp sign_in_sentence(:timeout), do: "The sign-in was not completed in time."

  defp sign_in_sentence({endpoint, _url})
       when endpoint in [:insecure_token_endpoint, :untrusted_token_endpoint],
       do: "The sign-in was sent to an address this daemon does not trust."

  defp sign_in_sentence({:persist_failed, reason}) do
    log("the credentials could not be stored", reason)
    "The sign-in succeeded but the credentials could not be stored. See the daemon log."
  end

  # The residue. What is left is the login flow's own internal term, which
  # carries the account, the endpoint and the paths it read; it goes to the
  # daemon log rather than to the sentence a client renders.
  defp sign_in_sentence(reason) do
    log("the sign-in could not be completed", reason)
    "The sign-in could not be completed. See the daemon log."
  end

  # The absent case in the three spellings that reach it: an injected importer's
  # `:not_found`, and the atom each of the two real importers answers with.
  defp import_sentence(absent)
       when absent in [:not_found, :no_claude_code_credentials, :no_codex_auth],
       do: "No existing sign-in was found on this Mac."

  defp import_sentence(:claude_code_credentials_expired),
    do: "The sign-in on this Mac has expired, so there was nothing to adopt."

  defp import_sentence(unreadable)
       when unreadable in [
              :claude_code_credentials_invalid,
              :codex_auth_invalid_json,
              :codex_auth_missing_refresh_token
            ],
       do: "The sign-in on this Mac could not be read, so there was nothing to adopt."

  defp import_sentence(reason) do
    log("the sign-in could not be imported", reason)
    "The sign-in could not be imported. See the daemon log."
  end

  defp reload_sentence(reason) do
    log("the credentials could not be loaded", reason)
    "The credentials were stored but could not be loaded. See the daemon log."
  end

  defp route_sentence(reason) do
    log("the sign-in route could not be changed", reason)
    "The provider's sign-in route could not be changed. See the daemon log."
  end

  defp log(what, reason), do: Logger.error("management auth: #{what}: #{format(reason)}")

  defp format(reason), do: Redaction.format(reason)
  defp silent(_message), do: :ok
end
