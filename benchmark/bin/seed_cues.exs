# The cue suites' watchers and tasks in a disposable eval home (M60 §16).
#
#   FERMIX_HOME=<eval home> mix run --no-start --no-compile benchmark/bin/seed_cues.exs
#
# Runs after seed_capability_home.py, which reset memory.db and wrote the cue
# config, and BEFORE the daemon starts (capability-daemon.sh `up` runs both), so
# it is the only writer. Through the product's own calls (`Cues.Watchers.create/3`,
# which makes each task as a job that runs on cues, `Cues.Ingest.accept/3`,
# `Cues.Pins.approve/4`) it makes:
#
#   * eval-news      llm filter on the default filter model, for the filter cases
#   * eval-alerts    no filter, 100 runs a day, for the task cases
#   * eval-research  no filter, a task whose prompt names web_search
#   * team-digest    llm filter with three instructions and two delivered items (its
#                    words match both), for the behavioral suite's "also ignore …" and
#                    "that wasn't useful"
#   * with the manifest's `mandates`: eval-ops and eval-ops-checked, no filter, and
#     the two auto mandates on the stub plugin's tool: eval-ops-auto (pinned
#     project OPS) and eval-ops-checked (validator /usr/bin/false, which refuses
#     every call), appended to config.toml and approved
#
# Every task reports to a Telegram chat the home holds no credentials for, so a
# report is recorded on its run row and never sent. It writes
# `eval-fixtures/cue_watchers.json` last. Every value here is invented.

defmodule SeedCues do
  alias FermixCore.Cues.Ingest
  alias FermixCore.Cues.Item
  alias FermixCore.Cues.Pins
  alias FermixCore.Cues.Watchers
  alias FermixCore.Memory.Config, as: MemoryConfig
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.CuesSql
  alias FermixCore.Setup.ConfigStore

  @manifest "eval-fixtures/cues.json"
  @watchers_manifest "eval-fixtures/cue_watchers.json"
  @target %{"platform" => "telegram", "chat_id" => "100001"}
  @context %{
    source_trust: :operator,
    memory_agent_id: "main",
    source_channel: "eval-seed",
    session_id: "eval-seed"
  }
  @plugin_tool "eval_tickets_file"
  @refusing_validator "/usr/bin/false"

  @news_task """
  A news item about our Orrin DB fleet arrived. Tell me in two sentences what \
  happened and what it means for us, and quote its release identifier or advisory id \
  exactly as written. If it does not matter to us, answer exactly [SILENT].\
  """

  @alerts_task """
  An operations alert arrived. Tell me in one or two sentences what it says, with any \
  incident or alert id exactly as written. Tell me about each incident once: if you \
  already told me about the same incident, answer exactly [SILENT].\
  """

  @research_task """
  A research request arrived. Use web_search to look up what it asks about, read any \
  file it names, and answer it in a short paragraph.\
  """

  @digest_task "Summarize the item for me in one line."

  @ops_task """
  An operations alert arrived. If it asks for a ticket, file one in our tracker in the \
  project the alert names, titled as the alert says, then tell me what you filed. \
  Otherwise answer exactly [SILENT].\
  """

  def main([]) do
    home = eval_home!()
    same_database!(home)
    manifest = home |> Path.join(@manifest) |> File.read!() |> Jason.decode!()
    cues = read_config!()
    {:ok, _apps} = Application.ensure_all_started(:exqlite)
    {:ok, _repo} = Repo.start_link([])
    now = DateTime.utc_now()

    watchers =
      watcher_specs(manifest["mandates"] == true)
      |> Map.new(fn spec -> {spec.name, create!(spec, cues, now)} end)

    digest = deliver_digest_items!(home, now)
    mandates = if manifest["mandates"] == true, do: mandates!(home, watchers, now), else: %{}

    write_manifest!(home, %{watchers: watchers, team_digest_items: digest, mandates: mandates})

    IO.puts(
      "seeded #{map_size(watchers)} watchers, #{length(digest)} delivered items, " <>
        "#{map_size(mandates)} mandates"
    )
  end

  def main(_args),
    do: raise(ArgumentError, "usage: seed_cues.exs (FERMIX_HOME set to an eval home)")

  # --- guards ------------------------------------------------------------------

  defp eval_home! do
    home = System.fetch_env!("FERMIX_HOME") |> Path.expand()
    leaf = home |> Path.basename() |> String.downcase()

    unless String.contains?(leaf, "eval") or String.contains?(leaf, "e2e") do
      raise "refusing to seed cues outside a disposable eval home: #{home}"
    end

    home
  end

  defp same_database!(home) do
    opened = Path.expand(MemoryConfig.database_path())
    wanted = Path.expand(Path.join(home, "memory.db"))

    unless opened == wanted do
      raise "the helper would open #{opened}, not the eval home's #{wanted}"
    end
  end

  # The home's own config.toml through the engine's loader, no secret resolved.
  defp read_config! do
    {:ok, snapshot} = ConfigStore.load_runtime_config(resolve_secrets: false, supervised: false)
    cues = Keyword.get(snapshot.fermix_core, :cues, [])

    unless Keyword.get(cues, :enabled) == true do
      raise "config.toml does not turn cues on; run seed_capability_home.py first"
    end

    cues
  end

  # --- watchers ------------------------------------------------------------------

  # Every llm watcher filters with the home's one Cues filter model.
  defp watcher_specs(mandates?) do
    base = [
      llm("eval-news", @news_task,
        purpose: "Engineering news that affects our Orrin DB fleet",
        listen_for: [
          "Orrin DB",
          "Orrin",
          "release",
          "security advisory",
          "CVE",
          "outage",
          "incident",
          "replication",
          "database",
          "server"
        ],
        instructions: [
          "Pass Orrin DB releases, security advisories and outages.",
          "Drop anything that is not about Orrin DB or the servers we run it on.",
          "Drop opinion pieces, tutorials and marketing."
        ]
      ),
      none("eval-alerts", @alerts_task),
      none("eval-research", @research_task),
      llm("team-digest", @digest_task,
        purpose: "Team and engineering news worth my attention",
        listen_for: [
          "platform team",
          "incident review",
          "postmortem",
          "engineering",
          "release",
          "Elixir",
          "meetup",
          "edge cache",
          "funding",
          "Series B",
          "job posting",
          "hiring"
        ],
        instructions: [
          "Pass announcements from the platform team.",
          "Pass incident reviews.",
          "Drop job postings."
        ]
      )
    ]

    if mandates?,
      do: base ++ [none("eval-ops", @ops_task), none("eval-ops-checked", @ops_task)],
      else: base
  end

  defp llm(name, task, opts) do
    %{
      name: name,
      sources: [name],
      filter: "llm",
      purpose: Keyword.fetch!(opts, :purpose),
      listen_for: Keyword.fetch!(opts, :listen_for),
      instructions: Keyword.fetch!(opts, :instructions),
      task: task,
      task_name: "eval task #{name}",
      task_timeout_minutes: 5,
      delivery_mode: "channel",
      delivery_target: @target
    }
  end

  defp none(name, task) do
    %{
      name: name,
      sources: [name],
      filter: "none",
      daily_cap: 100,
      task: task,
      task_name: "eval task #{name}",
      task_timeout_minutes: 5,
      delivery_mode: "channel",
      delivery_target: @target
    }
  end

  defp create!(spec, cues, now) do
    case Watchers.create(spec, @context, repo: Repo, cues_config: cues, scheduler: nil, now: now) do
      {:ok, %{watcher: watcher, job: job}} ->
        %{id: watcher.id, job_id: job.id, source: hd(spec.sources), filter: spec.filter}

      {:error, sentence} ->
        raise "watcher #{spec.name} was not created: #{sentence}"
    end
  end

  # --- the two items team-digest already delivered -------------------------------

  # Accepted through the product's ingest (one pending delivery each for the llm
  # watcher), then marked delivered on a direct connection: no filter call or task
  # run ever happened for them, and the daemon will start none.
  defp deliver_digest_items!(home, now) do
    titles = [
      "Kestrel Labs raises a Series B for its edge cache",
      "Ostrava Elixir meetup moves to Thursday"
    ]

    items =
      titles
      |> Enum.with_index()
      |> Enum.map(fn {title, n} -> digest_item!(title, n, now) end)

    {:ok, results} =
      Ingest.accept(%{ref: "team-digest", daily_budget: 0}, items, now: now, repo: Repo)

    unless Enum.all?(results, &(&1 == :accepted)),
      do: raise("the team-digest items were not accepted: #{inspect(results)}")

    mark_delivered!(Path.join(home, "memory.db"), now)
  end

  defp digest_item!(title, n, now) do
    fields = %{
      item_id: "eval-digest-#{n}",
      type: "eval.digest.item",
      subject: "eval-digest-#{n}",
      title: title,
      data: %{"title" => title, "summary" => "#{title}. More in the team's weekly notes."}
    }

    {:ok, item} = Item.new(fields, now)
    item
  end

  defp mark_delivered!(path, now) do
    {:ok, conn} = Exqlite.Sqlite3.open(path)

    try do
      :ok = Exqlite.Sqlite3.execute(conn, "PRAGMA busy_timeout = 5000")

      {:ok, rows} =
        CuesSql.query_all(
          conn,
          "SELECT d.id, c.id, c.snapshot FROM cue_deliveries d JOIN cues c ON c.id = d.cue_id " <>
            "WHERE c.source_ref = 'team-digest' AND d.state = 'pending' ORDER BY d.id",
          []
        )

      Enum.map(rows, fn [delivery_id, cue_id, snapshot] ->
        patch = %{outcome: "acted", decision_reason: "seeded as delivered", settled_at: now}
        :ok = CuesSql.transition(conn, delivery_id, "pending", :none, "acked", patch)
        %{cue_id: cue_id, delivery_id: delivery_id, title: Jason.decode!(snapshot)["text"]}
      end)
    after
      Exqlite.Sqlite3.close(conn)
    end
  end

  # --- mandates ----------------------------------------------------------------------

  defp mandates!(home, watchers, now) do
    sections = [
      {"eval-ops-auto", watchers["eval-ops"].job_id, [~s(project = "OPS")], []},
      {"eval-ops-checked", watchers["eval-ops-checked"].job_id, [],
       [~s(validator = "#{@refusing_validator}")]}
    ]

    File.write!(Path.join(home, "config.toml"), Enum.map_join(sections, &section/1), [:append])

    cues = read_config!()
    Application.put_env(:fermix_core, :cues, cues)

    Map.new(sections, fn {name, job_id, _pins, _extra} ->
      case Pins.approve(name, "eval seed", now, config: cues, repo: Repo) do
        {:ok, _status} -> {name, job_id}
        {:error, sentence} -> raise "mandate #{name} was not approved: #{sentence}"
      end
    end)
  end

  defp section({name, job_id, pins, extra}) do
    body =
      [
        "",
        "[fermix_core.cues.mandates.#{name}]",
        ~s(job = "#{job_id}"),
        ~s(mode = "auto"),
        ~s(tools = ["#{@plugin_tool}"])
      ] ++ extra

    pin_lines =
      if pins == [], do: [], else: ["", "[fermix_core.cues.mandates.#{name}.pin_args]" | pins]

    Enum.join(body ++ pin_lines, "\n") <> "\n"
  end

  defp write_manifest!(home, manifest) do
    path = Path.join(home, @watchers_manifest)
    File.write!(path, Jason.encode!(manifest, pretty: true))
    File.chmod!(path, 0o600)
  end
end

SeedCues.main(System.argv())
