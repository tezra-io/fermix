defmodule FermixChannels.Accessories.SupervisorTest do
  @moduledoc """
  The accessories subtree's lifecycle (M91 §04, D9, D13): it starts with its
  setting, off by default, only on a Mac and only on a primary; its live
  switch starts and stops it the way the phone channel's does; one link's
  crash ends no other link; and the internal API answers `:not_running`
  when the subtree does not run.
  """

  use ExUnit.Case, async: false

  alias FermixChannels.Accessories
  alias FermixChannels.Accessories.Supervisor, as: AccessoriesSupervisor
  alias FermixCore.Accessories.P256
  alias FermixCore.Home.Role
  alias FermixTestSupport.AccessoryBus
  alias FermixTestSupport.AccessoryCase
  alias FermixTestSupport.AccessoryMemoryTransport
  alias FermixTestSupport.AccessorySim

  @mac {:unix, :darwin}

  setup do
    home = AccessoryCase.home!()
    {_clock, now} = AccessoryCase.clock!()
    unique = System.unique_integer([:positive])

    names = %{
      store_writer: :"accessory_writer_#{unique}",
      links: :"accessory_links_#{unique}",
      watcher: :"accessory_watcher_#{unique}"
    }

    %{home: home, now: now, names: names, unique: unique}
  end

  defp tree_opts(ctx, bus, overrides \\ []) do
    Keyword.merge(
      [
        name: :"accessories_#{ctx.unique}",
        switch: fn -> true end,
        os_type: @mac,
        home: ctx.home,
        names: ctx.names,
        transport: AccessoryMemoryTransport,
        transport_opts: [bus: bus],
        watcher_opts: [send_after: fn _dest, _message, _ms -> make_ref() end, observer: self()],
        link_opts: [
          clock: ctx.now,
          send_after: fn _dest, _message, _ms -> make_ref() end,
          readiness: fn -> :ready end
        ]
      ],
      overrides
    )
  end

  describe "where it runs" do
    test "off, the default, it starts nothing: no watcher, no port opened", ctx do
      bus = start_supervised!(AccessoryBus)
      opts = tree_opts(ctx, bus, switch: fn -> false end)

      assert AccessoriesSupervisor.start_link(opts) == :ignore
      assert Process.whereis(ctx.names.watcher) == nil
    end

    test "with no setting at all it reads off" do
      previous = Application.get_env(:fermix_channels, :accessories)
      Application.delete_env(:fermix_channels, :accessories)

      on_exit(fn ->
        if previous, do: Application.put_env(:fermix_channels, :accessories, previous)
      end)

      refute AccessoriesSupervisor.switch_on?()
    end

    test "on, but not on a Mac, it starts nothing", ctx do
      bus = start_supervised!(AccessoryBus)

      assert AccessoriesSupervisor.start_link(tree_opts(ctx, bus, os_type: {:unix, :linux})) ==
               :ignore

      assert Process.whereis(ctx.names.watcher) == nil
    end

    test "only a primary starts it: a device or a candidate leaves it out" do
      child = AccessoriesSupervisor.boot_child()

      assert FermixChannels.Accessories.Supervisor in Role.primary_only()
      assert Role.children([child], :primary) == [child]
      assert Role.children([child], :device) == []
      assert Role.children([child], :candidate) == []
    end
  end

  describe "the live switch" do
    test "turning it on starts the subtree, and off stops it while it stays registered", ctx do
      bus = start_supervised!(AccessoryBus)
      switch = start_supervised!({Agent, fn -> false end}, id: :switch)
      opts = tree_opts(ctx, bus, switch: fn -> Agent.get(switch, & &1) end)

      parent =
        start_supervised!(%{
          id: :parent,
          start:
            {Supervisor, :start_link, [[{AccessoriesSupervisor, opts}], [strategy: :one_for_one]]},
          type: :supervisor
        })

      assert Process.whereis(ctx.names.watcher) == nil
      assert {:ok, :not_started} = Accessories.switch(true, parent: parent)

      Agent.update(switch, fn _off -> true end)
      assert {:ok, :started} = Accessories.switch(true, parent: parent)
      assert is_pid(Process.whereis(ctx.names.watcher))

      assert {:ok, :stopped} = Accessories.switch(false, parent: parent)
      assert Process.whereis(ctx.names.watcher) == nil
      assert {:error, :not_running} = Accessories.status(names: ctx.names)

      assert {:ok, :started} = Accessories.switch(true, parent: parent)
    end

    test "a boot that registered no subtree has nothing to switch", _ctx do
      parent =
        start_supervised!(%{
          id: :empty_parent,
          start: {Supervisor, :start_link, [[], [strategy: :one_for_one]]},
          type: :supervisor
        })

      assert {:error, :not_ready} = Accessories.switch(true, parent: parent)
    end
  end

  describe "isolation" do
    test "one link's crash ends no other link, and the watcher opens it again", ctx do
      bus = start_supervised!(AccessoryBus)

      sims =
        for {path, serial} <- [
              {"/dev/cu.usbmodem1", "80:45:6B:00:00:01"},
              {"/dev/cu.usbmodem2", "80:45:6B:00:00:02"}
            ] do
          {public, private} = P256.generate()
          {host, _record} = AccessoryCase.enroll!(ctx.home, public, port_hint: serial)

          sim =
            start_supervised!(
              {AccessorySim,
               observer: self(), key: {public, private}, enrolled_host: host.public},
              id: path
            )

          AccessoryBus.plug(bus, path, serial: serial, peer: sim)
          {path, sim}
        end

      start_supervised!({AccessoriesSupervisor, tree_opts(ctx, bus)})
      send(ctx.names.watcher, :poll)
      for {_path, sim} <- sims, do: AccessoryCase.await_received(sim, "host_proof")
      [{first, _}, {second, _}] = sims
      first_pid = await_attached(ctx, first)
      second_pid = await_attached(ctx, second)

      ref = Process.monitor(first_pid)
      Process.exit(first_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^first_pid, :killed}
      # The watcher has taken in the link's end once its status answers.
      {:ok, _status} = Accessories.status(names: ctx.names)
      send(ctx.names.watcher, :poll)
      reopened = await_attached(ctx, first, &(&1 != first_pid))

      assert reopened != first_pid
      assert await_attached(ctx, second) == second_pid
      assert Process.alive?(second_pid)
    end
  end

  defp await_attached(ctx, path, pid_ok? \\ fn _pid -> true end, tries \\ 50) do
    {:ok, status} = Accessories.status(names: ctx.names)

    case Enum.find(status.ports, &(&1.path == path)) do
      %{state: :linked, link: %{phase: :attached}, pid: pid} when tries > 0 ->
        if pid_ok?.(pid), do: pid, else: wait_change(ctx, path, pid_ok?, tries)

      _other when tries > 0 ->
        wait_change(ctx, path, pid_ok?, tries)

      other ->
        flunk("#{path} never attached: #{inspect(other)}")
    end
  end

  defp wait_change(ctx, path, pid_ok?, tries) do
    watcher = Process.whereis(ctx.names.watcher)

    receive do
      {:watcher_changed, ^watcher} -> await_attached(ctx, path, pid_ok?, tries - 1)
    after
      2_000 -> await_attached(ctx, path, pid_ok?, 0)
    end
  end

  # A caller of the management layer is never taken down by the subtree: a
  # watcher that does not answer in time, or that dies mid-call, is a named
  # error.
  test "the internal API names a watcher that does not answer, or dies, instead of exiting",
       ctx do
    test = self()

    silent =
      spawn_link(fn ->
        Process.register(self(), ctx.names.watcher)
        send(test, :registered)
        receive(do: (:stop -> :ok))
      end)

    assert_receive :registered
    assert {:error, :timeout} = Accessories.status(names: ctx.names, timeout: 0)
    send(silent, :stop)
    ref = Process.monitor(silent)
    assert_receive {:DOWN, ^ref, :process, ^silent, _reason}

    Process.flag(:trap_exit, true)

    dying =
      spawn_link(fn ->
        Process.register(self(), ctx.names.watcher)
        send(test, :registered)
        receive(do: ({:"$gen_call", _from, _request} -> exit(:boom)))
      end)

    assert_receive :registered
    assert {:error, :accessories_unavailable} = Accessories.status(names: ctx.names)
    assert_receive {:EXIT, ^dying, :boom}
  end

  test "the internal API answers not_running when the subtree does not run", ctx do
    assert {:error, :not_running} = Accessories.status(names: ctx.names)
    assert {:error, :not_running} = Accessories.pair("/dev/cu.usbmodem1", names: ctx.names)

    assert {:error, :not_running} =
             Accessories.forget(String.duplicate("a", 64), names: ctx.names)

    assert {:error, :not_running} =
             Accessories.start_call(String.duplicate("a", 64), names: ctx.names)
  end
end
