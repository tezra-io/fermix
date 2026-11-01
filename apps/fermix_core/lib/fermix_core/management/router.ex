defmodule FermixCore.Management.Router do
  @moduledoc """
  Routes validated management v1 requests to daemon-owned capabilities.

  Every result is an explicit public projection. Internal paths, arbitrary
  failure terms, and Setup token state never cross this boundary.
  """

  alias FermixCore.BuildInfo
  alias FermixCore.Health
  alias FermixCore.Home.Role
  alias FermixCore.Introspection.Overview
  alias FermixCore.Management.AlwaysOn
  alias FermixCore.Management.Auth
  alias FermixCore.Management.Capabilities
  alias FermixCore.Management.ComputerUse
  alias FermixCore.Management.Cues
  alias FermixCore.Management.Detect
  alias FermixCore.Management.Diagnostics
  alias FermixCore.Management.Doctor
  alias FermixCore.Management.Home
  alias FermixCore.Management.HomeMove
  alias FermixCore.Management.IMessage
  alias FermixCore.Management.Jobs
  alias FermixCore.Management.Lifecycle
  alias FermixCore.Management.Logs
  alias FermixCore.Management.McpServers
  alias FermixCore.Management.Meetings
  alias FermixCore.Management.Mobile
  alias FermixCore.Management.Placement
  alias FermixCore.Management.Plugins
  alias FermixCore.Management.Protocol
  alias FermixCore.Management.Providers
  alias FermixCore.Management.Provision
  alias FermixCore.Management.Secrets
  alias FermixCore.Management.Settings
  alias FermixCore.Management.SetupState
  alias FermixCore.Setup.AccessToken
  alias FermixCore.Setup.Endpoint

  # Operations whose contract is "no input at all". Every other method declares
  # its own parameter set, so an unexpected key is refused rather than ignored.
  @no_param_methods ~w(
    hello overview.get setup.session.create lifecycle.prepare diagnostics.build setup.state.get
    settings.sections settings.reload job.list plugins.list meetings.signin.start
    computer_use.grant.start computer_use.permissions.get mobile.status mobile.pair.start
    mobile.devices.list browser.install.start imessage.permissions.get imessage.policy.confirm
    mcp.servers.list mcp.servers.import.scan cues.status cues.sources.list cues.watchers.list
    cues.mandates.list cues.mandates.choices home.snapshots.status home.snapshots.run
    home.enroll.withdraw home.candidates.list home.provision.options
  )
  @lease_params ~w(lease_id)
  @doctor_session_params ~w(session_id)
  @doctor_start_params ~w(scope)
  @doctor_scopes %{"local" => :local, "network" => :network}
  @settings_get_params ~w(section)
  @settings_apply_params ~w(section values)
  @secret_set_params ~w(id value)
  @secret_clear_params ~w(id)
  @detect_params ~w(targets)
  @job_id_params ~w(job_id)
  @provider_params ~w(provider)
  @models_params ~w(provider live query cursor limit)
  @import_params ~w(source)
  @capability_params ~w(target)
  @plugin_name_params ~w(name)
  @plugin_setting_params ~w(name key value)
  @oauth_client_params ~w(provider client_id redirect_port region)
  @workspace_select_params ~w(name profile workspace_id label)
  @mobile_session_params ~w(session_id)
  @mobile_decide_params ~w(session_id approved)
  @mobile_device_params ~w(device_id)
  @imessage_grant_params ~w(service)
  @mcp_name_params ~w(name)
  @mcp_server_params ~w(
    name transport command_line url cwd env_names auth key_header header_names oauth_client_id
  )
  @mcp_add_params ["draft_id" | @mcp_server_params]
  @mcp_draft_params ~w(text)
  @mcp_import_params ~w(servers)
  @mcp_tool_params ~w(name tool enabled)
  @home_status_params ~w(after wait_ms)
  # A summary's key is a short digest; the bound only refuses junk.
  @max_status_key_bytes 64
  @home_passphrase_params ~w(recovery_passphrase)
  @home_enroll_params ~w(kind)
  @home_readiness_params ~w(candidate_id)
  @home_move_params ~w(candidate_id recovery_passphrase keep_as_desktop)
  @home_act_params ~w(action key input)
  # A candidate (M75 §2) answers the protocol's hello and home.status, and
  # refuses every other method by name.
  @candidate_methods ~w(hello home.status)
  @candidate_sentence "This engine is a candidate primary waiting for its move; it answers " <>
                        "home.status and nothing else until the move makes it the primary."
  @cue_ref_params ~w(ref)
  @cue_form_params ~w(kind preset verify)
  @cue_add_params ~w(ref kind preset values)
  @cue_update_params ~w(ref values)
  @cue_name_params ~w(name)
  @cue_mandate_params ~w(name values)
  @cue_proposal_params ~w(proposal_id)
  @cue_list_params ~w(state)
  @cue_decide_params ~w(proposal_id decision)
  @cue_proposal_states %{"waiting" => :waiting, "recent" => :recent}
  @cue_decisions %{"confirm" => :confirm, "deny" => :deny}
  @primary_sections_unread "The server listed its settings in a form this computer does " <>
                             "not read."
  # A published name, an opaque workspace id and a display label are all bounded
  # strings; the widest of them is the workspace id's own 256-byte bound.
  @max_text_bytes 256
  # The methods that call a provider or touch a provider session (a sign-in, an
  # import, a sign-out's revocation, a probe, a live listing, the network
  # doctor, the notetaker's sign-in), each with the capability its refusal
  # names. A device-role engine
  # refuses them by name: the token file on its host is a retired copy and a
  # rotating refresh token has one live owner, the primary (M75 D5).
  @provider_methods %{
    "providers.probe.start" => "providers",
    "providers.models.list" => "providers",
    "auth.start" => "auth",
    "auth.import.start" => "auth",
    "auth.logout" => "auth",
    "plugins.disconnect" => "plugins",
    "meetings.signin.start" => "meetings",
    "doctor.start" => "doctor"
  }
  # The detection catalog is closed and small, so the ceiling is the catalog
  # rather than a round number: a longer list can only repeat targets.
  @max_detect_targets 6
  # One section per call, and a section id is a published name, so the bound is
  # the widest name this daemon can serve rather than a round number.
  @max_section_bytes 128

  @type route_result :: Protocol.route_result()

  @doc """
  Routes one validated management request against its own declared version.

  The declared version is the gate, not the daemon's own: a v2 daemon answering
  a v1-negotiated session refuses every method whose minimum exceeds 1, and says
  which version it needs, so the client can tell "restart onto the newer engine"
  apart from "this daemon has no such method".
  """
  @spec route(Protocol.request(), keyword()) :: route_result()
  def route(%{method: method, protocol_version: version, params: params}, opts \\ [])
      when is_integer(version) and version > 0 and is_map(params) and is_list(opts) do
    case Protocol.minimum_version(method) do
      {:ok, minimum} when minimum <= version ->
        with :ok <- admit(method, params, opts), do: route_known(method, params, opts)

      {:ok, minimum} ->
        {:error, :method_not_found, %{"method" => method, "requires" => minimum}}

      :error ->
        {:error, :method_not_found, %{"method" => public_method(method)}}
    end
  end

  @doc """
  The daemon's immutable public build identity, plus this OS process id.

  Shared with `diagnostics.build` so the app reads one identity, not two that
  can disagree about which engine answered.
  """
  @spec engine_identity() :: {:ok, map()}
  def engine_identity do
    {:ok, Map.put(BuildInfo.public_identity(), "pid", System.pid())}
  end

  defp route_known(method, params, _opts) when method in @no_param_methods and params != %{},
    do: {:error, :invalid_params, %{"method" => method}}

  defp route_known("hello", %{}, opts), do: hello(opts)
  defp route_known("overview.get", %{}, opts), do: overview(opts)
  defp route_known("setup.session.create", %{}, opts), do: setup_session(opts)
  defp route_known("diagnostics.build", %{}, opts), do: diagnostics(opts)
  defp route_known("lifecycle.prepare", %{}, opts), do: lifecycle_prepare(opts)
  defp route_known("lifecycle.commit", params, opts), do: lifecycle_release(:commit, params, opts)
  defp route_known("lifecycle.cancel", params, opts), do: lifecycle_release(:cancel, params, opts)
  defp route_known("doctor.start", params, opts), do: doctor_start(params, opts)
  defp route_known("doctor.get", params, opts), do: doctor_session(:get, params, opts)
  defp route_known("doctor.cancel", params, opts), do: doctor_session(:cancel, params, opts)
  defp route_known("logs.query", params, opts), do: logs_query(params, opts)
  defp route_known("setup.state.get", %{}, opts), do: setup_state(opts)
  defp route_known("settings.sections", %{}, opts), do: settings_sections(opts)
  defp route_known("settings.get", params, opts), do: settings_get(params, opts)
  defp route_known("settings.apply", params, opts), do: settings_apply(params, opts)
  defp route_known("settings.reload", %{}, opts), do: settings_reload(opts)
  defp route_known("secret.set", params, opts), do: secret_set(params, opts)
  defp route_known("secret.clear", params, opts), do: secret_clear(params, opts)
  defp route_known("setup.detect", params, opts), do: setup_detect(params, opts)
  defp route_known("providers.set_primary", params, opts), do: providers_primary(params, opts)
  defp route_known("providers.models.list", params, opts), do: providers_models(params, opts)
  defp route_known("providers.probe.start", params, opts), do: providers_probe(params, opts)
  defp route_known("job.get", params, opts), do: job_action(:get, params, opts)
  defp route_known("job.cancel", params, opts), do: job_action(:cancel, params, opts)
  defp route_known("job.list", %{}, opts), do: job_list(opts)
  defp route_known("auth.start", params, opts), do: auth_start(params, opts)
  defp route_known("auth.import.start", params, opts), do: auth_import(params, opts)
  defp route_known("auth.logout", params, opts), do: auth_logout(params, opts)

  defp route_known("plugins.list", %{}, opts), do: plugins_list(opts)

  defp route_known("plugins.install.start", params, opts),
    do: plugin_by_name(&Plugins.install_start/2, params, opts)

  defp route_known("plugins.check.start", params, opts),
    do: plugin_by_name(&Plugins.check_start/2, params, opts)

  defp route_known("plugins.workspaces.discover.start", params, opts),
    do: plugin_by_name(&Plugins.workspaces_discover_start/2, params, opts)

  defp route_known("plugins.workspace.select.start", params, opts),
    do: plugin_workspace_select(params, opts)

  defp route_known("plugins.enable", params, opts),
    do: plugin_by_name(&Plugins.enable/2, params, opts)

  defp route_known("plugins.disable", params, opts),
    do: plugin_by_name(&Plugins.disable/2, params, opts)

  defp route_known("plugins.disconnect", params, opts),
    do: plugin_by_name(&Plugins.disconnect/2, params, opts)

  defp route_known("plugins.oauth_client.set", params, opts),
    do: plugin_oauth_client(params, opts)

  defp route_known("plugins.setting.set", params, opts), do: plugin_setting(params, opts)

  defp route_known("capabilities.install.start", params, opts),
    do: capability_install(params, opts)

  defp route_known("meetings.signin.start", %{}, opts), do: meetings_signin(opts)
  defp route_known("computer_use.grant.start", %{}, opts), do: computer_use_grant(opts)
  defp route_known("computer_use.permissions.get", %{}, opts), do: computer_use_permissions(opts)
  defp route_known("mobile.status", %{}, opts), do: mobile(&Mobile.status/1, opts)
  defp route_known("mobile.pair.start", %{}, opts), do: mobile(&Mobile.pair_start/1, opts)
  defp route_known("mobile.pair.get", params, opts), do: mobile_session(:get, params, opts)
  defp route_known("mobile.pair.decide", params, opts), do: mobile_decide(params, opts)
  defp route_known("mobile.pair.cancel", params, opts), do: mobile_session(:cancel, params, opts)
  defp route_known("mobile.devices.list", %{}, opts), do: mobile(&Mobile.devices_list/1, opts)
  defp route_known("mobile.devices.revoke", params, opts), do: mobile_revoke(params, opts)
  defp route_known("browser.install.start", %{}, opts), do: browser_install(opts)

  defp route_known("imessage.permissions.get", %{}, opts),
    do: operation_result(IMessage.permissions(operation_opts(opts)))

  defp route_known("imessage.grant.start", params, opts), do: imessage_grant(params, opts)

  defp route_known("imessage.policy.confirm", %{}, opts),
    do: operation_result(IMessage.policy_confirm(operation_opts(opts)))

  defp route_known("mcp.servers.list", %{}, opts),
    do: operation_result(McpServers.list(operation_opts(opts)))

  defp route_known("mcp.servers.get", params, opts),
    do: mcp_by_name(&McpServers.get/2, params, opts)

  defp route_known("mcp.servers.draft", params, opts), do: mcp_draft(params, opts)

  defp route_known("mcp.servers.add", params, opts),
    do: mcp_server(&McpServers.add/2, params, @mcp_add_params, opts)

  defp route_known("mcp.servers.update", params, opts),
    do: mcp_server(&McpServers.update/2, params, @mcp_server_params, opts)

  defp route_known("mcp.servers.remove", params, opts),
    do: mcp_by_name(&McpServers.remove/2, params, opts)

  defp route_known("mcp.servers.enable", params, opts),
    do: mcp_by_name(&McpServers.enable/2, params, opts)

  defp route_known("mcp.servers.disable", params, opts),
    do: mcp_by_name(&McpServers.disable/2, params, opts)

  defp route_known("mcp.servers.tool.set", params, opts), do: mcp_tool_set(params, opts)

  defp route_known("mcp.servers.import.scan", %{}, opts),
    do: operation_result(McpServers.import_scan(operation_opts(opts)))

  defp route_known("mcp.servers.import", params, opts), do: mcp_import(params, opts)

  defp route_known("mcp.servers.check.start", params, opts),
    do: mcp_by_name(&McpServers.check_start/2, params, opts)

  defp route_known("cues." <> _rest = method, params, opts), do: route_cues(method, params, opts)
  # The server's Always On steps answer only a desktop's forward (Always On
  # setup §3.5); everything else of the family is routed as it comes.
  defp route_known("home." <> _rest = method, params, opts) do
    if Placement.rail_only?(method) and not match?({:desktop, _id}, Keyword.get(opts, :actor)),
      do: Placement.rail_only_refusal(method),
      else: route_home(method, params, opts)
  end

  # Answered locally in every role (M75 §14): a device reads its own home.
  # With `after` and `wait_ms` it waits for the summary's key to move
  # (Always On setup §3.3), held in this request's own process.
  defp route_home("home.status", params, opts) do
    with :ok <- reject_unknown_params(params, @home_status_params),
         {:ok, wait} <- status_wait(params) do
      case wait do
        :now -> operation_result(Home.status(home_opts(opts)))
        {key, ms} -> operation_result(Home.status_after(key, ms, home_opts(opts)))
      end
    end
  end

  defp route_home("home.snapshots.status", %{}, opts),
    do: operation_result(Home.snapshots_status(home_opts(opts)))

  defp route_home("home.snapshots.run", %{}, opts),
    do: operation_result(Home.snapshots_run(home_opts(opts)))

  defp route_home("home.snapshots.passphrase", params, opts) do
    with :ok <- reject_unknown_params(params, @home_passphrase_params) do
      operation_result(
        Home.snapshots_passphrase(Map.get(params, "recovery_passphrase"), home_opts(opts))
      )
    end
  end

  # `kind` `provisioned`, from the desktop replacing this server: the 24-hour
  # code it puts inside the new one.
  defp route_home("home.enroll.open", params, opts) do
    with :ok <- reject_unknown_params(params, @home_enroll_params) do
      operation_result(HomeMove.enroll_open(Map.get(params, "kind"), home_opts(opts)))
    end
  end

  defp route_home("home.enroll.withdraw", %{}, opts),
    do: operation_result(HomeMove.enroll_withdraw(home_opts(opts)))

  defp route_home("home.candidates.list", %{}, opts),
    do: operation_result(HomeMove.candidates_list(home_opts(opts)))

  defp route_home("home.move.readiness", params, opts) do
    with :ok <- reject_unknown_params(params, @home_readiness_params) do
      operation_result(HomeMove.move_readiness(Map.get(params, "candidate_id"), home_opts(opts)))
    end
  end

  # `keep_as_desktop` (default true): false when the source is a server being
  # replaced, which then becomes no desktop of the new primary (M75).
  defp route_home("home.move.start", params, opts) do
    with :ok <- reject_unknown_params(params, @home_move_params),
         {:ok, keep?} <- keep_as_desktop(params) do
      operation_result(
        HomeMove.move_start(
          Map.get(params, "candidate_id"),
          Map.get(params, "recovery_passphrase"),
          Keyword.put(home_opts(opts), :keep_as_desktop, keep?)
        )
      )
    end
  end

  # The Always On provisioner's offers (M75 lean v1 §4.3): device-class,
  # answered on the computer that creates the server, for the provider in
  # use, which the call need not name.
  defp route_home("home.provision.options", %{}, opts),
    do: operation_result(Provision.options(provision_opts(opts)))

  # Every Always On step (Always On setup §3.4): `input` is decoded here into
  # `AlwaysOn.Input`, which withholds its token and recovery passphrase from
  # any log, and the raw map goes no further.
  defp route_home("home.act", params, opts) do
    with :ok <- reject_unknown_params(params, @home_act_params) do
      case AlwaysOn.decode(params) do
        {:ok, request} -> AlwaysOn.act(request, always_on_opts(opts))
        {:error, _invalid} = refused -> operation_result(refused)
      end
    end
  end

  defp status_wait(params) when map_size(params) == 0, do: {:ok, :now}

  defp status_wait(params) do
    with {:ok, key} <- status_key(Map.get(params, "after")),
         {:ok, ms} <- wait_ms(Map.get(params, "wait_ms")),
         do: {:ok, {key, ms}}
  end

  defp status_key(key)
       when is_binary(key) and byte_size(key) > 0 and byte_size(key) <= @max_status_key_bytes,
       do: {:ok, key}

  defp status_key(_key), do: invalid_params("after")

  defp wait_ms(ms) when is_integer(ms) and ms >= 0 do
    if ms <= Home.max_wait_ms(), do: {:ok, ms}, else: invalid_params("wait_ms")
  end

  defp wait_ms(_ms), do: invalid_params("wait_ms")

  defp keep_as_desktop(params) do
    case Map.get(params, "keep_as_desktop", true) do
      keep? when is_boolean(keep?) -> {:ok, keep?}
      _other -> invalid_params("keep_as_desktop")
    end
  end

  defp route_cues("cues.status", %{}, opts), do: operation_result(Cues.status(cues_opts(opts)))

  defp route_cues("cues.sources.list", %{}, opts),
    do: operation_result(Cues.sources_list(cues_opts(opts)))

  defp route_cues("cues.sources.get", params, opts),
    do: cue_by_ref(&Cues.sources_get/2, params, opts)

  defp route_cues("cues.sources.form", params, opts), do: cue_form(params, opts)
  defp route_cues("cues.sources.add", params, opts), do: cue_add(params, opts)
  defp route_cues("cues.sources.update", params, opts), do: cue_update(params, opts)

  defp route_cues("cues.sources.remove", params, opts),
    do: cue_by_ref(&Cues.sources_remove/2, params, opts)

  defp route_cues("cues.sources.enable", params, opts),
    do: cue_by_ref(&Cues.sources_switch(&1, true, &2), params, opts)

  defp route_cues("cues.sources.disable", params, opts),
    do: cue_by_ref(&Cues.sources_switch(&1, false, &2), params, opts)

  defp route_cues("cues.sources.token.new", params, opts),
    do: cue_by_ref(&Cues.sources_token_new/2, params, opts)

  defp route_cues("cues.sources.url.get", params, opts),
    do: cue_by_ref(&Cues.sources_url_get/2, params, opts)

  defp route_cues("cues.watchers.list", %{}, opts),
    do: operation_result(Cues.watchers_list(cues_opts(opts)))

  defp route_cues("cues.watchers.get", params, opts),
    do: cue_by_name(&Cues.watchers_get/2, params, opts)

  defp route_cues("cues.watchers.always_allow.revoke", params, opts),
    do: cue_by_name(&Cues.watchers_always_allow_revoke/2, params, opts)

  defp route_cues("cues.mandates.list", %{}, opts),
    do: operation_result(Cues.mandates_list(cues_opts(opts)))

  defp route_cues("cues.mandates.choices", %{}, opts),
    do: operation_result(Cues.mandates_choices(cues_opts(opts)))

  defp route_cues("cues.mandates.add", params, opts),
    do: cue_mandate(&Cues.mandates_add/3, params, opts)

  defp route_cues("cues.mandates.update", params, opts),
    do: cue_mandate(&Cues.mandates_update/3, params, opts)

  defp route_cues("cues.mandates.remove", params, opts),
    do: cue_by_name(&Cues.mandates_remove/2, params, opts)

  defp route_cues("cues.mandates.enable", params, opts),
    do: cue_by_name(&Cues.mandates_switch(&1, true, &2), params, opts)

  defp route_cues("cues.mandates.disable", params, opts),
    do: cue_by_name(&Cues.mandates_switch(&1, false, &2), params, opts)

  defp route_cues("cues.mandates.approve", params, opts),
    do: cue_by_name(&Cues.mandates_approve/2, params, opts)

  defp route_cues("cues.proposals.list", params, opts), do: cue_proposals(params, opts)

  defp route_cues("cues.proposals.get", params, opts) do
    with {:ok, id} <- fetch_string(params, "proposal_id", @cue_proposal_params) do
      operation_result(Cues.proposals_get(id, cues_opts(opts)))
    end
  end

  defp route_cues("cues.proposals.decide", params, opts), do: cue_decide(params, opts)

  defp setup_detect(params, opts) do
    with :ok <- reject_unknown_params(params, @detect_params),
         {:ok, targets} <- fetch_targets(params) do
      {:ok, Detect.run(targets, operation_opts(opts))}
    end
  end

  defp providers_primary(params, opts) do
    with {:ok, provider} <- fetch_string(params, "provider", @provider_params) do
      operation_result(Providers.set_primary(provider, operation_opts(opts)))
    end
  end

  defp providers_models(params, opts) do
    with :ok <- reject_unknown_params(params, @models_params) do
      operation_result(Providers.models(params, operation_opts(opts)))
    end
  end

  defp providers_probe(params, opts) do
    with {:ok, provider} <- fetch_string(params, "provider", @provider_params) do
      operation_result(Providers.probe_start(provider, operation_opts(opts)))
    end
  end

  defp job_action(action, params, opts) do
    with {:ok, job_id} <- fetch_string(params, "job_id", @job_id_params) do
      apply_job_action(action, job_id, jobs_opts(opts))
    end
  end

  defp apply_job_action(action, job_id, jobs_opts) do
    result =
      case action do
        :get -> Jobs.get(job_id, jobs_opts)
        :cancel -> Jobs.cancel(job_id, jobs_opts)
      end

    case result do
      {:ok, view} -> {:ok, view}
      {:error, :unknown_job} -> {:error, :unknown_job, %{"job_id" => job_id}}
    end
  end

  defp job_list(opts) do
    {:ok, jobs} = Jobs.list(jobs_opts(opts))

    {:ok, %{"jobs" => jobs}}
  end

  # A sign-in started by a desktop over the rail (`:actor`, M75 D17) is
  # recorded as that desktop's, so its loopback reply is forwarded there.
  defp auth_start(params, opts) do
    with {:ok, provider} <- fetch_string(params, "provider", @provider_params) do
      operation_result(Auth.start(provider, with_actor(operation_opts(opts), opts)))
    end
  end

  defp with_actor(operation_opts, opts) do
    case Keyword.fetch(opts, :actor) do
      {:ok, actor} -> Keyword.put(operation_opts, :actor, actor)
      :error -> operation_opts
    end
  end

  defp auth_import(params, opts) do
    with {:ok, source} <- fetch_string(params, "source", @import_params) do
      operation_result(Auth.import_start(source, operation_opts(opts)))
    end
  end

  defp auth_logout(params, opts) do
    with {:ok, provider} <- fetch_string(params, "provider", @provider_params) do
      operation_result(Auth.logout(provider, operation_opts(opts)))
    end
  end

  defp capability_install(params, opts) do
    with {:ok, target} <- fetch_string(params, "target", @capability_params) do
      operation_result(Capabilities.install_start(target, operation_opts(opts)))
    end
  end

  defp plugins_list(opts) do
    reader = Keyword.get(opts, :plugins_reader, &Plugins.list/1)

    operation_result(reader.(operation_opts(opts)))
  end

  # Six methods take one plugin name and nothing else, so the parameter check is
  # written once and the method chooses only which verb runs.
  defp plugin_by_name(verb, params, opts) when is_function(verb, 2) do
    with {:ok, name} <- fetch_string(params, "name", @plugin_name_params) do
      operation_result(verb.(name, operation_opts(opts)))
    end
  end

  defp plugin_workspace_select(params, opts) do
    with :ok <- reject_unknown_params(params, @workspace_select_params),
         {:ok, name} <- fetch_text(params, "name", 1),
         {:ok, profile} <- fetch_text(params, "profile", 1),
         {:ok, workspace_id} <- fetch_text(params, "workspace_id", 1),
         {:ok, label} <- fetch_text(params, "label", 0) do
      selection = %{"profile" => profile, "workspace_id" => workspace_id, "label" => label}

      operation_result(Plugins.workspace_select_start(name, selection, operation_opts(opts)))
    end
  end

  defp plugin_oauth_client(params, opts) do
    with :ok <- reject_unknown_params(params, @oauth_client_params),
         {:ok, provider} <- fetch_text(params, "provider", 1),
         {:ok, client_id} <- fetch_text(params, "client_id", 1),
         {:ok, port} <- fetch_redirect_port(params),
         {:ok, region} <- fetch_region(params) do
      operation_result(
        Plugins.oauth_client_set(provider, client_id, port, region, operation_opts(opts))
      )
    end
  end

  defp plugin_setting(params, opts) do
    with :ok <- reject_unknown_params(params, @plugin_setting_params),
         {:ok, name} <- fetch_text(params, "name", 1),
         {:ok, key} <- fetch_text(params, "key", 1) do
      value = Map.get(params, "value")

      operation_result(Plugins.setting_set(name, key, value, operation_opts(opts)))
    end
  end

  # An absent redirect port is the daemon's own default rather than a refusal:
  # the operator leaving the field blank is what asks for it.
  defp fetch_redirect_port(params) do
    case Map.get(params, "redirect_port") do
      nil -> {:ok, nil}
      port when is_integer(port) and port >= 1 and port <= 65_535 -> {:ok, port}
      _invalid -> invalid_params("redirect_port")
    end
  end

  # An absent region reaches the operation rather than being refused here: only
  # it knows whether the provider publishes any to choose from, and a client
  # older than this field sends none at all. A present one is a published id, so
  # it is bounded like one rather than by the generic text ceiling.
  defp fetch_region(params) do
    case Map.get(params, "region") do
      nil ->
        {:ok, nil}

      value when is_binary(value) and byte_size(value) >= 2 and byte_size(value) <= 8 ->
        {:ok, value}

      _invalid ->
        invalid_params("region")
    end
  end

  defp fetch_text(params, field, minimum) do
    case Map.get(params, field) do
      value
      when is_binary(value) and byte_size(value) >= minimum and
             byte_size(value) <= @max_text_bytes ->
        {:ok, value}

      _invalid ->
        invalid_params(field)
    end
  end

  defp meetings_signin(opts), do: operation_result(Meetings.signin_start(operation_opts(opts)))

  defp browser_install(opts),
    do: operation_result(Capabilities.browser_install_start(operation_opts(opts)))

  defp computer_use_grant(opts),
    do: operation_result(ComputerUse.grant_start(operation_opts(opts)))

  defp computer_use_permissions(opts),
    do: operation_result(ComputerUse.permissions(operation_opts(opts)))

  defp imessage_grant(params, opts) do
    with {:ok, service} <- fetch_string(params, "service", @imessage_grant_params) do
      operation_result(IMessage.grant_start(service, operation_opts(opts)))
    end
  end

  defp mobile(verb, opts) when is_function(verb, 1),
    do: operation_result(verb.(mobile_opts(opts)))

  defp mobile_session(action, params, opts) do
    with {:ok, session_id} <- fetch_string(params, "session_id", @mobile_session_params) do
      result =
        case action do
          :get -> Mobile.pair_get(session_id, mobile_opts(opts))
          :cancel -> Mobile.pair_cancel(session_id, mobile_opts(opts))
        end

      operation_result(result)
    end
  end

  defp mobile_decide(params, opts) do
    with {:ok, session_id} <- fetch_string(params, "session_id", @mobile_decide_params),
         {:ok, approved} <- fetch_boolean(params, "approved") do
      operation_result(Mobile.pair_decide(session_id, approved, mobile_opts(opts)))
    end
  end

  defp mobile_revoke(params, opts) do
    with {:ok, device_id} <- fetch_string(params, "device_id", @mobile_device_params) do
      operation_result(Mobile.devices_revoke(device_id, mobile_opts(opts)))
    end
  end

  # Five methods take one server name and nothing else, so the parameter check
  # is written once and the method chooses only which verb runs.
  defp mcp_by_name(verb, params, opts) when is_function(verb, 2) do
    with {:ok, name} <- fetch_string(params, "name", @mcp_name_params) do
      operation_result(verb.(name, operation_opts(opts)))
    end
  end

  # A server's fields are typed by the operation, which names the field a form
  # marks in its refusal; this only closes the set. Only an add takes a
  # `draft_id`.
  defp mcp_server(verb, params, allowed, opts) when is_function(verb, 2) do
    with :ok <- reject_unknown_params(params, allowed) do
      operation_result(verb.(params, operation_opts(opts)))
    end
  end

  # The text's length and what it says are the translator's to refuse, with a
  # sentence the form shows under the field.
  defp mcp_draft(params, opts) do
    with :ok <- reject_unknown_params(params, @mcp_draft_params) do
      case Map.get(params, "text") do
        text when is_binary(text) ->
          operation_result(McpServers.draft(text, operation_opts(opts)))

        _invalid ->
          invalid_params("text")
      end
    end
  end

  # Each entry is typed by the operation, which refuses the list with the
  # sentence a client shows.
  defp mcp_import(params, opts) do
    with :ok <- reject_unknown_params(params, @mcp_import_params) do
      operation_result(
        McpServers.import_servers(Map.get(params, "servers"), operation_opts(opts))
      )
    end
  end

  defp mcp_tool_set(params, opts) do
    with :ok <- reject_unknown_params(params, @mcp_tool_params),
         {:ok, name} <- fetch_text(params, "name", 1),
         {:ok, tool} <- fetch_text(params, "tool", 1),
         {:ok, enabled} <- fetch_boolean(params, "enabled") do
      operation_result(McpServers.tool_set(name, tool, enabled, operation_opts(opts)))
    end
  end

  # Every source verb but add, update and the form takes one ref and nothing
  # else, so the parameter check is written once.
  defp cue_by_ref(verb, params, opts) when is_function(verb, 2) do
    with {:ok, ref} <- fetch_string(params, "ref", @cue_ref_params) do
      operation_result(verb.(ref, cues_opts(opts)))
    end
  end

  defp cue_by_name(verb, params, opts) when is_function(verb, 2) do
    with {:ok, name} <- fetch_string(params, "name", @cue_name_params) do
      operation_result(verb.(name, cues_opts(opts)))
    end
  end

  # The three choices are each optional; one that is present is a name.
  defp cue_form(params, opts) do
    with :ok <- reject_unknown_params(params, @cue_form_params),
         {:ok, kind} <- fetch_optional_text(params, "kind"),
         {:ok, preset} <- fetch_optional_text(params, "preset"),
         {:ok, verify} <- fetch_optional_text(params, "verify") do
      operation_result(Cues.sources_form(kind, preset, verify, cues_opts(opts)))
    end
  end

  # A value's type is the form's to refuse, under the field it names; this
  # closes the set and checks only that `values` is an object. The name is
  # optional: absent or empty, Fermix makes one.
  defp cue_add(params, opts) do
    with :ok <- reject_unknown_params(params, @cue_add_params),
         {:ok, ref} <- fetch_optional_name(params, "ref"),
         {:ok, kind} <- fetch_optional_text(params, "kind"),
         {:ok, preset} <- fetch_optional_text(params, "preset"),
         :ok <- kind_or_preset(kind, preset),
         {:ok, values} <- fetch_values(params) do
      operation_result(Cues.sources_add(ref, kind, preset, values, cues_opts(opts)))
    end
  end

  defp cue_update(params, opts) do
    with :ok <- reject_unknown_params(params, @cue_update_params),
         {:ok, ref} <- fetch_text(params, "ref", 1),
         {:ok, values} <- fetch_values(params) do
      operation_result(Cues.sources_update(ref, values, cues_opts(opts)))
    end
  end

  defp cue_mandate(verb, params, opts) when is_function(verb, 3) do
    with :ok <- reject_unknown_params(params, @cue_mandate_params),
         {:ok, name} <- fetch_text(params, "name", 1),
         {:ok, values} <- fetch_values(params) do
      operation_result(verb.(name, values, cues_opts(opts)))
    end
  end

  defp cue_proposals(params, opts) do
    with :ok <- reject_unknown_params(params, @cue_list_params),
         {:ok, state} <- fetch_choice(params, "state", @cue_proposal_states, "waiting") do
      operation_result(Cues.proposals_list(state, cues_opts(opts)))
    end
  end

  defp cue_decide(params, opts) do
    with :ok <- reject_unknown_params(params, @cue_decide_params),
         {:ok, id} <- fetch_text(params, "proposal_id", 1),
         {:ok, decision} <- fetch_choice(params, "decision", @cue_decisions, nil) do
      operation_result(Cues.proposals_decide(id, decision, cues_opts(opts)))
    end
  end

  defp kind_or_preset(nil, nil), do: invalid_params("kind")
  defp kind_or_preset(_kind, _preset), do: :ok

  defp fetch_optional_text(params, field) do
    case Map.get(params, field) do
      nil -> {:ok, nil}
      _present -> fetch_text(params, field, 1)
    end
  end

  defp fetch_optional_name(params, field) do
    case Map.get(params, field) do
      nil -> {:ok, nil}
      _present -> fetch_text(params, field, 0)
    end
  end

  # A closed word, or its default where the field is absent and one exists.
  defp fetch_choice(params, field, choices, default) do
    case Map.get(params, field, default) do
      value when is_map_key(choices, value) -> {:ok, Map.fetch!(choices, value)}
      _invalid -> invalid_params(field)
    end
  end

  defp fetch_boolean(params, field) do
    case Map.get(params, field) do
      value when is_boolean(value) -> {:ok, value}
      _invalid -> invalid_params(field)
    end
  end

  defp fetch_targets(params) do
    targets = Map.get(params, "targets")

    if is_list(targets) and length(targets) <= @max_detect_targets and
         Enum.all?(targets, &Detect.target?/1) do
      {:ok, targets}
    else
      invalid_params("targets")
    end
  end

  # Every operation module answers with the same tagged refusals, so the seam
  # that carries their dependencies is one keyword list rather than one option
  # per operation.
  defp operation_opts(opts), do: Keyword.get(opts, :operation_opts, [])
  defp jobs_opts(opts), do: opts |> operation_opts() |> Keyword.get(:jobs, [])
  defp mobile_opts(opts), do: opts |> operation_opts() |> Keyword.get(:mobile, [])
  defp cues_opts(opts), do: opts |> operation_opts() |> Keyword.get(:cues, [])

  # The router's own `:engine_role` (tests) reaches the provisioner as its
  # seam.
  defp provision_opts(opts) do
    provision = opts |> operation_opts() |> Keyword.get(:provision, [])

    case Keyword.fetch(opts, :engine_role) do
      {:ok, role} -> Keyword.put_new(provision, :engine_role, role)
      :error -> provision
    end
  end

  # An act reaches every family it steps through with one set of seams, the
  # router's own `:engine_role` (tests), a linked desktop's way to its server
  # (`:primary_forward`, from the daemon) and who asked (`:actor`).
  defp always_on_opts(opts) do
    always_on =
      opts
      |> operation_opts()
      |> Keyword.get(:always_on, [])
      |> Keyword.merge(Keyword.take(opts, [:actor, :primary_forward]))

    case Keyword.fetch(opts, :engine_role) do
      {:ok, role} -> Keyword.put_new(always_on, :engine_role, role)
      :error -> always_on
    end
  end

  # The router's own `:engine_role` (tests) reaches the family as its seam, a
  # linked device's way to its primary (`:primary_forward`, from the daemon)
  # lets `home.status` add the primary's own, and the actor says whether a
  # desktop forwarded the request.
  defp home_opts(opts) do
    home =
      opts
      |> operation_opts()
      |> Keyword.get(:home, [])
      |> Keyword.merge(Keyword.take(opts, [:actor]))

    home =
      case Keyword.fetch(opts, :engine_role) do
        {:ok, role} -> Keyword.put_new(home, :engine_role, role)
        :error -> home
      end

    case Keyword.fetch(opts, :primary_forward) do
      {:ok, forward} -> Keyword.put(home, :primary_forward, forward)
      :error -> home
    end
  end

  # Composed on a linked device (M75): this machine's own sections, which
  # configure it alone, and the primary's others, asked within the composed
  # deadline; while the primary's part is missing, `primary_missing` says why.
  # Every other engine lists its own and nothing is missing.
  defp settings_sections(opts) do
    inventory =
      Keyword.get(opts, :settings_sections, fn -> Settings.sections(settings_opts(opts)) end)

    sections = Enum.map(inventory.(), &section_row/1)

    case Keyword.fetch(opts, :primary_forward) do
      {:ok, forward} -> composed_sections(sections, forward)
      :error -> {:ok, %{"sections" => sections, "primary_missing" => nil}}
    end
  end

  defp section_row(section),
    do: %{"id" => section.id, "pane" => section.pane, "title" => section.title}

  defp composed_sections(sections, forward) do
    own = Enum.filter(sections, &(&1["id"] in Placement.device_sections()))

    case Placement.primary_part(forward, "settings.sections") do
      {:ok, %{"sections" => primary}} when is_list(primary) ->
        theirs = Enum.reject(primary, &(&1["id"] in Placement.device_sections()))
        {:ok, %{"sections" => theirs ++ own, "primary_missing" => nil}}

      {:ok, _malformed} ->
        {:ok, %{"sections" => own, "primary_missing" => @primary_sections_unread}}

      {missing, sentence} when missing in [:missing, :too_old] ->
        {:ok, %{"sections" => own, "primary_missing" => sentence}}
    end
  end

  defp settings_get(params, opts) do
    reader = Keyword.get(opts, :settings_reader, &Settings.get/2)

    with {:ok, section} <- fetch_section(params, @settings_get_params) do
      case reader.(section, settings_opts(opts)) do
        {:ok, view} -> {:ok, view}
        {:error, {:unknown_section, _section}} -> invalid_params("section")
      end
    end
  end

  defp settings_apply(params, opts) do
    writer = Keyword.get(opts, :settings_writer, &Settings.apply/3)

    with :ok <- reject_unknown_params(params, @settings_apply_params),
         {:ok, section} <- fetch_section(params, @settings_apply_params),
         {:ok, values} <- fetch_values(params) do
      operation_result(writer.(section, values, settings_opts(opts)))
    end
  end

  defp settings_reload(opts) do
    reloader = Keyword.get(opts, :settings_reloader, &Settings.reload/1)

    operation_result(reloader.(settings_opts(opts)))
  end

  defp secret_set(params, opts) do
    writer = Keyword.get(opts, :secret_writer, &Secrets.set/2)

    with :ok <- reject_unknown_params(params, @secret_set_params),
         {:ok, id} <- fetch_string(params, "id", @secret_set_params),
         {:ok, value} <- fetch_secret_value(params) do
      operation_result(writer.(id, value))
    end
  end

  defp secret_clear(params, opts) do
    writer = Keyword.get(opts, :secret_clearer, &Secrets.clear/1)

    with {:ok, id} <- fetch_string(params, "id", @secret_clear_params) do
      operation_result(writer.(id))
    end
  end

  # One place every operation refusal becomes a public error, so two families
  # answer the same code for the same cause. A refusal that carries an operator
  # sentence rides `invalid_params`; a capability that could not answer names
  # itself and logs its reason at the operation.
  defp operation_result({:ok, view}), do: {:ok, view}

  defp operation_result({:error, {:busy, operation}}),
    do: {:error, :busy, %{"operation" => operation}}

  defp operation_result({:error, {:unavailable, capability}}),
    do: {:error, :unavailable, %{"capability" => capability}}

  defp operation_result({:error, {:unavailable, capability, sentence}}),
    do: {:error, :unavailable, %{"capability" => capability, "sentence" => sentence}}

  defp operation_result({:error, {:invalid_params, field, sentence}}),
    do: {:error, :invalid_params, %{"field" => field, "sentence" => sentence}}

  defp operation_result({:error, {:unknown_section, _section}}), do: invalid_params("section")

  defp operation_result({:error, {:external_change, sections}}),
    do: {:error, :external_change, %{"section" => List.first(sections) || "settings"}}

  defp operation_result({:error, {:config_unreadable, sentence}}),
    do: {:error, :config_unreadable, %{"sentence" => sentence}}

  defp operation_result({:error, {:secret_store_failed, id, reason}}),
    do: {:error, :secret_store_failed, %{"id" => id, "reason" => reason}}

  defp operation_result({:error, {:unknown_pairing_session, session_id}}),
    do: {:error, :unknown_pairing_session, %{"session_id" => session_id}}

  defp fetch_section(params, allowed) do
    with :ok <- reject_unknown_params(params, allowed) do
      case Map.get(params, "section") do
        value
        when is_binary(value) and byte_size(value) > 0 and
               byte_size(value) <= @max_section_bytes ->
          {:ok, value}

        _invalid ->
          invalid_params("section")
      end
    end
  end

  defp fetch_values(params) do
    case Map.get(params, "values") do
      values when is_map(values) -> {:ok, values}
      _invalid -> invalid_params("values")
    end
  end

  # The one method whose params may carry a secret. The value is never logged,
  # never traced and never echoed back; only its size is checked here.
  defp fetch_secret_value(params) do
    case Map.get(params, "value") do
      value when is_binary(value) -> {:ok, value}
      _invalid -> invalid_params("value")
    end
  end

  defp settings_opts(opts),
    do: Keyword.take(opts, [:snapshot, :supervised, :macos?])

  defp invalid_params(field), do: {:error, :invalid_params, %{"field" => field}}

  defp hello(opts) do
    identity_provider = Keyword.get(opts, :identity_provider, &engine_identity/0)
    endpoint_opts = Keyword.get(opts, :endpoint_opts, [])

    with {:ok, identity} <- identity_provider.(),
         :ok <- validate_identity(identity),
         {:ok, setup} <- Endpoint.describe(endpoint_opts) do
      {minimum, maximum} = Protocol.supported_version_range()

      {:ok,
       %{
         "protocol" => %{
           "current_version" => Protocol.protocol_version(),
           "minimum_version" => minimum,
           "maximum_version" => maximum
         },
         "capabilities" => %{
           "methods" => Protocol.methods(),
           "minimum_versions" => Protocol.method_minimum_versions()
         },
         "engine" => identity,
         "setup" => setup
       }}
    else
      {:error, {:invalid_port, _source, _value}} -> unavailable("setup_endpoint")
      {:error, _reason} -> unavailable("engine_identity")
    end
  end

  defp setup_state(opts) do
    reporter = Keyword.get(opts, :setup_state_reporter, &SetupState.report/1)

    case reporter.(Keyword.get(opts, :setup_state_opts, [])) do
      report when is_map(report) -> {:ok, report}
      _invalid -> unavailable("setup_state")
    end
  end

  defp overview(opts) do
    health_reporter = Keyword.get(opts, :health_reporter, &Health.report/0)
    health = health_reporter.()
    overview_provider = overview_provider(opts)

    with true <- is_map(health),
         {:ok, snapshot} when is_map(snapshot) <- overview_provider.(health) do
      {:ok, project_overview(snapshot, health)}
    else
      _failure -> unavailable("overview")
    end
  end

  defp setup_session(opts) do
    endpoint_opts = Keyword.get(opts, :endpoint_opts, [])
    launch_token_provider = Keyword.get(opts, :launch_token_provider, launch_token_provider(opts))

    with {:ok, port} <- Endpoint.port(endpoint_opts),
         {:ok, launch} <- launch_token_provider.(),
         {:ok, token, expires_at_ms} <- validate_launch(launch),
         {:ok, url} <- Endpoint.launch_url(port, token) do
      {:ok, %{"url" => url, "expires_at_ms" => expires_at_ms}}
    else
      _failure -> unavailable("setup_session")
    end
  end

  defp diagnostics(opts) do
    builder = Keyword.get(opts, :diagnostics_builder, &Diagnostics.build/1)

    case builder.(Keyword.get(opts, :diagnostics_opts, [])) do
      {:ok, report} -> {:ok, report}
      {:error, _reason} -> unavailable("diagnostics")
    end
  end

  defp lifecycle_prepare(opts) do
    case Lifecycle.prepare(lifecycle_opts(opts)) do
      {:ok, %{lease_id: lease_id, ttl_ms: ttl_ms}} ->
        {:ok, %{"lease_id" => lease_id, "ttl_ms" => ttl_ms}}

      {:error, :busy} ->
        {:error, :busy, %{"operation" => "lifecycle"}}
    end
  end

  defp lifecycle_release(action, params, opts) do
    with {:ok, lease_id} <- fetch_string(params, "lease_id", @lease_params) do
      apply_lease(action, lease_id, lifecycle_opts(opts))
    end
  end

  defp apply_lease(action, lease_id, lifecycle_opts) do
    result =
      case action do
        :commit -> Lifecycle.commit(lease_id, lifecycle_opts)
        :cancel -> Lifecycle.cancel(lease_id, lifecycle_opts)
      end

    case result do
      {:ok, %{lease_id: id, status: status}} ->
        {:ok, %{"lease_id" => id, "status" => Atom.to_string(status)}}

      {:error, reason} when reason in [:lease_expired, :unknown_lease] ->
        {:error, reason, %{"lease_id" => lease_id}}
    end
  end

  defp doctor_start(params, opts) do
    with :ok <- reject_unknown_params(params, @doctor_start_params),
         {:ok, scope} <- fetch_scope(params) do
      start_doctor(scope, opts)
    end
  end

  defp start_doctor(scope, opts) do
    case Doctor.start(Keyword.put(doctor_opts(opts), :scope, scope)) do
      {:ok, view} -> {:ok, view}
      {:error, :busy} -> {:error, :busy, %{"operation" => "doctor"}}
      {:error, :invalid_scope} -> {:error, :invalid_params, %{"field" => "scope"}}
    end
  end

  defp doctor_session(action, params, opts) do
    with {:ok, session_id} <- fetch_string(params, "session_id", @doctor_session_params) do
      apply_doctor_session(action, session_id, doctor_opts(opts))
    end
  end

  defp apply_doctor_session(action, session_id, doctor_opts) do
    result =
      case action do
        :get -> Doctor.get(session_id, doctor_opts)
        :cancel -> Doctor.cancel(session_id, doctor_opts)
      end

    case result do
      {:ok, view} -> {:ok, view}
      {:error, :unknown_session} -> {:error, :unknown_session, %{"session_id" => session_id}}
    end
  end

  defp logs_query(params, opts) do
    query = Keyword.get(opts, :logs_query, &Logs.query/2)

    case query.(params, Keyword.get(opts, :logs_opts, [])) do
      {:ok, result} -> {:ok, result}
      {:error, :invalid_params} -> {:error, :invalid_params, %{"method" => "logs.query"}}
      {:error, :cursor_expired} -> {:error, :cursor_expired, %{"method" => "logs.query"}}
      {:error, :unreadable} -> unavailable("logs")
    end
  end

  defp fetch_scope(params) do
    case Map.get(params, "scope", "local") do
      scope when is_map_key(@doctor_scopes, scope) -> {:ok, Map.fetch!(@doctor_scopes, scope)}
      _invalid -> {:error, :invalid_params, %{"field" => "scope"}}
    end
  end

  defp fetch_string(params, field, allowed) do
    with :ok <- reject_unknown_params(params, allowed) do
      case Map.get(params, field) do
        value when is_binary(value) and byte_size(value) > 0 and byte_size(value) <= 256 ->
          {:ok, value}

        _invalid ->
          {:error, :invalid_params, %{"field" => field}}
      end
    end
  end

  defp reject_unknown_params(params, allowed) do
    case Enum.find(Map.keys(params), &(&1 not in allowed)) do
      nil -> :ok
      field -> {:error, :invalid_params, %{"field" => field}}
    end
  end

  defp lifecycle_opts(opts), do: [server: Keyword.get(opts, :lifecycle_server, Lifecycle)]

  defp doctor_opts(opts) do
    [server: Keyword.get(opts, :doctor_server, Doctor)] ++ Keyword.take(opts, [:descriptors])
  end

  defp overview_provider(opts) do
    case Keyword.get(opts, :overview_provider) do
      nil ->
        overview_opts = Keyword.get(opts, :overview_opts, [])
        fn health -> Overview.snapshot(Keyword.put(overview_opts, :health_report, health)) end

      provider ->
        provider
    end
  end

  defp launch_token_provider(opts) do
    token_opts = Keyword.get(opts, :token_opts, [])
    fn -> AccessToken.mint_launch_token(token_opts) end
  end

  defp validate_launch(%{token: token, expires_at_ms: expires_at_ms})
       when is_binary(token) and byte_size(token) > 0 and is_integer(expires_at_ms) and
              expires_at_ms >= 0,
       do: {:ok, token, expires_at_ms}

  defp validate_launch(_launch), do: {:error, :invalid_launch}

  defp validate_identity(identity) when is_map(identity) do
    fields = ~w(
      engine_id product_version build_id source_commit distribution_identity artifact_target
      architecture pid
    )

    valid? =
      Enum.sort(Map.keys(identity)) == Enum.sort(fields) and
        Enum.all?(
          ~w(engine_id product_version distribution_identity architecture pid),
          fn field ->
            public_identity_value?(identity[field])
          end
        ) and
        Enum.all?(~w(build_id source_commit artifact_target), fn field ->
          is_nil(identity[field]) or public_identity_value?(identity[field])
        end)

    if valid?, do: :ok, else: {:error, :invalid_identity}
  end

  defp validate_identity(_identity), do: {:error, :invalid_identity}

  defp public_identity_value?(value) when is_binary(value),
    do: byte_size(value) > 0 and byte_size(value) <= 256

  defp public_identity_value?(_value), do: false

  defp project_overview(snapshot, health) do
    %{
      "generated_at" => public_scalar(value(snapshot, :generated_at)),
      "readiness" => project_readiness(value(snapshot, :readiness, %{})),
      "health" => project_health(health),
      "daemon" => project_daemon(value(snapshot, :daemon, %{})),
      "provider" => project_provider(value(snapshot, :provider, %{})),
      "channels" => project_channels(value(snapshot, :channels, [])),
      "memory" => project_memory(value(snapshot, :memory, %{})),
      "jobs" => project_jobs(value(snapshot, :jobs, %{})),
      "agents" => project_agents(value(snapshot, :agents, %{})),
      "realtime" => project_realtime(value(snapshot, :realtime, %{})),
      "capabilities" => project_capabilities(value(snapshot, :capabilities, %{}))
    }
  end

  defp project_readiness(readiness) do
    failures = value(readiness, :failures, [])

    %{
      "status" => public_scalar(value(readiness, :status, :unknown)),
      "failure_count" => if(is_list(failures), do: length(failures), else: 0)
    }
  end

  defp project_health(health) do
    %{
      "status" => public_scalar(value(health, :status, :unknown)),
      "restart_required" => value(health, :restart_required?, false) == true,
      "restart_reasons" => project_restart_reasons(value(health, :restart_reasons, [])),
      "providers" => project_health_providers(value(health, :providers, []))
    }
  end

  # Section names only. The sentence for each lives in `setup.state.get`, so a
  # surface that shows one reason line and a surface that shows the list read
  # the same words from one place rather than composing their own.
  defp project_restart_reasons(reasons) when is_list(reasons),
    do: reasons |> Enum.map(&public_scalar/1) |> Enum.reject(&is_nil/1)

  defp project_restart_reasons(_reasons), do: []

  defp project_health_providers(providers) when is_list(providers) do
    Enum.map(providers, fn provider ->
      %{
        "name" => public_scalar(value(provider, :name)),
        "status" => public_scalar(value(provider, :status, :unknown)),
        "auth_mode" => public_scalar(value(provider, :auth_mode)),
        "primary" => value(provider, :primary, false) == true
      }
    end)
  end

  defp project_health_providers(_providers), do: []

  defp project_daemon(daemon) do
    %{
      "status" => public_scalar(value(daemon, :status, :unknown)),
      "version" => public_scalar(value(daemon, :version)),
      "uptime_ms" => public_scalar(value(daemon, :uptime_ms)),
      "pid" => public_scalar(value(daemon, :pid))
    }
  end

  defp project_provider(provider) do
    %{
      "active" => public_scalar(value(provider, :active)),
      "model" => public_scalar(value(provider, :model)),
      "auth_mode" => public_scalar(value(provider, :auth_mode)),
      "reasoning_effort" => public_scalar(value(provider, :reasoning_effort))
    }
  end

  defp project_channels(channels) when is_list(channels) do
    Enum.map(channels, fn channel ->
      %{
        "name" => public_scalar(value(channel, :name)),
        "status" => public_scalar(value(channel, :status, :unknown)),
        "enabled" => value(channel, :enabled, false) == true,
        "mode" => public_scalar(value(channel, :mode)),
        "process_alive" => public_scalar(value(channel, :process_alive))
      }
    end)
  end

  defp project_channels(_channels), do: []

  defp project_memory(memory) do
    %{
      "repo" => public_scalar(value(memory, :repo, :unknown)),
      "conversation_store" => public_scalar(value(memory, :conversation_store, :unknown)),
      "store" => public_scalar(value(memory, :store, :unknown))
    }
  end

  defp project_jobs(jobs) do
    %{
      "scheduled" => public_count(value(jobs, :scheduled, 0)),
      "running" => public_count(value(jobs, :running, 0)),
      "paused" => public_count(value(jobs, :paused, 0)),
      "failed_recent" => public_count(value(jobs, :failed_recent, 0)),
      "next" => project_next_job(value(jobs, :next)),
      "status" => public_scalar(value(jobs, :status, :unknown))
    }
  end

  defp project_next_job(nil), do: nil

  defp project_next_job(job) when is_map(job) do
    %{
      "id" => public_scalar(value(job, :id)),
      "name" => public_scalar(value(job, :name)),
      "next_run_at" => public_scalar(value(job, :next_run_at)),
      "state" => public_scalar(value(job, :state))
    }
  end

  defp project_next_job(_job), do: nil

  defp project_agents(agents) do
    main = value(agents, :main, %{})

    %{
      "main" => %{
        "health" => public_scalar(value(main, :health, :unknown)),
        "activity" => public_scalar(value(main, :activity, :unknown)),
        "status" => public_scalar(value(main, :status, :unknown)),
        "active_conversations" => public_count(value(main, :active_conversations, 0)),
        "pending_conversations" => public_count(value(main, :pending_conversations, 0))
      },
      "skill_workers" => public_count(value(agents, :skill_workers, 0)),
      "running_skill_workers" => public_count(value(agents, :running_skill_workers, 0))
    }
  end

  defp project_realtime(realtime) do
    %{
      "enabled" => value(realtime, :enabled, false) == true,
      "status" => public_scalar(value(realtime, :status, :unknown)),
      "provider" => public_scalar(value(realtime, :provider)),
      "engine" => public_scalar(value(realtime, :engine)),
      "model" => public_scalar(value(realtime, :model)),
      "socket_alive" => public_scalar(value(realtime, :socket_alive)),
      "active_sessions" => public_count(value(realtime, :active_sessions, 0)),
      "active_clients" => public_count(value(realtime, :active_clients, 0)),
      "companion_connected" => value(realtime, :companion_connected?, false) == true
    }
  end

  defp project_capabilities(capabilities) do
    %{
      "builtin" => public_count(value(capabilities, :builtin, 0)),
      "skill" => public_count(value(capabilities, :skill, 0)),
      "mcp" => public_count(value(capabilities, :mcp, 0)),
      "total" => public_count(value(capabilities, :total, 0))
    }
  end

  defp value(map, key, default \\ nil) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp public_scalar(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp public_scalar(%Date{} = value), do: Date.to_iso8601(value)

  defp public_scalar(value) when is_atom(value) and value not in [nil, true, false],
    do: Atom.to_string(value)

  defp public_scalar(value) when is_binary(value) or is_number(value) or is_boolean(value),
    do: value

  defp public_scalar(nil), do: nil
  defp public_scalar(_value), do: nil

  defp public_count(value) when is_integer(value) and value >= 0, do: value
  defp public_count(_value), do: 0
  defp public_method(method) when is_binary(method), do: method
  defp public_method(_method), do: "invalid"
  defp unavailable(capability), do: {:error, :unavailable, %{"capability" => capability}}

  # `:engine_role` stands in for the role this boot recorded (tests).
  defp admit(method, params, opts) do
    record = Keyword.get_lazy(opts, :engine_role, &Role.recorded/0)

    with :ok <- candidate_answers(method, record),
         {:ok, capability} <- provider_call(method, params),
         {:error, {:device_role, sentence}} <- Role.admit(record) do
      {:error, :unavailable, %{"capability" => capability, "sentence" => sentence}}
    else
      :no_provider_call -> :ok
      :ok -> :ok
      {:error, :unavailable, _details} = refusal -> refusal
    end
  end

  defp candidate_answers(method, %{role: :candidate}) when method not in @candidate_methods,
    do: {:error, :unavailable, %{"capability" => "candidate", "sentence" => @candidate_sentence}}

  defp candidate_answers(_method, _record), do: :ok

  @doc "The sentence a candidate primary (M75 §2) refuses everything else with."
  @spec candidate_sentence() :: String.t()
  def candidate_sentence, do: @candidate_sentence

  # A catalog listing and the local doctor read only this host. The Anthropic
  # setup token is a sign-in: storing it starts the token, and clearing it
  # signs out (`Management.Secrets`), so it is refused before either.
  defp provider_call("providers.models.list", %{"live" => false}), do: :no_provider_call

  defp provider_call(method, %{"id" => "anthropic_setup_token"})
       when method in ["secret.set", "secret.clear"],
       do: {:ok, "secrets"}

  defp provider_call("doctor.start", %{"scope" => "local"}), do: :no_provider_call

  defp provider_call(method, _params) do
    case Map.fetch(@provider_methods, method) do
      {:ok, capability} -> {:ok, capability}
      :error -> :no_provider_call
    end
  end
end
