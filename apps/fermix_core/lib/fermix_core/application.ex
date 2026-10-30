defmodule FermixCore.Application do
  @moduledoc false

  use Application
  require Logger

  alias Burrito.Util, as: BurritoUtil
  alias Burrito.Util.Args, as: BurritoArgs
  alias Fermix.CLI.Daemon
  alias Fermix.CLI.Setup
  alias FermixCore.Agents.AgentSupervisor
  alias FermixCore.Agents.MainAgent
  alias FermixCore.Agents.SkillRegistry
  alias FermixCore.Auth.Store, as: AuthStore
  alias FermixCore.Auth.TokenSupervisor
  alias FermixCore.Boot.PathBaseline
  alias FermixCore.BootProfile
  alias FermixCore.BuildInfo
  alias FermixCore.Capabilities.BuiltinSeeder
  alias FermixCore.Capabilities.MCP.LoginPath, as: McpLoginPath
  alias FermixCore.Capabilities.MCP.RuntimeStatus, as: McpRuntimeStatus
  alias FermixCore.Capabilities.MCP.Supervisor, as: McpSupervisor
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.CommandHost.Supervisor, as: CommandHostSupervisor
  alias FermixCore.ComputerHistory
  alias FermixCore.ComputerHistory.Supervisor, as: ComputerHistorySupervisor
  alias FermixCore.ComputerUse
  alias FermixCore.ComputerUse.Supervisor, as: ComputerUseSupervisor
  alias FermixCore.Cues
  alias FermixCore.Cues.Supervisor, as: CuesSupervisor
  alias FermixCore.Harness.Supervisor, as: HarnessSupervisor
  alias FermixCore.Home.Candidate
  alias FermixCore.Home.Epoch
  alias FermixCore.Home.Move
  alias FermixCore.Home.Role
  alias FermixCore.Home.Snapshot.Scheduler, as: SnapshotScheduler
  alias FermixCore.HostFacts
  alias FermixCore.Jobs.RunnerSupervisor, as: JobRunnerSupervisor
  alias FermixCore.Jobs.Scheduler, as: JobScheduler
  alias FermixCore.Log.RedactingFormatter
  alias FermixCore.Management.Doctor, as: ManagementDoctor
  alias FermixCore.Management.Jobs, as: ManagementJobs
  alias FermixCore.Management.Lifecycle, as: ManagementLifecycle
  alias FermixCore.Management.McpServers.DraftValues, as: McpDraftValues
  alias FermixCore.Management.Plugins.Discovery, as: ManagementPluginDiscovery
  alias FermixCore.Meetings.Supervisor, as: MeetingsSupervisor
  alias FermixCore.Memory.ConversationStore
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Store
  alias FermixCore.Native.Provider, as: NativeProvider
  alias FermixCore.NativeHost.Supervisor, as: NativeHostSupervisor
  alias FermixCore.Net.Egress
  alias FermixCore.OpenLoops.CheckInSupervisor, as: OpenLoopsCheckInSupervisor
  alias FermixCore.OpenLoops.Config, as: OpenLoopsConfig
  alias FermixCore.OpenLoops.Scheduler, as: OpenLoopsScheduler
  alias FermixCore.Plugins.CapabilitySeeder, as: PluginCapabilitySeeder
  alias FermixCore.Plugins.Dist.Installer, as: PluginInstaller
  alias FermixCore.Prompt.BootstrapRename
  alias FermixCore.Prompt.IdentityName
  alias FermixCore.Prompt.TemplateReconciler
  alias FermixCore.Realtime.Config, as: RealtimeConfig
  alias FermixCore.Realtime.Supervisor, as: RealtimeSupervisor
  alias FermixCore.Sandbox.CommandCapabilities
  alias FermixCore.Sandbox.DecisionTelemetry
  alias FermixCore.Setup.BootReport
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.EngineOwner
  alias FermixCore.Setup.HomeSeeder
  alias FermixCore.Setup.RestartState
  alias FermixCore.Setup.SecretAclState
  alias FermixCore.Setup.SecretWriteLog
  alias FermixCore.SkillCuration.Config, as: SkillCurationConfig
  alias FermixCore.SkillCuration.Scheduler, as: SkillCurationScheduler
  alias FermixCore.Temporal.DeliverySupervisor, as: TemporalDeliverySupervisor
  alias FermixCore.Temporal.Scheduler, as: TemporalScheduler
  alias FermixCore.Trace

  # Compile-time env: the boot-time computer-use sidecar ensure is a network
  # side effect, so it is gated OUT of `:test` here (never in `mix test`).
  @compiled_env Mix.env()

  @impl true
  def start(_type, _args) do
    profile =
      BootProfile.select(
        BuildInfo.distribution_identity(),
        &BurritoUtil.running_standalone?/0
      )

    :ok = BootProfile.remember(profile)
    start_profile(profile)
  end

  defp start_profile(:app_engine) do
    :ok = BootProfile.prepare(:app_engine)
    start_supervision_tree()
  end

  defp start_profile(:standalone_cli), do: cli_dispatch(:standalone_cli, BurritoArgs.argv())

  # The packaged Linux CLI (M38 §4.4.7). The baseline `PATH` is applied before
  # every verb, not only the daemon ones: a packaged `fermix` is invoked by the
  # desktop client and by systemd as often as from a shell, and both hand it an
  # environment that resolves neither the bundled `cosign` nor a vendor CLI in
  # `~/.local/bin`. It appends only, so an operator's own `PATH` is never shadowed.
  defp start_profile(:linux_package_cli) do
    _added = PathBaseline.ensure!()
    cli_dispatch(:linux_package_cli, BurritoArgs.argv())
  end

  # Dev (mix test, mix fermix.dev, iex -S mix phx.server) or an ordinary
  # plain release. `mix fermix.dev` sets the existing gates before starting
  # the application; only the immutable app-engine profile opens all daemon
  # surfaces here without going through the CLI.
  defp start_profile(:source), do: start_supervision_tree()

  # `run`: enable the endpoint server now (before OTP proceeds to start
  # fermix_web), build the supervision tree, then spawn `Fermix.CLI.Run`
  # for log + block. The BEAM stays alive because all sibling apps are
  # `:permanent` — we do not call `System.halt`.
  defp cli_dispatch(profile, ["run" | _] = argv), do: run_daemon(profile, argv)

  # `service run` is the systemd vendor unit's launch entry point (M38 §4.2),
  # and it is the daemon run under another name: the binding that names this
  # service's home is resolved in `config/runtime.exs`, before any configuration
  # is read, so by the time dispatch happens there is nothing left to decide.
  defp cli_dispatch(profile, ["service", "run" | rest]), do: run_daemon(profile, ["run" | rest])

  # `setup`: the service-first web path avoids the local tree and starts
  # the real daemon instead. Terminal setup still builds the tree needed
  # for `SetupSeeder`, then halts before sibling OTP apps start.
  defp cli_dispatch(_profile, ["setup" | _] = argv) do
    if Setup.supervision_required?(tl(argv)) do
      {:ok, _pid} = start_supervision_tree()
    end

    System.halt(run_cli(argv))
  end

  defp cli_dispatch(_profile, ["memory" | _] = argv) do
    {:ok, _pid} = start_supervision_tree()
    System.halt(run_cli(argv))
  end

  # version / help / start / stop / pair / devices / unknown — no local tree.
  # Mobile management is deliberately daemon-only: the daemon owns the one
  # pairing window, device store, and live socket registry. Starting a second
  # tree here would create a competing listener and a split persistence path.
  # Halt before any sibling app starts so there is no file logger, no
  # `Memory.Repo`, no token manager, and no port bind.
  defp cli_dispatch(_profile, argv) do
    System.halt(run_cli(argv))
  end

  defp run_daemon(profile, argv) do
    :ok = BootProfile.prepare(profile)

    with {:ok, pid} <- start_supervision_tree() do
      spawn(fn -> run_cli(argv) end)
      {:ok, pid}
    end
  end

  defp start_supervision_tree do
    # First, before anything writes to the home or opens `memory.db`: a home
    # that moved refuses to open as the primary here, by name, and the boot
    # fails (M75 step 1). Every later child list is filtered by this role.
    :ok =
      Role.remember!(ConfigStore.fermix_home(), Application.get_env(:fermix_core, :engine, []))

    :ok = HostFacts.remember()
    remember_launch_cwd()
    :ok = prepare_home(ConfigStore.fermix_home(), Role.current())
    setup_file_logger()
    redact_default_logger()
    Trace.TelemetryHandler.attach()
    DecisionTelemetry.attach()
    maybe_ensure_sidecar(Role.current())

    opts = [strategy: :rest_for_one, name: FermixCore.Supervisor]

    Supervisor.start_link(supervision_children(Egress.activate(), Role.current()), opts)
  end

  # What a boot writes into its home before any child starts. A candidate
  # (M75 §2) writes nothing there: its home is where a move will rename a
  # restored one into place, so it gets no workspace, no epoch, no prompt
  # files and no token-file check. A primary first finishes a candidate's
  # activation that a crash cut short after the restored settings were in place
  # (`Candidate.finish_activation/1`), before anything reads the home. Then
  # either role says the ending of a move the engine before this restart
  # left half-said (`Move.finish_at_boot/2`): only the engine that came back
  # publishes `done` or `aborted`.
  defp prepare_home(_root, :candidate), do: :ok

  defp prepare_home(root, role) do
    :ok = finish_activation(root, role)
    :ok = finish_move(root, role)
    :ok = ConfigStore.ensure_workspace()
    :ok = initialise_primary_epoch(root, role)
    :ok = BootstrapRename.run()
    :ok = IdentityName.reconcile()
    AuthStore.validate_permissions!()
  end

  defp finish_activation(_root, :device), do: :ok

  defp finish_activation(root, :primary) do
    case Candidate.finish_activation(root) do
      :ok -> :ok
      {:error, reason} -> raise Candidate.error_sentence(reason)
    end
  end

  # A failure here does not stop the boot, and is not dropped: the boot
  # records that it left the ending unrecorded, and `home.status` tries the
  # write again at each read and says the ending and why until it is written
  # (`Move.view/3`); an unreadable phase file is named by the move worker
  # (device) or the next `home.move.start` (primary). The log says so now.
  defp finish_move(root, role) do
    case Move.finish_at_boot(root, role) do
      :ok -> :ok
      {:error, reason} -> left_to_status(reason)
    end
  end

  defp left_to_status(reason) do
    Logger.error(
      "move: the ending of a move could not be recorded at boot (#{inspect(reason)}); " <>
        "home.status tries again at each read and says why until it is recorded"
    )

    Move.remember_unrecorded_ending()
  end

  # A primary home carries its epoch from its first boot (M75 D14): 1 when it
  # has none, kept when it has one, refused by name when the file is invalid.
  # It lands here, before the channels application starts the mobile subtree,
  # so the phone identity's own epoch write never races it. A device-role boot
  # mints nothing: its home is a retired copy or was never the primary.
  defp initialise_primary_epoch(_root, :device), do: :ok

  defp initialise_primary_epoch(root, :primary) do
    case Epoch.initialise(root) do
      {:ok, _state, _epoch} -> :ok
      {:error, reason} -> raise Epoch.error_sentence(reason)
    end
  end

  # The children this boot starts, in order, for the engine `role`:
  # `Role.children/2` leaves a device's primary-only ones out. Public (@doc
  # false) so tests read the real list for a role without booting a second tree.
  @doc false
  @spec supervision_children(Egress.t(), Role.role()) :: [Role.child()]
  def supervision_children(%Egress{} = egress, role)
      when role in [:primary, :device, :candidate] do
    children =
      [
        # First child (`:rest_for_one`): every process that can run an external
        # command starts after its owner supervisor exists. `:temporary` hosts
        # add no restart intensity to the tree.
        CommandHostSupervisor,
        {Task.Supervisor, name: FermixCore.TaskSupervisor},
        # The OAuth loopback listeners open now (M75 D17), before anything
        # that runs a sign-in: a desktop's sign-in is forwarded from it.
        FermixCore.Auth.LoopbackRegistry,
        finch_children(egress),
        {Trace, trace_opts()},
        TokenSupervisor,
        # The browser bridge listens on a socket the browser extension's pump
        # connects to, so it starts in a daemon and nowhere else — the same
        # question `maybe_daemon_socket/0` answers below.
        {FermixCore.Browser.Supervisor, bridge: daemon_boot?()},
        CapabilityRegistry,
        BuiltinSeeder,
        {CommandCapabilities, capability_registry: CapabilityRegistry},
        PluginInstaller,
        {PluginCapabilitySeeder, capability_registry: CapabilityRegistry},
        {SkillRegistry, capability_registry: CapabilityRegistry},
        # Outside the MCP tree on purpose (M27 §7.8): a remote server's subtree
        # is `:temporary`, so a status table living inside it would vanish
        # exactly when it holds the only explanation of why the client is gone.
        McpRuntimeStatus,
        # The login shell's PATH, read the first time an operator stdio server
        # starts, never at boot: most homes have none.
        McpLoginPath,
        {McpSupervisor, capability_registry: CapabilityRegistry},
        Repo,
        # Prompt-template reconciliation (M43 §9.3) runs here and nowhere else:
        # it needs the resource registry, so it cannot join `BootstrapRename` and
        # `IdentityName` above `Repo`, and it must finish before `MainAgent` or
        # the realtime supervisor composes a prompt — one pass, before any turn,
        # so nothing can read a half-migrated set and no cache needs invalidating.
        TemplateReconciler,
        # A home with no config yet is seeded here (owner rule of 2026-09-27):
        # after the registry and the repo the prompt seed needs, before the
        # restart state and the boot report so both read the seeded file as
        # the baseline rather than as a change made behind their backs.
        HomeSeeder,
        ConversationStore,
        Store,
        # Before the boot report and the restart state, because both of those
        # start by reading state a secret write can change, and a write that
        # landed before this process exists is a rotation nothing recorded.
        SecretWriteLog,
        # The record of the last keychain-ACL measurement. Measuring prompts,
        # so only Doctor measures; `setup.state.get` publishes what is recorded
        # here and never shells out.
        SecretAclState,
        BootReport,
        # Beside `BootReport` rather than inside it: the boot report is the boot
        # artifact its name promises, while restart and external-change truth is
        # read live by `/health`, `overview.get` and `setup.state.get`. One read
        # path, no cache plus an invalidation rule.
        RestartState,
        # The daemon's record of which allowed sandbox variables it can read
        # (boot probe, every config apply, every shell command). Before every
        # process that runs shell commands, so readiness has an answer before
        # the first command; after the command host, because a `command`
        # source spawns its helper through it.
        FermixCore.Sandbox.EnvHealth,
        # Access-sensitive calls parked for the owner's confirmation
        # (`Capabilities.AccessGate`). Before every process that dispatches a
        # tool; a restart forgets them, which asks the owner again.
        FermixCore.Capabilities.AccessGate.Pending,
        # The place records a conversation's searches returned, kept for the
        # reply that links them (M72). Before every process that dispatches a
        # tool; a restart forgets them, and a reply then carries its text alone.
        FermixCore.ReplyBlocks,
        AgentSupervisor,
        MainAgent,
        JobRunnerSupervisor,
        # Meetings tree (M21 C2 §2.9), unconditionally: it holds no OS process
        # and spawns nothing until `Meetings.join/2`, so an always-on tree lets
        # web setup enable meetings without a daemon restart, and lets the boot
        # sweep reconcile rows stranded by an install that has since been
        # turned off. The enable gate lives in `join/2` and the tool seeder.
        MeetingsSupervisor,
        {JobScheduler, jobs_scheduler_opts()},
        # Temporal reminder rail (M30 §6.3): the scheduler starts BEFORE its
        # delivery supervisor, and that order is load-bearing — under
        # `:rest_for_one` a scheduler crash tears down the supervisor and every
        # in-flight worker first, so no delivery worker can outlive the
        # scheduler. That invariant is what replaces lease tokens and fenced
        # settlement. Timers are gated by an init-time flag (the jobs-scheduler
        # precedent), disabled in `config/test.exs`, never by omission.
        {TemporalScheduler, temporal_scheduler_opts()},
        TemporalDeliverySupervisor,
        # Open-loop check-ins (M78 §04 stage 3), the temporal shape: the
        # scheduler starts BEFORE its check-in supervisor, so under
        # `:rest_for_one` a scheduler crash tears down every in-flight check-in
        # (and every later child) before it restarts, and its boot sweep then
        # returns the claims those runs held. Absent unless enabled.
        maybe_open_loops_children(),
        # Coding-harness local rail (design §6.4 / spec §5): one `:rest_for_one`
        # supervisor (Manager → RunSupervisor → DeliveryWorker) so a Manager crash
        # tears down and re-reconciles live runs instead of orphaning them. Always
        # in the tree so boot reconciliation + the delivery drain run even when the
        # feature is disabled; timers are gated by an init-time flag (the scheduler
        # precedent), disabled in `config/test.exs`, never by omission.
        {HarnessSupervisor, harness_worker_opts()},
        maybe_daemon_socket(),
        maybe_native_host(),
        maybe_realtime_supervisor(),
        maybe_computer_use_supervisor(),
        maybe_computer_history_supervisor(),
        maybe_skill_curation_scheduler(),
        # The primary's snapshots (M75 §8), before the cue tree so a crash of
        # either restarts nothing but the cue tree. Its timers stay dark under
        # `mix test`; tests start their own with an injected clock and timer.
        {SnapshotScheduler, timer_enabled: @compiled_env != :test},
        # Deletes expired browser hand-offs (M75 D18) from the owner profile;
        # dark under `mix test`, where tests start their own.
        {FermixCore.Browser.Handoff.Sweeper, timer_enabled: @compiled_env != :test},
        # Cue tree (M60 §5.3) LAST, and that order is load-bearing, as it is
        # for the temporal rail above: under `:rest_for_one` a crash of
        # `JobScheduler` or anything before it restarts the cue subsystem,
        # which re-reads its rows, and a crash inside it restarts nothing
        # outside it. Present only where `Cues.enabled?/0` admits it.
        maybe_cues_supervisor()
      ]
      |> List.flatten()

    Role.children(children, role)
  end

  # Shared outbound HTTP pool for `FermixCore.Net.HttpClient`. Finch's
  # default `conn_max_idle_time` is `:infinity`, so a long-lived daemon
  # reuses keep-alive sockets that cloud LBs silently RST'd while the host
  # slept or sat idle — the next request then fails with a `:closed`
  # transport error before any byte arrives. Capping idle age means
  # checkout discards stale connections and handshakes fresh ones (a few
  # hundred ms of TLS, noise next to an LLM call).
  @http_conn_max_idle_ms 15_000

  # Finch's default pool count is 1 — a single pool process per host. Right
  # after wake-from-sleep that lone process can block ~5s tearing down a stale
  # socket (a synchronous `:ssl.close`), and every checkout queued behind it
  # times out as "excess queuing for connections" — which has silently dropped
  # scheduled Telegram deliveries. Running a few pool processes per host lets a
  # checkout be served while one process is mid-teardown, so the wider
  # `pool_timeout` (see `FermixCore.Net.HttpClient`) is a rarely-needed floor
  # rather than the common path.
  @http_pool_count 2

  # Web-search backend hosts get the same idle-capped pool plus the backends'
  # fail-fast connect budget (they degrade to DuckDuckGo on failure, so a dead
  # provider should fail in seconds, not hang the reply path on a stalled
  # connect). The budget lives here rather than as per-request
  # `connect_options` because Req forbids `:connect_options` with `:finch` —
  # and per-request `connect_options` is exactly what used to fork these
  # backends onto Req-managed dynamic pools with `conn_max_idle_time:
  # :infinity`, reviving the stale-socket `:closed` class this pool exists to
  # kill. Keep in sync with the backends' `@endpoint` hosts.
  @web_search_connect_timeout_ms 3_000
  @web_search_hosts [
    "https://api.exa.ai",
    "https://api.firecrawl.dev",
    "https://api.parallel.ai",
    "https://api.perplexity.ai",
    "https://api.search.brave.com",
    "https://api.tavily.com",
    "https://html.duckduckgo.com"
  ]

  # Public (@doc false) because Finch has no API to read pool config back,
  # so tests pin these literals here — a regression to the :infinity / count:1
  # defaults would otherwise be invisible to the suite. Every pool dials IPv6
  # first and falls back to IPv4 (`Egress.prefer_ipv6/1`).
  @doc false
  @spec finch_pools() :: %{(atom() | String.t()) => keyword()}
  def finch_pools do
    Map.merge(
      %{
        :default => [
          conn_max_idle_time: @http_conn_max_idle_ms,
          count: @http_pool_count,
          conn_opts: Egress.prefer_ipv6([])
        ]
      },
      Map.new(@web_search_hosts, &{&1, web_search_pool()})
    )
  end

  defp web_search_pool do
    [
      conn_max_idle_time: @http_conn_max_idle_ms,
      count: @http_pool_count,
      conn_opts: Egress.prefer_ipv6(transport_opts: [timeout: @web_search_connect_timeout_ms])
    ]
  end

  @doc """
  The outbound pools this process runs: the direct one always, and a second one
  for proxied destinations when `[fermix_core.network]` names a proxy. The
  proxied table is the direct table with the proxy added, so both keep the idle
  caps and pool counts above.
  """
  @spec finch_instances(Egress.t()) :: [keyword()]
  def finch_instances(%Egress{} = egress) do
    direct = [name: Egress.direct_pool(), pools: finch_pools()]

    case Egress.proxied_pools(egress, finch_pools()) do
      nil -> [direct]
      proxied -> [direct, [name: Egress.proxied_pool(), pools: proxied]]
    end
  end

  @doc """
  Starts the outbound pools for a caller that has no supervision tree (a CLI
  verb, a Mix task), through the same constructor the daemon uses, so a probe
  travels the route a turn would. A no-op when the pools are already running.
  """
  @spec ensure_finch_pools() :: :ok
  def ensure_finch_pools do
    if Process.whereis(Egress.direct_pool()) == nil do
      Egress.activate() |> finch_instances() |> Enum.each(&start_finch!/1)
    end

    :ok
  end

  defp start_finch!(instance) do
    {:ok, _pid} = Finch.start_link(instance)
    :ok
  end

  defp finch_children(egress) do
    egress
    |> finch_instances()
    |> Enum.map(&Supervisor.child_spec({Finch, &1}, id: Keyword.fetch!(&1, :name)))
  end

  defp run_cli(argv) do
    Fermix.CLI.main(argv)
  rescue
    error ->
      IO.puts(:stderr, "fermix: unexpected error — #{Exception.message(error)}")
      IO.puts(:stderr, Exception.format_stacktrace(__STACKTRACE__))
      1
  end

  # The management operations the socket routes to are owned by long-lived
  # processes (one drain lease, retained Doctor sessions, retained jobs), so
  # they start with the socket and never independently of it: a management
  # method whose owner is absent would answer `unavailable` for the life of the
  # daemon.
  defp maybe_daemon_socket do
    if Application.get_env(:fermix_core, :daemon_socket_enabled, false) do
      # The ownership marker is rewritten by the engine that is actually serving
      # this home, which is exactly the set of boots that can claim it. A source
      # run or a test tree serves no socket and claims nothing.
      :ok = EngineOwner.record()

      [
        ManagementLifecycle,
        ManagementDoctor,
        ManagementJobs,
        # Beside the job family it serves: a workspace discovery is a job, and
        # what it found is republished on the plugin row rather than in the job.
        ManagementPluginDiscovery,
        # The values a pasted MCP server carried, held in memory under their
        # draft_id until an add stores them; a restart forgets every one.
        McpDraftValues,
        Daemon
      ]
    else
      []
    end
  end

  # The Fermix app's native host socket (M76 §4.4): served by a daemon whose
  # provider is the app, the one build an app attaches to for this Mac's own
  # services. Every other build serves nothing an app could attach to.
  defp maybe_native_host do
    if daemon_boot?() and NativeProvider.current() == :mac_app,
      do: [NativeHostSupervisor],
      else: []
  end

  defp maybe_realtime_supervisor do
    if realtime_socket_enabled?() and realtime_ready?() do
      [RealtimeSupervisor]
    else
      []
    end
  end

  # Same gate as tool registration (`ComputerUse.ready?/0`): the session
  # infrastructure boots only when computer use is enabled, the sidecar is
  # installed, and OS permissions are granted. Off/unready (the default) starts
  # nothing — no OS-driver process is ever spawned.
  defp maybe_computer_use_supervisor do
    if ComputerUse.ready?() do
      [ComputerUseSupervisor]
    else
      []
    end
  end

  # Computer History (MILESTONE_32 §6.3): the always-present, inert supervisor
  # is present on macOS whenever the daemon boots, regardless of `enabled?()` —
  # Retention must always run so a spool left behind by a disable still drains
  # by the 48h horizon (inv. 16). Its work is tick-gated; the timer is disabled
  # in `:test` (the scheduler precedent), never by omission. Off macOS the whole
  # feature is unavailable, so the supervisor is absent (Decision 12).
  defp maybe_computer_history_supervisor do
    if ComputerHistory.macos?() do
      [{ComputerHistorySupervisor, timer_enabled: @compiled_env != :test}]
    else
      []
    end
  end

  # Skill-curation clock (MILESTONE_26_SKILL_CURATION §6.1): child-ABSENT when
  # gated out. Three conditions, all required — the compile-time env gate (the
  # env-flag-is-not-an-env-gate lesson), the config switch, and memory
  # persistence (every curation surface lives in memory.db; with memory off
  # the scheduler would only churn run_error every cycle). Public (@doc false)
  # so tests can pin the gating without booting a second app tree; the env
  # param exists only so tests can exercise the non-test branches — production
  # callers always use the baked default.
  @doc false
  def maybe_skill_curation_scheduler(compiled_env \\ @compiled_env) do
    if compiled_env != :test and SkillCurationConfig.enabled?() and
         FermixCore.Memory.Config.enabled?() do
      [SkillCurationScheduler]
    else
      []
    end
  end

  # Open loops (MILESTONE_78 §10): child-ABSENT when gated out, the
  # skill-curation precedent. The compile-time env gate (so `mix test` never
  # starts the rail and `config/test.exs` never needs to reach its timers), the
  # config switch, default off, and memory persistence (every loop lives in
  # memory.db; with memory off the scheduler would only log a failed scan every
  # five seconds). Read once at boot: a switch flipped afterwards takes effect
  # at the next start. Public (@doc false) so tests can pin the gating; the env
  # param exists only for the non-test branches.
  @doc false
  def maybe_open_loops_children(compiled_env \\ @compiled_env) do
    if compiled_env != :test and OpenLoopsConfig.enabled?() and
         FermixCore.Memory.Config.enabled?() do
      [{OpenLoopsScheduler, [timer_enabled: true]}, OpenLoopsCheckInSupervisor]
    else
      []
    end
  end

  # Cue subsystem (M60 §5.3, §15): child-ABSENT when gated out, like the
  # skill-curation clock above. `Cues.enabled?/0` holds the
  # `[fermix_core.cues] enabled` switch and memory being on; `mix test` never
  # starts the tree on top of that, so no suite reaches the door's port or the
  # sweeps. Public (@doc false) for the gating test; production callers use the
  # baked default.
  @doc false
  def maybe_cues_supervisor(compiled_env \\ @compiled_env) do
    if compiled_env != :test and Cues.enabled?() do
      [CuesSupervisor]
    else
      []
    end
  end

  # Only in a real daemon boot: if a feature that needs the compux sidecar is
  # enabled but the sidecar for the compiled-in version isn't installed — the
  # state a fermix upgrade that bumped the compux ref lands in — download it now,
  # before the readiness gates (tool registration + supervisor boot) run, so the
  # upgrade transparently keeps those features working. The one binary is shared,
  # so EITHER computer-use or computer-history wanting it triggers the download.
  # Fail-soft and bounded; see `ComputerUse.ensure_sidecar_installed/1`.
  # A candidate installs nothing: it is a fresh host waiting for a move.
  defp maybe_ensure_sidecar(:candidate), do: :ok

  defp maybe_ensure_sidecar(_role) do
    if daemon_boot?() do
      ComputerUse.ensure_sidecar_installed(
        wanted?: ComputerUse.enabled?() or ComputerHistory.operative?()
      )
    else
      :ok
    end
  end

  # A real in-process daemon run (`fermix run` / `mix fermix.dev`) — both enable
  # the daemon control socket before the tree builds — and never `mix test`,
  # `fermix setup`, or `fermix memory`.
  defp daemon_boot? do
    @compiled_env != :test and
      Application.get_env(:fermix_core, :daemon_socket_enabled, false)
  end

  defp realtime_socket_enabled? do
    Application.get_env(:fermix_core, :realtime_socket_enabled, false)
  end

  defp realtime_ready? do
    config = RealtimeConfig.current()

    config.enabled? and RealtimeConfig.api_key_present?(config)
  end

  defp trace_opts, do: [base_dir: trace_dir()]

  defp jobs_scheduler_opts do
    Application.get_env(:fermix_core, :jobs, [])
  end

  # The harness `Manager`/`DeliveryWorker` are permanent, but their timers + boot
  # reconciliation + artifact GC must stay dark under `mix test` (the scheduler's
  # `scheduler_enabled` precedent). One init-time flag, defaulting on, gates both
  # workers; `config/test.exs` sets it false so the app tree touches neither the
  # real `Memory.Repo` nor the real `FERMIX_HOME` on boot.
  defp harness_worker_opts do
    [timer_enabled: Application.get_env(:fermix_core, :harness_workers_enabled, true)]
  end

  # The temporal scheduler has no operator TOML surface: reminder timing is
  # internal constants (M30 §6.3). This key exists so `config/test.exs` can keep
  # the app-tree instance dark the way `[:jobs] scheduler_enabled` does, so
  # `mix test` never sweeps or claims against the real `Memory.Repo`.
  defp temporal_scheduler_opts do
    Application.get_env(:fermix_core, :temporal, [])
  end

  defp setup_file_logger do
    log_config = Application.get_env(:fermix_core, :log, [])

    if Keyword.get(log_config, :enabled, true) do
      log_file = Keyword.get(log_config, :file, default_log_file())
      max_bytes = Keyword.get(log_config, :max_no_bytes, 10_485_760)
      max_files = log_max_no_files()

      File.mkdir_p!(Path.dirname(log_file))

      case :logger.add_handler(:fermix_file, :logger_std_h, %{
             config: %{
               file: String.to_charlist(log_file),
               max_no_bytes: max_bytes,
               max_no_files: max_files
             },
             formatter:
               RedactingFormatter.wrap(
                 {:logger_formatter, %{template: [:time, ~c" ", :level, ~c" ", :msg, ~c"
"]}}
               )
           }) do
        :ok -> :ok
        {:error, {:already_exist, _}} -> :ok
        {:error, reason} -> Logger.warning("Failed to add file logger: #{inspect(reason)}")
      end
    end
  end

  defp redact_default_logger do
    case RedactingFormatter.install(:default) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to install log redaction on default handler: #{inspect(reason)}")
    end
  end

  @doc """
  The directory `FermixCore.Trace` writes its JSONL rows under:
  `[:fermix_core, :trace] :base_dir`, else the workspace's `traces` directory.

  Public so the Doctor's provider health check
  (`FermixCore.Setup.ProviderHealth`) reads the rows the Trace child writes:
  one resolver for "where are the traces", not two that can drift.
  """
  @spec trace_dir() :: Path.t()
  def trace_dir do
    :fermix_core
    |> Application.get_env(:trace, [])
    |> Keyword.get_lazy(:base_dir, &default_trace_dir/0)
  end

  defp default_trace_dir, do: ConfigStore.workspace_paths().traces

  @doc """
  The log file `:logger_std_h` writes when `[:fermix_core, :log] :file` is unset.

  Public so `FermixCore.Management.Logs` reads the same rotated set the handler
  writes — one resolver for "where is the log", not two that can drift.
  """
  @spec default_log_file() :: Path.t()
  def default_log_file, do: Path.join(ConfigStore.workspace_paths().logs, "fermix.log")

  @doc """
  How many rotated archives `:logger_std_h` retains beside the live log file.

  One resolver, for the same reason `default_log_file/0` is one: the handler
  writes the set and `FermixCore.Management.Logs` reads it, and two resolvers
  with different defaults make the reader silently scan fewer files than the
  handler keeps.
  """
  @spec log_max_no_files() :: non_neg_integer()
  def log_max_no_files do
    :fermix_core
    |> Application.get_env(:log, [])
    |> Keyword.get(:max_no_files, 10)
  end

  defp remember_launch_cwd do
    Application.put_env(:fermix_core, :sandbox_launch_cwd, File.cwd!())
  end
end
