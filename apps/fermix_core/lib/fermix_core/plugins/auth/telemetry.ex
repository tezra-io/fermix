defmodule FermixCore.Plugins.Auth.Telemetry do
  @moduledoc """
  Emitter for `[:fermix, :plugin, :auth]`: one event per plugin credential op
  (`:login`, `:refresh`, `:logout`, `:set`, `:clear`) with its outcome and
  duration. Registered in `Trace.TelemetryHandler` and `FermixOpik` per
  `docs/TELEMETRY_CONTRACT.md`; never hand-roll this event elsewhere.

  The metadata is a fixed allowlist of constructed keys: `op`, `plugin`,
  `result` (the success tag, or `:error`), a derived `error_class`, and, only
  for a refused sign-in client, the vendor's own `vendor_error` and
  `vendor_description` (already redacted and bounded by
  `Auth.ClientRejection`). The raw reason never rides: a sign-in reason can
  carry the authorize url, which must reach no log and no trace, and a vendor
  body can carry anything. `error_class` is an atom (a reason's atom, or a
  tagged tuple's atom head) and anything else flattens to `:unclassified`.
  """

  @event [:fermix, :plugin, :auth]

  @ops [:login, :refresh, :logout, :set, :clear]

  @success_tags [:ready, :logged_out]

  @trace_event_definitions [
    %{
      event: @event,
      trace_type: :agent_event,
      agent_field: :plugin,
      trace_event: "plugin_auth"
    }
  ]

  @type outcome :: {:ok, :ready | :logged_out} | {:error, term()}

  @doc "The stable plugin auth event name."
  @spec event() :: [atom()]
  def event, do: @event

  @doc "Every op this emitter can emit, ordered."
  @spec ops() :: [atom()]
  def ops, do: @ops

  @spec trace_event_definitions() :: [map()]
  def trace_event_definitions, do: @trace_event_definitions

  @doc "Monotonic start timestamp for an op, in milliseconds."
  @spec start() :: integer()
  def start, do: System.monotonic_time(:millisecond)

  @doc """
  Emit the outcome of one op on `plugin`, started at `started_ms` (from
  `start/0`). `outcome` is `{:ok, :ready}`, `{:ok, :logged_out}` or
  `{:error, reason}`; only the reason's derived class leaves this function.
  """
  @spec emit(atom(), String.t(), outcome(), integer()) :: :ok
  def emit(op, plugin, outcome, started_ms)
      when op in @ops and is_binary(plugin) and is_integer(started_ms) do
    duration = System.monotonic_time(:millisecond) - started_ms

    metadata =
      %{op: op, plugin: plugin}
      |> Map.merge(outcome_metadata(outcome))
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    :telemetry.execute(@event, %{duration_ms: duration}, metadata)
  end

  @doc """
  The bounded class of a failed op's reason: the reason itself when it is an
  atom, a tagged tuple's atom head, and `:unclassified` for anything else.
  """
  @spec error_class(term()) :: atom()
  def error_class(reason) when is_atom(reason) and reason not in [nil, true, false],
    do: reason

  def error_class(reason) when is_tuple(reason) and tuple_size(reason) > 0 do
    case elem(reason, 0) do
      head when is_atom(head) and head not in [nil, true, false] -> head
      _other -> :unclassified
    end
  end

  def error_class(_reason), do: :unclassified

  defp outcome_metadata({:ok, tag}) when tag in @success_tags, do: %{result: tag}

  defp outcome_metadata({:error, {:oauth_client_rejected, detail} = reason}) do
    %{
      result: :error,
      error_class: error_class(reason),
      vendor_error: Map.fetch!(detail, :error),
      vendor_description: Map.fetch!(detail, :description)
    }
  end

  defp outcome_metadata({:error, reason}), do: %{result: :error, error_class: error_class(reason)}
end
