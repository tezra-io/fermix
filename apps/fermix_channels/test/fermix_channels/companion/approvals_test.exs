defmodule FermixChannels.Companion.ApprovalsTest do
  # FEAT-2: an approval card outlives the socket that was open when it went
  # out. It is kept, in memory as its token is, until it resolves or its ttl
  # runs out, and at the end of its ttl its watchers are told it expired. Its
  # token resolves only from the transport that raised it (M19 §9.5), so the
  # card, its re-send and its end reach that transport alone (R1-2).
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias FermixChannels.Companion.Approvals
  alias FermixChannels.Companion.Output

  setup do
    test_pid = self()
    {:ok, clock} = Agent.start_link(fn -> 1_000_000 end)

    server =
      start_supervised!(
        {Approvals,
         name: nil,
         clock: fn -> Agent.get(clock, & &1) end,
         schedule: fn message, delay_ms ->
           send(test_pid, {:scheduled, message, delay_ms})
           make_ref()
         end,
         announce: fn profile, event, audience ->
           send(test_pid, {:announced, profile, event, audience})
           :ok
         end}
      )

    %{server: server, clock: clock}
  end

  test "a card is kept for its own transport until it resolves there", %{server: server} do
    card = card("TOKEN")

    assert :ok = Approvals.announce(server, "main", card, :mobile)
    # The card goes out the one way its end does: the store's own announce (R4-6).
    assert_received {:announced, "main", ^card, :mobile}

    assert [%{"approval_id" => id, "t" => "approval"}] =
             Approvals.pending(server, "main", :mobile)

    assert id == card["approval_id"]
    assert Approvals.pending(server, "main", :companion) == []
    assert Approvals.pending(server, "work", :mobile) == []

    resolved = %{"t" => "approval_resolved", "approval_id" => id, "outcome" => "approved"}
    assert :ok = Approvals.resolve(server, "main", resolved, :mobile)
    assert_received {:announced, "main", ^resolved, :mobile}
    assert Approvals.pending(server, "main", :mobile) == []
  end

  # A card the store could not keep still resolves, and its resolution still
  # reaches the transport that answered it.
  test "a card never kept is still announced resolved to the transport that resolved it", %{
    server: server
  } do
    resolved = %{"t" => "approval_resolved", "approval_id" => "sandbox-x", "outcome" => "denied"}
    assert :ok = Approvals.resolve(server, "main", resolved, :companion)
    assert_received {:announced, "main", ^resolved, :companion}
  end

  test "a card kept again keeps its first deadline", %{server: server, clock: clock} do
    card = card("TOKEN")
    assert :ok = Approvals.announce(server, "main", card, :companion)
    Agent.update(clock, &(&1 + 30_000))

    assert :ok = Approvals.announce(server, "main", card, :companion)
    assert [%{"ttl_s" => 30}] = Approvals.pending(server, "main", :companion)
  end

  test "a card sent again carries the time it has left", %{server: server, clock: clock} do
    assert :ok = Approvals.announce(server, "main", card("TOKEN"), :mobile)
    Agent.update(clock, &(&1 + 20_500))

    assert [%{"ttl_s" => 40}] = Approvals.pending(server, "main", :mobile)

    Agent.update(clock, &(&1 + 40_000))
    assert Approvals.pending(server, "main", :mobile) == []
  end

  test "a card that outlives its ttl is withdrawn from its transport as expired", %{
    server: server
  } do
    card = card("TOKEN")
    assert :ok = Approvals.announce(server, "main", card, :companion)
    assert_received {:scheduled, message, 60_000}

    send(server, message)

    expired = %{
      "t" => "approval_resolved",
      "approval_id" => card["approval_id"],
      "outcome" => "expired"
    }

    assert_receive {:announced, "main", ^expired, :companion}
    assert Approvals.pending(server, "main", :companion) == []
  end

  test "a card resolved before its ttl ends is never announced as expired", %{server: server} do
    card = card("TOKEN")
    assert :ok = Approvals.announce(server, "main", card, :mobile)
    assert_received {:announced, "main", ^card, :mobile}
    assert_received {:scheduled, message, _delay_ms}

    resolved = %{
      "t" => "approval_resolved",
      "approval_id" => card["approval_id"],
      "outcome" => "denied"
    }

    assert :ok = Approvals.resolve(server, "main", resolved, :mobile)
    assert_received {:announced, "main", ^resolved, :mobile}

    send(server, message)
    _state = :sys.get_state(server)
    refute_received {:announced, _profile, _event, _audience}
  end

  test "the store is bounded: a card past its bound still goes out live, and is not kept", %{
    server: server
  } do
    for index <- 1..Approvals.max_pending() do
      assert :ok = Approvals.announce(server, "main", card("TOKEN-#{index}"), :mobile)
    end

    live = card("ONE-TOO-MANY")

    log =
      capture_log(fn ->
        assert :ok = Approvals.announce(server, "main", live, :companion)
      end)

    assert log =~ "pending_approvals_full"
    assert_received {:announced, "main", ^live, :companion}
    assert Approvals.pending(server, "main", :companion) == []
    assert length(Approvals.pending(server, "main", :mobile)) == 64
  end

  # M106 §8, D12 (stage S6): a card asked in the app with no turn is answered
  # from the Mac chat or a paired phone, so it belongs to both.
  test "a card asked in the app is kept for both transports, and resolved to both", %{
    server: server
  } do
    card = card("INBOX")

    assert :ok = Approvals.announce(server, "main", card, :all)
    assert_received {:announced, "main", ^card, :all}
    assert [%{"approval_id" => id}] = Approvals.pending(server, "main", :companion)
    assert [%{"approval_id" => ^id}] = Approvals.pending(server, "main", :mobile)

    # Answered on the phone: its end reaches both, as the card did.
    resolved = %{"t" => "approval_resolved", "approval_id" => id, "outcome" => "approved"}
    assert :ok = Approvals.resolve(server, "main", resolved, :mobile)
    assert_received {:announced, "main", ^resolved, :all}
    assert Approvals.pending(server, "main", :companion) == []
  end

  test "a heal's card is offered to both transports and never kept", %{server: server} do
    card = job_change_card("jhl_0a1b2c3d4e5f6a7b")

    assert :ok = Approvals.offer(server, "main", card)
    assert_received {:announced, "main", ^card, :all}
    refute_received {:scheduled, _message, _delay_ms}
    assert Approvals.pending(server, "main", :mobile) == []
  end

  test "after a hello a heal's cards are read again, after the cards in memory", %{
    clock: clock
  } do
    heal = job_change_card("jhl_0a1b2c3d4e5f6a7b")
    server = store(clock, fn "main" -> {:ok, [heal]} end)

    assert :ok = Approvals.announce(server, "main", card("TOKEN"), :companion)

    assert [%{"kind" => "sandbox"}, ^heal] = Approvals.pending(server, "main", :companion)
    assert [^heal] = Approvals.pending(server, "main", :mobile)
  end

  test "a source that fails, or answers what is no card, still lets the cards in memory out",
       %{clock: clock} do
    kept = card("TOKEN")
    heal = job_change_card("jhl_0a1b2c3d4e5f6a7b")

    for {answer, offered} <- [
          {{:error, :repo_timeout}, []},
          {:not_a_reply, []},
          {{:ok, [%{"t" => "row"}, heal, %{"t" => "approval", "ttl_s" => 0}]}, [heal]}
        ] do
      server = store(clock, fn "main" -> answer end)
      assert :ok = Approvals.announce(server, "main", kept, :companion)

      log =
        capture_log(fn ->
          assert Approvals.pending(server, "main", :companion) ==
                   [Map.put(kept, "ttl_s", 60) | offered]
        end)

      assert log =~ "heal card"
    end
  end

  test "announce refuses anything but an approval card", %{server: server} do
    assert_raise FunctionClauseError, fn ->
      Approvals.announce(server, "main", %{"t" => "text_done", "text" => "hi"}, :mobile)
    end

    assert_raise FunctionClauseError, fn ->
      Approvals.announce(server, "main", card("TOKEN"), :telegram)
    end
  end

  defp card(token), do: Output.approval(%{kind: :sandbox, text: "Allow?", token: token})

  defp job_change_card(heal_id) do
    Output.approval(%{
      kind: :job_change,
      text: "the whole card",
      lines: [~s(Change job "Harbour tide table"?), ~s(- Schedule: "every 2 hours")],
      detail: "Details: each change in full",
      token: heal_id,
      ttl_s: 604_800
    })
  end

  # A store of the test's own, its heal cards read from `durable`.
  defp store(clock, durable) do
    test_pid = self()

    start_supervised!(
      {Approvals,
       name: nil,
       clock: fn -> Agent.get(clock, & &1) end,
       schedule: fn _message, _delay_ms -> make_ref() end,
       announce: fn profile, event, audience ->
         send(test_pid, {:announced, profile, event, audience})
         :ok
       end,
       durable: durable},
      id: {:durable_store, System.unique_integer([:positive])}
    )
  end
end
