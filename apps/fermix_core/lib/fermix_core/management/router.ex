defmodule FermixCore.Management.Router do
  @moduledoc """
  Routes validated management v1 requests to daemon-owned capabilities.

  Every result is an explicit public projection. Internal paths, arbitrary
  failure terms, and Setup token state never cross this boundary.
  """

  alias FermixCore.BuildInfo
  alias FermixCore.Health
  alias FermixCore.Introspection.Overview
  alias FermixCore.Management.Diagnostics
  alias FermixCore.Management.Doctor
  alias FermixCore.Management.Lifecycle
  alias FermixCore.Management.Logs
  alias FermixCore.Management.Protocol
  alias FermixCore.Setup.AccessToken
  alias FermixCore.Setup.Endpoint

  # Operations whose contract is "no input at all". Every other method declares
  # its own parameter set, so an unexpected key is refused rather than ignored.
  @no_param_methods ~w(hello overview.get setup.session.create lifecycle.prepare diagnostics.build)
  @lease_params ~w(lease_id)
  @doctor_session_params ~w(session_id)
  @doctor_start_params ~w(scope)
  @doctor_scopes %{"local" => :local, "network" => :network}

  @type route_result :: Protocol.route_result()

  @doc "Routes one validated v1 management request."
  @spec route(Protocol.request(), keyword()) :: route_result()
  def route(request, opts \\ []) when is_map(request) and is_list(opts) do
    method = Map.get(request, :method)
    params = Map.get(request, :params)

    if method in Protocol.methods() do
      route_known(method, params, opts)
    else
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
         "capabilities" => %{"methods" => Protocol.methods()},
         "engine" => identity,
         "setup" => setup
       }}
    else
      {:error, {:invalid_port, _source, _value}} -> unavailable("setup_endpoint")
      {:error, _reason} -> unavailable("engine_identity")
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
      "providers" => project_health_providers(value(health, :providers, []))
    }
  end

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
