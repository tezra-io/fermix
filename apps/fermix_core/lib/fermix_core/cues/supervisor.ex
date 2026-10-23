defmodule FermixCore.Cues.Supervisor do
  @moduledoc """
  The cue subsystem's tree (M60 §5.3), last in the core `rest_for_one` tree and
  present only when `FermixCore.Cues.enabled?/0` at boot.

  `one_for_one` over three children, because every child's durable state is
  rows and the only shared memory is `Cues.Buckets`' tables:

    * the intake group, `rest_for_one`: `Cues.Buckets` first, since the
      sources and the door read its tables, then `Cues.SourceSupervisor`,
      `Cues.SourceManager` and `Cues.Door`. A source or door crash restarts
      what follows it in the group and nothing else;
    * the filtering group, `rest_for_one`: `Cues.Filters` before its task
      supervisor, so a dispatcher crash also ends every filter call it
      started (their late settles are refused by the boot reset's fence).
      `Cues.Filters` dispatches nothing before its first sweep timer, so the
      task supervisor is always up before the first call;
    * `Cues.Sweeper`, so a crash in sweep logic restarts nothing else.

  Options: `:door`, `:sources` and `:sweeper`, each passed to that child (a
  test's port and timers; `:sources` goes to `Cues.SourceManager`).
  """

  use Supervisor

  alias FermixCore.Cues.Buckets
  alias FermixCore.Cues.Door
  alias FermixCore.Cues.Sweeper

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    intake = [
      Buckets,
      FermixCore.Cues.SourceSupervisor,
      {FermixCore.Cues.SourceManager, Keyword.get(opts, :sources, [])},
      {Door, Keyword.get(opts, :door, [])}
    ]

    filtering = [
      FermixCore.Cues.Filters,
      {Task.Supervisor, name: FermixCore.Cues.FilterSupervisor}
    ]

    children = [
      group(:intake, intake, FermixCore.Cues.IntakeSupervisor),
      group(:filtering, filtering, FermixCore.Cues.FilteringSupervisor),
      {Sweeper, Keyword.get(opts, :sweeper, [])}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp group(id, children, name) do
    %{
      id: id,
      start: {Supervisor, :start_link, [children, [strategy: :rest_for_one, name: name]]},
      type: :supervisor
    }
  end
end
