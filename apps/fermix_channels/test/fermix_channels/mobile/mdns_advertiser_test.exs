defmodule FermixChannels.Mobile.MdnsAdvertiserTest do
  use ExUnit.Case, async: true

  alias FermixChannels.Mobile.MdnsAdvertiser

  test "disabled advertising performs no application or network action" do
    start = fn -> flunk("mDNS must not start while disabled") end

    advertiser =
      start_supervised!({MdnsAdvertiser, name: nil, enabled: false, start_mdns: start})

    assert MdnsAdvertiser.status(advertiser) == :disabled
  end

  test "supervisor-driven shutdown removes the service and releases the responder" do
    test_pid = self()

    opts = [
      name: nil,
      enabled: true,
      port: 4_031,
      host_label: "fermix-host",
      start_mdns: fn -> {:ok, [:mdns_lite]} end,
      add_service: fn _service -> :ok end,
      remove_service: fn id ->
        send(test_pid, {:removed, id})
        :ok
      end,
      stop_mdns: fn ->
        send(test_pid, :stopped)
        :ok
      end
    ]

    assert {:ok, parent} =
             Supervisor.start_link([{MdnsAdvertiser, opts}], strategy: :one_for_one)

    on_exit(fn -> if Process.alive?(parent), do: Process.exit(parent, :shutdown) end)
    assert :ok = Supervisor.stop(parent)

    assert_receive {:removed, :fermix_mobile}
    assert_receive :stopped
  end

  test "publishes only version and host label and removes its service on shutdown" do
    test_pid = self()

    start = fn ->
      send(test_pid, :started)
      {:ok, [:mdns_lite]}
    end

    add = fn service ->
      send(test_pid, {:added, service})
      :ok
    end

    remove = fn id ->
      send(test_pid, {:removed, id})
      :ok
    end

    stop = fn ->
      send(test_pid, :stopped)
      :ok
    end

    advertiser =
      start_supervised!(
        {MdnsAdvertiser,
         name: nil,
         enabled: true,
         port: 4_031,
         host_label: "fermix-host",
         start_mdns: start,
         add_service: add,
         remove_service: remove,
         stop_mdns: stop}
      )

    assert_receive :started

    assert_receive {:added,
                    %{
                      id: :fermix_mobile,
                      protocol: "fermix",
                      transport: "tcp",
                      port: 4_031,
                      txt_payload: %{v: "1", name: "fermix-host"}
                    }}

    assert MdnsAdvertiser.status(advertiser) == :advertising
    GenServer.stop(advertiser)
    assert_receive {:removed, :fermix_mobile}
    assert_receive :stopped
  end

  test "releases mDNS when service registration fails during initialization" do
    test_pid = self()
    start = fn -> {:ok, [:mdns_lite]} end
    add = fn _service -> {:error, :unavailable} end

    stop = fn ->
      send(test_pid, :stopped)
      :ok
    end

    Process.flag(:trap_exit, true)

    assert {:error, {:mdns_start_failed, :unavailable}} =
             MdnsAdvertiser.start_link(
               name: nil,
               enabled: true,
               start_mdns: start,
               add_service: add,
               stop_mdns: stop
             )

    assert_receive :stopped
  end
end
