defmodule FermixCore.Management.RouterTest do
  use ExUnit.Case, async: true

  alias FermixCore.BuildInfo
  alias FermixCore.Management.Doctor
  alias FermixCore.Management.Lifecycle
  alias FermixCore.Management.Protocol
  alias FermixCore.Management.Router

  @identity %{
    "engine_id" => "fermix-engine-test",
    "product_version" => "1.2.3",
    "build_id" => "build-456",
    "source_commit" => "abcdef123456",
    "distribution_identity" => "macos_app",
    "artifact_target" => "macos_aarch64",
    "architecture" => "arm64",
    "pid" => "4321"
  }

  test "hello returns protocol, capability, engine, and setup endpoint identity" do
    request = request("hello")

    assert {:ok, result} =
             Router.route(request,
               identity_provider: fn -> {:ok, @identity} end,
               endpoint_opts: [port: 4041]
             )

    assert result == %{
             "protocol" => %{
               "current_version" => 1,
               "minimum_version" => 1,
               "maximum_version" => 1
             },
             "capabilities" => %{"methods" => Protocol.methods()},
             "engine" => @identity,
             "setup" => %{
               "origin" => "http://127.0.0.1:4041",
               "path" => "/setup"
             }
           }
  end

  test "hello defaults to the shared immutable build identity" do
    assert {:ok, result} =
             Router.route(request("hello"), endpoint_opts: [port: 4030])

    expected_engine =
      BuildInfo.public_identity()
      |> Map.put("pid", System.pid())

    assert result["engine"] == expected_engine
  end

  test "hello rejects non-public engine identity values" do
    invalid_identity = Map.put(@identity, "pid", self())

    assert {:error, :unavailable, %{"capability" => "engine_identity"}} =
             Router.route(request("hello"),
               identity_provider: fn -> {:ok, invalid_identity} end,
               endpoint_opts: [port: 4030]
             )
  end

  test "hello reports dependency failures without exposing internal reasons" do
    secret_reason = {:bad_identity, "authorization-token"}

    assert {:error, :unavailable, %{"capability" => "engine_identity"}} =
             Router.route(request("hello"),
               identity_provider: fn -> {:error, secret_reason} end,
               endpoint_opts: [port: 4030]
             )
  end

  test "overview.get returns a stable projection without internal paths or errors" do
    health = %{
      status: :ready,
      restart_required?: false,
      providers: [
        %{name: "openai_codex", status: :ready, auth_mode: :oauth, primary: true}
      ],
      failures: [%{component: "channel:telegram", reason: {:secret, "/Users/private"}}]
    }

    snapshot = %{
      generated_at: ~U[2026-08-19 10:30:00Z],
      readiness: %{status: :ready, failures: health.failures},
      daemon: %{status: :running, version: "1.2.3", uptime_ms: 5_000, pid: "4321"},
      provider: %{
        active: :openai_codex,
        model: "gpt-5.6-sol",
        auth_mode: :oauth,
        reasoning_effort: :high
      },
      channels: [
        %{
          name: "telegram",
          status: :ready,
          enabled: true,
          mode: :polling,
          process_alive: true
        }
      ],
      memory: %{
        database_path: "/Users/private/.fermix/memory.db",
        repo: :ready,
        conversation_store: :ready,
        store: :ready,
        paths: %{skills: "/Users/private/.fermix/workspace/skills"}
      },
      jobs: %{
        scheduled: 1,
        running: 0,
        paused: 0,
        failed_recent: 1,
        next: nil,
        status: :unavailable,
        error: "{:secret, \"authorization-token\"}"
      },
      agents: %{
        main: %{
          health: :online,
          activity: :idle,
          status: :idle,
          active_conversations: 0,
          pending_conversations: 0
        },
        skill_workers: 1,
        running_skill_workers: 0
      },
      realtime: %{
        enabled: true,
        status: :ready,
        provider: :openai,
        model: "gpt-realtime",
        socket_path: "/Users/private/.fermix/realtime.sock",
        socket_alive: true,
        active_sessions: 0,
        active_clients: 1,
        companion_connected?: true
      },
      capabilities: %{builtin: 3, skill: 2, mcp: 1, total: 6},
      paths: %{
        home: "/Users/private/.fermix",
        config: "/Users/private/.fermix/config.toml",
        logs: "/Users/private/.fermix/logs",
        traces: "/Users/private/.fermix/traces"
      }
    }

    assert {:ok, result} =
             Router.route(request("overview.get"),
               health_reporter: fn -> health end,
               overview_provider: fn ^health -> {:ok, snapshot} end
             )

    assert result["generated_at"] == "2026-08-19T10:30:00Z"
    assert result["readiness"] == %{"status" => "ready", "failure_count" => 1}

    assert result["health"]["providers"] == [
             %{
               "name" => "openai_codex",
               "status" => "ready",
               "auth_mode" => "oauth",
               "primary" => true
             }
           ]

    assert result["memory"] == %{
             "repo" => "ready",
             "conversation_store" => "ready",
             "store" => "ready"
           }

    assert result["jobs"] == %{
             "scheduled" => 1,
             "running" => 0,
             "paused" => 0,
             "failed_recent" => 1,
             "next" => nil,
             "status" => "unavailable"
           }

    assert result["realtime"]["socket_alive"] == true
    refute Map.has_key?(result["realtime"], "socket_path")

    encoded = Jason.encode!(result)
    refute encoded =~ "/Users/private"
    refute encoded =~ "authorization-token"
    refute encoded =~ "database_path"
    refute encoded =~ "paths"
    refute encoded =~ "\"reason\":"
    refute encoded =~ "\"error\":"
  end

  test "overview.get maps provider failures to an allowlisted public error" do
    assert {:error, :unavailable, %{"capability" => "overview"}} =
             Router.route(request("overview.get"),
               health_reporter: fn -> %{status: :ready, providers: [], failures: []} end,
               overview_provider: fn _health -> {:error, {:secret, "authorization-token"}} end
             )
  end

  test "setup.session.create returns only the one-use URL and expiration metadata" do
    parent = self()

    assert {:ok, result} =
             Router.route(request("setup.session.create"),
               endpoint_opts: [port: 4041],
               launch_token_provider: fn ->
                 send(parent, :minted)
                 {:ok, %{token: "one/use token", expires_at_ms: 1_800_000}}
               end
             )

    assert_received :minted

    assert result == %{
             "url" => "http://127.0.0.1:4041/setup?t=one%2Fuse+token",
             "expires_at_ms" => 1_800_000
           }

    refute Map.has_key?(result, "token")
    refute Map.has_key?(result, "fingerprint")
    refute Map.has_key?(result, "path")
  end

  test "setup.session.create resolves the endpoint before minting a token" do
    parent = self()

    assert {:error, :unavailable, %{"capability" => "setup_session"}} =
             Router.route(request("setup.session.create"),
               endpoint_opts: [port: 70_000],
               launch_token_provider: fn -> send(parent, :minted) end
             )

    refute_received :minted
  end

  test "input-free methods refuse any params" do
    for method <- ~w(hello overview.get setup.session.create lifecycle.prepare diagnostics.build) do
      request = request(method, %{"unexpected" => true})

      assert {:error, :invalid_params, %{"method" => ^method}} = Router.route(request)
    end
  end

  test "every method carrying params refuses an unknown key" do
    for method <- ~w(doctor.start doctor.get doctor.cancel lifecycle.commit lifecycle.cancel) do
      request = request(method, %{"unexpected" => true})

      assert {:error, :invalid_params, %{"field" => "unexpected"}} = Router.route(request)
    end

    assert {:error, :invalid_params, %{"method" => "logs.query"}} =
             Router.route(request("logs.query", %{"unexpected" => true}))
  end

  test "unknown methods return a stable method_not_found result" do
    assert {:error, :method_not_found, %{"method" => "missing.method"}} =
             Router.route(request("missing.method"))
  end

  describe "management operations" do
    setup context do
      lifecycle =
        start_supervised!(
          {Lifecycle,
           name: :"router_lifecycle_#{:erlang.phash2(context.test)}", shutdown: fn -> :ok end}
        )

      tasks = :"router_tasks_#{:erlang.phash2(context.test)}"
      start_supervised!({Task.Supervisor, name: tasks}, id: tasks)

      doctor =
        start_supervised!(
          {Doctor, name: :"router_doctor_#{:erlang.phash2(context.test)}", task_supervisor: tasks}
        )

      %{opts: [lifecycle_server: lifecycle, doctor_server: doctor]}
    end

    test "lifecycle prepare, commit, and cancel round-trip through public shapes", %{opts: opts} do
      assert {:ok, %{"lease_id" => lease_id, "ttl_ms" => ttl_ms} = prepared} =
               Router.route(request("lifecycle.prepare"), opts)

      assert is_binary(lease_id)
      assert is_integer(ttl_ms) and ttl_ms > 0
      refute Map.has_key?(prepared, "expires_at_ms")

      assert {:error, :busy, %{"operation" => "lifecycle"}} =
               Router.route(request("lifecycle.prepare"), opts)

      assert {:ok, %{"lease_id" => ^lease_id, "status" => "cancelled"}} =
               Router.route(request("lifecycle.cancel", %{"lease_id" => lease_id}), opts)

      assert {:error, :unknown_lease, %{"lease_id" => ^lease_id}} =
               Router.route(request("lifecycle.commit", %{"lease_id" => lease_id}), opts)

      assert {:error, :invalid_params, %{"field" => "lease_id"}} =
               Router.route(request("lifecycle.commit", %{"lease_id" => 42}), opts)
    end

    test "doctor start, get, and cancel round-trip through public shapes", %{opts: opts} do
      descriptors = [
        %{
          id: "readiness",
          category: :runtime,
          severity: :critical,
          applicability: :always,
          origin: :engine,
          run: fn -> %{name: "readiness", status: :ok, detail: "ready"} end
        }
      ]

      opts = Keyword.put(opts, :descriptors, descriptors)

      assert {:ok, %{"session_id" => session_id, "scope" => "local"}} =
               Router.route(request("doctor.start"), opts)

      assert {:ok, %{"session_id" => ^session_id}} =
               Router.route(request("doctor.get", %{"session_id" => session_id}), opts)

      assert {:ok, %{"status" => status}} =
               Router.route(request("doctor.cancel", %{"session_id" => session_id}), opts)

      assert status in ~w(completed cancelled)

      assert {:error, :unknown_session, %{"session_id" => "doctor:missing"}} =
               Router.route(request("doctor.get", %{"session_id" => "doctor:missing"}), opts)

      assert {:error, :invalid_params, %{"field" => "scope"}} =
               Router.route(request("doctor.start", %{"scope" => "everything"}), opts)
    end

    test "logs.query params and bounded errors cross the boundary intact", %{opts: opts} do
      parent = self()

      query = fn params, _query_opts ->
        send(parent, {:query, params})
        {:ok, %{"entries" => [], "count" => 0, "truncated" => false, "cursor" => nil}}
      end

      opts = Keyword.put(opts, :logs_query, query)

      assert {:ok, %{"count" => 0}} =
               Router.route(request("logs.query", %{"limit" => 10, "level" => "info"}), opts)

      assert_receive {:query, %{"limit" => 10, "level" => "info"}}

      expired = Keyword.put(opts, :logs_query, fn _params, _opts -> {:error, :cursor_expired} end)

      assert {:error, :cursor_expired, %{"method" => "logs.query"}} =
               Router.route(request("logs.query", %{"cursor" => "stale"}), expired)
    end

    test "diagnostics.build returns the builder's object and hides its failures", %{opts: opts} do
      report = %{"schema_version" => 1, "engine" => %{}}
      built = Keyword.put(opts, :diagnostics_builder, fn _opts -> {:ok, report} end)

      assert {:ok, ^report} = Router.route(request("diagnostics.build"), built)

      failing =
        Keyword.put(opts, :diagnostics_builder, fn _opts ->
          {:error, {:secret_reason, "authorization-token"}}
        end)

      assert {:error, :unavailable, %{"capability" => "diagnostics"}} =
               Router.route(request("diagnostics.build"), failing)
    end
  end

  defp request(method, params \\ %{}) do
    %{
      request_id: "req-123",
      protocol_version: 1,
      method: method,
      params: params
    }
  end
end
