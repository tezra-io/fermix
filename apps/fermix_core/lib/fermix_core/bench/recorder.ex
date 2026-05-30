defmodule FermixCore.Bench.Recorder do
  @moduledoc """
  Telemetry recorder for benchmark scenarios.

  The handler writes only integer durations into a private ETS table. It does
  no disk or network work on the measured path.
  """

  @type event_spec :: {[atom()], String.t()}
  @type t :: %__MODULE__{
          table: :ets.tid(),
          handler_id: String.t(),
          events: [event_spec()]
        }

  defstruct [:table, :handler_id, events: []]

  @spec start(keyword()) :: {:ok, t()} | {:error, term()}
  def start(opts) when is_list(opts) do
    {:ok, _apps} = Application.ensure_all_started(:telemetry)

    events = Keyword.fetch!(opts, :events)

    table =
      :ets.new(__MODULE__, [
        :duplicate_bag,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])

    handler_id = "fermix-bench-recorder-#{System.unique_integer([:positive])}"

    case attach(handler_id, events, table) do
      :ok -> {:ok, %__MODULE__{table: table, handler_id: handler_id, events: events}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec stop(t()) :: :ok
  def stop(%__MODULE__{handler_id: handler_id, table: table}) do
    :telemetry.detach(handler_id)
    :ets.delete(table)
    :ok
  end

  @spec samples(t()) :: %{String.t() => [non_neg_integer()]}
  def samples(%__MODULE__{table: table}) do
    table
    |> :ets.tab2list()
    |> Enum.group_by(fn {stage, _duration_us} -> stage end, fn {_stage, duration_us} ->
      duration_us
    end)
    |> Map.new(fn {stage, durations} -> {stage, Enum.reverse(durations)} end)
  end

  defp attach(handler_id, events, table) do
    stage_by_event = Map.new(events)

    :telemetry.attach_many(
      handler_id,
      Map.keys(stage_by_event),
      &__MODULE__.handle_event/4,
      %{table: table, stage_by_event: stage_by_event}
    )
  end

  @doc false
  def handle_event(event, measurements, _metadata, config) do
    with {:ok, stage} <- Map.fetch(config.stage_by_event, event),
         {:ok, duration_us} <- duration_us(measurements) do
      :ets.insert(config.table, {stage, duration_us})
    end

    :ok
  end

  defp duration_us(%{duration_us: duration}) when is_integer(duration) and duration >= 0 do
    {:ok, duration}
  end

  defp duration_us(%{duration_ms: duration}) when is_integer(duration) and duration >= 0 do
    {:ok, duration * 1_000}
  end

  defp duration_us(_measurements), do: :error
end
