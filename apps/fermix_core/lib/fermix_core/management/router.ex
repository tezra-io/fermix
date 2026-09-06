defmodule FermixCore.Management.Router do
  @moduledoc """
  Routes validated management v1 requests to daemon-owned capabilities.

  Every result is an explicit public projection. Internal paths, arbitrary
  failure terms, and Setup token state never cross this boundary.
  """

  alias FermixCore.BuildInfo
  alias FermixCore.Health
  alias FermixCore.Introspection.Overview
  alias FermixCore.Management.Auth
  alias FermixCore.Management.Capabilities
  alias FermixCore.Management.ComputerUse
  alias FermixCore.Management.Detect
  alias FermixCore.Management.Diagnostics
  alias FermixCore.Management.Doctor
  alias FermixCore.Management.Jobs
  alias FermixCore.Management.Lifecycle
  alias FermixCore.Management.Logs
  alias FermixCore.Management.Meetings
  alias FermixCore.Management.Plugins
  alias FermixCore.Management.Protocol
  alias FermixCore.Management.Providers
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
    computer_use.grant.start computer_use.permissions.get
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
  @oauth_client_params ~w(provider client_id redirect_port)
  @workspace_select_params ~w(name profile workspace_id label)
  # A published name, an opaque workspace id and a display label are all bounded
  # strings; the widest of them is the workspace id's own 256-byte bound.
  @max_text_bytes 256
  # The detection catalog is closed and small, so the ceiling is the catalog
  # rather than a round number: a longer list can only repeat targets.
  @max_detect_targets 5
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
        route_known(method, params, opts)

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

  defp auth_start(params, opts) do
    with {:ok, provider} <- fetch_string(params, "provider", @provider_params) do
      operation_result(Auth.start(provider, operation_opts(opts)))
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
         {:ok, port} <- fetch_redirect_port(params) do
      operation_result(Plugins.oauth_client_set(provider, client_id, port, operation_opts(opts)))
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

  defp computer_use_grant(opts),
    do: operation_result(ComputerUse.grant_start(operation_opts(opts)))

  defp computer_use_permissions(opts),
    do: operation_result(ComputerUse.permissions(operation_opts(opts)))

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

  defp settings_sections(opts) do
    inventory = Keyword.get(opts, :settings_sections, &Settings.sections/0)

    sections =
      Enum.map(inventory.(), fn section ->
        %{"id" => section.id, "pane" => section.pane, "title" => section.title}
      end)

    {:ok, %{"sections" => sections}}
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

  defp operation_result({:error, {:invalid_params, field, sentence}}),
    do: {:error, :invalid_params, %{"field" => field, "sentence" => sentence}}

  defp operation_result({:error, {:unknown_section, _section}}), do: invalid_params("section")

  defp operation_result({:error, {:external_change, sections}}),
    do: {:error, :external_change, %{"section" => List.first(sections) || "settings"}}

  defp operation_result({:error, {:config_unreadable, sentence}}),
    do: {:error, :config_unreadable, %{"sentence" => sentence}}

  defp operation_result({:error, {:secret_store_failed, id, reason}}),
    do: {:error, :secret_store_failed, %{"id" => id, "reason" => reason}}

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

  defp settings_opts(opts), do: Keyword.take(opts, [:snapshot, :supervised])

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
end
