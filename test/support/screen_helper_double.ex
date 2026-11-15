defmodule FermixTestSupport.ScreenHelperDouble do
  @moduledoc """
  The computer use helper as a double, for the computer's side of a server
  driving a computer's screen (M97 §6.4): a `Compux.Driver` that answers as a
  helper does and tells the test every request it was sent, so a test proves
  which reads and which actions reached the screen without any real input
  ever being sent.

  Started per test with `driver/2`'s spec; its knobs are an Agent the test
  holds (`set/3`): `idle_ms` and `idle` (the person's activity, for courtesy),
  `hold` (an action waits until `release/1` or the driver stops) and
  `actions`/`input_methods` (what its `hello` lists).

  Each request is told to the test as `{:screen_helper, action, request}`, each
  control as `{:screen_helper_control, action}`, and a stop as
  `:screen_helper_stopped`.
  """

  @behaviour Compux.Driver

  alias Compux.Protocol
  alias FermixTestSupport.ComputerUseObservations
  alias FermixTestSupport.ComputerUseReceipts

  @png <<137, 80, 78, 71, 13, 10, 26, 10>>

  @doc "The image every look answers with."
  @spec png() :: binary()
  def png, do: @png

  @doc "The driver spec for a seat, and the knobs the test holds."
  @spec driver(pid(), keyword()) :: {{module(), keyword()}, pid()}
  def driver(test, knobs \\ []) when is_pid(test) do
    defaults = %{
      idle_ms: 60_000,
      idle: true,
      hold: false,
      actions: Protocol.actions(),
      input_methods: ["ax"],
      held: nil
    }

    {:ok, agent} = Agent.start_link(fn -> Map.merge(defaults, Map.new(knobs)) end)
    {{__MODULE__, [test: test, knobs: agent]}, agent}
  end

  @doc "Sets one knob."
  @spec set(pid(), atom(), term()) :: :ok
  def set(knobs, key, value), do: Agent.update(knobs, &Map.put(&1, key, value))

  @doc "Lets a held action answer."
  @spec release(pid()) :: :ok
  def release(knobs) do
    case Agent.get(knobs, & &1.held) do
      pid when is_pid(pid) -> send(pid, :screen_helper_release)
      nil -> :ok
    end

    :ok
  end

  @impl true
  def start(opts),
    do: {:ok, %{test: Keyword.fetch!(opts, :test), knobs: Keyword.fetch!(opts, :knobs)}}

  @impl true
  def execute(state, %{"action" => "hello"}) do
    knobs = Agent.get(state.knobs, & &1)

    {:ok,
     %{
       "actions" => knobs.actions,
       "capabilities" => %{"input_methods" => knobs.input_methods}
     }}
  end

  def execute(_state, %{"action" => "probe"}),
    do: {:ok, %{"input_control" => true, "platform" => "macos"}}

  def execute(state, %{"action" => "idle_ms"} = request) do
    send(state.test, {:screen_helper, "idle_ms", request})
    {:ok, %{"idle_ms" => Agent.get(state.knobs, & &1.idle_ms)}}
  end

  def execute(state, %{"action" => "wait_for_idle"} = request) do
    send(state.test, {:screen_helper, "wait_for_idle", request})
    {:ok, %{"idle" => Agent.get(state.knobs, & &1.idle)}}
  end

  def execute(state, %{"action" => action} = request) do
    hold? = hold(state.knobs)
    send(state.test, {:screen_helper, action, request})
    held(hold?, request)
  end

  @impl true
  def control(state, action) do
    send(state.test, {:screen_helper_control, action})
    {:ok, %{action: action, ok: true, in_flight_request_id: nil}}
  end

  # The knobs die with the test that held them; a seat stopped after it ends
  # stops a helper with nothing held.
  @impl true
  def stop(state) do
    send(state.test, :screen_helper_stopped)

    case held_by(state.knobs) do
      pid when is_pid(pid) -> send(pid, :screen_helper_gone)
      nil -> :ok
    end

    :ok
  end

  defp held_by(knobs) do
    if Process.alive?(knobs), do: Agent.get(knobs, & &1.held)
  catch
    :exit, {:noproc, _call} -> nil
  end

  # Whether the test holds actions; one it holds is registered before the test
  # is told of it, so a stop the test sends next always finds it.
  defp hold(knobs) do
    me = self()

    Agent.get_and_update(knobs, fn knobs ->
      if knobs.hold, do: {true, %{knobs | held: me}}, else: {false, knobs}
    end)
  end

  # An action the test holds answers when released, and as a helper that
  # ended when the driver is stopped first.
  defp held(false, request), do: answer(request)

  defp held(true, request) do
    receive do
      :screen_helper_release -> answer(request)
      :screen_helper_gone -> {:error, {:sidecar_exited, 137}}
    after
      30_000 -> {:error, {:timeout, :cu_sidecar_action, 30_000}}
    end
  end

  defp answer(%{"action" => action} = request) do
    response =
      if Protocol.read_only?(action),
        do: look(request),
        else: %{"ok" => true}

    {:ok,
     response
     |> ComputerUseObservations.stamp(request)
     |> ComputerUseReceipts.stamp(request)}
  end

  defp look(%{"action" => "screenshot"} = request) do
    %{
      "ok" => true,
      "data" => Base.encode64(@png),
      "mime" => "image/png",
      "width" => 800,
      "height" => 600,
      "region" => ComputerUseObservations.resolved_region(request)
    }
  end

  defp look(_request), do: %{"ok" => true}
end
