defmodule FermixCore.ComputerUse.RemoteSessionTest do
  # M97 §6.4: a session on a computer's screen is the server's session with
  # that computer's driver beneath it. What is this machine's own (its input
  # seat, its helper reading) is not that session's.
  use ExUnit.Case, async: false

  alias FermixCore.ComputerUse.Config
  alias FermixCore.ComputerUse.HelperActions
  alias FermixCore.ComputerUse.InputOwner
  alias FermixCore.ComputerUse.Session
  alias FermixCore.ComputerUse.Supervisor, as: CuSupervisor
  alias FermixTestSupport.ScreenHelperDouble

  @computer %{device_id: "device-studio", name: "studio Mac"}
  @key %{"action" => "key", "chord" => "cmd+s"}

  setup do
    start_supervised!(CuSupervisor)
    holder = spawn_link(fn -> receive do: (:never -> :ok) end)
    :ok = InputOwner.acquire(holder)
    %{config: Config.normalize(enabled: true, courtesy: "off")}
  end

  test "a computer's screen does not wait on this machine's input seat", %{config: config} do
    {spec, _knobs} = ScreenHelperDouble.driver(self())

    remote =
      start_supervised!({Session, config: config, driver: spec, computer: @computer}, id: :remote)

    {:ok, :auto, request} = Session.classify(remote, @key)
    assert {:ok, %{outcome: :performed}} = Session.execute(remote, request)
    assert_received {:screen_helper, "key", _request}
  end

  test "this machine's own screen still does", %{config: config} do
    {spec, _knobs} = ScreenHelperDouble.driver(self())
    local = start_supervised!({Session, config: config, driver: spec}, id: :local)

    {:ok, :auto, request} = Session.classify(local, @key)
    assert {:error, {:refused, :input_busy}} = Session.execute(local, request)
    refute_received {:screen_helper, "key", _request}
  end

  test "a computer's helper reading is not recorded as this machine's", %{config: config} do
    {spec, _knobs} = ScreenHelperDouble.driver(self(), actions: ~w(elements press wait))

    _remote =
      start_supervised!({Session, config: config, driver: spec, computer: @computer}, id: :remote)

    assert HelperActions.offered() == HelperActions.pixel()
  end
end
