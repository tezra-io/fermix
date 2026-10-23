defmodule FermixCore.Cues.SourceSupervisor do
  @moduledoc """
  The DynamicSupervisor every stream and feed worker runs under (M60 §5.3),
  inside `Cues.Supervisor`, after `Cues.Buckets` and before
  `Cues.SourceManager`.

  It never restarts a worker itself: `Cues.SourceManager` starts every worker as
  `:temporary` and decides what follows its exit, so one source that keeps
  crashing cannot spend this supervisor's shared restart budget and take the
  other sources down with it.
  """

  use DynamicSupervisor

  @doc "Starts the supervisor. Option `:name` (default `#{inspect(__MODULE__)}`)."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    DynamicSupervisor.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(:ok), do: DynamicSupervisor.init(strategy: :one_for_one)
end
