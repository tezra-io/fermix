defmodule FermixCore.Management.RouterTest do
  use ExUnit.Case, async: true

  alias FermixCore.BuildInfo
  alias FermixCore.Management.Doctor
  alias FermixCore.Management.Jobs
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
               "current_version" => 2,
               "minimum_version" => 1,
               "maximum_version" => 2
             },
             "capabilities" => %{
               "methods" => Protocol.methods(),
               "minimum_versions" => Protocol.method_minimum_versions()
             },
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

  # The two refusals must stay distinguishable: one says restart onto a newer
  # engine, the other says no such method exists anywhere. A shared shape would
  # send an operator chasing an upgrade that changes nothing.
  test "a v2 method on a v1 session is refused with the version it requires" do
    assert {:error, :method_not_found, %{"method" => "setup.state.get", "requires" => 2}} =
             Router.route(request("setup.state.get"))

    refute match?(%{"requires" => _requires}, elem(Router.route(request("missing.method")), 2))
  end

  # One loop over the published table, not a hand-kept list per describe block:
  # the two that stood here between them named twenty of the forty-two methods
  # and no plugin verb at all, so a method published above v1 and served at v1
  # was refused by nothing. The `requires` value is the table's own, so a method
  # introduced at any future version joins this gate by existing.
  test "every method the table publishes above v1 is refused on a v1 session" do
    above_v1 = Enum.reject(Protocol.method_minimum_versions(), fn {_method, min} -> min == 1 end)

    # A walk over an empty list proves nothing, and the family neither hand-kept
    # list named at all was the plugin verbs.
    assert above_v1 != []
    assert Enum.any?(above_v1, fn {method, _min} -> String.starts_with?(method, "plugins.") end)

    for {method, minimum} <- above_v1 do
      assert {:error, :method_not_found, %{"method" => ^method, "requires" => ^minimum}} =
               Router.route(request(method, %{})),
             "#{method} was served on a v1 session"
    end
  end

  test "a v2 method on a v2 session is served" do
    request = %{request("setup.state.get") | protocol_version: 2}

    assert {:ok, %{"readiness" => _readiness}} =
             Router.route(request, setup_state_reporter: fn _opts -> %{"readiness" => %{}} end)
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

  # Every settings and secret refusal becomes a public error in one place, so
  # the two write families answer the same code for the same cause. The seams
  # inject the writer, never a rendered envelope: what is under test here is the
  # translation from an in-VM refusal to a wire code.
  describe "settings and secret operations" do
    test "the section inventory is published as the daemon orders it" do
      inventory = fn -> [%{id: "memory", pane: "memory", title: "Memory"}] end

      assert {:ok, %{"sections" => [section]}} =
               Router.route(v2("settings.sections"), settings_sections: inventory)

      assert section == %{"id" => "memory", "pane" => "memory", "title" => "Memory"}
    end

    test "a section read serves the view, and an unknown section is invalid_params" do
      view = fn "memory", _opts ->
        {:ok, %{"id" => "memory", "title" => "Memory", "rows" => []}}
      end

      assert {:ok, %{"id" => "memory"}} =
               Router.route(v2("settings.get", %{"section" => "memory"}), settings_reader: view)

      unknown = fn section, _opts -> {:error, {:unknown_section, section}} end

      assert {:error, :invalid_params, %{"field" => "section"}} =
               Router.route(v2("settings.get", %{"section" => "nope"}), settings_reader: unknown)
    end

    test "a read with no section named is refused rather than answered" do
      assert {:error, :invalid_params, %{"field" => "section"}} =
               Router.route(v2("settings.get", %{}))

      assert {:error, :invalid_params, %{"field" => "extra"}} =
               Router.route(v2("settings.get", %{"section" => "memory", "extra" => 1}))
    end

    test "an apply carries its values through and answers with what landed" do
      writer = fn "memory", %{"review_interval_hours" => 6}, _opts ->
        {:ok, %{"applied" => ["review_interval_hours"]}}
      end

      params = %{"section" => "memory", "values" => %{"review_interval_hours" => 6}}

      assert {:ok, %{"applied" => ["review_interval_hours"]}} =
               Router.route(v2("settings.apply", params), settings_writer: writer)
    end

    test "an apply with no values object is refused by field" do
      assert {:error, :invalid_params, %{"field" => "values"}} =
               Router.route(v2("settings.apply", %{"section" => "memory"}))
    end

    test "a refused value answers invalid_params with the daemon's own sentence" do
      writer = fn _section, _values, _opts ->
        {:error, {:invalid_params, "sandbox_mode", "invalid sandbox mode."}}
      end

      params = %{"section" => "sandbox", "values" => %{"sandbox_mode" => "paranoid"}}

      assert {:error, :invalid_params, details} =
               Router.route(v2("settings.apply", params), settings_writer: writer)

      assert details == %{"field" => "sandbox_mode", "sentence" => "invalid sandbox mode."}
    end

    test "an outside edit and an unreadable file are two codes, not one" do
      changed = fn _section, _values, _opts -> {:error, {:external_change, ["sandbox"]}} end
      unreadable = fn _section, _values, _opts -> {:error, {:config_unreadable, "line 14."}} end
      params = %{"section" => "sandbox", "values" => %{}}

      assert {:error, :external_change, %{"section" => "sandbox"}} =
               Router.route(v2("settings.apply", params), settings_writer: changed)

      assert {:error, :config_unreadable, %{"sentence" => "line 14."}} =
               Router.route(v2("settings.apply", params), settings_writer: unreadable)
    end

    test "a reload answers the state it left behind" do
      reloader = fn _opts -> {:ok, %{"reloaded" => true, "config_state" => "clear"}} end

      assert {:ok, %{"reloaded" => true, "config_state" => "clear"}} =
               Router.route(v2("settings.reload"), settings_reloader: reloader)
    end

    test "a secret is stored by id and answered with presence alone" do
      writer = fn "openai_api_key", "sk-live" ->
        {:ok, %{"id" => "openai_api_key", "present" => true}}
      end

      params = %{"id" => "openai_api_key", "value" => "sk-live"}

      assert {:ok, %{"id" => "openai_api_key", "present" => true}} =
               Router.route(v2("secret.set", params), secret_writer: writer)
    end

    test "a keyring refusal is its own code, with the published reason word" do
      writer = fn _id, _value ->
        {:error, {:secret_store_failed, "openai_api_key", "locked"}}
      end

      params = %{"id" => "openai_api_key", "value" => "sk-live"}

      assert {:error, :secret_store_failed, details} =
               Router.route(v2("secret.set", params), secret_writer: writer)

      assert details == %{"id" => "openai_api_key", "reason" => "locked"}
    end

    test "a secret write with no value is refused before anything is stored" do
      assert {:error, :invalid_params, %{"field" => "value"}} =
               Router.route(v2("secret.set", %{"id" => "openai_api_key"}))
    end

    test "a secret is forgotten by id" do
      clearer = fn "openai_api_key" -> {:ok, %{"id" => "openai_api_key", "present" => false}} end

      assert {:ok, %{"present" => false}} =
               Router.route(v2("secret.clear", %{"id" => "openai_api_key"}),
                 secret_clearer: clearer
               )
    end
  end

  describe "job and flow operations" do
    setup context do
      tasks = :"router_tasks_#{:erlang.phash2(context.test)}"
      start_supervised!({Task.Supervisor, name: tasks}, id: tasks)

      server =
        start_supervised!(
          {Jobs, name: :"router_jobs_#{:erlang.phash2(context.test)}", task_supervisor: tasks}
        )

      %{operation_opts: [jobs: [server: server]]}
    end

    test "detection answers only the targets asked for", %{operation_opts: opts} do
      probes = [claude_code: fn -> true end]
      params = %{"targets" => ["claude_code"]}

      assert {:ok, %{"results" => [row]}} =
               Router.route(v2("setup.detect", params),
                 operation_opts: Keyword.put(opts, :probes, probes)
               )

      assert row == %{"target" => "claude_code", "present" => true, "detail" => nil}
    end

    test "a detection target this daemon has no probe for is refused by field" do
      assert {:error, :invalid_params, %{"field" => "targets"}} =
               Router.route(v2("setup.detect", %{"targets" => ["everything"]}))

      assert {:error, :invalid_params, %{"field" => "targets"}} =
               Router.route(v2("setup.detect", %{}))
    end

    test "a started job answers with the uniform view", %{operation_opts: opts} do
      probe = fn :anthropic, _probe_opts -> {:ok, %{model: "m", latency_ms: 1}} end
      params = %{"provider" => "anthropic"}

      assert {:ok, view} =
               Router.route(v2("providers.probe.start", params),
                 operation_opts: Keyword.put(opts, :probe, probe)
               )

      assert view["kind"] == "provider_probe"

      assert Enum.sort(Map.keys(view)) ==
               ~w(budget_ms failure finished_at job_id kind phase progress result started_at status)

      assert {:ok, %{"jobs" => [listed]}} = Router.route(v2("job.list"), operation_opts: opts)
      assert listed["job_id"] == view["job_id"]

      assert {:ok, polled} =
               Router.route(v2("job.get", %{"job_id" => view["job_id"]}), operation_opts: opts)

      assert polled["job_id"] == view["job_id"]
    end

    test "a job this daemon does not retain answers unknown_job", %{operation_opts: opts} do
      params = %{"job_id" => "job:missing"}

      assert {:error, :unknown_job, %{"job_id" => "job:missing"}} =
               Router.route(v2("job.get", params), operation_opts: opts)

      assert {:error, :unknown_job, %{"job_id" => "job:missing"}} =
               Router.route(v2("job.cancel", params), operation_opts: opts)
    end

    test "cancelling stops the run and answers its terminal view", %{operation_opts: opts} do
      owner = self()

      probe = fn :anthropic, _probe_opts ->
        send(owner, :probing)

        receive do
          :never -> {:ok, %{model: "m", latency_ms: 1}}
        end
      end

      assert {:ok, started} =
               Router.route(v2("providers.probe.start", %{"provider" => "anthropic"}),
                 operation_opts: Keyword.put(opts, :probe, probe)
               )

      assert_receive :probing

      assert {:ok, cancelled} =
               Router.route(v2("job.cancel", %{"job_id" => started["job_id"]}),
                 operation_opts: opts
               )

      assert cancelled["status"] == "cancelled"
    end

    test "a second run of the same kind and name is busy", %{operation_opts: opts} do
      owner = self()

      probe = fn :anthropic, _probe_opts ->
        send(owner, :probing)

        receive do
          :never -> {:ok, %{model: "m", latency_ms: 1}}
        end
      end

      params = %{"provider" => "anthropic"}
      probe_opts = [operation_opts: Keyword.put(opts, :probe, probe)]

      assert {:ok, _first} = Router.route(v2("providers.probe.start", params), probe_opts)
      assert_receive :probing

      assert {:error, :busy, %{"operation" => "provider_probe"}} =
               Router.route(v2("providers.probe.start", params), probe_opts)
    end

    test "a sign-in answers with the job plus the url it minted", %{operation_opts: opts} do
      owner = self()

      login = fn login_opts ->
        :ok = Keyword.fetch!(login_opts, :oauth_opener).("https://auth.example/authorize")
        send(owner, {:opened, self()})

        receive do
          :finish -> {:ok, %{auth_mode: "chatgpt", tokens: %{}, expires_at: nil}}
        end
      end

      assert {:ok, view} =
               Router.route(v2("auth.start", %{"provider" => "openai_codex"}),
                 operation_opts: Keyword.merge(opts, login: login, reload: fn -> :ok end)
               )

      assert view["authorize_url"] == "https://auth.example/authorize"
      assert view["expires_in_ms"] == Jobs.budget_ms(:auth)
      assert_receive {:opened, pid}
      send(pid, :finish)
    end

    test "an import and a sign-out answer their own shapes", %{operation_opts: opts} do
      importer = fn -> {:ok, %{auth_mode: "oauth", tokens: %{}, expires_at: nil}} end

      # `promote:` and `drop_live_tokens:` are injected because their real
      # implementations reach beyond this case: the promotion writes the suite's
      # `config.toml`, and the token drop invalidates the tree's own manager for
      # every module that runs after this one.
      assert {:ok, imported} =
               Router.route(v2("auth.import.start", %{"source" => "claude_code"}),
                 operation_opts:
                   opts
                   |> Keyword.put(:importer, importer)
                   |> Keyword.put(:promote, fn _provider -> :ok end)
               )

      assert imported["kind"] == "auth_import"

      assert {:ok, %{"restart" => restart}} =
               Router.route(v2("auth.logout", %{"provider" => "openai_codex"}),
                 operation_opts:
                   opts
                   |> Keyword.put(:forget, fn _profile -> :ok end)
                   |> Keyword.put(:drop_live_tokens, fn _provider, _profile -> :ok end)
               )

      assert Enum.sort(Map.keys(restart)) == ~w(reasons required)
    end

    test "a model listing pages and never degrades to the catalog" do
      params = %{"provider" => "anthropic", "live" => false, "limit" => 1}

      assert {:ok, page} = Router.route(v2("providers.models.list", params))
      assert page["source"] == "catalog"
      assert page["truncated"] == true

      live = %{"provider" => "anthropic", "live" => true}

      assert {:error, :unavailable, %{"capability" => "model_listing"}} =
               Router.route(v2("providers.models.list", live))
    end

    test "making a provider primary answers with restart and side effects" do
      opts = [operation_opts: [configured?: fn _id -> true end, commit: fn _id -> {:ok, %{}} end]]

      assert {:ok, result} =
               Router.route(v2("providers.set_primary", %{"provider" => "anthropic"}), opts)

      assert Enum.sort(Map.keys(result)) == ~w(restart side_effects)
    end

    test "the device operations answer their own results", %{operation_opts: opts} do
      permissions = fn -> {:ok, %{state: :not_installed}} end

      assert {:ok, view} =
               Router.route(v2("computer_use.permissions.get"),
                 operation_opts: Keyword.put(opts, :probe, permissions)
               )

      assert Enum.sort(Map.keys(view)) == ~w(input_control installed probed_at screen_capture)

      grant = fn -> {:ok, %{screen_capture: true, input_control: true}} end

      assert {:ok, granted} =
               Router.route(v2("computer_use.grant.start"),
                 operation_opts: Keyword.put(opts, :grant, grant)
               )

      assert granted["kind"] == "computer_use_grant"

      signin = [
        signin: fn -> {:ok, :signed_in} end,
        installed?: fn -> true end,
        browser_installed?: fn -> true end
      ]

      assert {:ok, started} =
               Router.route(v2("meetings.signin.start"),
                 operation_opts: Keyword.merge(opts, signin)
               )

      assert started["kind"] == "meetings_signin"

      install = [install: fn -> {:ok, "/tmp/compux"} end]

      assert {:ok, installing} =
               Router.route(
                 v2("capabilities.install.start", %{"target" => "computer_use_sidecar"}),
                 operation_opts: Keyword.merge(opts, install)
               )

      assert installing["kind"] == "capability_install"
    end

    test "a no-parameter method refuses parameters rather than ignoring them" do
      for method <- ~w(job.list meetings.signin.start computer_use.grant.start
                       computer_use.permissions.get) do
        assert {:error, :invalid_params, %{"method" => ^method}} =
                 Router.route(v2(method, %{"extra" => 1})),
               "#{method} ignored an unexpected parameter"
      end
    end
  end

  # The parameter checks, not the plugin domain: every verb here is injected or
  # refused before it reaches the registry, so nothing in this block reads a
  # plugin store or a catalog.
  describe "plugin operations" do
    test "the listing is served whole, and takes no parameters" do
      reader = fn _opts -> {:ok, %{"plugins" => [], "oauth_clients" => []}} end

      assert {:ok, %{"plugins" => [], "oauth_clients" => []}} =
               Router.route(v2("plugins.list"), plugins_reader: reader)

      assert {:error, :invalid_params, %{"method" => "plugins.list"}} =
               Router.route(v2("plugins.list", %{"name" => "eden"}), plugins_reader: reader)
    end

    test "a listing the daemon could not build names the capability, never the reason" do
      reader = fn _opts -> {:error, {:unavailable, "plugins"}} end

      assert {:error, :unavailable, %{"capability" => "plugins"}} =
               Router.route(v2("plugins.list"), plugins_reader: reader)
    end

    test "every name-only verb refuses a request that names nothing" do
      for method <- ~w(
            plugins.enable plugins.disable plugins.disconnect plugins.install.start
            plugins.check.start plugins.workspaces.discover.start
          ) do
        assert {:error, :invalid_params, %{"field" => "name"}} = Router.route(v2(method, %{})),
               "#{method} answered a request with no plugin named"

        assert {:error, :invalid_params, %{"field" => "extra"}} =
                 Router.route(v2(method, %{"name" => "eden", "extra" => 1}))
      end
    end

    test "a workspace selection needs all four of its fields" do
      complete = %{
        "name" => "eden",
        "profile" => "read_only",
        "workspace_id" => "ws_a",
        "label" => "A"
      }

      for field <- ~w(name profile workspace_id) do
        assert {:error, :invalid_params, %{"field" => ^field}} =
                 Router.route(v2("plugins.workspace.select.start", Map.delete(complete, field)))
      end

      # An unnamed workspace is a display problem, not a configuration error, so
      # the empty label is legal and only an absent one is refused.
      assert {:error, :invalid_params, %{"field" => "label"}} =
               Router.route(v2("plugins.workspace.select.start", Map.delete(complete, "label")))
    end

    test "a sign-in client bounds its redirect port and takes no client secret" do
      params = %{"provider" => "google", "client_id" => "id", "redirect_port" => 70_000}

      assert {:error, :invalid_params, %{"field" => "redirect_port"}} =
               Router.route(v2("plugins.oauth_client.set", params))

      secret = %{"provider" => "google", "client_id" => "id", "client_secret" => "s"}

      assert {:error, :invalid_params, %{"field" => "client_secret"}} =
               Router.route(v2("plugins.oauth_client.set", secret))
    end

    test "a setting write names its plugin and its key" do
      assert {:error, :invalid_params, %{"field" => "key"}} =
               Router.route(v2("plugins.setting.set", %{"name" => "eden", "value" => "x"}))

      assert {:error, :invalid_params, %{"field" => "extra"}} =
               Router.route(
                 v2("plugins.setting.set", %{
                   "name" => "eden",
                   "key" => "K",
                   "value" => "x",
                   "extra" => 1
                 })
               )
    end
  end

  defp v2(method, params \\ %{}), do: %{request(method, params) | protocol_version: 2}

  defp request(method, params \\ %{}) do
    %{
      request_id: "req-123",
      protocol_version: 1,
      method: method,
      params: params
    }
  end
end
