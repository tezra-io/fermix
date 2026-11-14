defmodule FermixChannels.Desktop.TwoEnginesSettingsTest do
  @moduledoc """
  One set of settings after a move (M97 §19, D28), end to end: a linked
  computer's app speaks only its own `daemon.sock` (a real
  `Fermix.CLI.Daemon` in the device role with its desktop link), and each
  request is answered on the machine its id names, across the real relay,
  the primary's real `Mobile.Session`, its desktop peer and `manage` family
  and the primary's own `Fermix.CLI.Daemon`.

  Each daemon reads its own settings (`:snapshot`) and stores through its
  own writers, which tell the test which engine wrote what, so neither
  engine touches this VM's configuration and nothing is written to disk.
  Both engines say §19.3's rule as they do: the real session's `hello_ack`
  says `caps.computer.machine_settings`, the real relay's `hello` says it,
  and the primary's peer hands the hello's word to the `manage` family. An
  older engine is stood in for by a tag: `server_rule: false` answers the
  computer with an older server's `hello_ack`, and `computer_rule: false`
  serves the forwarded calls as for a computer whose hello said nothing
  (the session reading a hello without the flag is `DesktopSessionTest`'s).
  """

  use ExUnit.Case, async: true

  alias Fermix.CLI.Daemon
  alias Fermix.CLI.Daemon.Client
  alias FermixChannels.Desktop.Manage
  alias FermixChannels.Desktop.Relay
  alias FermixChannels.Mobile.Protocol
  alias FermixChannels.Test.DesktopRail
  alias FermixCore.Computers.Computer
  alias FermixCore.Management.Jobs

  @reply_ms 15_000
  @older_server "garden server runs an older Fermix, which takes its own sandbox and coding " <>
                  "settings only on the server. It updates on its own."

  setup ctx do
    test = self()
    task_supervisor = start_supervised!({Task.Supervisor, []}, id: :daemon_tasks)

    jobs = %{
      server: start_jobs!(:server, task_supervisor),
      computer: start_jobs!(:computer, task_supervisor)
    }

    server = start_daemon!(:server, task_supervisor, %{jobs: jobs.server}, [])
    older_computer? = Map.get(ctx, :computer_rule, true) == false

    serve = fn frame, computer ->
      send(test, {:served, Jason.decode!(frame)["method"]})
      send(test, {:computer_rule, computer.machine_settings})
      computer = if older_computer?, do: %{computer | machine_settings: false}, else: computer
      Daemon.serve_forwarded(frame, computer, server)
    end

    primary =
      DesktopRail.primary!(
        [families: %{manage: {Manage, serve: serve, task_supervisor: task_supervisor}}] ++
          older_server(ctx)
      )

    root = DesktopRail.desktop_home!(primary, name: "garden server")
    relay = DesktopRail.start_relay!(root, primary)
    DesktopRail.await_connected(relay)

    computer =
      start_daemon!(:computer, task_supervisor, %{jobs: jobs.computer, relay: relay},
        forwarding: [primary_forward: &Relay.forward(relay, &1, &2)]
      )

    %{socket: computer, relay: relay}
  end

  # The test that failed first (§19.13): a sandbox value typed in the
  # computer's own Sandbox pane was sent to the server like every secret, so
  # it was stored there while the pane went on drawing the computer's own
  # sandbox without it.
  test "a value typed in this computer's own sandbox is stored on this computer", ctx do
    own = own_sandbox!(ctx)
    key = env_key!(own, "LEDGER_TOKEN")

    assert {:ok, %{"id" => ^key}} =
             request(ctx, "secret.set", %{"id" => key, "value" => "ledger-7c41"})

    assert_receive {:stored, :computer, _id}
    refute_received {:stored, :server, _id}
  end

  test "Settings lists the server's sections and machine sections, then This Mac's", ctx do
    assert {:ok, %{"sections" => sections, "primary_missing" => nil}} =
             request(ctx, "settings.sections", %{})

    # Both said the rule themselves: the server's real hello_ack and the
    # computer's real hello, which its peer handed the forwarded call.
    assert %{machine_settings: true} = Relay.status(ctx.relay)
    assert_receive {:computer_rule, true}

    titles = Map.new(sections, &{&1["id"], {&1["pane"], &1["title"]}})

    assert titles["sandbox"] == {"sandbox", "Sandbox on garden server"}
    assert titles["browser"] == {"browser", "Browser on garden server"}
    assert titles["harness_machine"] == {"coding", "garden server"}
    assert titles["computer.sandbox"] == {"always_on", "Sandbox on this Mac"}
    assert titles["computer.browser"] == {"always_on", "Browser on this Mac"}
    assert titles["computer.computer_use"] == {"always_on", "Computer use on this Mac"}
    assert titles["computer.computer_history"] == {"always_on", "Computer history on this Mac"}
    assert titles["computer.accessories"] == {"always_on", "StackChan on this Mac"}
    assert titles["computer"] == {"always_on", "This computer"}

    # Nobody sits at the server: it lists no screen of its own, and the
    # computer lists no plain screen section beside its own.
    refute Map.has_key?(titles, "computer_use")
    refute Map.has_key?(titles, "computer_history")
    refute Map.has_key?(titles, "computer.harness_machine")
  end

  test "each machine section sent to the server is written there, and only there", ctx do
    writes = [
      {"sandbox", %{"sandbox_mode" => "standard"}},
      {"harness_machine", %{"harness_approved" => true}},
      {"browser", %{"browser_max_tabs" => 6}}
    ]

    for {section, values} <- writes do
      assert {:ok, %{"applied" => [_ | _]}} =
               request(ctx, "settings.apply", %{"section" => section, "values" => values})

      assert_receive {:applied, :server, ^section, ^values}
      refute_received {:applied, :computer, _section, _values}
    end

    # The server's sandbox and coding approval, changed from a computer, are
    # said on the server, naming the computer (§19.5); its browser is not.
    assert_received {:said, %{what: :sandbox_mode, value: "standard", computer: "studio Mac"}}
    assert_received {:said, %{what: :harness_approved, value: true, computer: "studio Mac"}}
    refute_received {:said, _change}

    assert {:ok, %{"id" => "env:GARDEN_TOKEN"}} =
             request(ctx, "secret.set", %{"id" => "env:GARDEN_TOKEN", "value" => "garden-19aa"})

    assert_receive {:stored, :server, "env:GARDEN_TOKEN"}
    refute_received {:stored, :computer, _id}

    assert {:ok, %{"id" => "sandbox", "title" => "Sandbox on garden server", "rows" => rows}} =
             request(ctx, "settings.get", %{"section" => "sandbox"})

    assert Enum.any?(rows, &(&1["key"] == "env:GARDEN_TOKEN"))
  end

  test "each of this computer's own sections is written here, and only here", ctx do
    writes = [
      {"computer.sandbox", "sandbox", %{"sandbox_mode" => "standard"}},
      {"computer.browser", "browser", %{"browser_max_tabs" => 3}},
      {"computer.computer_use", "computer_use", %{"computer_use_enabled" => true}}
    ]

    for {section, plain, values} <- writes do
      assert {:ok, %{"applied" => [_ | _]}} =
               request(ctx, "settings.apply", %{"section" => section, "values" => values})

      assert_receive {:applied, :computer, ^plain, ^values}
      refute_received {:applied, :server, _section, _values}
    end

    refute_received {:said, _change}

    assert {:ok, %{"id" => "computer.env:LEDGER_TOKEN"}} =
             request(ctx, "secret.clear", %{"id" => "computer.env:LEDGER_TOKEN"})

    assert_receive {:cleared, :computer, "env:LEDGER_TOKEN"}
    refute_received {:cleared, :server, _id}

    assert {:ok, %{"id" => "computer.sandbox", "title" => "Sandbox on this Mac", "rows" => rows}} =
             request(ctx, "settings.get", %{"section" => "computer.sandbox"})

    assert Enum.any?(rows, &(&1["key"] == "computer.env:LEDGER_TOKEN"))
    refute Enum.any?(rows, &(&1["key"] == "env:LEDGER_TOKEN"))
  end

  # An outside edit of this computer's own files is cleared here: its refusal
  # names this computer's section, and a reload of that section is this
  # computer's; a reload of a plain section, or of none, is the server's.
  test "an outside edit is named for its machine, and cleared there", ctx do
    assert {:error, {:management_error, "external_change", _message, details}} =
             request(ctx, "settings.apply", %{
               "section" => "computer.sandbox",
               "values" => %{"sandbox_profile" => "open"}
             })

    assert details == %{"section" => "computer.sandbox"}

    for {params, engine} <- [
          {%{"section" => "computer.sandbox"}, :computer},
          {%{"section" => "sandbox"}, :server},
          {%{}, :server}
        ] do
      assert {:ok, %{"reloaded" => true}} = request(ctx, "settings.reload", params)
      assert_receive {:reloaded, ^engine}
    end

    refute_received {:reloaded, _engine}
  end

  # A job is answered by the engine that started it: one this computer
  # started (an install of its own) names it, `computer.job:<id>`, and is
  # polled and cancelled here; one the server started is the server's.
  test "a job is polled and cancelled on the engine that started it", ctx do
    assert {:ok, %{"job_id" => "computer.job:" <> _rest = mine, "status" => "running"}} =
             request(ctx, "capabilities.install.start", %{"target" => "computer_use_sidecar"})

    assert_receive {:installing, :computer}, 10_000

    assert {:ok, %{"job_id" => ^mine, "status" => "running"}} =
             request(ctx, "job.get", %{"job_id" => mine})

    assert {:ok, %{"job_id" => ^mine, "status" => "cancelled"}} =
             request(ctx, "job.cancel", %{"job_id" => mine})

    refute_received {:served, "job." <> _method}
    refute_received {:served, "capabilities.install.start"}

    assert {:ok, %{"job_id" => "job:" <> _rest = theirs, "status" => "running"}} =
             request(ctx, "capabilities.install.start", %{"target" => "meetbot"})

    assert_receive {:served, "capabilities.install.start"}
    assert_receive {:installing, :server}, 10_000

    assert {:ok, %{"job_id" => ^theirs, "status" => "running"}} =
             request(ctx, "job.get", %{"job_id" => theirs})

    assert {:ok, %{"job_id" => ^theirs, "status" => "cancelled"}} =
             request(ctx, "job.cancel", %{"job_id" => theirs})

    assert_receive {:served, "job.get"}
    assert_receive {:served, "job.cancel"}
  end

  test "an id that is no section of this computer's is refused here, and nothing is sent", ctx do
    for section <- ["computer.providers.openai", "computer.harness_machine", "computer."] do
      assert {:error, {:management_error, "invalid_params", _message, %{"field" => "section"}}} =
               request(ctx, "settings.get", %{"section" => section}),
             section
    end

    assert {:error, {:management_error, "invalid_params", _message, %{"field" => "id"}}} =
             request(ctx, "secret.set", %{"id" => "computer.anthropic_api_key", "value" => "x"})

    refute_received {:stored, _engine, _id}
  end

  @tag server_rule: false
  test "a server without the rule is asked for none of its machine settings", ctx do
    assert {:ok, %{"sections" => sections}} = request(ctx, "settings.sections", %{})
    ids = Enum.map(sections, & &1["id"])

    refute "sandbox" in ids
    refute "harness_machine" in ids
    refute "browser" in ids
    assert "computer.sandbox" in ids

    for {method, params} <- [
          {"settings.get", %{"section" => "sandbox"}},
          {"settings.apply",
           %{"section" => "harness_machine", "values" => %{"harness_approved" => true}}},
          {"secret.set", %{"id" => "env:GARDEN_TOKEN", "value" => "garden-19aa"}}
        ] do
      assert {:error, {:management_error, "unavailable", _message, details}} =
               request(ctx, method, params)

      assert details == %{"capability" => "settings", "sentence" => @older_server}
    end

    refute_received {:applied, _engine, _section, _values}
    refute_received {:stored, _engine, _id}

    assert %{machine_settings: false, connected: true} = Relay.status(ctx.relay)
  end

  @tag computer_rule: false
  test "the server refuses a sandbox value from a computer without the rule", ctx do
    assert {:error, {:management_error, "unavailable", _message, details}} =
             request(ctx, "secret.set", %{"id" => "env:LEDGER_TOKEN", "value" => "ledger-7c41"})

    assert details == %{
             "capability" => "settings",
             "sentence" => "Update Fermix on this computer to change its sandbox values."
           }

    refute_received {:stored, _engine, _id}

    # Its other writes are the server's as they always were.
    assert {:ok, _applied} =
             request(ctx, "settings.apply", %{
               "section" => "browser",
               "values" => %{"browser_max_tabs" => 6}
             })

    assert_receive {:applied, :server, "browser", _values}
  end

  # The sandbox section whose rows are this computer's own (its allowed
  # name is LEDGER_TOKEN, the server's GARDEN_TOKEN), whatever its id.
  defp own_sandbox!(ctx) do
    {:ok, %{"sections" => sections}} = request(ctx, "settings.sections", %{})

    sections
    |> Enum.filter(&(&1["id"] in ["sandbox", "computer.sandbox"]))
    |> Enum.map(fn %{"id" => id} ->
      {:ok, view} = request(ctx, "settings.get", %{"section" => id})
      view
    end)
    |> Enum.find(fn view -> Enum.any?(view["rows"], &(&1["label"] == "LEDGER_TOKEN")) end)
    |> tap(&assert(&1, "no sandbox section of this computer's own"))
  end

  defp env_key!(view, name) do
    %{"key" => key} = Enum.find(view["rows"], &(&1["label"] == name and &1["kind"] == "secret"))
    key
  end

  # The real session's hello_ack, or an older server's, which says nothing of
  # the rule.
  defp older_server(%{server_rule: false}),
    do: [hello_ack_builder: fn _state -> {:ok, ack(false)} end]

  defp older_server(_ctx), do: []

  # An older server's hello_ack, saying it applies §19.3's rule or not.
  defp ack(rule?) do
    {min_version, max_version} = Protocol.supported_version_range()
    computer = %{"v" => 1, "offers" => true, "link_path" => true, "invoke" => true}

    %{
      "session_id" => "garden-session",
      "min_version" => min_version,
      "max_version" => max_version,
      "profiles" => [%{"id" => "main", "name" => "Fermix"}],
      "candidates" => [],
      "history_head_seq" => 0,
      "read_up_to_seq" => 0,
      "caps" => %{
        "commands" => [],
        "max_media_bytes" => 20_971_520,
        "computer" => if(rule?, do: Map.put(computer, "machine_settings", true), else: computer)
      },
      "primary_epoch" => 3
    }
  end

  # Each engine's own job family: the computer's mints ids that name it
  # (`computer.job:<id>`), as a linked computer's does.
  defp start_jobs!(engine, task_supervisor) do
    name = :"two_engines_settings_jobs_#{engine}_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Jobs, name: name, task_supervisor: task_supervisor, computer?: engine == :computer},
      id: name
    )

    name
  end

  defp start_daemon!(engine, task_supervisor, seams, opts) do
    # Short: the socket's path must fit a Unix socket address.
    socket_path = Path.join(DesktopRail.root!("fx-ds"), "d.sock")
    name = :"two_engines_settings_daemon_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Daemon,
       [
         name: name,
         socket_path: socket_path,
         task_supervisor: task_supervisor,
         management_opts: management_opts(engine, seams)
       ] ++ Keyword.put_new(opts, :forwarding, [])},
      id: name
    )

    if engine == :server, do: name, else: socket_path
  end

  defp management_opts(engine, seams) do
    test = self()

    [
      engine_role: role(engine),
      snapshot: snapshot(engine),
      computer?: engine == :computer,
      server_primary?: engine == :server,
      macos?: engine == :computer,
      settings_writer: fn
        section, %{"sandbox_profile" => _profile}, _opts ->
          {:error, {:external_change, [section]}}

        section, values, _opts ->
          send(test, {:applied, engine, section, values})
          {:ok, %{"applied" => Map.keys(values), "restart" => restart(), "side_effects" => []}}
      end,
      settings_reloader: fn _opts ->
        send(test, {:reloaded, engine})
        {:ok, %{"reloaded" => true, "restart" => restart()}}
      end,
      secret_writer: fn id, _value ->
        send(test, {:stored, engine, id})
        {:ok, %{"id" => id, "present" => true, "restart" => restart()}}
      end,
      secret_clearer: fn id ->
        send(test, {:cleared, engine, id})
        {:ok, %{"id" => id, "present" => false, "restart" => restart()}}
      end,
      record_change: fn _home, change ->
        send(test, {:said, change})
        :ok
      end,
      computer_lookup: fn id -> {:ok, %Computer{device_id: id, name: "studio Mac"}} end,
      identity_provider: fn -> {:ok, identity()} end,
      endpoint_opts: [port: 4041]
    ] ++ [operation_opts: operation_opts(engine, seams)]
  end

  # Each engine's job family, and an install that runs until the test ends it;
  # the computer's link as its relay says it: the server's name, and whether
  # its hello_ack said it applies the rule.
  defp operation_opts(engine, seams) do
    test = self()

    install = fn ->
      send(test, {:installing, engine})

      receive do
        :finish -> {:ok, "/invented/helper"}
      after
        30_000 -> {:error, :never_finished}
      end
    end

    [jobs: [server: seams.jobs], install: install] ++ link(engine, seams)
  end

  defp link(:computer, %{relay: relay}),
    do: [home: [link_status: fn -> %{primary: Relay.status(relay)} end]]

  defp link(:server, _seams), do: []

  defp restart, do: %{"required" => false, "reasons" => []}

  defp role(:server), do: %{role: :primary, primary: nil}
  defp role(:computer), do: %{role: :device, primary: "garden server"}

  # Each engine's own sandbox: the server open with one allowed name, the
  # computer strict with another.
  defp snapshot(:server), do: %{sandbox: [mode: :open, env: [allow: ["GARDEN_TOKEN"]]]}
  defp snapshot(:computer), do: %{sandbox: [mode: :strict, env: [allow: ["LEDGER_TOKEN"]]]}

  defp identity do
    %{
      "engine_id" => "fermix-engine-test",
      "product_version" => "1.2.3",
      "build_id" => nil,
      "source_commit" => nil,
      "distribution_identity" => "standalone",
      "artifact_target" => nil,
      "architecture" => "arm64",
      "pid" => "4321"
    }
  end

  defp request(ctx, method, params) do
    Client.request_v1(method, params, socket_path: ctx.socket, timeout: @reply_ms)
  end
end
