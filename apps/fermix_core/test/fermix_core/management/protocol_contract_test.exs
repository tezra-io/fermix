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
  alias FermixCore.Capabilities.MCP.Config, as: McpConfig
  alias FermixCore.Capabilities.MCP.RuntimeStatus
  alias FermixCore.Cues.Config, as: CuesConfig
  alias FermixCore.Jobs.Registry, as: JobsRegistry
  alias FermixCore.Management.Cues.MandateRow, as: CueMandateRow
  alias FermixCore.Management.Cues.SourceRow, as: CueSourceRow
  alias FermixCore.Management.Cues.WatcherRow, as: CueWatcherRow
  alias FermixCore.Management.Detect
  alias FermixCore.Management.Doctor
  alias FermixCore.Management.Doctor.Descriptor
  alias FermixCore.Management.Doctor.Remediation
  alias FermixCore.Management.Jobs
  alias FermixCore.Management.Lifecycle
  alias FermixCore.Management.Logs
  alias FermixCore.Management.McpServers.Candidate
  alias FermixCore.Management.McpServers.Draft, as: McpDraft
  alias FermixCore.Management.McpServers.DraftValues
  alias FermixCore.Management.McpServers.ImportSources
  alias FermixCore.Management.McpServers.Interchange
  alias FermixCore.Management.McpServers.PastedValues
  alias FermixCore.Management.McpServers.Row, as: McpRow
  alias FermixCore.Management.Plugins.Row, as: PluginRow
  alias FermixCore.Management.Protocol
  alias FermixCore.Management.Router
  alias FermixCore.Management.Settings
  alias FermixCore.Management.Settings.Row
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.CuesSql
  alias FermixCore.Readiness
  alias FermixCore.Setup.ConfigStore
  alias FermixTestSupport.CueFixtures
  alias FermixTestSupport.MandateFixtures
  alias FermixTestSupport.SafeRm

  @protocol_doc Application.app_dir(:fermix_core, "priv/management/PROTOCOL.md")
  @schema_path Application.app_dir(:fermix_core, "priv/management/protocol.schema.json")
  @requests Application.app_dir(:fermix_core, "priv/management/fixtures/requests.jsonl")
  @successes Application.app_dir(:fermix_core, "priv/management/fixtures/success.jsonl")
  @errors Application.app_dir(:fermix_core, "priv/management/fixtures/errors.jsonl")
  @compatibility Application.app_dir(:fermix_core, "priv/management/fixtures/compatibility.jsonl")

  @mcp_router_toml ~S"""
  [mcp.servers.filesystem]
  command = "/bin/sh"
  args = ["serve.sh"]
  origin = "added"

  [mcp.servers.linear]
  transport = "http"
  url = "https://mcp.linear.app/mcp"
  auth = "none"
  origin = "added"
  """

  # The servers the golden rows illustrate, as a hand edit would hold them.
  @mcp_golden_toml ~S"""
  [mcp.servers.context7]
  transport = "http"
  url = "https://mcp.context7.com/mcp"
  auth = "header"
  key_header = "CONTEXT7_API_KEY"
  header_secrets = ["CONTEXT7_API_KEY"]
  origin = "added"

  [mcp.servers.filesystem]
  command = "npx"
  args = ["-y", "@modelcontextprotocol/server-filesystem", "/Users/owner/Documents"]
  origin = "added"

  [mcp.servers.github]
  transport = "http"
  url = "https://api.githubcopilot.com/mcp/"
  origin = "added"

  [mcp.servers.linear]
  transport = "http"
  url = "https://mcp.linear.app/mcp"
  auth = "header"
  key_header = "Authorization"
  header_secrets = ["Authorization"]
  origin = "added"

  [mcp.servers.linear.tools.delete_comment]
  hidden_from_agent = true

  [mcp.servers.linear.tools.update_project]
  hidden_from_agent = true

  [mcp.servers.notes]
  command = "node"
  args = ["index.js"]
  cwd = "/Users/owner/mcp/notes-server"
  enabled = false

  [mcp.servers.postgres]
  command = "uvx"
  args = ["postgres-mcp", "--access-mode=restricted"]
  env_secrets = ["DATABASE_URI"]
  origin = "added"
  """

  # The server the sign-in goldens illustrate: a remote one that signs in by
  # itself (M74 E5).
  @mcp_sign_in_toml ~S"""
  [mcp.servers.linear]
  transport = "http"
  url = "https://mcp.linear.app/mcp"
  origin = "added"
  """

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

  # The app models its panes as exactly the schema's set and refuses a pane
  # outside it, so every pane this daemon can serve (a settings section's, or a
  # readiness failure's) must be in the enum. The browser section shipped with
  # a pane the schema did not list.
  test "every pane a section or a readiness failure names is in the schema's pane enum", %{
    schema: schema
  } do
    enum = schema["$defs"]["settingsPane"]["enum"]
    section_panes = for %{pane: pane} <- Settings.sections(), do: pane
    outside = Enum.uniq(section_panes ++ Readiness.panes()) -- enum

    assert outside == [],
           "the daemon serves panes the schema does not list: #{inspect(outside)}"
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

  # The iMessage grant and confirmation goldens are terminal job views, because
  # each job's whole answer is the probe it finishes with (plus, for a
  # confirmation, its outcome). Each runs the real job against the live registry
  # with only the helper injected.
  test "the golden iMessage grant and confirmation results are the ones their jobs finish with" do
    cases = [
      {"imessage.grant.start", %{"service" => "automation"}},
      {"imessage.policy.confirm", %{}}
    ]

    for {method, params} <- cases do
      jobs = jobs()
      request = %{request_id: "req-1", protocol_version: 2, method: method, params: params}
      opts = [operation_opts: [jobs: jobs] ++ imessage_sources()]

      assert {:ok, started} = Router.route(request, opts)
      assert {:ok, finished} = eventually_terminal(jobs, started["job_id"])

      assert finished["status"] == "completed"
      assert shape(finished) == shape(fixture_result(method, params))
    end
  end

  # The browser download's goldens are its two terminal views: the one a client
  # reads the browser's name from, and the one it reads the daemon's sentence
  # from. Each is the job the real run finishes with, against the live registry,
  # with only the downloads and the launcher's answer injected.
  test "the golden browser download views are the ones its job finishes with" do
    installed = fn -> {:ok, "/tmp/fermix-meetbot"} end
    found = fn -> {:ok, %{path: "/tmp/chrome", label: "Google Chrome for Testing"}} end

    cases = [
      {"job_get_browser_install_completed", fn -> {:ok, :installed} end, "completed"},
      {"job_get_browser_install_failed", fn -> {:error, {:browser_install_failed, 1}} end,
       "failed"}
    ]

    for {golden, install_browser, status} <- cases do
      jobs = jobs()

      opts = [
        operation_opts: [
          jobs: jobs,
          install: installed,
          install_browser: install_browser,
          resolve: found
        ]
      ]

      request = %{
        request_id: "req-1",
        protocol_version: 2,
        method: "browser.install.start",
        params: %{}
      }

      assert {:ok, started} = Router.route(request, opts)
      assert {:ok, finished} = eventually_terminal(jobs, started["job_id"])
      expected = named_fixture_result(golden)

      assert finished["status"] == status
      assert finished["kind"] == expected["kind"]
      assert shape(finished) == shape(expected)
    end
  end

  # The section inventory is what three consumers walk, so a fixture that lists
  # a section the daemon does not serve, or omits one it does, is a client
  # rendering a pane that answers nothing.
  # The export is the Mac's inventory: `channels.imessage` exists only there
  # (M54 §12), and the app that vendors this contract is a Mac app. The host is
  # named rather than inherited so every CI leg compares the same list.
  #
  # Provider sections are the exception: there is one per descriptor, and which
  # providers exist is data every app reads from the daemon, not wire shape. The
  # golden illustrates some of them, so a provider added to the engine moves no
  # export an app vendors.
  test "the golden section inventory is the one the daemon publishes" do
    published = Enum.map(Settings.sections(macos?: true), & &1.id)

    fixture =
      "settings.sections"
      |> fixture_result(%{})
      |> Map.fetch!("sections")
      |> Enum.map(& &1["id"])

    {fixture_providers, fixture_rest} = Enum.split_with(fixture, &provider_section?/1)
    {published_providers, published_rest} = Enum.split_with(published, &provider_section?/1)

    assert fixture_rest == published_rest
    assert fixture_providers -- published_providers == []
  end

  # The goldens illustrate the wire, not the catalog. A provider section's Model
  # row shows example options, and the models a daemon offers are data every app
  # reads at runtime (`settings_test.exs` pins the live row to `ModelCatalog`),
  # so a model added to the catalog moves no export an app vendors. What a golden
  # must still do is hold a value one of its own options can show: the app's
  # choice control drew a blank popup for `gpt-6-astra` while the golden's
  # options began at `gpt-5.6-sol`.
  test "every golden provider section holds one of its own models" do
    for fixture <- fixtures(@successes),
        String.starts_with?(fixture["name"], "settings_get_providers_") do
      result = fixture["response"]["result"]
      row = Enum.find(result["rows"], &(&1["key"] == "default_model"))

      assert_holds_offered_model(row, result["id"])
    end
  end

  defp provider_section?(id), do: String.starts_with?(id, "providers.")

  # The voice section's rows depend on the engine, and the section's first
  # golden runs the default one, so the rows only Live publishes (its backend
  # and whether calls join the chat, M56 §6) have a golden of their own. It is
  # the producer's own answer for a Live block: the same rows in the same
  # order, and the conversation row exactly.
  test "the golden Live voice section is the one the daemon publishes under Live" do
    realtime = [enabled: false, engine: "openai_live", model: "gpt-live-1", voice: "marin"]
    providers = [openai: [primary: true, default_model: "gpt-5.4"]]

    snapshot =
      Map.update(ConfigStore.current_snapshot(), :fermix_core, [], fn core ->
        core
        |> Keyword.put(:realtime, realtime)
        |> Keyword.put(:providers, providers)
        |> Keyword.put(:agent, [])
      end)

    {:ok, live} = Settings.get("realtime", snapshot: snapshot)
    golden = named_fixture_result("settings_get_realtime_live")

    assert Enum.map(golden["rows"], & &1["key"]) == Enum.map(live["rows"], & &1["key"])

    assert Enum.find(golden["rows"], &(&1["key"] == "realtime_conversation")) ==
             Enum.find(live["rows"], &(&1["key"] == "realtime_conversation"))
  end

  # Grok (M70 §06) publishes the task-engine rows Live does, its own voices, and
  # the SpaceXAI provider's key row where the other engines publish OpenAI's, so
  # its section has a golden of its own: the same rows in the same order, and
  # the rows only Grok words its own way exactly.
  test "the golden Grok voice section is the one the daemon publishes under Grok" do
    realtime = [enabled: false, engine: "xai_realtime", model: "grok-voice-3.0", voice: "eve"]
    providers = [openai: [primary: true, default_model: "gpt-5.4"], xai: [api_key: "xai-test"]]

    snapshot =
      Map.update(ConfigStore.current_snapshot(), :fermix_core, [], fn core ->
        core
        |> Keyword.put(:realtime, realtime)
        |> Keyword.put(:providers, providers)
        |> Keyword.put(:agent, [])
      end)

    {:ok, grok} = Settings.get("realtime", snapshot: snapshot)
    golden = named_fixture_result("settings_get_realtime_grok")

    assert Enum.map(golden["rows"], & &1["key"]) == Enum.map(grok["rows"], & &1["key"])

    for key <- ~w(realtime_model realtime_voice realtime_backend xai_api_key) do
      assert Enum.find(golden["rows"], &(&1["key"] == key)) ==
               Enum.find(grok["rows"], &(&1["key"] == key)),
             key
    end
  end

  # A provider whose models are discovered live (OpenAI Codex) ships no catalog,
  # so its section offers nothing and holds the empty value until one is chosen.
  defp assert_holds_offered_model(%{"options" => [], "value" => value}, id),
    do: assert(value == "", id)

  defp assert_holds_offered_model(row, id),
    do: assert(Enum.any?(row["options"], &(&1["value"] == row["value"])), id)

  # Every kind and format a row may carry is pinned to the module, so a kind
  # added in Elixir fails here rather than reaching a client that cannot render
  # it.
  # The router publishes `realtime.engine` on the overview and the golden
  # carries it; the schema must declare it too, or the app decodes a field the
  # contract never promised (the declaration was lost once in a merge).
  test "the overview's realtime object declares the engine field", %{schema: schema} do
    realtime = schema["$defs"]["overview_get_result"]["properties"]["realtime"]

    assert Map.has_key?(realtime["properties"], "engine")
    assert "engine" in realtime["required"]
  end

  test "the schema's row vocabulary matches the settings module", %{schema: schema} do
    row = schema["$defs"]["settingsRow"]["properties"]
    %{kinds: kinds, formats: formats} = Settings.vocabulary()

    assert row["kind"]["enum"] == Enum.map(kinds, &Atom.to_string/1)
    assert row["format"]["enum"] == Enum.map(formats, &Atom.to_string/1) ++ [nil]
  end

  # The row contract is "every field is always present", and the schema closes
  # the object, so a field added in Elixir and not declared here is a frame the
  # app's own validator refuses. Pinned to a built row rather than to a golden:
  # the builder is what mints the shape, and a golden can only lag it.
  test "the schema declares exactly the fields a row carries", %{schema: schema} do
    settings_row = schema["$defs"]["settingsRow"]
    fields = "key" |> Row.new(:text, "Label", restart: false) |> Map.keys() |> Enum.sort()

    assert settings_row["additionalProperties"] == false
    assert Enum.sort(settings_row["required"]) == fields
    assert settings_row["properties"] |> Map.keys() |> Enum.sort() == fields
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
    assert published["setting_kinds"] == PluginRow.setting_kinds()
  end

  # An MCP server row's closed sets are published once, beside the plugin
  # vocabulary, and pinned to the builder that mints them (M74 §5).
  test "the schema's MCP server vocabulary matches the row builder", %{schema: schema} do
    published = schema["x-mcp-server-vocabulary"]
    defs = schema["$defs"]

    assert published["statuses"] == Enum.map(McpRow.statuses(), &Atom.to_string/1)
    assert published["actions"] == McpRow.actions()
    assert published["auth_states"] == McpRow.auth_states()
    assert defs["mcpServerAction"]["enum"] == McpRow.actions()

    assert defs["mcpServerRow"]["properties"]["auth"]["properties"]["state"]["enum"] ==
             McpRow.auth_states()
  end

  # The row is "every field always present" and the schema closes it, so a
  # field added in Elixir and not declared is a frame the app refuses. `tools`
  # is the one field only `mcp.servers.get` carries.
  test "the schema declares exactly the fields an MCP server row carries", %{schema: schema} do
    row_def = schema["$defs"]["mcpServerRow"]
    tool_def = schema["$defs"]["mcpServerTool"]
    [server] = McpConfig.from_toml(@mcp_router_toml) |> Enum.filter(&(&1.name == "linear"))
    tools = [%{name: "t", title: nil, description: nil, read_only: false, destructive: false}]

    entry = %{
      mcp_entry(:ready, nil)
      | discovery: %{tool_count: 1, server_info: nil, tools: tools}
    }

    row = McpRow.build(server, mcp_facts(%{entry: entry}), tools?: true)
    fields = row |> Map.delete("tools") |> Map.keys() |> Enum.sort()

    assert row_def["additionalProperties"] == false
    assert Enum.sort(row_def["required"]) == fields
    assert row_def["properties"] |> Map.keys() |> Enum.sort() == Enum.sort(["tools" | fields])
    assert Enum.sort(tool_def["required"]) == row["tools"] |> hd() |> Map.keys() |> Enum.sort()
  end

  # The golden rows are what the builder writes for the facts they illustrate,
  # sentences included, so a word changed in Elixir fails here rather than
  # reaching an app that renders the golden's.
  test "the golden MCP server rows are the ones the row builder writes" do
    servers = Map.new(McpConfig.from_toml(@mcp_golden_toml), &{&1.name, &1})
    get = named_fixture_result("mcp_servers_get")["server"]
    facts = mcp_golden_facts(Enum.map(get["tools"], &tool_metadata/1))
    build = fn name, opts -> McpRow.build(servers[name], facts[name], opts) end

    assert named_fixture_result("mcp_servers_list")["servers"] ==
             Enum.map(~w(filesystem github linear notes postgres), &build.(&1, []))

    assert get == build.("linear", tools?: true)
    assert named_fixture_result("mcp_servers_add_remote_key")["server"] == build.("context7", [])
  end

  # A signed-in row and an expired one, from the grant facts `OAuth.Grant`
  # reads (M74 E5), sentences, actions, account and issuer included.
  test "the golden signed-in and expired MCP server rows are the ones the row builder writes" do
    [server] = McpConfig.from_toml(@mcp_sign_in_toml)
    signed_in = named_fixture_result("mcp_servers_get_signed_in")["server"]

    discovery = %{
      tool_count: 2,
      server_info: info("linear", "Linear", "1.4.2"),
      tools: Enum.map(signed_in["tools"], &tool_metadata/1)
    }

    grant = %{
      state: :signed_in,
      account_label: "owner@example.com",
      issuer: "https://mcp.linear.app",
      wanted_scopes: []
    }

    ready =
      mcp_facts(%{
        entry: %{mcp_entry(:ready, nil) | discovery: discovery},
        alive?: true,
        grant: grant
      })

    asked = %{mcp_entry(:reauthorization_required, :sign_in_required) | discovery: discovery}
    expired = mcp_facts(%{entry: asked, grant: %{grant | state: :expired}})

    assert signed_in == McpRow.build(server, ready, tools?: true)

    assert named_fixture_result("mcp_servers_get_expired")["server"] ==
             McpRow.build(server, expired, tools?: true)
  end

  # `auth.start mcp:linear`, the job it starts read while it discovers and once
  # it completed, `auth.logout mcp:linear`, and the refusals, each driven
  # through the router with only the sign-in itself stood in for. The job id
  # and the clock are the daemon's, so they are the golden's only free fields.
  test "the golden MCP sign-in answers are the ones the router writes" do
    servers = McpConfig.from_toml(@mcp_sign_in_toml)
    jobs = jobs()
    test = self()

    login = fn %{name: "linear"}, login_opts ->
      Keyword.fetch!(login_opts, :phase).("discovering")
      send(test, {:discovering, self()})
      receive do: (:go -> :ok)
      Keyword.fetch!(login_opts, :phase).("registering")

      :ok =
        Keyword.fetch!(login_opts, :opener).(
          named_fixture_result("auth_start_mcp")["authorize_url"]
        )

      receive do: (:finish -> {:ok, %{account_label: "owner@example.com"}})
    end

    opts = [operation_opts: [jobs: jobs, servers: fn -> servers end, mcp_login: login]]

    start =
      Task.async(fn ->
        Router.route(request("auth.start", %{"provider" => "mcp:linear"}), opts)
      end)

    assert_receive {:discovering, run}

    {:ok, [%{"job_id" => job_id}]} = Jobs.list(jobs)
    {:ok, view} = Router.route(request("job.get", %{"job_id" => job_id}), opts)
    assert view == volatile(named_fixture_result("job_get_auth_discovering"), view)

    send(run, :go)
    assert {:ok, started} = Task.await(start)
    assert started == volatile(named_fixture_result("auth_start_mcp"), started)

    send(run, :finish)
    {:ok, _terminal} = eventually_terminal(jobs, job_id)
    {:ok, completed} = Router.route(request("job.get", %{"job_id" => job_id}), opts)
    assert completed == volatile(named_fixture_result("job_get_auth_completed"), completed)

    logout_opts = [
      operation_opts: [
        servers: fn -> servers end,
        mcp_forget: fn "linear" -> :ok end,
        mcp_supervisor: __MODULE__.FakeMcpTree
      ]
    ]

    {:ok, logout} =
      Router.route(request("auth.logout", %{"provider" => "mcp:linear"}), logout_opts)

    assert logout == %{"restart" => Settings.restart()}
    assert shape(logout) == shape(named_fixture_result("auth_logout_mcp"))
  end

  test "the golden MCP sign-in refusals are the ones the router answers" do
    servers =
      McpConfig.from_toml(~S"""
      [mcp.servers.files]
      command = "/bin/sh"

      [mcp.servers.keyed]
      transport = "http"
      url = "https://mcp.example.com/mcp"
      auth = "header"
      key_header = "X-Key"
      header_secrets = ["X-Key"]

      [mcp.servers.open]
      transport = "http"
      url = "https://mcp.example.com/mcp"
      auth = "none"
      """)

    opts = [operation_opts: [servers: fn -> servers end]]

    for {name, provider} <- [
          {"invalid_params_auth_start_mcp_unknown", "mcp:linear"},
          {"invalid_params_auth_start_mcp_stdio", "mcp:files"},
          {"invalid_params_auth_start_mcp_key", "mcp:keyed"},
          {"invalid_params_auth_start_mcp_none", "mcp:open"}
        ] do
      assert {:error, :invalid_params, details} =
               Router.route(request("auth.start", %{"provider" => provider}), opts)

      assert details == golden_error_details(name), name
    end
  end

  defp request(method, params),
    do: %{request_id: "req-1", protocol_version: 2, method: method, params: params}

  # The golden with the fields only the live job can know taken from it.
  defp volatile(golden, live),
    do: Map.merge(golden, Map.take(live, ["job_id", "started_at", "finished_at"]))

  # A draft is "every field always present" and the schema closes it, as it
  # closes the row.
  test "the schema declares exactly the fields an MCP server draft carries", %{schema: schema} do
    draft_def = schema["$defs"]["mcpServerDraft"]
    {:ok, [translated]} = Interchange.translate("uvx mcp-server-fetch", "/Users/owner")

    fields =
      translated
      |> McpDraft.build(%{resolution: nil, conflict: false, draft_id: nil})
      |> Map.keys()

    assert draft_def["additionalProperties"] == false
    assert Enum.sort(draft_def["required"]) == Enum.sort(fields)
    assert draft_def["properties"] |> Map.keys() |> Enum.sort() == Enum.sort(fields)
  end

  # The golden drafts are what the translator and the draft builder write for
  # the text each one's request sends, sentences and names included. The facts
  # beside the text are the golden's own: where its command resolves (the
  # sentence for a program this Mac lacks is the builder's), and the id its
  # values are held under, present exactly where the draft carried a value.
  test "the golden MCP server drafts are the ones the translator and the builder write" do
    goldens = ~w(
      mcp_servers_draft_url mcp_servers_draft_command mcp_servers_draft_command_uvx
      mcp_servers_draft_command_not_found mcp_servers_draft_pasted_config
      mcp_servers_draft_claude_add mcp_servers_draft_codex
    )

    for name <- goldens do
      text = named_request(name)["frame"]["params"]["text"]
      drafts = named_fixture_result(name)["drafts"]
      assert {:ok, translated} = Interchange.translate(text, "/Users/owner"), name
      assert length(translated) == length(drafts), name

      for {server, golden} <- Enum.zip(translated, drafts) do
        assert is_binary(golden["draft_id"]) == not PastedValues.empty?(server.values), name
        assert McpDraft.build(server, golden_draft_facts(server, golden)) == golden, name
      end
    end
  end

  test "the golden draft refusals are the ones the router answers" do
    holder = start_supervised!({DraftValues, name: :"contract_drafts_#{unique()}"})

    for {name, request} <- [
          {"invalid_params_mcp_servers_draft_text",
           {"mcp.servers.draft", %{"text" => ~s({"editor.fontSize": 14})}}},
          {"invalid_params_mcp_servers_add_draft_id",
           {"mcp.servers.add", named_request("mcp_servers_add_draft")["frame"]["params"]}}
        ] do
      {method, params} = request
      route = %{request_id: "req-1", protocol_version: 2, method: method, params: params}

      assert {:error, :invalid_params, details} =
               Router.route(route, operation_opts: [draft_values: holder])

      assert details == golden_error_details(name)
    end
  end

  # A candidate is "every field always present" and the schema closes it; the
  # skipped and refused entries are closed to the keys their goldens, pinned to
  # the import's own answers, carry.
  test "the schema declares exactly the fields an MCP import answers", %{schema: schema} do
    defs = schema["$defs"]
    {:ok, source} = ImportSources.fetch("cursor")

    {:ok, translated} =
      Interchange.translate_server(:toml, "fetch", %{"command" => "sh"}, "/Users/owner")

    candidate = Candidate.build(source, translated, %{resolution: nil, conflict: false})
    scan = named_fixture_result("mcp_servers_import_scan")
    import = named_fixture_result("mcp_servers_import")

    closed = fn name ->
      {defs[name]["additionalProperties"], Enum.sort(defs[name]["required"])}
    end

    assert closed.("mcpImportCandidate") == {false, candidate |> Map.keys() |> Enum.sort()}

    assert closed.("mcpImportSkipped") ==
             {false, scan["skipped"] |> hd() |> Map.keys() |> Enum.sort()}

    refused = defs["mcp_servers_import_result"]["properties"]["refused"]["items"]

    assert Enum.sort(refused["required"]) ==
             import["refused"] |> hd() |> Map.keys() |> Enum.sort()

    assert defs["mcpImportSource"]["enum"] == ImportSources.ids()
  end

  test "the golden import refusal is the one the router answers" do
    route = %{
      request_id: "req-1",
      protocol_version: 2,
      method: "mcp.servers.import",
      params: %{"servers" => []}
    }

    assert {:error, :invalid_params, details} = Router.route(route)
    assert details == golden_error_details("invalid_params_mcp_servers_import_servers")
  end

  # The cue rows are "every field always present" and the schema closes them,
  # so a field added in Elixir and not declared is a frame the app refuses.
  # Pinned to the goldens, which `CuesTest` and the router cases above pin to
  # the builders.
  test "the schema declares exactly the fields the cue rows carry", %{schema: schema} do
    defs = schema["$defs"]

    rows = [
      {"cueSourceRow", named_fixture_result("cues_sources_list")["sources"] |> hd()},
      {"cueWatcherRow", named_fixture_result("cues_watchers_list")["watchers"] |> hd()},
      {"cueWatcherDetail", named_fixture_result("cues_watchers_get")["watcher"]},
      {"cueMandateRow", named_fixture_result("cues_mandates_list")["mandates"] |> hd()},
      {"cueProposalRecord", named_fixture_result("cues_proposals_list")["proposals"] |> hd()},
      {"cueProposalCard", named_fixture_result("cues_proposals_get")["proposal"]}
    ]

    for {name, row} <- rows do
      fields = row |> Map.keys() |> Enum.sort()

      assert defs[name]["additionalProperties"] == false, name
      assert Enum.sort(defs[name]["required"]) == fields, name
      assert defs[name]["properties"] |> Map.keys() |> Enum.sort() == fields, name
    end
  end

  test "the schema's cue vocabulary matches the row builders", %{schema: schema} do
    published = schema["x-cue-vocabulary"]
    defs = schema["$defs"]

    assert published["source_states"] == CueSourceRow.states()
    assert published["source_actions"] == CueSourceRow.actions()
    assert published["watcher_states"] == CueWatcherRow.states()
    assert published["mandate_actions"] == CueMandateRow.actions()
    assert defs["cueSourceAction"]["enum"] == CueSourceRow.actions()
    assert defs["cueMandateAction"]["enum"] == CueMandateRow.actions()

    assert defs["cueProposalRecord"]["properties"]["state"]["enum"] ==
             published["proposal_states"]
  end

  # One golden per state a proposal can be in, so the app draws each card.
  test "the golden proposal cards cover every proposal state", %{schema: schema} do
    states =
      @successes
      |> fixtures()
      |> Enum.filter(&(&1["method"] == "cues.proposals.get"))
      |> Enum.map(& &1["response"]["result"]["proposal"]["state"])
      |> Enum.sort()

    assert states == Enum.sort(schema["x-cue-vocabulary"]["proposal_states"])
  end

  test "every golden cue row routes on its own closed actions" do
    for record <- fixtures(@successes),
        String.starts_with?(record["method"], "cues."),
        row <- cue_rows_in(record["response"]["result"]) do
      allowed =
        if Map.has_key?(row, "ref"), do: CueSourceRow.actions(), else: CueMandateRow.actions()

      assert Enum.all?(row["actions"], &(&1 in allowed)), record["name"]

      assert is_nil(row["primary_action"]) or row["primary_action"] in row["actions"],
             record["name"]
    end
  end

  defp cue_rows_in(%{"sources" => rows}) when is_list(rows), do: rows
  defp cue_rows_in(%{"mandates" => rows}) when is_list(rows), do: rows
  defp cue_rows_in(%{"source" => row}) when is_map(row), do: [row]
  defp cue_rows_in(%{"mandate" => row}) when is_map(row), do: [row]
  defp cue_rows_in(_result), do: []

  test "every golden MCP server row routes on its own closed actions", %{schema: schema} do
    published = schema["$defs"]["mcpServerAction"]["enum"]
    rows = golden_mcp_rows()

    assert length(rows) >= 10

    for row <- rows do
      assert Enum.all?(row["actions"], &(&1 in published)), row["name"]
      assert is_nil(row["primary_action"]) or row["primary_action"] in row["actions"], row["name"]
    end
  end

  defp golden_mcp_rows do
    @successes
    |> fixtures()
    |> Enum.filter(&String.starts_with?(&1["method"], "mcp.servers."))
    |> Enum.flat_map(&mcp_rows_in(&1["response"]["result"]))
  end

  defp mcp_rows_in(%{"servers" => rows}) when is_list(rows), do: rows
  defp mcp_rows_in(%{"server" => row}) when is_map(row), do: [row]
  defp mcp_rows_in(_result), do: []

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

    setting = schema["$defs"]["pluginSetting"]["properties"]
    assert enum_of(setting["kind"]) == PluginRow.setting_kinds()
  end

  # A setting's kind is what picks the control the app draws, so a golden entry
  # without one is a row the far side renders by guessing. Walked over every
  # settings entry in the export rather than the one the shape comparison
  # happens to reach, which is only the head of each list.
  test "every golden setting entry publishes a kind from the closed set" do
    settings = golden_plugin_rows() |> Enum.flat_map(& &1["settings"])

    assert settings != [], "no golden plugin row illustrates a setting"

    for setting <- settings do
      assert setting["kind"] in PluginRow.setting_kinds(),
             "a golden setting publishes #{inspect(setting["kind"])} as its kind"
    end
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
      {"imessage.permissions.get", %{}, [operation_opts: imessage_sources()]},
      # The listing runs against the daemon's own registry and baked catalog with
      # no seam at all: it reads and writes nothing, so the shape under test is
      # the live projection rather than an injected stand-in.
      {"plugins.list", %{}, []}
    ] ++
      settings_cases() ++
      job_view_cases() ++ flow_cases() ++ mobile_cases() ++ mcp_cases() ++ cues_cases()
  end

  # Stands in for `Cues.Proposals` with the record and the card in the shape
  # `Cues.ProposalView` mints, so the proposal reads and the answer are
  # compared without a proposal of their own in the Repo.
  defmodule FakeProposals do
    @moduledoc false

    def records(_which, _opts), do: {:ok, [record("waiting")]}

    def card(id, _opts) do
      card =
        Map.merge(record("waiting"), %{
          proposal_id: id,
          received_at: "2026-10-17T11:49:58Z",
          summary: "A task wants to run github_create_issue under your mandate release-issues.",
          outside: %{
            args_text: "{}",
            cue: %{type: "feed.item", subject: nil, text: "Invented.", occurred_at: nil}
          }
        })

      {:ok, card}
    end

    def decide(_id, _decision, _origin, _opts), do: {:ok, record("confirmed")}

    defp record(state) do
      %{
        proposal_id: "cpr_1",
        state: state,
        mandate: "release-issues",
        tool: "github_create_issue",
        task: %{job_id: "job_1", name: "Release watch"},
        watcher: "release-watch",
        source_ref: "eng-blogs",
        created_at: "2026-10-17T11:50:00Z",
        expires_at: "2026-10-17T12:20:00Z",
        decided_at: nil,
        decided_from: nil,
        result_status: nil,
        status_sentence: "Waiting for your answer; it runs only if you confirm."
      }
    end
  end

  # The cue reads against settings of this case's own (`:config`), a temp Repo
  # of its own and the proposal stand-in above; every write answers from a home
  # and is pinned to its golden in `CuesTest`.
  defp cues_cases do
    %{repo: repo, conn: conn} = CueFixtures.start_repo("contract")
    now = ~U[2026-10-17 12:00:00.000000Z]

    {:ok, job} =
      JobsRegistry.create_cue_job(
        %{
          name: "Release watch",
          task_prompt: "Open an issue for each release.",
          delivery_mode: "channel",
          delivery_target: %{"platform" => "telegram", "chat_id" => "4417"},
          created_by_trust: "operator"
        },
        repo: repo,
        scheduler: nil
      )

    watcher =
      CueFixtures.insert_watcher(conn, %{
        name: "release-watch",
        filter: "llm",
        sources: ["eng-blogs"]
      })

    CueFixtures.exec!(
      conn,
      "INSERT INTO cue_watcher_instructions (id, watcher_id, number, text, added_at) " <>
        "VALUES ('cwi_c1', ?, 1, 'Ignore opinion pieces.', '2026-10-12T09:00:00.000000Z')",
      [watcher]
    )

    for request <- [
          {:source_reject, "gh-hooks", %{"unauthorized" => 3}, now},
          {:extend_gap, "gh-hooks", nil, "rate_limited", 4, nil, now}
        ] do
      {:ok, _} = Repo.cues_call(CuesSql, request, server: repo)
    end

    config =
      CuesConfig.normalize(%{
        "enabled" => true,
        "sources" => %{
          "eng-blogs" => %{"preset" => "rss", "url" => "https://example.org/releases.atom"},
          "gh-hooks" => %{
            "preset" => "github",
            "secret" => "@keyring",
            "path_secret" => "@keyring"
          },
          "home-alerts" => %{"kind" => "local_push", "token" => "@keyring"}
        },
        "mandates" => %{
          "release-issues" => %{
            "job" => job.id,
            "mode" => "approve",
            "tools" => ["github_create_issue"],
            "read_tools" => ["github_search_issues"]
          }
        }
      })

    plugin = %{
      name: "github",
      tools: [%{"name" => "github_create_issue", "title" => "Create an issue", "request" => %{}}]
    }

    opts = [
      operation_opts: [
        cues: [
          available?: true,
          memory?: true,
          running?: true,
          config: config,
          repo: repo,
          door: :contract_cues_no_door,
          now: fn -> now end,
          proposals: FakeProposals,
          mandate_opts: [plugin_tool: MandateFixtures.plugin_tool()],
          plugins: fn -> {:ok, [plugin]} end,
          enabled_plugins: fn -> ["github"] end
        ]
      ]
    ]

    [
      {"cues.status", %{}, opts},
      {"cues.sources.list", %{}, opts},
      {"cues.sources.get", %{"ref" => "gh-hooks"}, opts},
      {"cues.sources.form", %{"preset" => "github"}, opts},
      {"cues.watchers.list", %{}, opts},
      {"cues.watchers.get", %{"name" => "release-watch"}, opts},
      {"cues.mandates.list", %{}, opts},
      {"cues.mandates.choices", %{}, opts},
      {"cues.proposals.list", %{}, opts},
      {"cues.proposals.get", %{"proposal_id" => "cpr_1"}, opts},
      {"cues.proposals.decide", %{"proposal_id" => "cpr_1", "decision" => "confirm"}, opts}
    ]
  end

  # Stands in for the MCP tree: every server's subtree runs and answers one
  # tool. Nothing else is asked of it by a read or a check of a ready server.
  defmodule FakeMcpTree do
    @moduledoc false

    def subtree_alive?(_source_id), do: true
    def list_tools(_source_id, _server), do: {:ok, [%{name: "create_issue"}]}
    def restart_server(_source_id, _server), do: {:ok, self()}
  end

  # The three MCP reads and the check against servers whose declared values are
  # none, so no store is read, and a status table of this case's own in which
  # both servers have connected. The four writes answer from a home and are
  # pinned to their goldens in `McpServersTest`.
  defp mcp_cases do
    status = start_supervised!({RuntimeStatus, name: :"contract_mcp_status_#{unique()}"})

    tools = [
      %{name: "create_issue", title: nil, description: nil, read_only: false, destructive: true}
    ]

    info = %{name: "linear", title: "Linear", version: "1.4.2"}

    for name <- ~w(filesystem linear) do
      owner = spawn_link(fn -> receive do: (:stop -> :ok) end)
      {:ok, generation} = RuntimeStatus.register_owner(status, {:operator, name}, owner)
      discovery = %{tool_count: 1, server_info: info, tools: tools}
      :ok = RuntimeStatus.put_ready(status, {:operator, name}, generation, discovery)
    end

    servers = McpConfig.from_toml(@mcp_router_toml)
    sources = [servers: fn -> servers end, runtime_status: status, mcp_supervisor: FakeMcpTree]

    [
      {"mcp.servers.list", %{}, [operation_opts: sources]},
      {"mcp.servers.get", %{"name" => "linear"}, [operation_opts: sources]},
      {"mcp.servers.draft", %{"text" => "https://mcp.linear.app/mcp"}, [operation_opts: sources]},
      {"mcp.servers.check.start", %{"name" => "linear"},
       [operation_opts: [jobs: jobs()] ++ sources]},
      {"mcp.servers.import.scan", %{}, [operation_opts: [import_home: import_home()] ++ sources]}
    ]
  end

  # A home of this case's own holding one app's server and another app's file
  # that does not parse, so a scan answers both lists; never the real home.
  defp import_home do
    home = SafeRm.make_tmp_dir!("contract-mcp-import")
    on_exit(fn -> SafeRm.rm_rf!(home) end)

    for {path, contents} <- [
          {".cursor/mcp.json",
           ~s({"mcpServers": {"fetch": {"command": "/bin/sh", "env": {"K": "v"}}}})},
          {".codeium/windsurf/mcp_config.json", ~s({"mcpServers": {},})}
        ] do
      File.mkdir_p!(Path.dirname(Path.join(home, path)))
      File.write!(Path.join(home, path), contents)
    end

    home
  end

  # Facts in the shape the phone channel hands over. `pair_get` answers a phone
  # waiting for a decision, the state whose request the golden illustrates.
  defmodule FakeMobileProvider do
    @moduledoc false

    @session_id "5b0c7d2e-8f41-4a6b-9c3d-2e7f1a8b4c60"
    @device_id "3f4a1a55-69a0-4f8a-9132-17d6ac728f84"

    def status(_opts) do
      {:ok,
       %{
         enabled: true,
         started: true,
         refused: false,
         refusal: nil,
         listener: %{
           status: :ready,
           reason: nil,
           port: 4031,
           bind: "0.0.0.0",
           candidates: ["wss://192.168.1.20:4031/ws"]
         },
         mdns: :advertising,
         tailnet: %{detected: true, candidates: ["100.101.102.103"]},
         identity: %{present: true, fingerprint: "3f9a 1c2e 7b4d 05a8"},
         remote: %{
           state: :ready,
           endpoint_id: "79b5562e8fe654f94078b112e8a98ba7901f853ae695bed7e0e3910bad049664",
           relay: "https://us1.relay.fermix.ai/",
           connected: true,
           relay_error: nil,
           refused: %{busy: 0, alpn: 0, bridge_unreachable: 0}
         },
         apns: %{enabled: false, credentials: :missing, delivery: :down, reason: nil},
         fcm: %{enabled: false, credentials: :missing, delivery: :down, reason: nil},
         paired_devices: 1,
         protocol_version: 1,
         pairing: %{session_id: @session_id, state: :awaiting_decision}
       }}
    end

    def pair_start(_opts) do
      {:ok, %{session: session(:awaiting_scan, 120_000, nil, nil), uri: "fermix://pair?v=2"}}
    end

    def pair_get(_session_id, _opts),
      do: {:ok, session(:awaiting_decision, 83_400, request(), nil)}

    def pair_decide(_session_id, true, _opts),
      do: {:ok, session(:approved, nil, request(), %{device_id: @device_id})}

    def pair_cancel(_session_id, _opts),
      do: {:ok, session(:cancelled, nil, nil, %{reason: :cancelled})}

    def devices_list(_opts) do
      {:ok,
       [
         %{
           device_id: @device_id,
           name: "Sam's phone",
           model: "Google Pixel 9 Pro",
           platform: nil,
           signer_role: nil,
           boot_state: nil,
           push_registered: false,
           created_at: "2026-09-26T12:01:05Z",
           last_seen: "2026-09-26T12:04:40Z"
         }
       ]}
    end

    def devices_revoke(device_id, _opts), do: {:ok, %{device_id: device_id}}

    defp session(state, ttl_ms, request, outcome) do
      %{
        session_id: @session_id,
        state: state,
        ttl_ms: ttl_ms,
        request: request,
        outcome: outcome,
        failure: nil
      }
    end

    defp request do
      %{
        device_name: "Sam's phone",
        model: "Google Pixel 9 Pro",
        platform: "android",
        app_version: "1.0.0",
        sas: "481062",
        build_role: :release,
        boot_state: %{verified: true, locked: true},
        attestation: :verified
      }
    end
  end

  # The seven phone methods against the fake above: what is compared is the view
  # the adapter builds from the provider's facts, which is the daemon's own.
  defp mobile_cases do
    opts = [operation_opts: [mobile: [provider: FakeMobileProvider]]]
    session = %{"session_id" => "5b0c7d2e-8f41-4a6b-9c3d-2e7f1a8b4c60"}

    [
      {"mobile.status", %{}, opts},
      {"mobile.pair.start", %{}, opts},
      {"mobile.pair.get", session, opts},
      {"mobile.pair.decide", Map.put(session, "approved", true), opts},
      {"mobile.pair.cancel", session, opts},
      {"mobile.devices.list", %{}, opts},
      {"mobile.devices.revoke", %{"device_id" => "3f4a1a55-69a0-4f8a-9132-17d6ac728f84"}, opts}
    ]
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
      # The route write and the token-manager reload are seams like every other
      # one here, and leaving them live made this async case do two things to
      # daemon-wide state: rewrite the suite's `config.toml` through the real
      # `Wizard`, and start a permanent `anthropic_oauth` manager under
      # `Auth.TokenSupervisor`'s dynamic supervisor, which nothing reaps. The
      # golden result is the started view, so neither showed up here while the
      # leaked manager failed `AuthCompletionTest` three cases at a time.
      {"auth.import.start", %{"source" => "claude_code"},
       [
         operation_opts: [
           jobs: jobs(),
           importer: importer(),
           set_auth_mode: fn :anthropic, :oauth -> {:ok, %{}} end,
           reload: fn -> :ok end,
           promote: fn _id -> :ok end
         ]
       ]},
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
      {"meetings.signin.start", %{}, [operation_opts: [jobs: jobs()] ++ signin()]},
      {"browser.install.start", %{}, [operation_opts: [jobs: jobs(), install: fn -> block() end]]}
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
    for section <- Settings.sections(macos?: true),
        do: {"settings.get", %{"section" => section.id}, [macos?: true]}
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
        end,
        meetbot_installed: fn -> true end,
        meetbot_browser_installed: fn -> true end,
        meetbot_signed_in: fn -> true end
      ]
    ]
  end

  defp probe, do: fn :anthropic, _opts -> {:ok, %{model: "claude-opus-5", latency_ms: 812}} end

  defp permissions do
    %{state: :probed, screen_capture: true, input_control: false, platform: "macos"}
  end

  # Sources for the iMessage methods: the helper's probe, its stored policy and
  # the saved section, never a rendered view.
  defp imessage_sources do
    probe = %{
      helper_version: "0.1.0",
      full_disk_access: :granted,
      db: :readable,
      automation: :granted,
      messages_running: true,
      signed_in: true,
      user_session: true,
      policy: :confirmed,
      self_aliases: nil
    }

    policy = %{
      posture: :dedicated_account,
      owner_handle: "+15551234567",
      handles: ["+15551234567"],
      confirmed_at: "2026-10-03T12:00:00Z"
    }

    [
      macos?: true,
      installed?: fn -> true end,
      config: [owner_user_id: "+15551234567"],
      probe: fn -> {:ok, probe} end,
      grant: fn _service -> {:ok, probe} end,
      policy: fn -> {:ok, policy} end,
      policy_set: fn _policy ->
        {:ok, %{confirmed_at: "2026-10-03T12:00:00Z", posture: :dedicated_account}}
      end
    ]
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
      :ok = Keyword.fetch!(login_opts, :opener).("https://auth.example/authorize")
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

  defp named_request(name), do: @requests |> fixtures() |> Enum.find(&(&1["name"] == name))

  defp golden_draft_facts(server, golden) do
    resolution =
      case {server.server, golden["resolved_command"]} do
        {%{transport: :http}, nil} -> nil
        {_stdio, nil} -> {:error, {:command_not_found, server.server.command}}
        {_stdio, program} -> {:ok, program}
      end

    %{resolution: resolution, conflict: golden["conflict"], draft_id: golden["draft_id"]}
  end

  defp named_fixture_result(name) do
    @successes
    |> fixtures()
    |> Enum.find(&(&1["name"] == name))
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

  # What the daemon holds about each golden server: what is stored, its live
  # status and discovery, whether its subtree runs and where its command is.
  defp mcp_golden_facts(linear_tools) do
    linear = %{
      tool_count: 23,
      server_info: info("linear", "Linear", "1.4.2"),
      tools: linear_tools
    }

    fs_info = info("secure-filesystem-server", nil, "0.6.2")
    stopped = mcp_entry(:remote_unreachable, :shutdown)

    notes_discovery = %{
      tool_count: 4,
      server_info: info("notes-server", "Notes", "0.3.0"),
      tools: []
    }

    %{
      "context7" =>
        mcp_facts(%{
          presence: %{env: [], headers: [{"CONTEXT7_API_KEY", false}], client_secret: false}
        }),
      "filesystem" =>
        mcp_facts(%{
          entry: %{
            mcp_entry(:ready, nil)
            | discovery: %{tool_count: 11, server_info: fs_info, tools: []}
          },
          alive?: true,
          resolution: {:ok, "/opt/homebrew/bin/npx"}
        }),
      "github" => mcp_facts(%{entry: mcp_entry(:reauthorization_required, :sign_in_required)}),
      "linear" =>
        mcp_facts(%{
          presence: %{env: [], headers: [{"Authorization", true}], client_secret: false},
          entry: %{mcp_entry(:ready, nil) | discovery: linear},
          alive?: true
        }),
      "notes" =>
        mcp_facts(%{
          entry: %{stopped | discovery: notes_discovery},
          resolution: {:ok, "/opt/homebrew/bin/node"}
        }),
      "postgres" =>
        mcp_facts(%{
          presence: %{env: [{"DATABASE_URI", true}], headers: [], client_secret: false},
          entry: mcp_entry(:invalid_remote_config, :command_not_found),
          resolution: {:error, {:command_not_found, "uvx"}}
        })
    }
  end

  defp mcp_facts(facts) do
    Map.merge(
      %{
        presence: %{env: [], headers: [], client_secret: false},
        entry: nil,
        alive?: false,
        resolution: nil,
        grant: nil
      },
      facts
    )
  end

  defp mcp_entry(status, detail),
    do: %{status: status, detail: detail, subject: nil, discovery: nil, stderr_tail: []}

  defp info(name, title, version), do: %{name: name, title: title, version: version}

  defp tool_metadata(tool) do
    %{
      name: tool["name"],
      title: tool["title"],
      description: tool["description"],
      read_only: tool["read_only"],
      destructive: tool["destructive"]
    }
  end

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
        engine: "openai_realtime",
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
