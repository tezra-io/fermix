defmodule FermixCore.Management.Plugins do
  @moduledoc """
  The `plugins.*` methods: the integrations surface, over the registry, the
  baked catalog and `Plugins.Config` (M34 native setup §5.6, §7.3).

  `plugins.list` is one read of the union the browser door already shows —
  installed plugins from the registry, the rest of the catalog index as
  not-yet-installed rows — projected into the one row shape every verb also
  answers with. Every word on a row is the daemon's (`Plugins.Row`); a client
  arranges them.

  Five verbs are requests because they finish at once: enable, disable,
  disconnect, one manifest setting, one sign-in client. Four are jobs because
  they wait on a network or a person: the install, the health check, the
  workspace discovery and the workspace binding. The credential half never
  appears here at all: a plugin's own token arrives through
  `secret.set plugin:<name>`, a sign-in client's secret through
  `secret.set oauth_client:<provider>`, and a plugin's browser sign-in through
  `auth.start plugin:<name>`.

  Native driver features (computer use, computer history, the meeting
  notetaker) are deliberately absent from this listing even where the catalog
  carries an entry for their sidecar: they are settings sections with their own
  panes, and a row here would be a second switch for one key. The browser door
  drops them from its own card grid for the same reason.
  """

  alias FermixCore.Auth.Redaction
  alias FermixCore.Capabilities.MCP.RuntimeStatus
  alias FermixCore.ComputerUse.SidecarInstaller
  alias FermixCore.Management.Jobs
  alias FermixCore.Management.Plugins.Discovery
  alias FermixCore.Management.Plugins.Row
  alias FermixCore.Plugins.Auth, as: PluginAuth
  alias FermixCore.Plugins.Catalog
  alias FermixCore.Plugins.Config
  alias FermixCore.Plugins.Dist.Installer
  alias FermixCore.Plugins.Health
  alias FermixCore.Plugins.Plugin
  alias FermixCore.Plugins.Registry
  alias FermixCore.Plugins.RemoteSetup
  alias FermixCore.Plugins.Status

  require Logger

  @max_setting_bytes 4_096

  @type error ::
          {:invalid_params, String.t(), String.t()}
          | {:busy, String.t()}
          | {:unavailable, String.t()}
          | {:external_change, [String.t()]}
          | {:config_unreadable, String.t()}

  @doc "Every plugin this daemon can show, and every sign-in client they need."
  @spec list(keyword()) :: {:ok, map()} | {:error, error()}
  def list(opts \\ []) when is_list(opts) do
    case Catalog.overview(dist_opts(opts)) do
      {:ok, overview} -> {:ok, project(overview, opts)}
      {:error, reason} -> refuse("the plugin catalog could not be read", reason)
    end
  end

  @doc "Turns one installed plugin on, and answers with its row."
  @spec enable(String.t(), keyword()) :: {:ok, map()} | {:error, error()}
  def enable(name, opts \\ []) when is_binary(name) and is_list(opts) do
    write(name, opts, fn -> Config.enable(name) end)
  end

  @doc "Turns one plugin off, and answers with its row."
  @spec disable(String.t(), keyword()) :: {:ok, map()} | {:error, error()}
  def disable(name, opts \\ []) when is_binary(name) and is_list(opts) do
    write(name, opts, fn -> Config.disable(name) end)
  end

  @doc """
  Forgets the credential behind one plugin, and answers with its row.

  Local only: an OAuth session is deleted here, a stored token is removed from
  the keychain, and neither is revoked upstream.
  """
  @spec disconnect(String.t(), keyword()) :: {:ok, map()} | {:error, error()}
  def disconnect(name, opts \\ []) when is_binary(name) and is_list(opts) do
    with {:ok, plugin} <- fetch_plugin(name, opts) do
      write(name, opts, fn -> forget_credential(plugin, opts) end)
    end
  end

  @doc "Writes one manifest-declared setting, and answers with the plugin's row."
  @spec setting_set(String.t(), String.t(), term(), keyword()) :: {:ok, map()} | {:error, error()}
  def setting_set(name, key, value, opts \\ [])
      when is_binary(name) and is_binary(key) and is_list(opts) do
    with {:ok, text} <- setting_value(value) do
      write(name, opts, fn -> Config.set_plugin_setting(name, key, text) end)
    end
  end

  @doc """
  Registers one sign-in client, and answers with the client row.

  The client secret is not a parameter: it arrives through
  `secret.set oauth_client:<provider>`, and this refuses until it has. An
  absent `redirect_port` clears any override, which is what leaves the
  daemon's own default in force.
  """
  @spec oauth_client_set(String.t(), String.t(), pos_integer() | nil, keyword()) ::
          {:ok, map()} | {:error, error()}
  def oauth_client_set(provider, client_id, redirect_port, opts \\ [])
      when is_binary(provider) and is_binary(client_id) and is_list(opts) do
    with {:ok, providers} <- published_providers(opts),
         :ok <- known_provider(provider, providers),
         {:ok, _config} <- store_oauth_client(provider, client_id, redirect_port) do
      {:ok, %{"oauth_client" => oauth_client(provider)}}
    end
  end

  @doc "Starts one catalog install. The consent that precedes it is the client's."
  @spec install_start(String.t(), keyword()) :: {:ok, map()} | {:error, error()}
  def install_start(name, opts \\ []) when is_binary(name) and is_list(opts) do
    start_job(:plugin_install, name, install_run(name, opts), opts)
  end

  @doc "Starts one health check, which runs the plugin's own live probe."
  @spec check_start(String.t(), keyword()) :: {:ok, map()} | {:error, error()}
  def check_start(name, opts \\ []) when is_binary(name) and is_list(opts) do
    start_job(:plugin_check, name, check_run(name, opts), opts)
  end

  @doc """
  Starts one workspace discovery for a remote plugin.

  What it finds is republished on the plugin's row rather than in the job: a
  job result is flat scalars only, so the rows themselves cannot ride on it.
  """
  @spec workspaces_discover_start(String.t(), keyword()) :: {:ok, map()} | {:error, error()}
  def workspaces_discover_start(name, opts \\ []) when is_binary(name) and is_list(opts) do
    with {:ok, plugin} <- fetch_remote_plugin(name, opts) do
      start_job(:plugin_workspaces_discover, name, discover_run(plugin, opts), opts)
    end
  end

  @doc """
  Binds one remote plugin to one workspace under one access profile.

  Success means the replacement client reached ready, contract check included,
  not that a child process started.
  """
  @spec workspace_select_start(String.t(), map(), keyword()) :: {:ok, map()} | {:error, error()}
  def workspace_select_start(name, selection, opts \\ [])
      when is_binary(name) and is_map(selection) and is_list(opts) do
    with {:ok, plugin} <- fetch_remote_plugin(name, opts) do
      start_job(:plugin_workspace_select, name, select_run(plugin, selection, opts), opts)
    end
  end

  # --- listing ---

  defp project(overview, opts) do
    enabled = Config.enabled_plugins()
    runtime = runtime_entries(opts)
    discovered = Discovery.all(discovery_opts(opts))

    installed =
      overview.installed
      |> Enum.reject(&native_feature?(&1.name))
      |> Enum.map(&Row.installed(&1, context(&1, enabled, runtime, discovered, opts)))

    available =
      overview.available
      |> Enum.reject(&native_feature?(&1.name))
      |> Enum.map(&Row.available/1)

    rows = installed ++ available
    %{"plugins" => rows, "oauth_clients" => Enum.map(providers_of(rows), &oauth_client/1)}
  end

  defp context(plugin, enabled, runtime, discovered, opts) do
    %{
      enabled: enabled,
      status: resolved_status(plugin, runtime, opts),
      workspaces: Map.get(discovered, plugin.name, [])
    }
  end

  # The local ladder answers whether the plugin can start; only once it says so
  # does the live table have anything to add, and what it adds is whether the
  # client is actually callable. Asking the table first would let a connection
  # that is merely open outrank a missing credential.
  defp resolved_status(plugin, runtime, opts) do
    case Status.status(plugin, Keyword.take(opts, [:probe])) do
      :ready -> live_status(plugin.name, runtime)
      local -> local
    end
  end

  defp live_status(name, runtime) do
    case Map.get(runtime, {:plugin, name}) do
      %{status: status} when is_atom(status) -> status
      _no_live_client -> :ready
    end
  end

  # A sign-in client is published only where a plugin needs one, which is the
  # daemon's own list rather than a table of every provider that exists.
  defp providers_of(rows) do
    rows
    |> Enum.map(&Map.get(&1, "auth_provider"))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp oauth_client(provider) do
    config = Config.oauth_provider(provider)

    %{
      "provider" => provider,
      "client_id" => Keyword.get(config, :client_id),
      "secret_present" => present?(Keyword.get(config, :client_secret)),
      "configured" =>
        present?(Keyword.get(config, :client_id)) and
          present?(Keyword.get(config, :client_secret)),
      "redirect_port" => redirect_port(Keyword.get(config, :redirect_port))
    }
  end

  defp redirect_port(port) when is_integer(port) and port > 0 and port <= 65_535, do: port
  defp redirect_port(_port), do: nil

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp native_feature?(name), do: name == SidecarInstaller.plugin_name()

  # --- write verbs ---

  defp write(name, opts, commit) do
    case commit.() do
      {:ok, _result} -> row_for(name, opts)
      :ok -> row_for(name, opts)
      {:error, reason} -> write_error(name, reason, opts)
    end
  end

  defp row_for(name, opts) do
    with {:ok, plugin} <- fetch_plugin(name, opts) do
      context =
        context(
          plugin,
          Config.enabled_plugins(),
          runtime_entries(opts),
          Discovery.all(discovery_opts(opts)),
          opts
        )

      {:ok, %{"plugin" => Row.installed(plugin, context)}}
    end
  end

  defp forget_credential(%Plugin{auth: %{type: :oauth2}, name: name}, opts) do
    logout = Keyword.get(opts, :logout, &PluginAuth.logout/1)
    logout.(name)
  end

  defp forget_credential(%Plugin{auth: %{type: :api_key}, name: name}, opts) do
    forget = Keyword.get(opts, :forget_secret, &PluginAuth.forget_secret/1)
    forget.(name)
  end

  defp forget_credential(%Plugin{}, _opts), do: {:error, :nothing_to_disconnect}

  defp setting_value(value) when is_binary(value) and byte_size(value) > 0 do
    if byte_size(value) <= @max_setting_bytes do
      {:ok, value}
    else
      {:error, {:invalid_params, "value", "This setting is at most 4096 bytes."}}
    end
  end

  defp setting_value(_value) do
    {:error, {:invalid_params, "value", "A plugin setting is text, and cannot be empty."}}
  end

  defp published_providers(opts) do
    with {:ok, %{"plugins" => rows}} <- list(opts), do: {:ok, providers_of(rows)}
  end

  defp known_provider(provider, providers) do
    if provider in providers do
      :ok
    else
      {:error, {:invalid_params, "provider", "No plugin on this Mac signs in through that."}}
    end
  end

  # The stored client secret is carried through rather than re-sent: it arrives
  # only through `secret.set`, and the one writer replaces the provider block
  # whole, so leaving it out here would erase the credential this call is not
  # allowed to carry.
  defp store_oauth_client(provider, client_id, redirect_port) do
    existing = Config.oauth_provider(provider)

    result =
      Config.set_oauth_provider(provider,
        client_type: "desktop_public_pkce",
        client_id: client_id,
        client_secret: Keyword.get(existing, :client_secret),
        redirect_host: Keyword.get(existing, :redirect_host),
        redirect_port: redirect_port
      )

    case result do
      {:ok, config} -> {:ok, config}
      {:error, reason} -> oauth_error(provider, reason)
    end
  end

  defp oauth_error(_provider, {:missing_oauth_client_field, _named, :client_secret}) do
    {:error, {:invalid_params, "provider", "Add this provider's client secret first."}}
  end

  defp oauth_error(_provider, {:missing_oauth_client_field, _named, :client_id}) do
    {:error, {:invalid_params, "client_id", "A sign-in client needs its identifier."}}
  end

  defp oauth_error(provider, reason), do: write_error(provider, reason, [])

  defp write_error(name, {:unknown_plugin, _name}, opts) do
    Logger.info("management plugins: no installed plugin named #{name}")
    absent_plugin(name, opts)
  end

  defp write_error(_name, {:external_change, sections}, _opts),
    do: {:error, {:external_change, sections}}

  defp write_error(_name, {:config_unreadable, sentence}, _opts),
    do: {:error, {:config_unreadable, sentence}}

  defp write_error(_name, {:unknown_config_key, _key}, _opts),
    do: {:error, {:invalid_params, "key", "This plugin declares no setting by that name."}}

  defp write_error(_name, {:blank_config_value, _key}, _opts),
    do: {:error, {:invalid_params, "value", "This setting cannot be empty."}}

  defp write_error(_name, :nothing_to_disconnect, _opts),
    do: {:error, {:invalid_params, "name", "This plugin holds no credential to forget."}}

  defp write_error(_name, {:not_api_key_plugin, _named}, _opts),
    do: {:error, {:invalid_params, "name", "This plugin holds no token to forget."}}

  defp write_error(name, reason, _opts),
    do: refuse("the write for #{name} was refused", reason)

  # --- jobs ---

  defp start_job(kind, name, run, opts) do
    started = Jobs.start(kind, Keyword.merge(jobs_opts(opts), name: name, run: run))

    case started do
      {:ok, view} -> {:ok, view}
      {:error, :busy} -> {:error, {:busy, Atom.to_string(kind)}}
    end
  end

  defp install_run(name, opts) do
    install = Keyword.get(opts, :install, &Installer.run_install/2)
    install_opts = dist_opts(opts)

    fn _job_id, report ->
      report.({:phase, "downloading"})
      finish_install(name, install.(name, install_opts))
    end
  end

  defp finish_install(name, {:ok, _outcome}), do: {:ok, %{"name" => name, "installed" => true}}

  defp finish_install(_name, {:error, reason}),
    do: {:error, {:unavailable, install_sentence(reason)}}

  defp check_run(name, opts) do
    check = Keyword.get(opts, :check, &Health.check/2)

    fn _job_id, report ->
      report.({:phase, "probing"})
      finish_check(name, check.(name, full?: true))
    end
  end

  defp finish_check(name, {:ok, result}) do
    {:ok,
     %{
       "name" => name,
       "status" => to_string(Map.get(result, :status)),
       "live_probe" => Map.get(result, :live_probe?, false)
     }}
  end

  defp finish_check(_name, {:error, {:not_ready, status}}),
    do: {:error, {:refused, Row.check_sentence(status)}}

  # A reason that gets this far is the probe's own internal term: it names files
  # on the operator's disk, so it goes to the daemon log and the sentence a
  # client renders stays fixed.
  defp finish_check(_name, {:error, reason}) do
    Logger.error("management plugins: the check did not finish: #{Redaction.format(reason)}")
    {:error, {:unavailable, "The check did not finish. See the daemon log."}}
  end

  defp discover_run(plugin, opts) do
    discover = Keyword.get(opts, :discover, &RemoteSetup.discover_workspaces/2)
    remote = Keyword.get(opts, :remote_opts, [])
    record = discovery_opts(opts)

    fn _job_id, report ->
      report.({:phase, "listing"})
      finish_discovery(plugin.name, discover.(plugin, remote), record)
    end
  end

  defp finish_discovery(name, {:ok, workspaces}, record) do
    :ok = Discovery.record(name, workspaces, record)
    {:ok, %{"name" => name, "found" => length(workspaces)}}
  end

  defp finish_discovery(_name, {:error, reason}, _record),
    do: {:error, {:unavailable, remote_sentence("The workspaces could not be listed", reason)}}

  defp select_run(plugin, selection, opts) do
    select = Keyword.get(opts, :select, &RemoteSetup.select_workspace/2)
    remote = Keyword.get(opts, :remote_opts, [])

    chosen = [
      access_profile: Map.get(selection, "profile"),
      workspace_id: Map.get(selection, "workspace_id"),
      workspace_label: Map.get(selection, "label")
    ]

    fn _job_id, report ->
      report.({:phase, "binding"})
      finish_selection(plugin.name, select.(plugin, chosen ++ remote))
    end
  end

  defp finish_selection(name, :ok), do: {:ok, %{"name" => name, "bound" => true}}

  defp finish_selection(_name, {:error, {:invalid_access_profile, _named, _profile}}),
    do: {:error, {:refused, "This plugin does not offer that access level."}}

  defp finish_selection(_name, {:error, {:invalid_workspace_id, _detail}}),
    do: {:error, {:refused, "That workspace identifier is not one this plugin can use."}}

  defp finish_selection(_name, {:error, {:invalid_workspace_label, _detail}}),
    do: {:error, {:refused, "That workspace name is not one this plugin can use."}}

  defp finish_selection(_name, {:error, reason}),
    do: {:error, {:unavailable, remote_sentence("The workspace could not be bound", reason)}}

  # --- sentences ---

  defp install_sentence({:bundled_plugin, _name}),
    do: "This plugin ships inside Fermix and is already installed."

  defp install_sentence({:unknown_plugin, _name}),
    do: "This daemon's catalog carries no plugin by that name."

  defp install_sentence({:version_not_found, _name, _version}),
    do: "This plugin has no installable version yet."

  defp install_sentence({:yanked, _name, _version}),
    do: "The published version of this plugin was withdrawn."

  defp install_sentence({:incompatible, _reason}),
    do: "This build of Fermix cannot run it."

  defp install_sentence({:missing_host_runtime, kind, _min_version}),
    do: "It needs #{kind} on this Mac, and it was not found on the daemon's PATH."

  defp install_sentence({:verification_failed, _reason}),
    do: "The download did not match the signature it was published with."

  defp install_sentence({:sha256_mismatch, _detail}),
    do: "The download did not match the checksum it was published with."

  defp install_sentence({:no_build_for_target, _target}),
    do: "This plugin has no build for this Mac."

  defp install_sentence({:host_unsupported, _reason}),
    do: "This daemon does not know how to install for this machine."

  defp install_sentence({:tree_missing, _root}),
    do: "The downloaded files were gone before they could be checked."

  defp install_sentence({:unsafe_member, _kind, _entry}),
    do: "The download holds a file that is not safe to unpack."

  defp install_sentence({boundary, _entry})
       when boundary in [:content_boundary_violation, :remote_content_boundary_violation],
       do: "The download holds files this plugin is not allowed to ship."

  defp install_sentence({:remote_executable_file, _path}),
    do: "This hosted plugin ships a program, which it is not allowed to do."

  defp install_sentence({mismatch, _found, _asked})
       when mismatch in [:manifest_name_mismatch, :manifest_version_mismatch],
       do: "The download does not describe the plugin that was asked for."

  defp install_sentence(manifest)
       when manifest in [:manifest_not_object, :manifest_invalid_json, :manifest_missing],
       do: "The download has no readable plugin description."

  defp install_sentence(:lock_unavailable),
    do: "Another plugin operation is using the plugin store."

  # The residue. Everything above is a refusal this daemon can explain; what is
  # left is the installer's internal term, which carries the operator's own
  # paths and the archive's own bytes. It goes to the daemon log, never to the
  # wire and never to the job bookend that carries the sentence.
  defp install_sentence(reason) do
    Logger.error("management plugins: the install did not finish: #{Redaction.format(reason)}")
    "The install did not finish. See the daemon log."
  end

  # Neither classified nor rendered: `RuntimeStatus.classify/1` answers
  # `:remote_unreachable` for every reason it does not recognise, so rendering
  # through it would put one word on a dozen different failures, and the reason
  # itself is an internal term. The daemon log keeps it; the sentence names the
  # half of the operation that failed.
  defp remote_sentence(what, reason) do
    Logger.error("management plugins: #{what}: #{Redaction.format(reason)}")
    "#{what}. See the daemon log."
  end

  # --- plumbing ---

  defp fetch_plugin(name, opts) do
    case Registry.find(name) do
      {:ok, plugin} -> {:ok, plugin}
      :error -> absent_plugin(name, opts)
      {:error, reason} -> refuse("the plugin registry could not be read", reason)
    end
  end

  # Two different states wearing one word. A name the catalog carries is one the
  # operator picked off the list this daemon published, so telling them it does
  # not exist sends them hunting for a typo instead of pressing Install.
  defp absent_plugin(name, opts) do
    case Catalog.overview(dist_opts(opts)) do
      {:ok, overview} -> {:error, {:invalid_params, "name", absent_sentence(name, overview)}}
      {:error, reason} -> refuse("the plugin catalog could not be read", reason)
    end
  end

  defp absent_sentence(name, %{available: available}) do
    if Enum.any?(available, &(&1.name == name)) do
      "Install this plugin before using it."
    else
      "This daemon has no plugin by that name."
    end
  end

  defp fetch_remote_plugin(name, opts) do
    with {:ok, plugin} <- fetch_plugin(name, opts), do: require_workspaces(plugin)
  end

  defp require_workspaces(%Plugin{resource_scope: scope} = plugin) when is_map(scope),
    do: {:ok, plugin}

  defp require_workspaces(%Plugin{}),
    do: {:error, {:invalid_params, "name", "This plugin does not bind to a workspace."}}

  defp runtime_entries(opts) do
    Keyword.get(opts, :runtime_entries, &default_runtime_entries/0).()
  end

  # The live table lives in the daemon's own memory. A tree-less verb has no
  # table, and its absence is "no live client", never "ready".
  defp default_runtime_entries do
    case Process.whereis(RuntimeStatus) do
      nil -> %{}
      _pid -> RuntimeStatus.list(RuntimeStatus)
    end
  end

  defp dist_opts(opts), do: Keyword.get(opts, :dist_opts, [])
  defp discovery_opts(opts), do: Keyword.take(opts, [:discovery])
  defp jobs_opts(opts), do: Keyword.get(opts, :jobs, [])

  defp refuse(what, reason) do
    Logger.error("management plugins: #{what}: #{Redaction.format(reason)}")
    {:error, {:unavailable, "plugins"}}
  end
end
