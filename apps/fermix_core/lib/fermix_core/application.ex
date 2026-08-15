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
  alias FermixCore.Auth.TokenManager
  alias FermixCore.Auth.TokenSupervisor
  alias FermixCore.Capabilities.BuiltinSeeder
  alias FermixCore.Capabilities.MCP.RuntimeStatus, as: McpRuntimeStatus
  alias FermixCore.Capabilities.MCP.Supervisor, as: McpSupervisor
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.CommandHost.Supervisor, as: CommandHostSupervisor
  alias FermixCore.ComputerUse
  alias FermixCore.ComputerUse.Supervisor, as: ComputerUseSupervisor
  alias FermixCore.Config, as: CoreConfig
  alias FermixCore.Harness.Supervisor, as: HarnessSupervisor
  alias FermixCore.Jobs.RunnerSupervisor, as: JobRunnerSupervisor
  alias FermixCore.Jobs.Scheduler, as: JobScheduler
  alias FermixCore.Log.RedactingFormatter
  alias FermixCore.Memory.ConversationStore
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Store
  alias FermixCore.Plugins.CapabilitySeeder, as: PluginCapabilitySeeder
  alias FermixCore.Plugins.Dist.Installer, as: PluginInstaller
  alias FermixCore.Prompt.BootstrapRename
  alias FermixCore.Prompt.IdentityName
  alias FermixCore.Providers.PrimaryConfig
  alias FermixCore.Providers.Selection
  alias FermixCore.Realtime.Config, as: RealtimeConfig
  alias FermixCore.Realtime.Supervisor, as: RealtimeSupervisor
  alias FermixCore.Sandbox.CommandCapabilities
  alias FermixCore.Sandbox.DecisionTelemetry
  alias FermixCore.Setup.BootReport
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.SkillCuration.Config, as: SkillCurationConfig
  alias FermixCore.SkillCuration.Scheduler, as: SkillCurationScheduler
  alias FermixCore.Temporal.DeliverySupervisor, as: TemporalDeliverySupervisor
  alias FermixCore.Temporal.FollowupSupervisor, as: TemporalFollowupSupervisor
  alias FermixCore.Temporal.Scheduler, as: TemporalScheduler
  alias FermixCore.Trace

  # Compile-time env: the boot-time computer-use sidecar ensure is a network
  # side effect, so it is gated OUT of `:test` here (never in `mix test`).
  @compiled_env Mix.env()

  @impl true
  def start(_type, _args) do
    if BurritoUtil.running_standalone?() do
      cli_dispatch(BurritoArgs.argv())
    else
      # Dev (mix test, mix fermix.dev, iex -S mix phx.server) or plain
      # release (`bin/fermix start`). All sibling apps are `:permanent`,
      # so OTP auto-starts them after this returns; whether the Phoenix
      # endpoint binds is governed by the existing PHX_SERVER convention
      # in `config/runtime.exs`. `mix fermix.dev` sets the gating env
      # flags before calling `Application.ensure_all_started/1`, so the
      # daemon socket and Realtime supervisor start without going
      # through `cli_dispatch/1`.
      start_supervision_tree()
    end
  end

  # `run`: enable the endpoint server now (before OTP proceeds to start
  # fermix_web), build the supervision tree, then spawn `Fermix.CLI.Run`
  # for log + block. The BEAM stays alive because all sibling apps are
  # `:permanent` — we do not call `System.halt`.
  defp cli_dispatch(["run" | _] = argv) do
    enable_endpoint_server()
    enable_daemon_socket()
    enable_realtime_socket()

    with {:ok, pid} <- start_supervision_tree() do
      spawn(fn -> run_cli(argv) end)
      {:ok, pid}
    end
  end

  # `setup`: the service-first web path avoids the local tree and starts
  # the real daemon instead. Terminal setup still builds the tree needed
  # for `SetupSeeder`, then halts before sibling OTP apps start.
  defp cli_dispatch(["setup" | _] = argv) do
    if Setup.supervision_required?(tl(argv)) do
      {:ok, _pid} = start_supervision_tree()
    end

    System.halt(run_cli(argv))
  end

  defp cli_dispatch(["memory" | _] = argv) do
    {:ok, _pid} = start_supervision_tree()
    System.halt(run_cli(argv))
  end

  # version / help / start / stop / pair / devices / unknown — no local tree.
  # Mobile management is deliberately daemon-only: the daemon owns the one
  # pairing window, device store, and live socket registry. Starting a second
  # tree here would create a competing listener and a split persistence path.
  # Halt before any sibling app starts so there is no file logger, no
  # `Memory.Repo`, no `TokenManager`, and no port bind.
  defp cli_dispatch(argv) do
    System.halt(run_cli(argv))
  end

  defp enable_endpoint_server do
    existing = Application.get_env(:fermix_web, FermixWebWeb.Endpoint, [])
    Application.put_env(:fermix_web, FermixWebWeb.Endpoint, Keyword.put(existing, :server, true))
  end

  defp enable_daemon_socket do
    Application.put_env(:fermix_core, :daemon_socket_enabled, true)
  end

  defp enable_realtime_socket do
    Application.put_env(:fermix_core, :realtime_socket_enabled, true)
  end

  defp start_supervision_tree do
    remember_launch_cwd()
    :ok = ConfigStore.ensure_workspace()
    :ok = BootstrapRename.run()
    :ok = IdentityName.reconcile()
    :ok = AuthStore.validate_permissions!()
    setup_file_logger()
    redact_default_logger()
    Trace.TelemetryHandler.attach()
    DecisionTelemetry.attach()
    maybe_ensure_computer_use_sidecar()

    children =
      [
        # First child (`:rest_for_one`): every process that can run an external
        # command starts after its owner supervisor exists. `:temporary` hosts
        # add no restart intensity to the tree.
        CommandHostSupervisor,
        {Task.Supervisor, name: FermixCore.TaskSupervisor},
        {Finch, name: FermixCore.Finch, pools: finch_pools()},
        {Trace, trace_opts()},
        TokenSupervisor,
        maybe_token_manager(),
        FermixCore.Browser.Supervisor,
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
        {McpSupervisor, capability_registry: CapabilityRegistry},
        Repo,
        ConversationStore,
        Store,
        BootReport,
        AgentSupervisor,
        MainAgent,
        JobRunnerSupervisor,
        {JobScheduler, jobs_scheduler_opts()},
        # Temporal reminder rail (M30 §6.3): the scheduler starts BEFORE its
        # delivery supervisor, and that order is load-bearing — under
        # `:rest_for_one` a scheduler crash tears down the supervisor and every
        # in-flight worker first, so no delivery worker can outlive the
        # scheduler. That invariant is what replaces lease tokens and fenced
        # settlement. Timers are gated by an init-time flag (the jobs-scheduler
        # precedent), disabled in `config/test.exs`, never by omission.
        #
        # The follow-up supervisor (§22.4) is LAST of the three, which the same
        # property serves twice: a scheduler crash tears down in-flight
        # deliveries and in-flight follow-ups together, and shutdown — reverse
        # order — kills follow-ups first, so a worker settling mid-shutdown can
        # find it already gone. That exit is caught, never fatal to a settlement.
        {TemporalScheduler, temporal_scheduler_opts()},
        TemporalDeliverySupervisor,
        TemporalFollowupSupervisor,
        # Coding-harness local rail (design §6.4 / spec §5): one `:rest_for_one`
        # supervisor (Manager → RunSupervisor → DeliveryWorker) so a Manager crash
        # tears down and re-reconciles live runs instead of orphaning them. Always
        # in the tree so boot reconciliation + the delivery drain run even when the
        # feature is disabled; timers are gated by an init-time flag (the scheduler
        # precedent), disabled in `config/test.exs`, never by omission.
        {HarnessSupervisor, harness_worker_opts()},
        maybe_daemon_socket(),
        maybe_realtime_supervisor(),
        maybe_computer_use_supervisor(),
        maybe_skill_curation_scheduler()
      ]
      |> List.flatten()

    opts = [strategy: :rest_for_one, name: FermixCore.Supervisor]

    Supervisor.start_link(children, opts)
  end

  # Shared outbound HTTP pool for `FermixCore.Net.HttpClient`. Finch's
  # default `conn_max_idle_time` is `:infinity`, so a long-lived daemon
  # reuses keep-alive sockets that cloud LBs silently RST'd while the host
  # slept or sat idle — the next request then fails with a `:closed`
  # transport error before any byte arrives. Capping idle age means
  # checkout discards stale connections and handshakes fresh ones (a few
  # hundred ms of TLS, noise next to an LLM call). chatgpt.com keeps the
  # Codex adapter's 5s connect timeout, moved here because Req forbids
  # combining `:finch` with `:connect_options`.
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

  # Reap a chatgpt.com pool process that has been idle this long: Finch's
  # `handle_ping` stops it (`{:stop, :idle_timeout}`, `restart: :transient`)
  # and the next request auto-starts a fresh one. Verified in deps/finch. This
  # moves stale-socket teardown OFF the request path — after a burst or a
  # wake, the sockets a returning checkout would otherwise have to close
  # synchronously are already gone with the reaped pool process, so a teardown
  # storm cannot land inside a checkout budget. It cannot rescue a pool process
  # that is ALREADY wedged mid-teardown (reaping is itself a ping-time
  # decision); the continuation retry in `FermixCore.AgentLoop` covers that.
  # Deliberately chatgpt.com only — the verified incident is Codex-specific,
  # and :default fans out over many low-traffic hosts where reaping would just
  # churn handshakes for no measured benefit.
  @codex_pool_max_idle_ms 60_000

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
  # defaults would otherwise be invisible to the suite.
  @doc false
  @spec finch_pools() :: %{(atom() | String.t()) => keyword()}
  def finch_pools do
    Map.merge(
      %{
        :default => [conn_max_idle_time: @http_conn_max_idle_ms, count: @http_pool_count],
        "https://chatgpt.com" => [
          conn_max_idle_time: @http_conn_max_idle_ms,
          count: @http_pool_count,
          pool_max_idle_time: @codex_pool_max_idle_ms,
          conn_opts: [transport_opts: [timeout: 5_000]]
        ]
      },
      Map.new(@web_search_hosts, &{&1, web_search_pool()})
    )
  end

  defp web_search_pool do
    [
      conn_max_idle_time: @http_conn_max_idle_ms,
      count: @http_pool_count,
      conn_opts: [transport_opts: [timeout: @web_search_connect_timeout_ms]]
    ]
  end

  defp run_cli(argv) do
    Fermix.CLI.main(argv)
  rescue
    error ->
      IO.puts(:stderr, "fermix: unexpected error — #{Exception.message(error)}")
      IO.puts(:stderr, Exception.format_stacktrace(__STACKTRACE__))
      1
  end

  # Codex participates in routing when it is the chosen primary (flag or
  # legacy agent.provider — PrimaryConfig owns that migration) OR a
  # configured failover fallback, so the token manager must be up for
  # either. Starting it tokenless is harmless (it serves {:error, :no_token});
  # NOT starting it while Codex is routable crashes the first Codex call
  # with :noproc.
  defp maybe_token_manager do
    if codex_routable?(), do: [TokenManager], else: []
  end

  defp codex_routable? do
    case PrimaryConfig.primary() do
      {:ok, :openai_codex} -> true
      _other_or_multiple -> Selection.configured?(:openai_codex)
    end
  end

  defp maybe_daemon_socket do
    if Application.get_env(:fermix_core, :daemon_socket_enabled, false) do
      [Daemon]
    else
      []
    end
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

  # Only in a real daemon boot: if computer-use is enabled but the sidecar for the
  # compiled-in compux version isn't installed — the state a fermix upgrade that
  # bumped the compux ref lands in — download it now, before the
  # `ComputerUse.ready?/0` gates (tool registration + supervisor boot) run, so the
  # upgrade transparently keeps computer-use working. Fail-soft and bounded; see
  # `ComputerUse.ensure_sidecar_installed/1`.
  defp maybe_ensure_computer_use_sidecar do
    if daemon_boot?(), do: ComputerUse.ensure_sidecar_installed(), else: :ok
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

    config.enabled? and config.provider == "openai" and
      match?({:ok, _api_key}, CoreConfig.provider_api_key(:openai))
  end

  defp trace_opts do
    trace_config = Application.get_env(:fermix_core, :trace, [])
    [base_dir: Keyword.get(trace_config, :base_dir, default_trace_dir())]
  end

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
      max_files = Keyword.get(log_config, :max_no_files, 10)

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

  defp default_trace_dir, do: ConfigStore.workspace_paths().traces
  defp default_log_file, do: Path.join(ConfigStore.workspace_paths().logs, "fermix.log")

  defp remember_launch_cwd do
    Application.put_env(:fermix_core, :sandbox_launch_cwd, File.cwd!())
  end
end
