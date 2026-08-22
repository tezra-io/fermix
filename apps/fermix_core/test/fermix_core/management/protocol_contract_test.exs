defmodule FermixCore.Management.ProtocolContractTest do
  @moduledoc """
  Guards the canonical wire-contract export under `priv/management/` against the
  source of truth (`FermixCore.Management.Protocol`). The macOS application
  vendors the schema and fixtures pinned by checksum, so if these drift from the
  module the app ships against a contract the daemon no longer speaks. This test
  is the daemon half of the cross-repo compatibility check described in
  `PROTOCOL.md`, mirroring the Realtime contract test.
  """

  use ExUnit.Case, async: true

  alias Fermix.CLI.Daemon.Client
  alias FermixCore.Management.Doctor
  alias FermixCore.Management.Doctor.Descriptor
  alias FermixCore.Management.Lifecycle
  alias FermixCore.Management.Logs
  alias FermixCore.Management.Protocol
  alias FermixCore.Management.Router
  alias FermixTestSupport.SafeRm

  @protocol_doc Application.app_dir(:fermix_core, "priv/management/PROTOCOL.md")
  @schema_path Application.app_dir(:fermix_core, "priv/management/protocol.schema.json")
  @requests Application.app_dir(:fermix_core, "priv/management/fixtures/requests.jsonl")
  @successes Application.app_dir(:fermix_core, "priv/management/fixtures/success.jsonl")
  @errors Application.app_dir(:fermix_core, "priv/management/fixtures/errors.jsonl")
  @compatibility Application.app_dir(:fermix_core, "priv/management/fixtures/compatibility.jsonl")

  setup_all do
    raw = File.read!(@schema_path)
    %{raw: raw, schema: Jason.decode!(raw)}
  end

  test "the schema's advertised version matches the protocol module", %{schema: schema} do
    {minimum, maximum} = Protocol.supported_version_range()

    assert schema["x-protocol-version"] == Protocol.protocol_version()
    assert schema["x-supported-version-range"] == %{"min" => minimum, "max" => maximum}
  end

  test "the schema's method enum matches the protocol module", %{schema: schema} do
    assert schema["$defs"]["request"]["properties"]["method"]["enum"] == Protocol.methods()
  end

  test "the schema's error enum matches the protocol module", %{schema: schema} do
    assert error_code_enum(schema) == Protocol.error_codes()
  end

  test "the schema's published limits match the protocol module", %{schema: schema} do
    assert schema["x-limits"] == stringify(Protocol.limits())
  end

  # The schema publishes a frame ceiling the app builds its packet-4 client
  # against. A client whose own ceiling is lower silently refuses frames the
  # contract promises; higher, and it sends frames the daemon drops.
  test "the published frame ceiling is the one the packet-4 client enforces" do
    ceiling = Protocol.limits().max_frame_bytes
    socket_dir = mkdir!()
    socket_path = Path.join(socket_dir, "m.sock")
    listen_socket = listen!(socket_path, ceiling)

    on_exit(fn ->
      :gen_tcp.close(listen_socket)
      FermixTestSupport.SafeRm.rm_rf(socket_dir)
    end)

    params = %{"value" => String.duplicate("x", ceiling)}

    assert {:error, {:request_too_large, size, maximum}} =
             Client.request_v1("hello", params, socket_path: socket_path, timeout: 1_000)

    assert maximum == ceiling
    assert size > ceiling
  end

  test "every method declares its own params and result definition", %{schema: schema} do
    defs = schema["$defs"]

    for method <- Protocol.methods() do
      key = def_key(method)

      assert is_map(defs["#{key}_params"]), "schema has no params def for #{method}"
      assert is_map(defs["#{key}_result"]), "schema has no result def for #{method}"
    end
  end

  # A per-method def that nothing $refs enforces nothing — the schema would then
  # validate frames the daemon rejects. A $ref to a def that does not exist is
  # the same drift from the other side.
  test "every schema def is referenced and every reference resolves", %{raw: raw, schema: schema} do
    defined = MapSet.new(Map.keys(schema["$defs"]))

    referenced =
      ~r{\#/\$defs/([A-Za-z0-9_]+)}
      |> Regex.scan(raw)
      |> MapSet.new(fn [_match, name] -> name end)

    assert MapSet.to_list(MapSet.difference(defined, referenced)) == [],
           "schema defs are defined but never referenced"

    assert MapSet.to_list(MapSet.difference(referenced, defined)) == [],
           "schema references point at defs that do not exist"
  end

  test "every golden request frame classifies through the live protocol" do
    for record <- fixtures(@requests), do: assert_classified(record)
  end

  test "the golden request fixtures cover every published method" do
    covered = @requests |> fixtures() |> Enum.map(& &1["method"]) |> Enum.uniq() |> Enum.sort()

    assert covered == Enum.sort(Protocol.methods())
  end

  test "every golden compatibility frame classifies through the live protocol" do
    for record <- fixtures(@compatibility), do: assert_classified(record)
  end

  test "the compatibility fixtures cover the v0 window and both negotiation directions" do
    expectations = @compatibility |> fixtures() |> Enum.map(&outcome_label/1) |> MapSet.new()

    for label <- ["v0", "invalid_v0", "invalid_request", "client_too_old", "daemon_too_old"] do
      assert label in expectations, "compatibility fixtures do not cover #{label}"
    end
  end

  test "every golden success envelope is reproduced exactly by the responder" do
    for record <- fixtures(@successes) do
      response = record["response"]

      assert {:ok, built} = Protocol.respond(response["request_id"], {:ok, response["result"]})
      assert built == response, "responder did not round-trip #{record["name"]}"
      assert Jason.encode!(built) == Jason.encode!(response)
    end
  end

  test "the golden success fixtures cover every published method" do
    covered = @successes |> fixtures() |> Enum.map(& &1["method"]) |> Enum.uniq() |> Enum.sort()

    assert covered == Enum.sort(Protocol.methods())
  end

  test "every golden error envelope is reproduced exactly by the responder" do
    for record <- fixtures(@errors) do
      response = record["response"]
      code = String.to_existing_atom(record["code"])
      details = response["error"]["details"]

      assert {:ok, built} = Protocol.respond(response["request_id"], {:error, code, details})
      assert built == response, "responder did not round-trip #{record["name"]}"
      assert Jason.encode!(built) == Jason.encode!(response)
    end
  end

  test "the golden error fixtures cover every published error code" do
    covered = @errors |> fixtures() |> Enum.map(& &1["code"]) |> Enum.uniq() |> Enum.sort()

    assert covered == Enum.sort(Protocol.error_codes())
  end

  # The golden success fixtures are hand-written, and round-tripping them
  # through `respond/2` proves only that the responder does not mangle a map it
  # was handed. Nothing tied them to what the daemon actually sends, so renaming
  # a key in `Router.project_overview/2` or `hello/1` left every contract test
  # green while the vendored macOS target validated against a shape the daemon
  # no longer produces. This drives the real router and compares key shapes.
  test "every golden success result carries the key shape the router returns", %{} do
    for {method, opts} <- router_cases() do
      request = %{request_id: "req-1", protocol_version: 1, method: method, params: %{}}

      assert {:ok, result} = Router.route(request, opts), "router refused #{method}"

      assert shape(result) == shape(fixture_result(method)),
             "the golden #{method} fixture no longer matches the router's own result shape"
    end
  end

  # The one shape the router cannot hand back inside a single call: a finished
  # check. It is pinned straight to the descriptor that builds it.
  test "the golden Doctor check shape is the one the descriptor produces" do
    spec = %{
      id: "readiness",
      category: :runtime,
      severity: :critical,
      applicability: :always,
      origin: :engine,
      run: fn -> %{name: "readiness", status: :ok, detail: "ready"} end
    }

    [golden | _rest] =
      "doctor.get" |> fixture_result() |> Map.fetch!("checks")

    assert shape(Descriptor.run(spec)) == shape(golden)
  end

  test "PROTOCOL.md documents every method, error code, and published bound" do
    doc = File.read!(@protocol_doc)

    for method <- Protocol.methods() do
      assert doc =~ "`#{method}`", "PROTOCOL.md does not document method #{method}"
    end

    for code <- Protocol.error_codes() do
      assert doc =~ "`#{code}`", "PROTOCOL.md does not document error code #{code}"
    end

    for {bound, value} <- Protocol.limits() do
      assert doc =~ "`#{bound}`", "PROTOCOL.md does not document bound #{bound}"
      assert doc =~ Integer.to_string(value), "PROTOCOL.md does not publish #{bound}'s value"
    end
  end

  # Every seam here injects a *source*, never a result: the projection,
  # scrubbing, bounding, and cursor logic under test is the daemon's own.
  defp router_cases do
    [
      {"hello", [identity_provider: fn -> {:ok, engine_identity()} end, endpoint_opts: port()]},
      {"overview.get",
       [
         health_reporter: fn -> health() end,
         overview_provider: fn _health -> {:ok, snapshot()} end
       ]},
      {"setup.session.create",
       [
         endpoint_opts: port(),
         launch_token_provider: fn -> {:ok, %{token: "t", expires_at_ms: 1_755_561_600_000}} end
       ]},
      {"logs.query", [logs_opts: [log_file: log_file()]]},
      {"lifecycle.prepare", [lifecycle_server: lifecycle_server()]},
      {"doctor.start", [doctor_server: doctor_server(), descriptors: []]},
      {"diagnostics.build", [diagnostics_opts: diagnostics_opts()]}
    ]
  end

  defp fixture_result(method) do
    @successes
    |> fixtures()
    |> Enum.find(&(&1["method"] == method))
    |> get_in(["response", "result"])
  end

  # Keys and container kinds only — values differ between a fixture and a live
  # run by construction. An empty list is its own shape, so a fixture that
  # illustrates an element the router never returns still fails.
  defp shape(value) when is_map(value), do: Map.new(value, fn {k, v} -> {k, shape(v)} end)
  defp shape([]), do: []
  defp shape([head | _rest]), do: [shape(head)]
  defp shape(_value), do: :scalar

  defp port, do: [port: 4030]

  defp engine_identity do
    %{
      "engine_id" => "fermix-core",
      "product_version" => "0.9.0",
      "build_id" => "b",
      "source_commit" => "c",
      "distribution_identity" => "macos_app",
      "artifact_target" => "macos_aarch64",
      "architecture" => "arm64",
      "pid" => "1"
    }
  end

  defp health do
    %{
      status: :ok,
      restart_required?: false,
      providers: [%{name: "openai_codex", status: :ok, auth_mode: :oauth, primary: true}],
      failures: []
    }
  end

  defp snapshot do
    %{
      generated_at: ~U[2026-08-19 12:00:00Z],
      readiness: %{status: :ready, failures: []},
      daemon: %{status: :running, version: "0.9.0", uptime_ms: 1, pid: "1"},
      provider: %{active: :openai_codex, model: "m", auth_mode: :oauth, reasoning_effort: :high},
      channels: [
        %{name: "telegram", status: :ok, enabled: true, mode: :polling, process_alive: true}
      ],
      memory: %{repo: :ready, conversation_store: :ready, store: :ready},
      jobs: %{
        scheduled: 1,
        running: 0,
        paused: 0,
        failed_recent: 0,
        next: %{id: "j", name: "n", next_run_at: "2026-08-19T12:00:00Z", state: "scheduled"},
        status: :ok
      },
      agents: %{
        main: %{
          health: :online,
          activity: :idle,
          status: :idle,
          active_conversations: 0,
          pending_conversations: 0
        },
        skill_workers: 0,
        running_skill_workers: 0
      },
      realtime: %{
        enabled: true,
        status: :ready,
        provider: :openai,
        model: "m",
        socket_alive: true,
        active_sessions: 0,
        active_clients: 0,
        companion_connected?: true
      },
      capabilities: %{builtin: 1, skill: 1, mcp: 1, total: 3}
    }
  end

  defp diagnostics_opts do
    [
      identity_provider: fn -> {:ok, engine_identity()} end,
      service_provider: fn -> {:ok, %{scope: nil, state: :app_managed}} end,
      logs_provider: fn params -> Logs.query(params, log_file: log_file()) end,
      doctor_provider: fn -> {:ok, doctor_session_view()} end
    ]
  end

  defp doctor_session_view do
    fixture_result("doctor.get")
  end

  defp log_file do
    dir = SafeRm.make_tmp_dir!("management_contract_logs")
    on_exit(fn -> SafeRm.rm_rf!(dir) end)
    path = Path.join(dir, "fermix.log")

    File.write!(path, """
    2026-08-19T12:00:00.512431 info [realtime] local voice socket listening
    2026-08-19T12:00:01.884907 warning Daemon accept error
    """)

    path
  end

  defp lifecycle_server do
    start_supervised!({Lifecycle, name: :"contract_lifecycle_#{unique()}"}, id: :"lc_#{unique()}")
  end

  defp doctor_server do
    tasks = :"contract_doctor_tasks_#{unique()}"
    start_supervised!({Task.Supervisor, name: tasks}, id: tasks)

    start_supervised!({Doctor, name: :"contract_doctor_#{unique()}", task_supervisor: tasks},
      id: :"doctor_#{unique()}"
    )
  end

  defp unique, do: System.unique_integer([:positive, :monotonic])

  defp assert_classified(%{"expect" => "v1"} = record) do
    assert {:ok, {:v1, request}} = classify(record), "golden v1 frame rejected: #{record["name"]}"
    assert request.method == record["method"]
  end

  defp assert_classified(%{"expect" => "v0"} = record) do
    assert {:ok, {:v0, _request}} = classify(record),
           "golden v0 frame rejected: #{record["name"]}"
  end

  defp assert_classified(%{"expect" => "invalid_v0"} = record) do
    assert {:error, :invalid_v0_request} = classify(record),
           "golden invalid frame accepted: #{record["name"]}"
  end

  defp assert_classified(%{"expect" => "error"} = record) do
    assert {:error, {:v1, response}} = classify(record),
           "golden reject frame accepted: #{record["name"]}"

    assert response["error"]["code"] == record["error_code"]
    refute Map.has_key?(response, "result")
  end

  defp classify(record), do: Protocol.decode_request(Jason.encode!(record["frame"]))

  defp outcome_label(%{"expect" => "error"} = record), do: record["error_code"]
  defp outcome_label(record), do: record["expect"]

  defp error_code_enum(schema) do
    schema["$defs"]["error"]["properties"]["error"]["properties"]["code"]["enum"]
  end

  defp def_key(method), do: String.replace(method, ".", "_")

  defp stringify(limits) do
    Map.new(limits, fn {key, value} -> {Atom.to_string(key), value} end)
  end

  defp fixtures(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp listen!(socket_path, ceiling) do
    {:ok, socket} =
      :gen_tcp.listen(0, [
        :binary,
        {:active, false},
        {:ifaddr, {:local, socket_path}},
        {:packet, 4},
        {:packet_size, ceiling},
        {:reuseaddr, true}
      ])

    socket
  end

  defp mkdir! do
    path =
      Path.join(
        System.tmp_dir!(),
        "fermix-management-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(path)
    path
  end
end
