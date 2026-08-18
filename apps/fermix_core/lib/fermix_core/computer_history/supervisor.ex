defmodule FermixCore.ComputerHistory.Supervisor do
  @moduledoc """
  The always-present, inert owner of the Computer History rail (MILESTONE_32
  §6.3). Present on macOS whenever the daemon boots, regardless of
  `enabled?()`, and owns two things:

    * **`Retention`** as an always-supervised child — presence unconditional,
      *work* tick-gated. A boot-time "tables non-empty" conditional child was
      unimplementable (the root child list is built before `Memory.Repo`
      starts) and would silently break the 48h retention promise on a fresh
      install, so retention is always here and does all repo work on its tick.

    * a **`DynamicSupervisor`** that starts/stops the runtime-controlled
      `Capturer` and `Summarizer.Scheduler` on `/history` enable/disable — a
      static boot-time child cannot perform a runtime shutdown or
      enable-from-disabled (the `ComputerUse.Supervisor` precedent).

  Unlike computer-use, this rail has no `CaptureHealth`: capture is
  Accessibility-only (no ScreenCaptureKit), so there is no SCK wedge to break.
  The capturer's health is bounded restart + first-class `observer.gap` rows +
  the `fermix doctor` row.
  """

  use Supervisor

  alias FermixCore.ComputerHistory.Controller
  alias FermixCore.ComputerHistory.Retention

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
    retention_opts =
      opts
      |> Keyword.take([:repo, :timer_enabled, :window_ms, :tick_interval_ms])

    controller_opts = Keyword.take(opts, [:operative_fun, :installed_fun, :children])

    # `:rest_for_one`, ordered DynamicSupervisor → Controller → Retention: a
    # DynamicSupervisor crash restarts the Controller after it, whose boot
    # `reconcile` repopulates the runtime children (never orphaned by a blip).
    # Retention is last and independent — a crash upstream harmlessly re-inits
    # its tick; a Retention crash restarts only itself.
    children = [
      {DynamicSupervisor, name: @dynamic_supervisor, strategy: :one_for_one},
      {Controller, controller_opts},
      {Retention, retention_opts}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
