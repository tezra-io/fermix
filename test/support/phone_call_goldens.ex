defmodule FermixTestSupport.PhoneCallGoldens do
  @moduledoc """
  The facts behind the Phone calls goldens (`success.jsonl`, `errors.jsonl`;
  M94 §12): a home whose phone calls are set up and on, a call in progress,
  a call that ended beside one whose end is unconfirmed, a dispatch whose
  answer was lost, and the stop of a call in progress. Each golden is what
  `Management.PhoneCalls` or `Management.Settings` builds from these invented
  facts, through a ledger of the case's own (`start_repo/0`) and a call
  manager that answers a stop as the real one does for a dialed call
  (`Manager`) and hands the owner's confirmation that a call ended to the
  real call manager over the same ledger, so a golden can only say what the
  engine says.

  Every name, number, id and credential here is invented.
  """

  import ExUnit.Callbacks, only: [start_supervised!: 2, on_exit: 1]

  alias FermixCore.Memory.Repo
  alias FermixCore.PhoneCalls.Brief
  alias FermixCore.PhoneCalls.Config
  alias FermixCore.PhoneCalls.Ledger
  alias FermixCore.Setup.ConfigStore

  @now ~U[2031-05-04 12:00:00.000000Z]
  @dialed_at ~U[2031-05-04 11:58:00.000000Z]
  @caller "+14155550142"
  @destination "+12125550101"
  @username "fermixtrunk01"
  @owner "default"
  @in_progress "pc_0a1b2c3d4e5f"
  @ended "pc_1b2c3d4e5f60"
  @unconfirmed "pc_2c3d4e5f6071"
  @lost "pc_3d4e5f607182"
  # What a test host cannot settle for readiness: this engine is the primary,
  # durable memory is on, and the backend a call's turns run on is wired (the
  # test build configures none, `config/test.exs`).
  @host [primary?: true, durable_memory?: true, call_backend?: true]

  defmodule Manager do
    @moduledoc """
    Answers `PhoneCalls.Manager.cancel/3` as the real manager does for a call
    already dialed: it marks the stop on the call's row and answers
    `{:ok, :stopping}`. Every other request is the real manager's
    (`opts[:real]`, which runs no call and reconciles nothing).
    """

    use GenServer

    alias FermixCore.PhoneCalls.Ledger

    def start_link(opts),
      do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

    @impl true
    def init(opts), do: {:ok, Map.new(opts)}

    @impl true
    def handle_call({:cancel, call_id, _owner}, _from, state) do
      {:ok, _row} = Ledger.mark_cancel_requested(call_id, state.now, server: state.repo)
      {:reply, {:ok, :stopping}, state}
    end

    def handle_call(request, _from, state),
      do: {:reply, GenServer.call(state.real, request), state}
  end

  @doc "The moment every golden is drawn at."
  @spec now() :: DateTime.t()
  def now, do: @now

  @doc "The ids of the goldens' calls."
  @spec ids() :: %{atom() => String.t()}
  def ids, do: %{in_progress: @in_progress, ended: @ended, unconfirmed: @unconfirmed, lost: @lost}

  @doc """
  A ledger of the calling test's own, supervised by it, with the calls of
  `world`: `:empty`, `:in_progress` (a call connected and talking), `:history`
  (a call that ended, then one whose end is unconfirmed) or `:lost` (a
  dispatch whose answer was lost). Answers the options `Management.PhoneCalls`
  takes, a call manager named in them that answers a stop.
  """
  @spec world(:empty | :in_progress | :history | :lost) :: keyword()
  def world(kind) when kind in [:empty, :in_progress, :history, :lost] do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-phone-goldens-#{unique}.db")
    repo = :"phone_goldens_repo_#{unique}"
    manager = :"phone_goldens_manager_#{unique}"
    real = :"phone_goldens_real_manager_#{unique}"
    registry = :"phone_goldens_registry_#{unique}"

    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path}, id: repo)
    start_supervised!({Registry, keys: :unique, name: registry}, id: registry)
    seed(kind, repo)
    live_worker(kind, registry)
    start_supervised!(real_manager(real, repo), id: real)
    start_supervised!({Manager, name: manager, repo: repo, now: @now, real: real}, id: manager)

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    [
      repo: repo,
      manager: manager,
      registry: registry,
      now: @now,
      owner_id: @owner,
      config: config(),
      readiness: @host ++ [openai_api_key?: true, sip_password?: true]
    ]
  end

  @doc """
  `world`'s options with its call manager one that is not the home's running
  engine (as `FermixCore.Application.phone_calls_opts/2` starts it outside
  the daemon): it owns none of the daemon's calls.
  """
  @spec not_the_daemon(keyword()) :: keyword()
  def not_the_daemon(world) when is_list(world) do
    name = :"phone_goldens_elsewhere_#{System.unique_integer([:positive])}"
    {module, opts} = real_manager(name, Keyword.fetch!(world, :repo))
    start_supervised!({module, Keyword.put(opts, :daemon, false)}, id: name)
    Keyword.put(world, :manager, name)
  end

  # The call in progress has a worker: a process registered under its id in
  # the world's call registry, as `PhoneCalls.Call` registers.
  defp live_worker(:in_progress, registry) do
    worker = {Agent, fn -> {:ok, _owner} = Registry.register(registry, @in_progress, nil) end}
    start_supervised!(worker, id: {:phone_goldens_worker, registry})
  end

  defp live_worker(_kind, _registry), do: :ok

  # The real call manager over the world's ledger: it runs no call (nothing is
  # admitted through it), reconciles nothing at boot and arms no timer.
  defp real_manager(name, repo) do
    {FermixCore.PhoneCalls.Manager,
     name: name,
     repo: repo,
     call_module: FermixCore.PhoneCalls.Call,
     hangup: fn _session_id -> :ok end,
     now_fn: fn -> @now end,
     reconcile: false,
     timer_enabled: false}
  end

  @doc "The section as the goldens' home holds it: on, with every setting made."
  @spec config() :: Config.t()
  def config,
    do: %Config{enabled: true, voice: "marin", caller_number: @caller, sip_username: @username}

  @doc """
  The settings snapshot of the goldens' home: phone calls set up and on, the
  trunk password and the OpenAI key stored, Talk to Fermix on Grok.
  """
  @spec snapshot() :: map()
  def snapshot do
    phone = Config.to_keyword(%Config{config() | sip_password: "invented-trunk-password"})

    Map.update(ConfigStore.current_snapshot(), :fermix_core, [], fn core ->
      providers = Keyword.get(core, :providers, [])
      openai = providers |> Keyword.get(:openai, []) |> Keyword.put(:api_key, "sk-invented-key")

      core
      |> Keyword.put(:phone_calls, phone)
      |> Keyword.put(:providers, Keyword.put(providers, :openai, openai))
      |> Keyword.put(:realtime,
        enabled: true,
        engine: "xai_realtime",
        model: "grok-voice-3.0",
        voice: "eve"
      )
    end)
  end

  @doc "The readiness inputs a section golden reads its host by."
  @spec host() :: keyword()
  def host, do: @host

  defp seed(:empty, _repo), do: :ok

  defp seed(:in_progress, repo) do
    admit!(repo, @in_progress, "main-golden-1")
    {:ok, _row} = Ledger.claim_dispatch(@in_progress, @dialed_at, server: repo)
    {:ok, _row} = Ledger.record_session(@in_progress, "sess_golden_1", @dialed_at, server: repo)
    {:ok, _row} = Ledger.advance(@in_progress, "active", @dialed_at, server: repo)
    {:ok, _row} = Ledger.record_usage(@in_progress, %{"seconds" => 41}, 41, server: repo)
    :ok
  end

  defp seed(:history, repo) do
    admit!(repo, @ended, "main-golden-2")
    {:ok, _row} = Ledger.claim_dispatch(@ended, @dialed_at, server: repo)
    {:ok, _row} = Ledger.record_session(@ended, "sess_golden_2", @dialed_at, server: repo)

    {:ok, _row} =
      Ledger.terminalize(
        @ended,
        "ended",
        %{
          ended_at: @dialed_at,
          outcome: "options",
          voice_seconds: 95,
          usage_state: "voice_duration_confirmed",
          backend_usage: %{"cost_usd" => 0.0042}
        },
        server: repo
      )

    admit!(repo, @unconfirmed, "main-golden-3")
    {:ok, _row} = Ledger.claim_dispatch(@unconfirmed, @now, server: repo)
    {:ok, _row} = Ledger.record_session(@unconfirmed, "sess_golden_3", @now, server: repo)

    {:ok, _row} =
      Ledger.terminalize(@unconfirmed, "closure_unconfirmed", %{ended_at: @now}, server: repo)

    :ok
  end

  defp seed(:lost, repo) do
    admit!(repo, @lost, "main-golden-4")
    {:ok, _row} = Ledger.claim_dispatch(@lost, @dialed_at, server: repo)

    {:ok, _row} =
      Ledger.terminalize(@lost, "dispatch_unknown", %{ended_at: @dialed_at}, server: repo)

    :ok
  end

  defp admit!(repo, id, request_id) do
    brief = brief()

    attrs = %{
      id: id,
      request_id: request_id,
      owner_id: @owner,
      authorization: "direct",
      origin_kind: "chat",
      delivery_mode: "origin",
      platform: "telegram",
      destination: "40017",
      mandate: Brief.to_map(brief),
      mandate_hash: Brief.hash(brief),
      model: "gpt-live-1",
      voice: "marin",
      prompt_version: "phone-golden-1",
      carrier_profile: "telnyx_credential_v1"
    }

    {:ok, {:admitted, _row}} = Ledger.admit(attrs, @dialed_at, server: repo)
    :ok
  end

  defp brief do
    params = %{
      "destination" => @destination,
      "destination_kind" => "business",
      "number_source" => "The bistro's own website.",
      "contact_name" => "Calloway Bistro",
      "timezone" => "America/New_York",
      "goal" => "Ask for a table for two on Saturday at 19:30.",
      "completion_criteria" => ["The host confirms a table for two at 19:30."]
    }

    {:ok, brief} = Brief.new(params, caller_number: @caller, now: @dialed_at)
    brief
  end
end
