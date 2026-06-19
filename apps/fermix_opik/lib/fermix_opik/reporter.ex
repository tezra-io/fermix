defmodule FermixOpik.Reporter do
  @moduledoc """
  Attaches to Fermix's telemetry events and forwards them to the `Aggregator`.

  The handler runs in the emitting process, so it does the minimum possible:
  stamp a wall-clock time and `cast` to the aggregator. All reconstruction and
  I/O happen elsewhere.
  """

  alias FermixOpik.Aggregator

  @events [
    [:fermix, :provider, :call],
    [:fermix, :provider, :failover],
    [:fermix, :tool, :exec],
    [:fermix, :memory, :write],
    [:fermix, :agent, :start],
    [:fermix, :agent, :stop],
    [:fermix, :agent, :task_start],
    [:fermix, :agent, :task_complete],
    [:fermix, :agent, :message],
    [:fermix, :agent, :message_error],
    [:fermix, :skill, :invoke],
    [:fermix, :job, :run_start],
    [:fermix, :job, :run_complete],
    [:fermix, :job, :run_error],
    [:fermix, :soul_curation, :run_start],
    [:fermix, :soul_curation, :run_complete],
    [:fermix, :soul_curation, :run_error],
    [:fermix, :channel, :stream],
    [:fermix, :plugin, :dist],
    [:fermix, :realtime, :call_start],
    [:fermix, :realtime, :session_created],
    [:fermix, :realtime, :session_updated],
    [:fermix, :realtime, :provider_error],
    [:fermix, :realtime, :reconnect],
    [:fermix, :realtime, :call_stop]
  ]

  @handler_id "fermix-opik-reporter"

  @doc "The telemetry events this reporter consumes."
  @spec events() :: [[atom()]]
  def events, do: @events

  @spec attach(keyword()) :: :ok | {:error, :already_exists}
  def attach(opts \\ []) do
    aggregator = Keyword.get(opts, :aggregator, Aggregator)
    handler_id = Keyword.get(opts, :handler_id, @handler_id)

    :telemetry.attach_many(handler_id, @events, &__MODULE__.handle_event/4, %{
      aggregator: aggregator
    })
  end

  @spec detach(String.t()) :: :ok
  def detach(handler_id \\ @handler_id), do: :telemetry.detach(handler_id)

  @spec handle_event([atom()], map(), map(), map()) :: :ok
  def handle_event(event, measurements, metadata, %{aggregator: aggregator}) do
    Aggregator.record(aggregator, event, measurements, metadata, DateTime.utc_now())
  end
end
