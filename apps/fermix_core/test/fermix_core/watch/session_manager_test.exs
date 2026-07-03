defmodule FermixCore.Watch.SessionManagerTest do
  use ExUnit.Case, async: false

  alias FermixCore.Watch.SessionManager
  alias FermixCore.Watch.Supervisor, as: WatchSupervisor

  setup do
    # Watch is off by default, so the app does not start this — the test owns it.
    start_supervised!(WatchSupervisor)
    :ok
  end

  # Attended context + injected fake effects: a real watch needs a model + a
  # channel, but the loop/lifecycle/gate these tests exercise do not.
  defp ctx(extra \\ %{}) do
    Map.merge(%{computer_use_origin: :interactive, conversation_key: {"cli", "c1", :root}}, extra)
  end

  defp quiet_opts(extra \\ []) do
    Keyword.merge(
      [
        task: "watch it",
        decide: fn _ -> :quiet end,
        deliver: fn _ -> :ok end,
        cooldown_ms: 10_000
      ],
      extra
    )
  end

  test "ensure starts an attended watch and reuses it for the same conversation" do
    c = ctx()
    assert {:ok, pid} = SessionManager.ensure(c, quiet_opts())
    assert is_pid(pid)
    assert {:ok, ^pid} = SessionManager.ensure(c, quiet_opts())
    assert {:ok, ^pid} = SessionManager.lookup(c)
  end

  test "an unattended origin is refused (fails closed) and starts nothing" do
    # No computer_use_origin → defaults to :unattended.
    unattended = %{conversation_key: {"background", "j1", :root}}

    assert {:error, {:watch_refused, :unattended}} =
             SessionManager.ensure(unattended, quiet_opts())

    assert :error = SessionManager.lookup(unattended)
  end

  test "different conversations get different watches" do
    {:ok, p1} = SessionManager.ensure(ctx(%{conversation_key: {"cli", "a", :root}}), quiet_opts())
    {:ok, p2} = SessionManager.ensure(ctx(%{conversation_key: {"cli", "b", :root}}), quiet_opts())
    refute p1 == p2
  end

  test "abort tears down a running watch and it does NOT restart" do
    c = ctx()
    {:ok, pid} = SessionManager.ensure(c, quiet_opts())
    ref = Process.monitor(pid)

    assert :ok = SessionManager.abort(c)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

    assert :error = SessionManager.lookup(c)
    Process.sleep(150)
    assert :error = SessionManager.lookup(c)
    assert [] = DynamicSupervisor.which_children(WatchSupervisor.session_supervisor())
  end

  test "abort is a no-op with no watch, no key, or a stopped registry" do
    assert :ok = SessionManager.abort(ctx(%{conversation_key: {"cli", "nope", :root}}))
    assert :ok = SessionManager.abort(%{})

    :ok = stop_supervised(WatchSupervisor)
    refute is_pid(Process.whereis(WatchSupervisor.registry()))
    assert :ok = SessionManager.abort(ctx())
  end

  test "a watch self-terminates at its max duration" do
    {:ok, pid} = SessionManager.ensure(ctx(), quiet_opts(max_duration_ms: 50))
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 500
  end

  test "a {:report, text} cycle delivers; :quiet delivers nothing" do
    me = self()

    decide = fn
      %{cycle: 0} -> {:report, "the build finished"}
      _ -> :quiet
    end

    deliver = fn text -> send(me, {:delivered, text}) end

    {:ok, _pid} =
      SessionManager.ensure(ctx(),
        task: "watch the build",
        decide: decide,
        deliver: deliver,
        cooldown_ms: 5
      )

    assert_receive {:delivered, "the build finished"}, 500
    # subsequent quiet cycles must not deliver
    refute_receive {:delivered, _}, 100
  end

  test "the watch stops after its cycle budget" do
    {:ok, pid} = SessionManager.ensure(ctx(), quiet_opts(max_cycles: 2, cooldown_ms: 5))
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000
  end

  test "a single crashing cycle is survived (bounded), not fatal" do
    me = self()
    # First cycle raises; the watch survives one failure and continues.
    decide = fn
      %{cycle: 0} -> raise "boom"
      _ -> send(me, :recovered) && :quiet
    end

    {:ok, pid} =
      SessionManager.ensure(ctx(),
        task: "watch",
        decide: decide,
        deliver: fn _ -> :ok end,
        cooldown_ms: 5
      )

    assert_receive :recovered, 500
    assert Process.alive?(pid)
  end

  test "a {:stop_watch, reason} decision stops immediately and tells the user why" do
    me = self()
    decide = fn _ -> {:stop_watch, "computer-use is disabled so I can't see your screen"} end
    deliver = fn text -> send(me, {:delivered, text}) end

    {:ok, pid} =
      SessionManager.ensure(ctx(),
        task: "watch my screen",
        decide: decide,
        deliver: deliver,
        cooldown_ms: 5
      )

    ref = Process.monitor(pid)
    assert_receive {:delivered, msg}, 1000
    assert msg =~ "computer-use is disabled"
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000
  end

  test "stops and notifies the user after repeated decision failures" do
    me = self()
    decide = fn _ -> {:error, :no_vision} end
    deliver = fn text -> send(me, {:delivered, text}) end

    {:ok, pid} =
      SessionManager.ensure(ctx(),
        task: "watch",
        decide: decide,
        deliver: deliver,
        cooldown_ms: 5
      )

    ref = Process.monitor(pid)
    assert_receive {:delivered, msg}, 1000
    assert msg =~ "stop watching"
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000
  end
end
