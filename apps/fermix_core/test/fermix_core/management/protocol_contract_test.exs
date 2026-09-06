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
  alias FermixCore.Management.Detect
  alias FermixCore.Management.Doctor
  alias FermixCore.Management.Doctor.Descriptor
  alias FermixCore.Management.Doctor.Remediation
  alias FermixCore.Management.Jobs
  alias FermixCore.Management.Lifecycle
  alias FermixCore.Management.Logs
  alias FermixCore.Management.Plugins.Row, as: PluginRow
  alias FermixCore.Management.Protocol
  alias FermixCore.Management.Router
  alias FermixCore.Management.Settings
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

  # The app refuses to decode a partial table: without a minimum for every
  # method it cannot tell "this method needs a newer engine" from "this daemon
  # does not serve it", and those are two states with two different remedies.
  test "the schema publishes a minimum version for every method", %{schema: schema} do
    published = schema["x-method-minimum-versions"]

    assert published == stringify_values(Protocol.method_minimum_versions())
    assert Map.keys(published) |> Enum.sort() == Enum.sort(Protocol.methods())
  end

  # A request frame's ceiling is the daemon's own maximum. A schema that allows
  # a version the daemon refuses validates frames that always answer
  # `daemon_too_old`.
  test "the schema's request version ceiling is the daemon's maximum", %{schema: schema} do
    {minimum, maximum} = Protocol.supported_version_range()
    version = schema["$defs"]["request"]["properties"]["protocol_version"]

    assert version["minimum"] == minimum
    assert version["maximum"] == maximum
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

  # The refusal a released app meets first, and the one the per-method table
  # exists for: a client that negotiated 1 reaches every v1 surface and is told
  # which version the rest need. Driven through the live router, because the
  # gate is the router's, not the envelope validator's.
  test "an N-1 client is refused every v2 method by the live router" do
    refusals = Enum.filter(fixtures(@compatibility), &(&1["expect"] == "refused_by_router"))

    assert length(refusals) >= 2, "no N-1 refusal case in the compatibility fixtures"

    for record <- refusals do
      frame = record["frame"]

      request = %{
        request_id: frame["request_id"],
        protocol_version: frame["protocol_version"],
        method: frame["method"],
        params: frame["params"]
      }

      assert {:error, code, details} = Router.route(request, []),
             "golden N-1 refusal was served: #{record["name"]}"

      assert Atom.to_string(code) == record["error_code"]
      assert details == %{"method" => record["method"], "requires" => record["requires"]}
    end
  end

  # A golden response in the compatibility file shows an absent rendering rather
  # than a refusal: every optional field of one row null at once, so a client
  # that infers a state from a null fails here rather than in front of a user.
  test "every golden compatibility response is reproduced exactly by the responder" do
    responses = Enum.filter(fixtures(@compatibility), &(&1["expect"] == "response"))

    assert Enum.any?(responses, &(&1["method"] == "plugins.list")),
           "no plugin case in the compatibility fixtures"

    for record <- responses do
      response = record["response"]

      assert {:ok, built} = Protocol.respond(response["request_id"], {:ok, response["result"]})
      assert built == response, "responder did not round-trip #{record["name"]}"
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

  # `message` is fixed per code, so for the whole `invalid_params` family it says
  # "Request parameters are invalid." and nothing else. Everything the daemon has
  # to say about THIS request rides `details.sentence`, and a client that renders
  # `message` alone shows the operator the one sentence in the catalog that tells
  # them nothing. The shape is driven from the live router, not hand-written, so
  # a refusal that stopped carrying its sentence fails here.
  test "a refusal that has something to say carries it in details.sentence" do
    request = %{
      request_id: "req-1",
      protocol_version: 2,
      method: "auth.start",
      params: %{"provider" => "anthropic"}
    }

    assert {:error, :invalid_params, details} = Router.route(request)

    assert details == golden_error_details("invalid_params_with_sentence")
    assert details["field"] == "provider"
    assert is_binary(details["sentence"]) and details["sentence"] != ""
  end

  defp golden_error_details(name) do
    @errors
    |> fixtures()
    |> Enum.find(&(&1["name"] == name))
    |> get_in(["response", "error", "details"])
  end

  # The golden success fixtures are hand-written, and round-tripping them
  # through `respond/2` proves only that the responder does not mangle a map it
  # was handed. Nothing tied them to what the daemon actually sends, so renaming
  # a key in `Router.project_overview/2` or `hello/1` left every contract test
  # green while the vendored macOS target validated against a shape the daemon
  # no longer produces. This drives the real router and compares key shapes.
  test "every golden success result carries the key shape the router returns", %{} do
    for {method, params, opts} <- router_cases() do
      {:ok, minimum} = Protocol.minimum_version(method)
      request = %{request_id: "req-1", protocol_version: minimum, method: method, params: params}

      assert {:ok, result} = Router.route(request, opts), "router refused #{method}"

      assert shape(result) == shape(fixture_result(method, params)),
             "the golden #{method} fixture no longer matches the router's own result shape"
    end
  end

  # The one flow method whose golden result is a job in its TERMINAL state: the
  # grant's whole answer is the pair of booleans the OS prompts returned, and a
  # started view carries `result: null`, so a case that stopped at the reply
  # would leave those two keys pinned to nothing. It starts the real grant and
  # reads the job it minted, both against the live registry.
  test "the golden computer-use grant result is the one its job finishes with" do
    jobs = jobs()
    grant = fn -> {:ok, %{screen_capture: true, input_control: false}} end

    request = %{
      request_id: "req-1",
      protocol_version: 2,
      method: "computer_use.grant.start",
      params: %{}
    }

    assert {:ok, started} = Router.route(request, operation_opts: [jobs: jobs, grant: grant])
    assert {:ok, finished} = eventually_terminal(jobs, started["job_id"])

    assert shape(finished) == shape(fixture_result("computer_use.grant.start", %{}))
  end

  # The section inventory is what three consumers walk, so a fixture that lists
  # a section the daemon does not serve, or omits one it does, is a client
  # rendering a pane that answers nothing.
  test "the golden section inventory is the one the daemon publishes" do
    published = Enum.map(Settings.sections(), & &1.id)

    fixture =
      "settings.sections"
      |> fixture_result(%{})
      |> Map.fetch!("sections")
      |> Enum.map(& &1["id"])

    assert fixture == published
  end

  # Every kind and format a row may carry is pinned to the module, so a kind
  # added in Elixir fails here rather than reaching a client that cannot render
  # it.
  test "the schema's row vocabulary matches the settings module", %{schema: schema} do
    row = schema["$defs"]["settingsRow"]["properties"]
    %{kinds: kinds, formats: formats} = Settings.vocabulary()

    assert row["kind"]["enum"] == Enum.map(kinds, &Atom.to_string/1)
    assert row["format"]["enum"] == Enum.map(formats, &Atom.to_string/1) ++ [nil]
  end

  # Every job kind, status word and failure code a client may meet is pinned to
  # the module that mints them, so a kind added in Elixir fails here rather than
  # reaching a client whose decoder has never heard of it.
  test "the schema's job vocabulary matches the jobs module", %{schema: schema} do
    defs = schema["$defs"]

    assert defs["jobKind"]["enum"] == Enum.map(Jobs.kinds(), &Atom.to_string/1)
    assert defs["jobFailure"]["properties"]["code"]["enum"] == Jobs.failure_codes()
  end

  # A phase the daemon can report and the contract does not publish is a token a
  # client has no sentence for, so it draws nothing. PROTOCOL.md is where the
  # vocabulary is published, and this pins it to the module.
  test "PROTOCOL.md publishes every phase a job may report" do
    doc = File.read!(@protocol_doc)

    for kind <- Jobs.kinds(), phase <- Jobs.phases(kind) do
      assert doc =~ "`#{phase}`", "PROTOCOL.md does not publish the #{kind} phase #{phase}"
    end
  end

  # A status a plugin row can carry and the contract does not publish is a word
  # nobody reading a support log can look up, and a verb the daemon mints and
  # the contract does not name is a button label with no provenance. Both sets
  # are derived from the modules that mint them, so one added in Elixir fails
  # here rather than reaching a client.
  test "the schema's plugin vocabulary matches the modules that mint it", %{schema: schema} do
    published = schema["x-plugin-vocabulary"]

    assert published["statuses"] == Enum.map(PluginRow.statuses(), &Atom.to_string/1)
    assert published["verbs"] == PluginRow.verbs()
    assert published["actions"] == PluginRow.actions()
    assert published["runtime_kinds"] == PluginRow.runtime_kinds()
    assert published["auth_kinds"] == PluginRow.auth_kinds()
  end

  # A word is not a routing key. Every golden row therefore carries an action id
  # beside every verb word, in the same order and from the schema's closed set,
  # so a client paints `verbs[i]` and routes on `actions[i]` instead of deriving
  # the method from the row's state and disagreeing with its own label.
  test "every golden plugin row publishes a closed action beside every verb", %{schema: schema} do
    published = schema["$defs"]["pluginAction"]["enum"]

    assert published == PluginRow.actions()
    rows = golden_plugin_rows()

    # A walk over an empty list proves nothing: the five plugin methods that
    # answer with a row are what this gate exists for.
    assert length(rows) >= 5

    for row <- rows do
      assert length(row["actions"]) == length(row["verbs"]),
             "#{row["name"]} publishes #{length(row["verbs"])} verbs and " <>
               "#{length(row["actions"])} actions"

      assert Enum.all?(row["actions"], &(&1 in published)),
             "#{row["name"]} publishes an action outside the closed set"

      assert is_nil(row["primary_verb"]) == is_nil(row["primary_action"]),
             "#{row["name"]} publishes a leading verb and action that disagree about being absent"

      assert is_nil(row["primary_action"]) or row["primary_action"] in row["actions"],
             "#{row["name"]} leads with an action that is not one of its own"
    end
  end

  defp golden_plugin_rows do
    @successes
    |> fixtures()
    |> Enum.flat_map(&plugin_rows_in(&1["response"]["result"]))
  end

  defp plugin_rows_in(%{"plugins" => rows}) when is_list(rows), do: rows
  defp plugin_rows_in(%{"plugin" => row}) when is_map(row), do: [row]
  defp plugin_rows_in(_result), do: []

  # The row's two closed fields are enums in the schema as well as vocabulary, so
  # a client that validates a frame and a client that enumerates the words read
  # one set rather than two that can disagree.
  test "the plugin row's own enums are the published vocabulary", %{schema: schema} do
    row = schema["$defs"]["pluginRow"]["properties"]

    assert enum_of(row["runtime_kind"]) == PluginRow.runtime_kinds()
    assert enum_of(row["auth_kind"]) == PluginRow.auth_kinds()
  end

  # `hello` is how a client learns what this daemon serves. A catalog in the
  # export that the daemon no longer publishes is the one drift a client cannot
  # detect for itself: it would refuse a method the daemon has, or call one it
  # does not.
  test "the golden hello fixture publishes the daemon's own catalog" do
    capabilities = "hello" |> fixture_result(%{}) |> Map.fetch!("capabilities")

    assert capabilities["methods"] == Protocol.methods()
    assert capabilities["minimum_versions"] == Protocol.method_minimum_versions()
  end

  # The detection catalog is closed and three consumers walk it, so a target the
  # daemon answers and the contract does not name is a row nothing can render.
  test "the schema's detection targets are the ones the daemon answers", %{schema: schema} do
    assert schema["$defs"]["detectTarget"]["enum"] == Detect.targets()
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
      "doctor.get" |> fixture_result(%{}) |> Map.fetch!("checks")

    assert shape(Descriptor.run(spec)) == shape(golden)
  end

  # A check whose remediation is always null illustrates the absent rendering and
  # nothing else, so the app would vendor a contract in which the action button
  # has never once been drawn. One golden check carries a whole remediation, and
  # it is pinned to the table that mints it rather than typed twice.
  test "the golden Doctor checks carry one whole remediation from the live table" do
    checks = "doctor.get" |> fixture_result(%{}) |> Map.fetch!("checks")
    remediated = Enum.filter(checks, &is_map(&1["remediation"]))

    assert [check] = remediated
    assert check["remediation"] == Remediation.fetch(check["id"], check["status"])
    assert check["remediation_code"] == "#{check["id"]}.#{check["status"]}"
    assert check["remediation"]["action"]["kind"] in Remediation.action_kinds()
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
      {"hello", %{},
       [identity_provider: fn -> {:ok, engine_identity()} end, endpoint_opts: port()]},
      {"setup.state.get", %{}, [setup_state_opts: setup_state_opts()]},
      {"overview.get", %{},
       [
         health_reporter: fn -> health() end,
         overview_provider: fn _health -> {:ok, snapshot()} end
       ]},
      {"setup.session.create", %{},
       [
         endpoint_opts: port(),
         launch_token_provider: fn -> {:ok, %{token: "t", expires_at_ms: 1_755_561_600_000}} end
       ]},
      {"logs.query", %{}, [logs_opts: [log_file: log_file()]]},
      {"lifecycle.prepare", %{}, [lifecycle_server: lifecycle_server()]},
      {"doctor.start", %{}, [doctor_server: doctor_server(), descriptors: []]},
      {"diagnostics.build", %{}, [diagnostics_opts: diagnostics_opts()]},
      # The two settings reads run against the daemon's own projection with no
      # seam at all: they read configuration and write nothing, so the shape
      # under test is the live one rather than an injected stand-in. The three
      # write methods are pinned beside their own writers, which own a home.
      {"settings.sections", %{}, []},
      # The job-backed methods run against the live job registry with only
      # their operation injected, so the view under test is the daemon's own.
      {"setup.detect", %{"targets" => Detect.targets()}, [operation_opts: detect_probes()]},
      {"providers.models.list", %{"provider" => "anthropic", "live" => false}, []},
      {"providers.probe.start", %{"provider" => "anthropic"},
       [operation_opts: [jobs: [server: jobs_server()], probe: probe()]]},
      {"computer_use.permissions.get", %{},
       [operation_opts: [probe: fn -> {:ok, permissions()} end]]},
      # The listing runs against the daemon's own registry and baked catalog with
      # no seam at all: it reads and writes nothing, so the shape under test is
      # the live projection rather than an injected stand-in.
      {"plugins.list", %{}, []}
    ] ++ settings_cases() ++ job_view_cases() ++ flow_cases()
  end

  # The seven flow methods whose golden result is the view the starting call
  # itself answers with, each against its own job registry so no case can make
  # another one `busy`, and every vendor call, keychain read, download and
  # browser sign-in injected. The seams are the ones `RouterTest` already drives
  # these through; what is compared is the view the router hands back, which is
  # the daemon's own. `computer_use.grant.start` is the eighth, pinned in its
  # own case above because its golden result is a terminal job view.
  #
  # Eight published methods are deliberately absent, and none of them for want
  # of a fixture:
  #
  #   * `providers.set_primary` and `auth.logout` both embed
  #     `Settings.restart()`, whose reason list is empty unless a boot-bound
  #     change stands in the daemon-wide `RestartState`. Seeding that here is
  #     exactly the leaked-global-state defect an async case must not create,
  #     and an empty list is its own shape, so the comparison would pass or
  #     fail on whichever module ran first. `SettingsTest` and `SecretsTest`
  #     pin the same `Settings.restart/0` projection against the same export,
  #     serially and with a home of their own.
  #   * `plugins.enable`, `plugins.disable`, `plugins.setting.set` and
  #     `plugins.oauth_client.set` commit through `Plugins.Config`, which
  #     rewrites `config.toml` under `FERMIX_HOME`. The router exposes no
  #     writer seam for them, so a case here would write the suite's own home.
  #   * `plugins.workspaces.discover.start` and `plugins.workspace.select.start`
  #     refuse before their job starts unless `Plugins.Registry` holds an
  #     installed plugin declaring a `resource_scope`. That read has no seam,
  #     and installing a fixture plugin needs a tmp home and a serial case.
  defp flow_cases do
    [
      {"auth.start", %{"provider" => "openai_codex"},
       [operation_opts: [jobs: jobs(), login: blocking_login()]]},
      {"auth.import.start", %{"source" => "claude_code"},
       [operation_opts: [jobs: jobs(), importer: importer(), promote: fn _id -> :ok end]]},
      {"plugins.install.start", %{"name" => "obsidian"},
       [operation_opts: [jobs: jobs(), install: fn _name, _opts -> {:ok, :installed} end]]},
      {"plugins.check.start", %{"name" => "google_calendar"},
       [operation_opts: [jobs: jobs(), check: check()]]},
      # The one plugin write verb with no config writer behind it: forgetting a
      # credential is the injected half, and the row it answers with is read
      # from the live registry exactly as `plugins.list` above is.
      {"plugins.disconnect", %{"name" => "google_calendar"},
       [operation_opts: [logout: fn _name -> :ok end]]},
      {"capabilities.install.start", %{"target" => "computer_use_sidecar"},
       [operation_opts: [jobs: jobs(), install: fn -> {:ok, "/tmp/compux"} end]]},
      {"meetings.signin.start", %{}, [operation_opts: [jobs: jobs()] ++ signin()]}
    ]
  end

  # `job.get`, `job.list` and `job.cancel` answer about a job something else
  # started, so each mints a real one through the live probe method rather than
  # handing the registry a view to read back. One registry per case: the fixture
  # each is compared with illustrates one job state, and a shared registry would
  # make which state is read depend on case order.
  defp job_view_cases do
    # A finished job for the `job.get` fixture: its golden result is a completed
    # view, so the probe answers at once and the case waits for the registry to
    # close it rather than reading a view that is still running.
    finished = jobs()
    completed = probe_job(finished, probe())
    {:ok, _terminal} = eventually_terminal(finished, completed)

    # One job, still running, for each of the other two: both golden results are
    # of a job that has not finished, and a probe that never answers is what
    # holds that state without a clock.
    listed = jobs()
    _running = probe_job(listed, blocking_probe())

    cancelling = jobs()
    doomed = probe_job(cancelling, blocking_probe())

    [
      {"job.get", %{"job_id" => completed}, [operation_opts: [jobs: finished]]},
      {"job.list", %{}, [operation_opts: [jobs: listed]]},
      {"job.cancel", %{"job_id" => doomed}, [operation_opts: [jobs: cancelling]]}
    ]
  end

  # Every section, not a representative one: the app's descriptor coverage test
  # reads the vendored fixture for the keys it binds, so a section with no
  # golden result is a pane whose keys nothing on the far side is held to.
  defp settings_cases do
    for section <- Settings.sections(),
        do: {"settings.get", %{"section" => section.id}, []}
  end

  # Sources, never rendered rows: the projection under test is the daemon's.
  defp detect_probes do
    [
      probes: [
        existing_primary: fn -> {:ok, :openai_codex} end,
        claude_code: fn -> true end,
        codex_cli: fn -> false end,
        ollama: fn -> {:error, :econnrefused} end,
        harness_vendors: fn ->
          %{
            "claude" => %{
              vendor: "claude",
              available?: true,
              version: "2.1.1",
              auth: :authenticated
            },
            "codex" => %{vendor: "codex", available?: true, version: "0.100.0", auth: :unverified}
          }
        end
      ]
    ]
  end

  defp probe, do: fn :anthropic, _opts -> {:ok, %{model: "claude-opus-5", latency_ms: 812}} end

  defp permissions do
    %{state: :probed, screen_capture: true, input_control: false, platform: "macos"}
  end

  defp jobs_server do
    tasks = :"contract_jobs_tasks_#{unique()}"
    start_supervised!({Task.Supervisor, name: tasks}, id: tasks)

    start_supervised!({Jobs, name: :"contract_jobs_#{unique()}", task_supervisor: tasks},
      id: :"jobs_#{unique()}"
    )
  end

  defp jobs, do: [server: jobs_server()]

  # Sources, never rendered views. The sign-in blocks after minting its url, so
  # the reply the router awaits is the running job plus the url — the state the
  # golden fixture illustrates — and no credential is ever stored. The run is
  # owned by the case's own task supervisor and stops with it.
  defp blocking_login do
    fn login_opts ->
      :ok = Keyword.fetch!(login_opts, :oauth_opener).("https://auth.example/authorize")
      block()
    end
  end

  defp importer, do: fn -> {:ok, %{auth_mode: "oauth", tokens: %{}, expires_at: nil}} end

  defp check, do: fn _name, _opts -> {:ok, %{status: :ready, live_probe?: true}} end

  defp signin do
    [
      signin: fn -> {:ok, :signed_in} end,
      installed?: fn -> true end,
      browser_installed?: fn -> true end
    ]
  end

  defp blocking_probe, do: fn _id, _opts -> block() end

  defp block do
    receive do
      :never_sent -> {:ok, %{model: "m", latency_ms: 1}}
    end
  end

  defp probe_job(jobs, probe) do
    request = %{
      request_id: "req-1",
      protocol_version: 2,
      method: "providers.probe.start",
      params: %{"provider" => "anthropic"}
    }

    assert {:ok, view} = Router.route(request, operation_opts: [jobs: jobs, probe: probe])

    view["job_id"]
  end

  # Terminal status is what a poller waits for, so this polls the way the app
  # does rather than sleeping a guessed interval. Bounded at 200 × 10 ms: an
  # injected double that has not answered by then is a defect in the case, and
  # the caller's match on `{:ok, view}` fails rather than hangs.
  defp eventually_terminal(jobs, job_id, attempts \\ 200)

  defp eventually_terminal(_jobs, job_id, 0), do: {:error, {:never_terminal, job_id}}

  defp eventually_terminal(jobs, job_id, attempts) do
    {:ok, view} = Jobs.get(job_id, jobs)

    if view["status"] == "running" do
      Process.sleep(10)
      eventually_terminal(jobs, job_id, attempts - 1)
    else
      {:ok, view}
    end
  end

  # Sources, never rendered results: the projection under test is the daemon's.
  defp setup_state_opts do
    [
      readiness: fn ->
        %{
          status: :setup_required,
          failures: [
            %{
              component: "provider:anthropic",
              action: "Set ANTHROPIC_API_KEY.",
              gating: true,
              pane: "providers",
              detail_key: "provider:missing_credentials:anthropic"
            }
          ]
        }
      end,
      restart: fn ->
        %{
          required: true,
          reasons: [%{section: "providers", sentence: "Provider settings changed."}]
        }
      end,
      accounts: fn -> %{} end,
      sidecar_installed?: fn -> false end,
      legacy_service_unit: fn -> %{present: true, scope: :user, path: "/tmp/unit.plist"} end,
      secret_acl_restricted: fn -> %{present: false, keys: []} end,
      config_state: fn -> :clear end
    ]
  end

  # A method with more than one golden result is selected by the parameters that
  # produced it, so `settings.get` on one section is compared with the fixture
  # for that section rather than with whichever one comes first.
  defp fixture_result(method, params) do
    @successes
    |> fixtures()
    |> Enum.filter(&(&1["method"] == method))
    |> Enum.find(&matching_result?(&1, params))
    |> get_in(["response", "result"])
  end

  defp matching_result?(record, %{"section" => section}),
    do: get_in(record, ["response", "result", "id"]) == section

  defp matching_result?(_record, _params), do: true

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
      restart_required?: true,
      restart_reasons: ["providers"],
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
    fixture_result("doctor.get", %{})
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

  # Both are valid v1 frames: what they prove happens after classification, in
  # the router and in the responder, so classification only has to accept them.
  defp assert_classified(%{"expect" => "refused_by_router"} = record) do
    assert {:ok, {:v1, request}} = classify(record),
           "golden N-1 frame rejected: #{record["name"]}"

    assert request.method == record["method"]
  end

  defp assert_classified(%{"expect" => "response"}), do: :ok

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

  defp enum_of(%{"enum" => enum}), do: enum
  defp enum_of(%{"oneOf" => [%{"enum" => enum} | _rest]}), do: enum

  defp stringify_values(minimums) do
    Map.new(minimums, fn {method, minimum} -> {method, minimum} end)
  end

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
