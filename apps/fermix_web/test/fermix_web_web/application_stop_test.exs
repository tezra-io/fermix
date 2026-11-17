defmodule FermixWeb.ApplicationStopTest do
  # When the web application runs, it started last, after the channels and
  # the core it needs, so an orderly stop stops it first: its `prep_stop/1`
  # drains the phone call in progress while every other tree still runs
  # (M94 §04). A stand-in for the Manager answers the drain and says what was
  # up when it was asked; the stop reaches it through
  # `:phone_calls_stop_manager`. async: false: that seam is application
  # environment.
  use ExUnit.Case, async: false

  defmodule StandIn do
    use GenServer

    def start_link(test), do: GenServer.start_link(__MODULE__, test)

    @impl true
    def init(test), do: {:ok, test}

    @impl true
    def handle_info({:phone_call_drain, from, ref}, test) do
      up = Enum.map([FermixChannels.Supervisor, FermixCore.Supervisor], &Process.whereis/1)
      send(test, {:drain_asked, up})
      send(from, {:phone_call_drained, ref, :drained})
      {:noreply, test}
    end
  end

  setup do
    stand_in = start_supervised!({StandIn, self()})
    name = :"phone_stop_stand_in_#{System.unique_integer([:positive])}"
    Process.register(stand_in, name)
    previous = Application.fetch_env(:fermix_core, :phone_calls_stop_manager)
    Application.put_env(:fermix_core, :phone_calls_stop_manager, name)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:fermix_core, :phone_calls_stop_manager, value)
        :error -> Application.delete_env(:fermix_core, :phone_calls_stop_manager)
      end
    end)

    :ok
  end

  test "the web application needs the channels and the core, so it stops before both" do
    needs = Application.spec(:fermix_web, :applications)
    assert :fermix_channels in needs
    assert :fermix_core in needs
  end

  test "its stop drains the phone call in progress while the channels and core trees run" do
    assert :state = FermixWeb.Application.prep_stop(:state)
    assert_receive {:drain_asked, [channels, core]}
    assert is_pid(channels) and is_pid(core)
  end
end
