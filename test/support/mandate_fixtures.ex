defmodule FermixTestSupport.MandateFixtures do
  @moduledoc """
  A claimed cue run of a cue-only job on a private temp Repo, with everything a
  mandate test hands the gate: an `http`-rail stand-in tool, a mandate section,
  the run's context, and seams that keep every check off the host.

  Nothing here reads the host: the ownership check gets a root-owned `:stat`,
  the plugin lookup a fixed manifest, the owner inbox a configured Telegram
  owner. That owner's id is the test process's pid as text, so the channel
  stand-in (`SinkAdapter`) and the proposal sender can deliver to the test that
  owns the run without any registered name (async-safe).
  """

  import ExUnit.Callbacks, only: [start_supervised!: 1, on_exit: 1]
  import FermixTestSupport.CueFixtures, only: [open_conn: 1, rows: 3, exec!: 3]

  alias FermixCore.Capabilities.Capability
  alias FermixCore.Cues.Config
  alias FermixCore.Jobs.Registry, as: JobsRegistry
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.CuesSql
  alias FermixCore.Tools.Telemetry, as: ToolTelemetry

  @tool "github_create_issue"
  @reader "github_search_issues"
  @plugin "github"
  @source "eng-blogs"
  @now ~U[2026-10-10 12:00:00.000000Z]

  defmodule SinkAdapter do
    @moduledoc "A channel adapter that hands each message to the test process its destination names."
    def send_message(destination, text, opts) do
      send(
        FermixTestSupport.MandateFixtures.pid_of(destination),
        {:sent, destination, text, opts}
      )

      :ok
    end
  end

  defmodule DownAdapter do
    @moduledoc "A channel adapter whose every send fails."
    def send_message(_destination, _text, _opts), do: {:error, :channel_down}
  end

  @doc "The stand-in action tool's name."
  def tool, do: @tool

  @doc "The stand-in reader's name."
  def reader, do: @reader

  @doc "The cue source of every fixture run."
  def source, do: @source

  @doc "The fixed `now` of a fixture run (the cue arrives a minute earlier)."
  def now, do: @now

  @doc "The text form of a pid, used as the owner's id."
  def owner_id(pid \\ self()), do: List.to_string(:erlang.pid_to_list(pid))

  @doc "The pid an owner id names."
  def pid_of(owner_id), do: :erlang.list_to_pid(String.to_charlist(owner_id))

  @doc """
  The manifest of an `http`-rail tool: `owner`, `repo`, `title` required,
  `labels` an array with a default, `client_id` a client-chosen id. The
  manifest carries the test pid for the stand-in executor.
  """
  def manifest(name \\ @tool, test_pid \\ self()) do
    %{
      "name" => name,
      "request" => %{"method" => "POST", "url" => "https://api.example.test/issues"},
      "parameters" => %{
        "type" => "object",
        "required" => ["owner", "repo", "title"],
        "properties" => %{
          "owner" => %{"type" => "string"},
          "repo" => %{"type" => "string"},
          "title" => %{"type" => "string"},
          "labels" => %{"type" => "array", "default" => ["cue"]},
          "client_id" => %{"type" => "string"}
        }
      },
      "test_pid" => test_pid
    }
  end

  @doc "The stand-in tool as the plugin registry would register it."
  def capability(name \\ @tool, opts \\ []) do
    tool = manifest(name, Keyword.get(opts, :test_pid, self()))

    Capability.new(%{
      name: name,
      description: "Open an issue.",
      parameters: tool["parameters"],
      kind: :builtin,
      executor: {__MODULE__, :execute, [@plugin, tool]},
      policy_class: :external_api,
      metadata: %{
        plugin_owned?: true,
        plugin: @plugin,
        auth_profile: "github:default",
        access_sensitive?: Keyword.get(opts, :flagged, false)
      }
    })
  end

  @doc false
  def execute(args, context, plugin, %{"test_pid" => pid} = tool) do
    send(pid, {:executed, tool["name"], args, context})
    ToolTelemetry.exec(tool["name"], context, true, 0, metadata: %{plugin: plugin})
    {:ok, %{success: true, output: ~s({"number":42}), error: nil}}
  end

  @doc "The plugin lookup seam: the two stand-in tools are `http` tools, nothing else is."
  def plugin_tool(test_pid \\ self()) do
    fn
      name when name in [@tool, @reader] ->
        {:ok, %{plugin: @plugin, tool: manifest(name, test_pid)}}

      _other ->
        :error
    end
  end

  @doc """
  A `[fermix_core.cues]` keyword with one mandate `name` on `job_id`: auto
  mode, the stand-in tool, `owner` pinned, 15 minutes of freshness, unless
  `section` says otherwise. `top` adds top-level keys (`mandates_enabled`).
  """
  def config(name, job_id, section \\ %{}, top \\ %{}) do
    base = %{
      "job" => job_id,
      "mode" => "auto",
      "tools" => [@tool],
      "read_tools" => [@reader],
      "max_cue_age" => "15m",
      "pin_args" => %{"owner" => "example-org"}
    }

    Config.normalize(Map.merge(%{"mandates" => %{name => Map.merge(base, section)}}, top))
  end

  @doc "A root-owned, owner-only-writable stat for every path (the ownership check's seam)."
  def root_stat, do: fn _path -> {:ok, %{uid: 0, mode: 0o100755, type: :regular}} end

  @doc """
  A claimed cue run: a cue-only job, its watcher, one cue (received a minute
  before `now/0`) and its delivery, claimed with a run. Returns the ids, the
  repo and a direct connection.
  """
  def cue_run(tag, attrs \\ %{}) do
    %{repo: repo, conn: conn, db_path: db_path} = start_repo(tag)
    job = cue_job!(repo, Map.get(attrs, :task_prompt, "Open an issue for each release."))
    watcher_id = watcher!(conn, job.id)
    received = Map.get(attrs, :received_at, DateTime.add(@now, -60, :second))
    {cue_id, delivery_id} = delivery!(conn, watcher_id, received, Map.get(attrs, :occurred_at))
    run = claim!(repo, job, @now)

    %{
      repo: repo,
      conn: conn,
      db_path: db_path,
      job: job,
      run: run,
      watcher_id: watcher_id,
      cue_id: cue_id,
      delivery_id: delivery_id,
      received_at: received,
      occurred_at: Map.get(attrs, :occurred_at)
    }
  end

  @doc """
  The context the runner gives a cue run of `fixture` under mandate `name`,
  with `seams` (merged over the defaults) as the gate's test seams.
  """
  def context(fixture, name, seams \\ []) do
    %{
      trigger: "cue",
      cue_mandate: name,
      cue_run_claimed_at: fixture.run.claimed_at,
      job_id: fixture.job.id,
      run_id: fixture.run.id,
      session_id: fixture.run.session_id,
      agent_name: "scheduled:#{fixture.job.id}",
      memory_repo: fixture.repo,
      source_trust: :operator,
      outside_sources: MapSet.new([{:cue, @source}]),
      cue: %{
        delivery_id: fixture.delivery_id,
        cue_id: fixture.cue_id,
        watcher_id: fixture.watcher_id,
        watcher_name: "release-watch",
        source_ref: @source,
        subject: "phoenix",
        occurred_at: fixture.occurred_at,
        received_at: fixture.received_at,
        item_id: "item-1",
        revision: "1",
        task_notes?: false
      },
      cue_mandate_opts: Keyword.merge(default_seams(fixture), seams)
    }
  end

  @doc "The seams every mandate test starts from."
  def default_seams(fixture) do
    [
      repo: fixture.repo,
      now: @now,
      plugin_tool: plugin_tool(),
      configured_owners: %{"telegram" => owner_id()},
      jobs_config: [],
      adapter: SinkAdapter,
      stat: root_stat(),
      resolve: fn path -> {:ok, path} end,
      daemon_uid: 501,
      home: "/Users/someone",
      proposal_sender: fn inbox, text, token ->
        send(pid_of(inbox.destination), {:proposal, inbox, text, token})
        :ok
      end,
      # A proposal's announcements to the app surfaces (M60 app surface §3.7)
      # reach the test that owns the run, never the global companion registry
      # other async tests listen on.
      proposal_listener: proposal_listener()
    ]
  end

  @doc "A proposal listener that hands each announcement to the calling test process."
  def proposal_listener(test_pid \\ self()),
    do: fn event -> send(test_pid, {:proposal_event, event}) end

  @doc "Every mandate-call row of `run_id`, oldest first, as maps."
  def call_rows(conn, run_id) do
    conn
    |> rows(
      "SELECT id, tool, args_json, idempotency_key, decision, reason, validator, proposal_id, " <>
        "result_status, result_summary, finished_at FROM cue_mandate_calls WHERE run_id = ? " <>
        "ORDER BY rowid",
      [run_id]
    )
    |> Enum.map(fn [
                     id,
                     tool,
                     args,
                     key,
                     decision,
                     reason,
                     validator,
                     proposal,
                     status,
                     summary,
                     fin
                   ] ->
      %{
        id: id,
        tool: tool,
        args: Jason.decode!(args),
        key: key,
        decision: decision,
        reason: reason,
        validator: validator,
        proposal_id: proposal,
        result_status: status,
        result_summary: summary,
        finished_at: fin
      }
    end)
  end

  @doc "The run's `tools_started_at`, or nil."
  def tools_started_at(conn, run_id) do
    [[at]] = rows(conn, "SELECT tools_started_at FROM job_runs WHERE id = ?", [run_id])
    at
  end

  @doc "Every proposal row, as `{id, state}` pairs."
  def proposals(conn) do
    conn
    |> rows("SELECT id, state FROM cue_proposals ORDER BY rowid", [])
    |> Enum.map(fn [id, state] -> {id, state} end)
  end

  # --- rows --------------------------------------------------------------------------

  # `CueFixtures.start_repo/1` with a child id of its own, so one test can hold
  # several runs (each on its own database).
  defp start_repo(tag) do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-mandates-#{tag}-#{unique}.db")
    repo = :"mandate_repo_#{tag}_#{unique}"

    spec =
      Supervisor.child_spec({Repo, name: repo, enabled: true, database_path: db_path}, id: repo)

    start_supervised!(spec)

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    %{repo: repo, db_path: db_path, conn: open_conn(db_path)}
  end

  # The job reports to the owner's Telegram chat, so its run's report and the
  # notices reach the test process through `SinkAdapter`.
  defp cue_job!(repo, task_prompt) do
    {:ok, job} =
      JobsRegistry.create_cue_job(
        %{
          name: "release issues",
          task_prompt: task_prompt,
          delivery_mode: "channel",
          delivery_target: %{"platform" => "telegram", "chat_id" => owner_id()},
          created_by_trust: "operator"
        },
        repo: repo,
        scheduler: nil
      )

    job
  end

  defp watcher!(conn, job_id) do
    id = "cwt_mandate#{System.unique_integer([:positive])}"
    stamp = CuesSql.stamp(@now)

    exec!(
      conn,
      """
      INSERT INTO cue_watchers (id, name, filter, task_job_id, daily_cap, enabled, created_at,
        updated_at)
      VALUES (?, 'release-watch', 'none', ?, 0, 1, ?, ?)
      """,
      [id, job_id, stamp, stamp]
    )

    exec!(conn, "INSERT INTO cue_watcher_sources (watcher_id, source_ref) VALUES (?, ?)", [
      id,
      @source
    ])

    id
  end

  defp delivery!(conn, watcher_id, received, occurred) do
    snapshot =
      Jason.encode!(%{
        "type" => "release",
        "subject" => "phoenix",
        "text" => "Phoenix 2.0 is out."
      })

    [[cue_id]] =
      rows(
        conn,
        """
        INSERT INTO cues (source_ref, item_id, revision, type, subject, occurred_at, received_at,
          content_hash, payload, payload_bytes, snapshot, routed_count, last_seen_at)
        VALUES (?, 'item-1', '1', 'release', 'phoenix', ?, ?, 'h1', '{}', 2, ?, 1, ?) RETURNING id
        """,
        [
          @source,
          occurred && CuesSql.stamp(occurred),
          CuesSql.stamp(received),
          snapshot,
          CuesSql.stamp(received)
        ]
      )

    [[delivery_id]] =
      rows(
        conn,
        """
        INSERT INTO cue_deliveries (cue_id, watcher_id, source_ref, subject, received_at, state,
          ready_at, valid_until)
        VALUES (?, ?, ?, 'phoenix', ?, 'passed', ?, ?) RETURNING id
        """,
        [
          cue_id,
          watcher_id,
          @source,
          CuesSql.stamp(received),
          CuesSql.stamp(received),
          CuesSql.stamp(DateTime.add(received, 7 * 86_400, :second))
        ]
      )

    {cue_id, delivery_id}
  end

  defp claim!(repo, job, now) do
    attrs = %{
      id: "run_mandate_#{System.unique_integer([:positive])}",
      job_id: job.id,
      session_id: "cron_#{job.id}_20261010_120000_#{System.unique_integer([:positive])}",
      trigger: "cue",
      status: "queued",
      claimed_at: now,
      delivery_status: "none",
      created_at: now,
      updated_at: now
    }

    {:ok, %{run: run}} = Repo.claim_cue_run(job.id, attrs, now, server: repo)
    run
  end
end
