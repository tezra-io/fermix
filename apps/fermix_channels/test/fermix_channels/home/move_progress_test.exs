defmodule FermixChannels.Home.MoveProgressTest do
  @moduledoc """
  The move's count, kept where the Always On summary reads it (Always On pane
  §3.13, P2 and P4): the source (`Home.MoveWorker`) puts each of its steps and
  each whole 5% of the bytes it hands the rail, the receiver
  (`Home.MoveResponder`) each whole 5% of the bytes it wrote, and each forgets
  the record when its part ends, however it ends; never a record per chunk.

  A whole move between two real homes in one VM, as `Home.MoveTest` runs it,
  with the receiver's responder behind a bridge of this test's own so that its
  store is the test's. Each store tells the test, from inside the store, the
  record it holds at each change: the order is exact and nothing is timed.
  """
  use ExUnit.Case, async: true

  alias FermixChannels.Home.Enrollment
  alias FermixChannels.Home.MoveResponder
  alias FermixChannels.Home.MoveWorker
  alias FermixChannels.Mobile.Iroh.Bridge
  alias FermixChannels.Mobile.Rail
  alias FermixChannels.Test.DesktopRail
  alias FermixChannels.Test.HomeMove
  alias FermixCore.Home.Candidate
  alias FermixCore.Home.Move
  alias FermixCore.Home.MoveProgress
  alias FermixCore.Home.Snapshot.Recipient

  @primary_record %{role: :primary, primary: nil}
  @chunk_bytes 60 * 1_024
  # More than twenty chunks, so each chunk is under 5% of the capture.
  @photo_bytes 1_536 * 1_024

  setup do
    primary = HomeMove.primary!()

    File.write!(
      Path.join([primary.root, "journals", "invented-photo.bin"]),
      :crypto.strong_rand_bytes(@photo_bytes)
    )

    {:ok, %{code: code}} = Enrollment.open(primary.enrollment)
    home = HomeMove.candidate_home!(code)
    candidate = HomeMove.start_candidate!(home, primary)
    %{"candidate_id" => candidate_id} = HomeMove.await_phase(home, "enrolled")
    recipient = Recipient.public(Recipient.generate())

    {:ok, started} =
      Move.start(primary.root, @primary_record, candidate_id, recipient, HomeMove.start_opts())

    source = store!(:source, fn -> nil end)
    receiver = store!(:receiver, fn -> candidate_phase(home) end)
    candidate = %{candidate | bridge_socket: responder_bridge!(candidate, receiver)}

    %{primary: primary, candidate: candidate, home: home, started: started, source: source}
  end

  test "each side puts its steps and each whole 5% of the bytes, never a chunk", ctx do
    source = ctx.primary.root
    run_worker(source, ctx.candidate, progress: ctx.source)
    assert_received :source_restart

    {:ok, %{"capture" => %{"size" => size}}} = Move.read_phase(source)
    chunks = div(size + @chunk_bytes - 1, @chunk_bytes)
    assert chunks > 21
    move_id = ctx.started.move_id

    {sent, nil} = told(:source)

    assert Enum.map(sent, & &1.step) ==
             [:capture] ++ List.duplicate(:send, 21) ++ [:staging, :commit]

    assert Enum.all?(sent, &(&1.move_id == move_id))
    assert [%{bytes: 0, size: nil}] = Enum.filter(sent, &(&1.step == :capture))
    assert [%{bytes: 0, size: nil}, %{bytes: 0, size: nil}] = Enum.take(sent, -2)
    assert_counted(Enum.filter(sent, &(&1.step == :send)), size)

    # The receiver forgets its record as the stream ends, before it stages
    # what came: the candidate is still receiving when it does.
    assert {received, "receiving"} = told(:receiver)
    assert Enum.map(received, & &1.step) == List.duplicate(:receive, 21)
    assert Enum.all?(received, &(&1.move_id == move_id))
    assert_counted(received, size)

    assert MoveProgress.read(ctx.source) == nil
  end

  test "an undone move forgets its record", ctx do
    source = ctx.primary.root
    request_file = Path.join(Move.dir(source), "request.json")
    # The candidate's recipient is not the one the source encrypts to, so the
    # candidate's accept is refused and the move undone.
    request = Jason.decode!(File.read!(request_file))
    request = put_in(request["candidate"]["recipient"], Base.encode64(:binary.copy(<<7>>, 32)))
    File.write!(request_file, Jason.encode!(request))

    run_worker(source, ctx.candidate, progress: ctx.source)
    assert_received :source_restart
    assert {:ok, %{"phase" => "undoing"}} = Move.read_phase(source)

    assert {[%{step: :capture}, %{step: :send, bytes: 0, size: size}], nil} = told(:source)
    assert size > @photo_bytes
    assert MoveProgress.read(ctx.source) == nil
  end

  test "a stream cut part-way is forgotten as its session closes, a chunk not put", ctx do
    {:ok, request} = Move.read_request(ctx.primary.root)
    move_id = request["move_id"]
    # Forty chunks: one chunk is 2.5%, so every second one crosses a twentieth.
    size = 40 * @chunk_bytes
    {:ok, rail} = open_move(ctx, request["candidate"])

    :ok =
      Rail.send_event(rail, "move_offer", %{
        "move_id" => move_id,
        "size_bytes" => size,
        "sha256" => String.duplicate("ab", 32),
        "source_epoch" => 4,
        "recovery_recipient" => request["recovery_recipient"],
        "attempt" => 1
      })

    assert_receive {:rail, ^rail, {:event, %{"t" => "move_accept"}, _bytes}}, 10_000

    for index <- 0..4 do
      payload = %{"move_id" => move_id, "index" => index}
      :ok = Rail.send_event(rail, "move_chunk", payload, :crypto.strong_rand_bytes(@chunk_bytes))
    end

    :ok = Rail.close(rail)

    {received, _phase} = told(:receiver)
    assert Enum.map(received, & &1.bytes) == [0, 2 * @chunk_bytes, 4 * @chunk_bytes]
    assert Enum.all?(received, &(&1.size == size and &1.move_id == move_id))
  end

  # -- the stores -------------------------------------------------------------

  # A store of the test's own that tells it `{side, record, fact}` at each
  # change, the fact being what `also` answers then.
  defp store!(side, also) do
    test = self()
    name = :"move_progress_#{side}_#{System.unique_integer([:positive])}"

    told = fn ->
      send(test, {side, MoveProgress.read(name), also.()})
      :ok
    end

    start_supervised!({MoveProgress, name: name, status_changed: told}, id: name)
    name
  end

  # The records `side` told, in order, up to the change that forgot the move,
  # and the fact told with that change.
  defp told(side, acc \\ []) do
    receive do
      {^side, nil, fact} -> {Enum.reverse(acc), fact}
      {^side, record, _fact} -> told(side, [record | acc])
    after
      10_000 -> flunk("#{side} never forgot the move; told so far: #{inspect(Enum.reverse(acc))}")
    end
  end

  # A transfer of `size` put at 0, then once at each whole 5% it crossed, at
  # the count of a whole chunk or the last, ending at the whole.
  defp assert_counted(records, size) do
    counts = Enum.map(records, & &1.bytes)
    assert Enum.all?(records, &(&1.size == size))
    assert hd(counts) == 0
    assert List.last(counts) == size
    assert Enum.map(counts, &div(&1 * 20, size)) == Enum.to_list(0..20)
    assert Enum.all?(counts, &(rem(&1, @chunk_bytes) == 0 or &1 == size))
  end

  defp candidate_phase(home) do
    {:ok, %{"phase" => phase}} = Candidate.read_state(home)
    phase
  end

  # The candidate's move responder, as `HomeMove.start_candidate!/3` serves
  # it, behind a bridge of the test's own whose responder counts into `store`.
  defp responder_bridge!(candidate, store) do
    suffix = System.unique_integer([:positive])

    connections =
      start_supervised!({DynamicSupervisor, strategy: :one_for_one}, id: {:connections, suffix})

    socket = Path.join(Candidate.dir(candidate.home), "p.sock")
    responder = {MoveResponder, [candidate: candidate.name, progress: store]}

    start_supervised!(
      {Bridge,
       name: nil,
       socket_path: socket,
       connection_supervisor: connections,
       connection_opts: [session_opts: [phone_modes: [], responders: %{ik_move: responder}]]},
      id: {:bridge, suffix}
    )

    socket
  end

  defp run_worker(source, candidate, overrides) do
    opts = HomeMove.worker_opts(source, candidate, overrides)
    :ok = Task.await(Task.async(fn -> MoveWorker.run(opts) end), 60_000)
  end

  defp open_move(ctx, candidate) do
    Rail.open(
      %{node_id: candidate.node_id, relays: candidate.relays, relays_rev: "0123456789abcdef"},
      :ik_move,
      static_keypair: ctx.primary.gateway,
      remote_static: candidate.noise_pk,
      connect: DesktopRail.bridge_connect(ctx.candidate.bridge_socket)
    )
  end
end
