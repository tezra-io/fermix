defmodule FermixCore.Cues.MandatesTest do
  @moduledoc """
  The mandate load checks (M60 §10.1, §10.4, PLAN §1 decision 1): a mandate that
  fails one is inactive with the check's sentence, grants a cue run nothing, and
  the setup page can read why.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog, only: [with_log: 1]
  import FermixTestSupport.CueFixtures, only: [exec!: 3]

  alias FermixCore.Capabilities.Advertisement
  alias FermixCore.Cues.Config
  alias FermixCore.Cues.Mandates
  alias FermixCore.Cues.Pins
  alias FermixCore.Jobs.CueRun
  alias FermixCore.Jobs.CueSurface
  alias FermixCore.Memory.Repo
  alias FermixTestSupport.MandateFixtures, as: F
  alias FermixTestSupport.SafeRm

  @name "release-issues"

  setup do
    fixture = F.cue_run("mandates")
    %{fixture: fixture}
  end

  defp seams(fixture, section, extra \\ []) do
    config = F.config(@name, fixture.job.id, section)
    fixture |> F.default_seams() |> Keyword.merge([config: config] ++ extra)
  end

  defp status(fixture, section, extra \\ []) do
    {:ok, mandate} = Mandates.get(@name, seams(fixture, section, extra))
    mandate.status
  end

  test "a mandate that passes every check is active, and a cue run of its job acts under it",
       %{fixture: fixture} do
    seams = seams(fixture, %{})

    assert {:ok, %Mandates{status: :active, mode: :auto, job_name: "release issues"}} =
             Mandates.get(@name, seams)

    assert %Mandates{name: @name, tools: ["github_create_issue"]} =
             Mandates.for_job(fixture.job.id, seams)

    assert Mandates.for_job("another_job", seams) == nil
    assert Mandates.get("nothing", seams) == :error
  end

  # A device opens no database (`FermixCore.Home.Role`), and its settings file
  # is the primary's retired copy, mandates and all: the setup page it serves
  # reads why the job is unknown here instead of losing its connection.
  test "a mandate whose job cannot be read where no database is open says so",
       %{fixture: fixture} do
    absent = :"mandates_absent_repo_#{System.unique_integer([:positive])}"
    job = fixture.job.id

    assert {:inactive, sentence} = status(fixture, %{}, repo: absent)
    assert sentence == "Job #{job} could not be read: :repo_not_running"
  end

  test "auto mode needs a validator or pinned arguments", %{fixture: fixture} do
    assert status(fixture, %{"pin_args" => %{}}) ==
             {:inactive,
              "Auto mode needs a validator or pinned arguments; use approve mode otherwise."}

    assert Mandates.for_job(fixture.job.id, seams(fixture, %{"pin_args" => %{}})) == nil
  end

  test "approve mode needs a Telegram, Signal, WhatsApp or iMessage chat, or the app (C55)",
       %{fixture: fixture} do
    approve = %{"mode" => "approve"}
    assert status(fixture, approve) == :active

    sentence =
      "Approve mode needs somewhere to ask you: a Telegram, Signal, WhatsApp or iMessage " <>
        "chat with you, or the Fermix app."

    no_app = [app_surface?: false]
    assert status(fixture, approve, [configured_owners: %{}] ++ no_app) == {:inactive, sentence}

    assert status(fixture, approve, [configured_owners: %{"slack" => "U1"}] ++ no_app) ==
             {:inactive, sentence}

    assert status(fixture, approve, configured_owners: %{"signal" => "+15550100"}) == :active

    # The Fermix app asks the owner itself (M60 app surface §3.7).
    assert status(fixture, approve, configured_owners: %{}, app_surface?: true) == :active
  end

  # The Linux desktop app is a Flatpak beside the host's package, so a package
  # build alone says nothing about it: a headless server with the package and
  # no app would hold every proposal unseen until it expired. What counts is
  # whether its entry was installed when Fermix started (HostFacts).
  test "the Linux desktop app counts as somewhere to ask only when it is installed" do
    assert Mandates.app_surface?(host_facts: %{linux_app: true})
    refute Mandates.app_surface?(host_facts: %{linux_app: false})
    refute Mandates.app_surface?(host_facts: %{linux_app: :not_asked})
    refute Mandates.app_surface?(host_facts: %{})
  end

  test "tools name http plugin tools only: an MCP tool, a command or web_fetch is refused",
       %{fixture: fixture} do
    for tool <- ["web_fetch", "shell", "my_mcp_server__create"] do
      assert {:inactive, sentence} = status(fixture, %{"tools" => [tool]})
      assert sentence =~ "#{tool} is not an http plugin tool"
    end

    assert {:inactive, sentence} = status(fixture, %{"read_tools" => ["web_fetch"]})
    assert sentence =~ "web_fetch is not an http plugin tool"
    assert {:inactive, sentence} = status(fixture, %{"tools" => []})
    assert sentence =~ "names no tools"
  end

  test "the job must exist and run on cues; one job has at most one mandate", %{fixture: fixture} do
    seams = F.default_seams(fixture)

    missing = Keyword.put(seams, :config, F.config(@name, "no_such_job"))

    assert {:ok, %{status: {:inactive, "Job no_such_job does not exist."}}} =
             Mandates.get(@name, missing)

    exec!(fixture.conn, "UPDATE scheduled_jobs SET schedule_kind = 'interval' WHERE id = ?", [
      fixture.job.id
    ])

    assert {:inactive, sentence} = status(fixture, %{})
    assert sentence =~ "runs on a schedule"

    two =
      Config.normalize(%{
        "mandates" => %{
          "first" => %{
            "job" => fixture.job.id,
            "tools" => [F.tool()],
            "pin_args" => %{"owner" => "x"},
            "mode" => "auto"
          },
          "second" => %{
            "job" => fixture.job.id,
            "tools" => [F.tool()],
            "pin_args" => %{"owner" => "x"},
            "mode" => "auto"
          }
        }
      })

    for mandate <- Mandates.load(Keyword.put(seams, :config, two)) do
      assert mandate.status ==
               {:inactive,
                "Mandates first and second name the same job; a job has at most one mandate."}
    end
  end

  test "idempotency_arg must be an argument of one of the tools", %{fixture: fixture} do
    assert status(fixture, %{"idempotency_arg" => "client_id"}) == :active
    assert {:inactive, sentence} = status(fixture, %{"idempotency_arg" => "order_id"})
    assert sentence =~ "order_id is not an argument"
  end

  test "every pinned argument is an argument of each tool in tools", %{fixture: fixture} do
    assert status(fixture, %{"pin_args" => %{"owner" => "example-org", "repo" => "ops"}}) ==
             :active

    assert status(fixture, %{"pin_args" => %{"organisation" => "example-org"}}) ==
             {:inactive,
              "pin_args organisation is not an argument of github_create_issue; every pinned " <>
                "argument must be an argument of each tool in tools."}
  end

  test "a reader that asks for confirmation on every call is refused in read_tools",
       %{fixture: fixture} do
    flagged = fn
      "github_search_issues" = name ->
        {:ok, %{plugin: "github", tool: Map.put(F.manifest(name), "access_sensitive", true)}}

      name ->
        F.plugin_tool().(name)
    end

    assert status(fixture, %{}, plugin_tool: flagged) ==
             {:inactive,
              "github_search_issues asks for confirmation on every call; list it under tools " <>
                "or leave it out."}
  end

  # A reader runs in a cue run with none of a mandate call's checks (no switch,
  # approval, freshness, limit, pin or record), so a tool that can change
  # something is no reader, whatever list it was put in.
  test "a reader its plugin does not mark read-only is refused in read_tools",
       %{fixture: fixture} do
    delete = "google_calendar_delete_event"

    writers = fn
      ^delete ->
        request = %{"method" => "DELETE", "url" => "https://calendar.example.test/events/{id}"}
        {:ok, %{plugin: "google_calendar", tool: %{"name" => delete, "request" => request}}}

      "github_search_issues" = name ->
        {:ok, %{plugin: "github", tool: Map.put(F.manifest(name), "read_only", false)}}

      name ->
        F.plugin_tool().(name)
    end

    assert status(fixture, %{"read_tools" => [delete]}, plugin_tool: writers) ==
             {:inactive,
              "google_calendar_delete_event is not marked read-only, so it can change " <>
                "something; list it under tools or leave it out."}

    assert {:inactive, sentence} = status(fixture, %{}, plugin_tool: writers)
    assert sentence =~ "github_search_issues is not marked read-only"
    assert Mandates.for_job(fixture.job.id, seams(fixture, %{}, plugin_tool: writers)) == nil

    assert status(fixture, %{}) == :active
  end

  test "the first entry of read_tools that is no reader is the one named", %{fixture: fixture} do
    flagged = "tesla_unlock_doors"

    lookup = fn
      ^flagged ->
        tool = %{"name" => flagged, "request" => %{}, "access_sensitive" => true}
        {:ok, %{plugin: "tesla", tool: tool}}

      "github_create_issue" = name ->
        {:ok, %{plugin: "github", tool: F.manifest(name)}}

      name ->
        F.plugin_tool().(name)
    end

    read_tools = [F.reader(), "github_create_issue", flagged]

    assert {:inactive, "github_create_issue is not marked read-only" <> _rest} =
             status(fixture, %{"read_tools" => read_tools}, plugin_tool: lookup)

    assert {:inactive, "tesla_unlock_doors asks for confirmation on every call" <> _rest} =
             status(fixture, %{"read_tools" => [F.reader(), flagged]}, plugin_tool: lookup)
  end

  # A reader runs with none of a mandate call's other checks, so a cue run is
  # offered the mandate's readers only while it is in force: switched on, with
  # mandates on in settings, and approved with an approval not disabled.
  test "a cue run is offered the mandate's readers only while it is in force",
       %{fixture: fixture} do
    offered = fn seams ->
      mandate = Mandates.for_job(fixture.job.id, seams)
      CueSurface.tools(fixture.job, nil, %{task_notes?: false}, mandate)
    end

    seams = seams(fixture, %{})
    assert %Mandates{tools: [tool], read_tools: []} = Mandates.for_job(fixture.job.id, seams)
    assert tool == F.tool()
    assert F.tool() in offered.(seams)
    refute F.reader() in offered.(seams)

    assert {:ok, %{state: :approved}} = Pins.approve(@name, "test", F.now(), seams)
    assert %Mandates{read_tools: [reader]} = Mandates.for_job(fixture.job.id, seams)
    assert reader == F.reader()
    assert F.reader() in offered.(seams)

    refute F.reader() in offered.(seams(fixture, %{"enabled" => false}))

    global_off = F.config(@name, fixture.job.id, %{}, %{"mandates_enabled" => false})
    refute F.reader() in offered.(Keyword.put(seams, :config, global_off))

    assert {:ok, _state} = Pins.disable(@name, "test", F.now(), seams)
    refute F.reader() in offered.(seams)
  end

  # `read_tools` and the task are pinned: an approval of something else does
  # not cover a reader, and a run that only reads never reaches the pin check
  # a mandate call takes, so the offer takes it.
  test "readers are not offered once the section or the task changed since the approval",
       %{fixture: fixture} do
    no_readers = seams(fixture, %{"read_tools" => []})
    assert {:ok, %{state: :approved}} = Pins.approve(@name, "test", F.now(), no_readers)

    assert %Mandates{read_tools: []} = Mandates.for_job(fixture.job.id, seams(fixture, %{}))

    assert {:ok, %{state: :approved}} = Pins.approve(@name, "test", F.now(), seams(fixture, %{}))

    assert %Mandates{read_tools: [_reader]} =
             Mandates.for_job(fixture.job.id, seams(fixture, %{}))

    exec!(fixture.conn, "UPDATE scheduled_jobs SET task_prompt = ? WHERE id = ?", [
      "Open an issue and close every other one.",
      fixture.job.id
    ])

    assert %Mandates{read_tools: []} = Mandates.for_job(fixture.job.id, seams(fixture, %{}))
  end

  # The setup page shows a mandate switched off, unapproved or changed; a read
  # that failed is shown nowhere, so it is logged.
  test "readers withheld because the approval could not be read are logged",
       %{fixture: fixture} do
    off = :"mandates_off_repo_#{System.unique_integer([:positive])}"
    unused = Path.join(System.tmp_dir!(), "#{off}.db")
    spec = {Repo, name: off, enabled: false, database_path: unused}
    start_supervised!(Supervisor.child_spec(spec, id: off))
    job = fixture.job
    seams = seams(fixture, %{}, repo: off, get_job: fn _id -> {:ok, job} end)

    {mandate, log} = with_log(fn -> Mandates.for_job(job.id, seams) end)
    assert %Mandates{read_tools: []} = mandate
    assert log =~ "Mandate release-issues"
    assert log =~ "approval could not be read"
  end

  test "an interpreter is a Python; a validator in another language runs directly",
       %{fixture: fixture} do
    for interpreter <- ~w(/usr/bin/node /bin/bash /usr/local/bin/pythonista) do
      section = %{"validator" => "/usr/local/libexec/fermix/v.js", "interpreter" => interpreter}

      assert status(fixture, section) ==
               {:inactive,
                "The interpreter #{interpreter} is not a Python (python, python3 or python3.N); " <>
                  "a validator in another language runs directly, with no interpreter."}
    end

    for interpreter <- ~w(/usr/bin/python /usr/bin/python3 /usr/local/bin/python3.12) do
      section = %{"validator" => "/usr/local/libexec/fermix/v.py", "interpreter" => interpreter}
      assert status(fixture, section) == :active
    end
  end

  describe "the validator's ownership (design §10.4, C35)" do
    test "a validator writable by the daemon's user keeps the mandate from starting", %{
      fixture: fixture
    } do
      dir = SafeRm.make_tmp_dir!("mandate-owned")
      on_exit(fn -> SafeRm.rm_rf!(dir) end)
      path = Path.join(dir, "validate.sh")
      File.write!(path, "#!/bin/sh\necho '{\"allow\": true}'\n")

      # The real file system: this test's user owns the file, as the daemon's would.
      seams =
        fixture
        |> seams(%{"validator" => path})
        |> Keyword.drop([:stat, :resolve])
        |> Keyword.merge(daemon_uid: File.stat!(path).uid, home: "/nonexistent-home")

      assert {:ok, %{status: {:inactive, sentence}}} = Mandates.get(@name, seams)
      assert sentence =~ "owned by another user than Fermix's"
      assert Mandates.for_job(fixture.job.id, seams) == nil
    end

    test "every directory above the validator and its interpreter is checked", %{fixture: fixture} do
      validator = "/usr/local/libexec/fermix/validate.py"
      interpreter = "/usr/bin/python3"

      stat = fn
        "/usr/local/libexec" -> {:ok, %{uid: 0, mode: 0o40777, type: :directory}}
        _path -> {:ok, %{uid: 0, mode: 0o100755, type: :regular}}
      end

      section = %{"validator" => validator, "interpreter" => interpreter}
      assert {:inactive, sentence} = status(fixture, section, stat: stat)
      assert sentence =~ "/usr/local/libexec is"
      assert sentence =~ "not be writable by group or others"

      linked = fn
        ^interpreter -> {:ok, "/Users/someone/homebrew/bin/python3.12"}
        path -> {:ok, path}
      end

      assert {:inactive, sentence} = status(fixture, section, resolve: linked)
      assert sentence =~ "under the daemon user's home"

      assert status(fixture, section) == :active
      assert {:inactive, sentence} = status(fixture, %{"validator" => "validate.py"})
      assert sentence =~ "must be an absolute path"
    end
  end

  test "a cue run's mandate lookup answers only for an active mandate", %{fixture: fixture} do
    # `CueRun.mandate/1` reads the application's settings, where no mandate
    # names this fresh job.
    assert CueRun.mandate(fixture.job) == nil
  end

  test "the model's schema loses idempotency_arg only in a cue run under the mandate",
       %{fixture: fixture} do
    config = F.config(@name, fixture.job.id, %{"idempotency_arg" => "client_id"})

    cue = %{trigger: "cue", cue_mandate: @name, cue_mandate_opts: [config: config]}
    [hidden] = Advertisement.prepare([F.capability()], cue)
    refute Map.has_key?(hidden.parameters["properties"], "client_id")
    assert hidden.parameters["required"] == ["owner", "repo", "title"]

    [kept] = Advertisement.prepare([F.capability()], %{cue | trigger: "schedule"})
    assert Map.has_key?(kept.parameters["properties"], "client_id")

    [other] = Advertisement.prepare([F.capability(F.reader())], cue)
    assert Map.has_key?(other.parameters["properties"], "client_id")
  end
end
