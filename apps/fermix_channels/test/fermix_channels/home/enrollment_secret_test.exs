defmodule FermixChannels.Home.EnrollmentSecretTest do
  # M75 §7.1: the window's secret leaves `mobile/enrollment.json` once it has
  # done its work (the window used and its candidate recorded) or can do none
  # (the window expired), and the candidate that used it is admitted again
  # only while the window lasts. Real Noise IKpsk2 from Mobile.Rail against
  # the primary's session; the window's timers come to the test and are
  # delivered by hand.
  use ExUnit.Case, async: true

  alias FermixChannels.Home.Enrollment
  alias FermixChannels.Mobile.Noise
  alias FermixChannels.Mobile.Rail
  alias FermixChannels.Test.DesktopRail
  alias FermixChannels.Test.HomeMove
  alias FermixCore.Home.Candidate
  alias FermixCore.Home.EnrollmentCode

  @window_ms 1_800_000

  setup do
    test = self()

    primary =
      HomeMove.primary!(
        schedule: fn message, delay ->
          send(test, {:scheduled, message, delay})
          make_ref()
        end
      )

    {:ok, %{code: code}} = Enrollment.open(primary.enrollment)
    assert_receive {:scheduled, {:expire, _at} = expire, @window_ms}, 10_000
    %{primary: primary, code: code, expire: expire}
  end

  test "a used window keeps no secret on disk, and admits its candidate again only while it lasts",
       ctx do
    {:ok, facts} = EnrollmentCode.decode(ctx.code)
    assert kept(ctx.primary)["secret"] == Base.encode64(facts.secret)

    home = HomeMove.candidate_home!(ctx.code)
    first = enroll!(ctx.primary, ctx.code, home)

    window = kept(ctx.primary)
    assert window["secret"] == nil
    assert window["used"] == true
    assert window["candidate_id"] == first["candidate_id"]
    assert window["expires_at"] == DateTime.to_iso8601(facts.expires_at)
    refute File.read!(Enrollment.path(ctx.primary.root)) =~ Base.encode64(facts.secret)
    assert %{state: :used} = Enrollment.status(ctx.primary.enrollment)

    # Its answer was lost: it is answered again, as the same candidate.
    assert enroll!(ctx.primary, ctx.code, home)["candidate_id"] == first["candidate_id"]

    # Once the window is over, not even that candidate is admitted.
    HomeMove.advance!(ctx.primary, 1_800)
    {:ok, rail} = open_enrollment(ctx.primary, ctx.code, home)
    :ok = Rail.send_event(rail, "ping", %{})

    assert_receive {:rail, ^rail,
                    {:event, %{"t" => "error", "code" => "enrollment_expired"}, _b}},
                   10_000
  end

  test "a window that expires unused has its secret taken off the disk", ctx do
    HomeMove.advance!(ctx.primary, 1_800)
    send(Process.whereis(ctx.primary.enrollment), ctx.expire)

    HomeMove.await(fn -> if kept(ctx.primary)["secret"] == nil, do: true end)
    assert %{state: :expired} = Enrollment.status(ctx.primary.enrollment)
    assert kept(ctx.primary)["expires_at"] == "2031-05-04T10:30:00Z"

    # The running window still answers a late candidate by name; an engine
    # that starts from the file holds no secret, and nothing completes a
    # handshake against it.
    {:ok, rail} = open_enrollment(ctx.primary, ctx.code)
    :ok = Rail.send_event(rail, "ping", %{})
    assert_receive {:rail, ^rail, {:event, %{"code" => "enrollment_expired"}, _bytes}}, 10_000

    restart!(ctx.primary.enrollment)
    assert %{state: :expired} = Enrollment.status(ctx.primary.enrollment)
    assert {:error, {:remote, 1002, _close}} = open_enrollment(ctx.primary, ctx.code)
  end

  test "an engine that starts after the window expired takes the secret off the disk", ctx do
    HomeMove.advance!(ctx.primary, 1_801)
    restart!(ctx.primary.enrollment)

    HomeMove.await(fn -> if kept(ctx.primary)["secret"] == nil, do: true end)
    assert %{state: :expired} = Enrollment.status(ctx.primary.enrollment)
  end

  defp restart!(enrollment) do
    old = Process.whereis(enrollment)
    :ok = GenServer.stop(enrollment)
    HomeMove.await(fn -> (pid = Process.whereis(enrollment)) && pid != old && pid end)
  end

  defp kept(primary), do: primary.root |> Enrollment.path() |> File.read!() |> Jason.decode!()

  defp enroll!(primary, code, home) do
    {:ok, rail} = open_enrollment(primary, code, home)
    :ok = Rail.send_event(rail, "enroll_request", request(home))

    assert_receive {:rail, ^rail, {:event, %{"t" => "enroll_accepted"} = accepted, _bytes}},
                   10_000

    assert_receive {:rail, ^rail, {:closed, {:remote, 1000, "enrolled"}}}, 10_000
    accepted
  end

  defp open_enrollment(primary, code, home \\ nil) do
    {:ok, facts} = EnrollmentCode.decode(code)

    keypair =
      if home,
        do: elem(Candidate.noise_keypair(home), 1),
        else: Noise.generate_keypair()

    Rail.open(
      %{node_id: facts.node_id, relays: facts.relays, relays_rev: facts.relays_rev},
      :ikpsk2_enroll,
      static_keypair: keypair,
      remote_static: facts.gateway_pk,
      psk: facts.secret,
      connect: DesktopRail.bridge_connect(primary.bridge_socket)
    )
  end

  defp request(home) do
    {:ok, pair} = Candidate.recipient_pair(home)
    iroh = File.read!(Candidate.path(home, "mobile/iroh_key"))
    {public, _secret} = :crypto.generate_key(:eddsa, :ed25519, iroh)

    %{
      "host" => %{
        "name" => "north-box",
        "os" => "linux",
        "arch" => "aarch64",
        "version" => "9.9.9"
      },
      "candidate" => %{
        "node_id" => Base.encode16(public, case: :lower),
        "relays" => [%{"url" => "https://eu1.relay.invalid/", "quic_port" => 7842}],
        "recipient" => Base.encode64(pair.public_key)
      }
    }
  end
end
