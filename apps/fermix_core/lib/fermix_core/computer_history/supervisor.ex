defmodule FermixCore.ComputerHistory.Supervisor do
  @moduledoc """
  The inert owner of the Computer History rail (MILESTONE_32 §6.3; M97 §8.1),
  regardless of `enabled?()`, wherever something here uses it: on any engine
  whose system has a recorder (`ComputerHistory.recorder?/1`: a Mac, and a Linux
  computer), and on the home's primary, where a computer's history can
  arrive. Anywhere else (a device with no recorder) its `init/1` answers
  `:ignore`: no process runs and no store is created. It owns four things:

    * **`Spool`**, this machine's own store of raw history
      (`device/history.db`), only where this system has a recorder, the home's
      own machine included (D9). A home with no recorder (an Always On server)
      keeps no store: nothing records there. A store that does not open never
      stops this rail or the engine: `Spool` stays up and says why, and the
      recorder stays off.

    * a **`DynamicSupervisor`** that starts/stops the runtime-controlled
      `Capturer` and `Summarizer.Scheduler` (the `ComputerUse.Supervisor`
      precedent), through the **`Controller`**: the recorder runs where history
      is switched on, and the scheduler wherever there is a half to run (the
      home's roll-up, or this machine's sittings to send).

    * **`Retention`**, always supervised: its work is tick-gated, and it
      sweeps this machine's store everywhere and the home's read audit and
      intervals on the home. A boot-time "tables non-empty" conditional child
      was unimplementable and would silently break the 48h retention promise
      on a fresh install, so retention is always here and does all store work
      on its tick.

  Unlike computer-use, this rail has no `CaptureHealth`: capture is
  Accessibility-only (no ScreenCaptureKit), so there is no SCK wedge to break.
  The capturer's health is bounded restart + first-class `observer.gap` rows +
  the `fermix doctor` row.
  """

  use Supervisor

  alias FermixCore.ComputerHistory
  alias FermixCore.ComputerHistory.Config
  alias FermixCore.ComputerHistory.Controller
  alias FermixCore.ComputerHistory.Retention
  alias FermixCore.ComputerHistory.Spool
  alias FermixCore.Home.Role
  alias FermixCore.Memory.Repo

  @dynamic_supervisor FermixCore.ComputerHistory.DynamicSupervisor

  @doc "Name of the DynamicSupervisor that owns the runtime capturer/summarizer children."
  @spec dynamic_supervisor() :: atom()
  def dynamic_supervisor, do: @dynamic_supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    role = Keyword.get_lazy(opts, :engine_role, &Role.current/0)
    recorder? = Keyword.get_lazy(opts, :recorder?, &ComputerHistory.recorder?/0)

    if recorder? or role == :primary,
      do: children(role, recorder?, opts),
      else: :ignore
  end

  defp children(role, recorder?, opts) do
    :ok = Config.warn_if_shadowed()
    spool = if recorder?, do: Keyword.get(opts, :spool, Spool)

    # The home keeps the read audit and the purge intervals, which a device does
    # not have: its Retention sweeps its own machine store alone.
    retention_opts =
      opts
      |> Keyword.take([:timer_enabled, :window_ms, :tick_interval_ms])
      |> Keyword.merge(
        spool: spool,
        repo: if(role == :primary, do: Keyword.get(opts, :repo, Repo))
      )

    controller_opts =
      opts
      |> Keyword.take([:operative_fun, :installed_fun, :children, :timer_enabled])
      |> Keyword.merge(engine_role: role, spool: spool)

    # `:rest_for_one`, ordered Spool → DynamicSupervisor → Controller → Retention:
    # this machine's store is first, since every other child writes or reads it;
    # a DynamicSupervisor crash restarts the Controller after it, whose boot
    # `reconcile` repopulates the runtime children (never orphaned by a blip).
    # Retention is last and independent — a crash upstream harmlessly re-inits
    # its tick; a Retention crash restarts only itself.
    children = [
      spool_child(recorder?, opts),
      {DynamicSupervisor, name: @dynamic_supervisor, strategy: :one_for_one},
      {Controller, controller_opts},
      {Retention, retention_opts}
    ]

    Supervisor.init(Role.children(Enum.reject(children, &is_nil/1), role),
      strategy: :rest_for_one
    )
  end

  # `:spool_path` is a test's seam; a boot opens the store under its home. No
  # recorder, no store.
  defp spool_child(false, _opts), do: nil

  defp spool_child(true, opts) do
    case Keyword.fetch(opts, :spool_path) do
      {:ok, path} -> {Spool, path: path}
      :error -> Spool
    end
  end
end
