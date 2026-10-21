defmodule FermixTestSupport.TelemetryCapture do
  @moduledoc """
  The pinned way for an async test to observe telemetry.

  A telemetry handler is VM-global: a raw `:telemetry.attach` in an
  `async: true` module also sees every event that concurrently running tests
  emit, so a test that asserts on "the next event" can receive another test's.
  `attach/2` forwards an event to the test that attached it only when the event
  carries that test's pin, and detaches when the test exits.

  Pins:

    * `:emitter` forwards only events emitted by the test process itself. A
      handler runs in the process that emits, so this fits only synchronous
      in-process emission; an event emitted by a GenServer, Task or port owner
      the test started never matches. Pin on an id the test minted instead.
    * a keyword list such as `[session_id: id]` forwards only events whose
      metadata holds every listed key with an equal value, from any process.

  Each forwarded event arrives as `{:telemetry, event, measurements, metadata}`.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @typedoc "Which events reach the test: its own emissions, or matching metadata."
  @type pin :: :emitter | [{atom(), term()}, ...]

  @typedoc "The telemetry handler id, unique to one `attach/2` call."
  @type handler_id :: {module(), pos_integer()}

  @doc """
  Attaches a pinned handler for `events` and detaches it in `on_exit`. Call it
  from a test or a `setup` block: events go to the process that calls it.
  """
  @spec attach([:telemetry.event_name(), ...], pin()) :: handler_id()
  def attach([_ | _] = events, pin) do
    validate_events!(events)
    validate_pin!(pin)

    id = {__MODULE__, System.unique_integer([:positive])}
    config = %{test: self(), pin: pin}
    :ok = :telemetry.attach_many(id, events, &__MODULE__.handle_event/4, config)
    on_exit(fn -> :ok = :telemetry.detach(id) end)
    id
  end

  def attach(events, _pin) do
    raise ArgumentError, "attach/2 needs a non-empty list of event names, got: #{inspect(events)}"
  end

  @doc false
  @spec handle_event(:telemetry.event_name(), map(), map(), %{test: pid(), pin: pin()}) :: :ok
  def handle_event(event, measurements, metadata, %{test: test, pin: pin}) do
    if pinned?(pin, test, metadata), do: send(test, {:telemetry, event, measurements, metadata})
    :ok
  end

  defp pinned?(:emitter, test, _metadata), do: self() == test

  defp pinned?(pairs, _test, metadata) do
    Enum.all?(pairs, fn {key, value} -> Map.fetch(metadata, key) == {:ok, value} end)
  end

  defp validate_events!(events) do
    Enum.each(events, fn
      [_ | _] = event -> if Enum.all?(event, &is_atom/1), do: :ok, else: invalid_event!(event)
      event -> invalid_event!(event)
    end)
  end

  defp invalid_event!(event) do
    raise ArgumentError, "an event name is a non-empty list of atoms, got: #{inspect(event)}"
  end

  defp validate_pin!(:emitter), do: :ok

  defp validate_pin!([_ | _] = pairs) do
    if Keyword.keyword?(pairs), do: :ok, else: invalid_pin!(pairs)
  end

  defp validate_pin!(pin), do: invalid_pin!(pin)

  defp invalid_pin!(pin) do
    raise ArgumentError,
          "pin must be :emitter or a non-empty keyword list of metadata, got: #{inspect(pin)}"
  end
end
