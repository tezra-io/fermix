defmodule FermixCore.ComputerHistory.Supervisor do
  @moduledoc """
  The always-present, inert owner of the Computer History rail (MILESTONE_32
  §6.3; M97 §8.1). Present on the home whenever the daemon boots, and on a
  computer where this system has a recorder, regardless of `enabled?()`, and
  owns four things:

    * **`Spool`**, this machine's own store of raw history
      (`device/history.db`), on every engine that runs it, the home's own
      machine included (D9).

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

    # The home keeps the read audit and the purge intervals, which a device does
    # not have: its Retention sweeps its own machine store alone.
    retention_opts =
      opts
      |> Keyword.take([:timer_enabled, :window_ms, :tick_interval_ms, :spool])
      |> Keyword.put(:repo, if(role == :primary, do: Keyword.get(opts, :repo, Repo)))

    controller_opts =
      opts
      |> Keyword.take([:operative_fun, :installed_fun, :children, :timer_enabled])
      |> Keyword.put(:engine_role, role)

    # `:rest_for_one`, ordered Spool → DynamicSupervisor → Controller → Retention:
    # this machine's store is first, since every other child writes or reads it;
    # a DynamicSupervisor crash restarts the Controller after it, whose boot
    # `reconcile` repopulates the runtime children (never orphaned by a blip).
    # Retention is last and independent — a crash upstream harmlessly re-inits
    # its tick; a Retention crash restarts only itself.
    children = [
      spool_child(opts),
      {DynamicSupervisor, name: @dynamic_supervisor, strategy: :one_for_one},
      {Controller, controller_opts},
      {Retention, retention_opts}
    ]

    Supervisor.init(Role.children(children, role), strategy: :rest_for_one)
  end

  # `:spool_path` is a test's seam; a boot opens the store under its home.
  defp spool_child(opts) do
    case Keyword.fetch(opts, :spool_path) do
      {:ok, path} -> {Spool, path: path}
      :error -> Spool
    end
  end
end
