defmodule FermixChannels.Home.EnrollmentJoinTest do
  # M97 §3.1, §7.5 through a real primary session: a computer's code, its
  # `join_request` over real Noise IKpsk2 from Mobile.Rail, the six digits
  # under the computer label, and the owner's answer. Until the owner adds
  # it, the computer has no row; every other ending adds nothing and spends
  # the code.
  use ExUnit.Case, async: true

  alias FermixChannels.Home.Enrollment
  alias FermixChannels.Mobile.DeviceStore
  alias FermixChannels.Mobile.Noise
  alias FermixChannels.Mobile.Rail
  alias FermixChannels.Test.DesktopRail
  alias FermixChannels.Test.HomeMove
  alias FermixCore.Home.EnrollmentCode

  @wait 10_000
  @request %{
    "host" => %{"name" => "loft-linux", "os" => "linux", "arch" => "x86_64", "version" => "9.9.9"},
    "platform" => "linux"
  }

  setup do
    primary = HomeMove.primary!()
    {:ok, %{code: code}} = Enrollment.open(primary.enrollment, nil, :computer)
    %{primary: primary, code: code}
  end

  test "the code is a computer's, and its join waits for the owner with the same digits", ctx do
    assert {:ok, %{purpose: :computer}} = EnrollmentCode.decode(ctx.code)

    {rail, keypair} = join!(ctx)
    sas = Rail.sas(rail, :computer)
    assert sas =~ ~r/\A[0-9]{6}\z/
    refute sas == Rail.sas(rail, :phone)

    assert %{state: :awaiting_approval, purpose: :computer, joiner: joiner} = wait_status(ctx)
    # The digits are the new computer's to show: the window names it, never
    # them, so no screen of the home can show them (M97 §7.5).
    assert joiner == %{name: "loft-linux", platform: "linux"}
    assert {:ok, []} = DeviceStore.list(ctx.primary.store)

    # The session is held while the owner decides, answering ping.
    :ok = Rail.send_event(rail, "ping", %{})
    assert_receive {:rail, ^rail, {:event, %{"t" => "pong"}, _bytes}}, @wait

    assert {:ok, %{device_id: id, name: "loft-linux"}} =
             Enrollment.approve(ctx.primary.enrollment, sas)

    assert_receive {:rail, ^rail, {:event, %{"t" => "join_approved"} = approved, _bytes}}, @wait
    assert_receive {:rail, ^rail, {:closed, {:remote, 1000, "joined"}}}, @wait

    assert %{"device_id" => ^id, "name" => "loft-linux", "primary_epoch" => 4} = approved
    assert approved["primary"]["name"] == "studio-mac"
    assert approved["primary"]["node_id"] == ctx.primary.node_id

    assert {:ok, [row]} = DeviceStore.list(ctx.primary.store)

    assert {row.device_id, row.kind, row.platform, row.backups, row.noise_pk} ==
             {id, :desktop, "linux", false, keypair.public}

    assert %{state: :approved, joined: %{device_id: ^id, name: "loft-linux"}} =
             Enrollment.status(ctx.primary.enrollment)
  end

  test "an answer that was lost reaches the same computer again", ctx do
    {rail, keypair} = join!(ctx)
    sas = Rail.sas(rail, :computer)
    _waiting = wait_status(ctx)
    {:ok, %{device_id: id}} = Enrollment.approve(ctx.primary.enrollment, sas)
    assert_receive {:rail, ^rail, {:closed, {:remote, 1000, "joined"}}}, @wait

    {again, _keypair} = join!(ctx, keypair)
    assert_receive {:rail, ^again, {:event, %{"t" => "join_approved"} = answer, _bytes}}, @wait
    assert answer["device_id"] == id
    assert {:ok, [_one_row]} = DeviceStore.list(ctx.primary.store)
  end

  test "the owner's denial adds nothing and spends the code", ctx do
    {rail, _keypair} = join!(ctx)
    _waiting = wait_status(ctx)

    :ok = Enrollment.deny(ctx.primary.enrollment)

    assert_receive {:rail, ^rail, {:event, %{"t" => "join_denied", "reason" => "denied"}, _}},
                   @wait

    assert_receive {:rail, ^rail, {:closed, {:remote, 4003, "join denied"}}}, @wait
    assert {:ok, []} = DeviceStore.list(ctx.primary.store)
    assert %{state: :denied} = Enrollment.status(ctx.primary.enrollment)
    assert_spent(ctx)
  end

  test "digits that are not the computer's deny it", ctx do
    {rail, _keypair} = join!(ctx)
    sas = Rail.sas(rail, :computer)
    _waiting = wait_status(ctx)
    wrong = if sas == "000000", do: "111111", else: "000000"

    assert {:error, :sas_mismatch} = Enrollment.approve(ctx.primary.enrollment, wrong)

    assert_receive {:rail, ^rail, {:event, %{"t" => "join_denied", "reason" => "denied"}, _}},
                   @wait

    assert {:ok, []} = DeviceStore.list(ctx.primary.store)
    assert {:error, :none} = Enrollment.approve(ctx.primary.enrollment, sas)
    assert_spent(ctx)
  end

  # A dropped session spends nothing: the window keeps the computer's key,
  # nobody waits until it dials again, and then it waits with the digits of
  # its new session, which are the ones the owner types.
  test "a computer whose session drops while it waits is admitted again by its key", ctx do
    {rail, keypair} = join!(ctx)
    first = Rail.sas(rail, :computer)
    _waiting = wait_status(ctx)

    :ok = Rail.close(rail)

    assert %{state: :used, joiner: nil} =
             HomeMove.await(fn ->
               case Enrollment.status(ctx.primary.enrollment) do
                 %{state: :awaiting_approval} -> nil
                 settled -> settled
               end
             end)

    assert {:error, :none} = Enrollment.approve(ctx.primary.enrollment, first)
    assert {:ok, []} = DeviceStore.list(ctx.primary.store)
    assert_spent(ctx)

    {again, ^keypair} = join!(ctx, keypair)
    _waiting = wait_status(ctx)

    assert {:ok, %{name: "loft-linux"}} =
             Enrollment.approve(ctx.primary.enrollment, Rail.sas(again, :computer))

    assert_receive {:rail, ^again, {:event, %{"t" => "join_approved"}, _bytes}}, @wait
  end

  # What a crash report or `:sys.get_status/1` prints of the window: never
  # the digits the owner types, nor the code's secret.
  test "the status of the window shows neither the digits nor the secret", ctx do
    {rail, _keypair} = join!(ctx)
    sas = Rail.sas(rail, :computer)
    _waiting = wait_status(ctx)
    {:ok, facts} = EnrollmentCode.decode(ctx.code)

    printed =
      ctx.primary.enrollment
      |> GenServer.whereis()
      |> :sys.get_status()
      |> inspect(limit: :infinity, printable_limit: :infinity)

    refute printed =~ sas
    refute printed =~ inspect(facts.secret, limit: :infinity)
    assert printed =~ "loft-linux"
  end

  test "the window closing while a computer waits denies it as a timeout", ctx do
    {rail, _keypair} = join!(ctx)
    %{expires_at: expires_at} = wait_status(ctx)

    HomeMove.advance!(ctx.primary, 1_800)
    send(GenServer.whereis(ctx.primary.enrollment), {:expire, expires_at})

    assert_receive {:rail, ^rail, {:event, %{"t" => "join_denied", "reason" => "timeout"}, _}},
                   @wait

    assert {:ok, []} = DeviceStore.list(ctx.primary.store)
  end

  test "a name another computer holds is kept apart", ctx do
    {:ok, _row} =
      DeviceStore.add(ctx.primary.store, %{
        device_id: "0f1e2d3c-4b5a-4968-8778-695a4b3c2d1e",
        name: "Loft-Linux",
        model: "Linux computer",
        noise_pk: :crypto.strong_rand_bytes(32),
        created_at: HomeMove.now(),
        kind: :desktop,
        platform: "linux",
        backups: false
      })

    {rail, _keypair} = join!(ctx)
    _waiting = wait_status(ctx)

    assert {:ok, %{name: "loft-linux 2"}} =
             Enrollment.approve(ctx.primary.enrollment, Rail.sas(rail, :computer))
  end

  # A code of the other purpose is refused before the window is burned, on
  # the wire and when it is opened.
  test "a candidate's request on a computer's window is refused by its purpose", ctx do
    {:ok, rail} = dial(ctx, Noise.generate_keypair())

    candidate = %{
      "node_id" => String.duplicate("c4", 32),
      "relays" => [%{"url" => "https://eu1.relay.invalid/", "quic_port" => 7842}],
      "recipient" => Base.encode64(:crypto.strong_rand_bytes(32))
    }

    :ok =
      Rail.send_event(rail, "enroll_request", %{
        "host" => @request["host"],
        "candidate" => candidate
      })

    assert_receive {:rail, ^rail, {:event, %{"t" => "error", "code" => "enrollment_purpose"}, _}},
                   @wait

    assert_receive {:rail, ^rail, {:closed, {:remote, 4003, "enrollment purpose"}}}, @wait
    assert %{state: :open} = Enrollment.status(ctx.primary.enrollment)

    assert {:error, {:unavailable, sentence}} = Enrollment.open(ctx.primary.enrollment)
    assert sentence =~ "A code for a new computer is open"
    assert %{state: :open, purpose: :computer} = Enrollment.status(ctx.primary.enrollment)
  end

  test "a computer's request on a candidate's window is refused by its purpose" do
    primary = HomeMove.primary!()
    {:ok, %{code: code}} = Enrollment.open(primary.enrollment)
    ctx = %{primary: primary, code: code}

    {:ok, rail} = dial(ctx, Noise.generate_keypair())
    :ok = Rail.send_event(rail, "join_request", @request)

    assert_receive {:rail, ^rail, {:event, %{"t" => "error", "code" => "enrollment_purpose"}, _}},
                   @wait

    assert %{state: :open, purpose: :candidate} = Enrollment.status(primary.enrollment)

    assert {:error, {:unavailable, "A code for your own server is open." <> _rest}} =
             Enrollment.open(primary.enrollment, nil, :computer)
  end

  defp join!(ctx, keypair \\ Noise.generate_keypair()) do
    {:ok, rail} = dial(ctx, keypair)
    :ok = Rail.send_event(rail, "join_request", @request)
    {rail, keypair}
  end

  defp dial(ctx, keypair) do
    {:ok, facts} = EnrollmentCode.decode(ctx.code)

    Rail.open(
      %{node_id: facts.node_id, relays: facts.relays, relays_rev: facts.relays_rev},
      :ikpsk2_enroll,
      static_keypair: keypair,
      remote_static: facts.gateway_pk,
      psk: facts.secret,
      connect: DesktopRail.bridge_connect(ctx.primary.bridge_socket)
    )
  end

  defp wait_status(ctx) do
    HomeMove.await(fn ->
      case Enrollment.status(ctx.primary.enrollment) do
        %{state: :awaiting_approval} = waiting -> waiting
        _not_yet -> nil
      end
    end)
  end

  # Another computer with the code is refused: one join burns the window.
  defp assert_spent(ctx) do
    {:ok, rail} = dial(ctx, Noise.generate_keypair())
    :ok = Rail.send_event(rail, "join_request", @request)

    assert_receive {:rail, ^rail, {:event, %{"t" => "error", "code" => code}, _bytes}}, @wait
    assert code in ["enrollment_used", "enrollment_expired"]
  end
end
