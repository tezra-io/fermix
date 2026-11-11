defmodule FermixCore.Browser.HeldTurnTest do
  # M97 §6.4: a server's turn on the computer whose browser it uses. Each of
  # the turn's requests runs in one process here, which ends as the turn
  # ended on the server: normally, which a pane task that was handed over
  # survives, or stopped, which no task survives. Every registry and
  # supervisor is this test's own.
  use ExUnit.Case, async: true

  alias FermixCore.Browser.HeldTurn

  setup do
    n = System.unique_integer([:positive])
    seams = %{registry: :"held_turns_#{n}", supervisor: :"held_turn_sup_#{n}"}
    start_supervised!({Registry, keys: :unique, name: seams.registry})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: seams.supervisor})
    %{seams: seams}
  end

  test "a turn's requests run in one process of their own, in order", %{seams: seams} do
    first = HeldTurn.run(seams, turn("main-41"), fn -> self() end)
    second = HeldTurn.run(seams, turn("main-41"), fn -> self() end)
    other = HeldTurn.run(seams, turn("main-42", "owner-c2hlZA"), fn -> self() end)

    assert first == second
    refute first == self()
    refute other == first
  end

  test "a turn that ended normally ends its process normally", %{seams: seams} do
    held = HeldTurn.run(seams, turn("main-43"), fn -> self() end)
    ref = Process.monitor(held)

    :ok = HeldTurn.finish(seams, "main-43", "ended")
    assert_receive {:DOWN, ^ref, :process, ^held, :normal}
  end

  test "a turn that was stopped ends its process as stopped", %{seams: seams} do
    held = HeldTurn.run(seams, turn("main-44"), fn -> self() end)
    ref = Process.monitor(held)

    :ok = HeldTurn.finish(seams, "main-44", "stopped")
    assert_receive {:DOWN, ^ref, :process, ^held, {:shutdown, :turn_stopped}}
  end

  test "the end of a turn this computer never held is already done", %{seams: seams} do
    assert :ok = HeldTurn.finish(seams, "main-45", "ended")
    assert Registry.count(seams.registry) == 0
  end

  test "a request after its turn's process ended starts a fresh one", %{seams: seams} do
    held = HeldTurn.run(seams, turn("main-46"), fn -> self() end)
    ref = Process.monitor(held)
    :ok = HeldTurn.finish(seams, "main-46", "ended")
    assert_receive {:DOWN, ^ref, :process, ^held, :normal}

    again = HeldTurn.run(seams, turn("main-46"), fn -> self() end)
    refute again == held
  end

  # INVOKE-1: the run that made a request is the request's life. When the
  # computer ends that run (the master or browser switch off, a cancel, a
  # deadline, a restart of its invocations), the request the held turn runs
  # for it ends there, and the turn with it, so its pane task does too.
  test "a request whose run ends is ended with it, and its turn with it", %{seams: seams} do
    test = self()

    run =
      spawn(fn ->
        HeldTurn.run(seams, turn("main-47"), fn ->
          send(test, {:working, self()})
          receive do: (:never -> :ok)
        end)
      end)

    assert_receive {:working, held}
    ref = Process.monitor(held)
    Process.exit(run, :shutdown)

    assert_receive {:DOWN, ^ref, :process, ^held, :shutdown}
  end

  # A request still waiting in the held turn's mailbox when its run ended
  # never starts: nobody waits for it, and the computer said it stopped.
  test "a request whose run ended before the turn took it never starts", %{seams: seams} do
    test = self()

    _first =
      spawn(fn ->
        HeldTurn.run(seams, turn("main-48"), fn ->
          send(test, {:working, self()})
          receive do: (:go_on -> :first_done)
        end)
      end)

    assert_receive {:working, held}

    second =
      spawn(fn -> HeldTurn.run(seams, turn("main-48"), fn -> send(test, :second_ran) end) end)

    await_queued(held, 1)
    ref = Process.monitor(second)
    Process.exit(second, :kill)
    assert_receive {:DOWN, ^ref, :process, ^second, :killed}

    send(held, :go_on)
    await_queued(held, 0)
    third = HeldTurn.run(seams, turn("main-48"), fn -> self() end)

    assert third == held
    refute_received :second_ran
  end

  # Another turn of the same conversation: on the server its turns run one
  # at a time, so the earlier one has ended there even when its end has not
  # reached this computer yet. It ends here first, as its end would, and
  # the pane task it held ends with it rather than under the new turn.
  test "a conversation's next turn ends the turn it held before, normally", %{seams: seams} do
    earlier = HeldTurn.run(seams, turn("main-50"), fn -> self() end)
    ref = Process.monitor(earlier)

    {next, alive?} =
      HeldTurn.run(seams, turn("main-51"), fn -> {self(), Process.alive?(earlier)} end)

    assert_receive {:DOWN, ^ref, :process, ^earlier, :normal}
    refute next == earlier
    refute alive?
  end

  # A delegated worker works in its turn's tab, as on the server: it never
  # ends the turn it works for, nor another turn of another conversation.
  test "a worker, and another conversation's turn, end no turn", %{seams: seams} do
    held = HeldTurn.run(seams, turn("main-52"), fn -> self() end)

    worker =
      HeldTurn.run(seams, %{turn("main-53") | worker?: true}, fn -> self() end)

    elsewhere = HeldTurn.run(seams, turn("main-54", "owner-c2hlZA"), fn -> self() end)

    assert Enum.all?([held, worker, elsewhere], &Process.alive?/1)
    assert length(Enum.uniq([held, worker, elsewhere])) == 3
  end

  test "ending every turn held here ends each at once, stopped", %{seams: seams} do
    held = HeldTurn.run(seams, turn("main-55"), fn -> self() end)
    other = HeldTurn.run(seams, turn("main-56", "owner-c2hlZA"), fn -> self() end)
    refs = Enum.map([held, other], &Process.monitor/1)

    assert :ok = HeldTurn.stop_all(seams)

    for {ref, pid} <- Enum.zip(refs, [held, other]),
        do: assert_receive({:DOWN, ^ref, :process, ^pid, :shutdown})

    assert DynamicSupervisor.which_children(seams.supervisor) == []
  end

  test "a session id is a turn's as the wire carries it" do
    assert HeldTurn.session?("main-41")
    refute HeldTurn.session?("")
    refute HeldTurn.session?("main 41")
    refute HeldTurn.session?(nil)
  end

  defp turn(session, conversation \\ "owner-YWxsb3RtZW50"),
    do: %{session: session, conversation: conversation, worker?: false}

  # Waits until the held turn has `count` requests in its mailbox: the
  # held turn tells nobody when one arrives.
  defp await_queued(pid, count, attempts \\ 1_000) do
    {:message_queue_len, queued} = Process.info(pid, :message_queue_len)

    cond do
      queued == count ->
        :ok

      attempts == 0 ->
        flunk("the held turn never had #{count} request(s) waiting")

      true ->
        # sleep: polls the held turn's mailbox, which announces nothing
        Process.sleep(10)
        await_queued(pid, count, attempts - 1)
    end
  end
end
