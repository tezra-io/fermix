defmodule FermixChannels.Home.EnrollmentTest do
  # M75 §7.1 through a real primary session: the enrollment window behind
  # Mobile.Session's prelude branch, real Noise IKpsk2 from Mobile.Rail.
  use ExUnit.Case, async: true

  alias FermixChannels.Home.Enrollment
  alias FermixChannels.Mobile.Noise
  alias FermixChannels.Mobile.Rail
  alias FermixChannels.Test.DesktopRail
  alias FermixChannels.Test.HomeMove
  alias FermixCore.Home.Candidate
  alias FermixCore.Home.Candidates
  alias FermixCore.Home.DeviceLocal
  alias FermixCore.Home.EnrollmentCode
  alias FermixCore.Management.Copy

  setup do
    primary = HomeMove.primary!()
    {:ok, %{code: code}} = Enrollment.open(primary.enrollment)
    %{primary: primary, code: code}
  end

  test "the code names this primary, and opening another replaces it", ctx do
    {:ok, facts} = EnrollmentCode.decode(ctx.code)
    assert facts.gateway_pk == ctx.primary.gateway.public
    assert facts.node_id == ctx.primary.node_id
    assert facts.name == "studio-mac"
    assert facts.expires_at == DateTime.add(HomeMove.now(), 1_800, :second)
    assert [%{"url" => "https://" <> _host, "quic_port" => _port} | _rest] = facts.relays

    {:ok, %{code: second}} = Enrollment.open(ctx.primary.enrollment)
    {:ok, replaced} = EnrollmentCode.decode(second)
    refute replaced.secret == facts.secret

    # The first code's secret no longer completes a handshake.
    assert {:error, {:handshake, _reason}} = open_enrollment(ctx.primary, ctx.code)

    {:ok, rail} = open_enrollment(ctx.primary, second)
    :ok = Rail.send_event(rail, "ping", %{})
    assert_receive {:rail, ^rail, {:event, %{"t" => "pong"}, _bytes}}, 10_000
  end

  test "a candidate with the code enrolls once; the window is burned", ctx do
    home = HomeMove.candidate_home!(ctx.code)
    {:ok, rail} = open_enrollment(ctx.primary, ctx.code, home)
    # What a host says of its instance is no field of the request: an older
    # host's is neither checked nor kept.
    :ok = Rail.send_event(rail, "enroll_request", Map.put(request(home), "instance", instance()))

    assert_receive {:rail, ^rail, {:event, %{"t" => "enroll_accepted"} = accepted, _bytes}},
                   10_000

    assert accepted["primary_name"] == "studio-mac"
    assert_receive {:rail, ^rail, {:closed, {:remote, 1000, "enrolled"}}}, 10_000

    {:ok, [record]} = Candidates.list(ctx.primary.root, HomeMove.now())
    {:ok, noise} = Candidate.noise_keypair(home)
    {:ok, pair} = Candidate.recipient_pair(home)
    assert record.candidate_id == accepted["candidate_id"]
    assert record.name == "north-box"
    assert record.noise_pk == noise.public
    assert record.recipient == pair.public_key
    refute Map.has_key?(record, :instance)
    assert Bitwise.band(File.stat!(Candidates.path(ctx.primary.root)).mode, 0o777) == 0o600

    assert %{state: :used} = Enrollment.status(ctx.primary.enrollment)

    # Another host with the same code is refused.
    other = HomeMove.candidate_home!(ctx.code)
    {:ok, again} = open_enrollment(ctx.primary, ctx.code, other)
    :ok = Rail.send_event(again, "enroll_request", request(other))
    assert_refused(again, "enrollment_used", "enrollment used")
    assert {:ok, [_one]} = Candidates.list(ctx.primary.root, HomeMove.now())
  end

  test "a candidate whose enroll_accepted was lost hears it again, as the same candidate",
       ctx do
    home = HomeMove.candidate_home!(ctx.code)
    {:ok, rail} = open_enrollment(ctx.primary, ctx.code, home)
    :ok = Rail.send_event(rail, "enroll_request", request(home))

    assert_receive {:rail, ^rail, {:event, %{"t" => "enroll_accepted"} = first, _bytes}},
                   10_000

    # The answer never reached it: it dials again with the same key.
    {:ok, again} = open_enrollment(ctx.primary, ctx.code, home)
    :ok = Rail.send_event(again, "enroll_request", request(home))

    assert_receive {:rail, ^again, {:event, %{"t" => "enroll_accepted"} = second, _bytes}},
                   10_000

    assert second["candidate_id"] == first["candidate_id"]
    assert {:ok, [_one]} = Candidates.list(ctx.primary.root, HomeMove.now())
  end

  test "the window outlives an engine restart, kept private and on this machine", ctx do
    enrollment = ctx.primary.enrollment
    old = Process.whereis(enrollment)
    :ok = GenServer.stop(enrollment)
    HomeMove.await(fn -> (pid = Process.whereis(enrollment)) && pid != old && pid end)

    assert %{state: :open} = Enrollment.status(enrollment)
    file = Path.join([ctx.primary.root, "mobile", "enrollment.json"])
    assert Bitwise.band(File.stat!(file).mode, 0o777) == 0o600
    assert DeviceLocal.excluded?("mobile/enrollment.json")

    home = HomeMove.candidate_home!(ctx.code)
    {:ok, rail} = open_enrollment(ctx.primary, ctx.code, home)
    :ok = Rail.send_event(rail, "enroll_request", request(home))
    assert_receive {:rail, ^rail, {:event, %{"t" => "enroll_accepted"}, _bytes}}, 10_000
  end

  test "a window past its thirty minutes refuses by name", ctx do
    HomeMove.advance!(ctx.primary, 1_800)
    {:ok, rail} = open_enrollment(ctx.primary, ctx.code)
    :ok = Rail.send_event(rail, "ping", %{})
    assert_refused(rail, "enrollment_expired", "enrollment expired")
    assert %{state: :expired} = Enrollment.status(ctx.primary.enrollment)
  end

  test "four held candidates are the limit", ctx do
    for n <- 1..4 do
      {:ok, _record} = Candidates.add(ctx.primary.root, held("box-#{n}"), HomeMove.now())
    end

    home = HomeMove.candidate_home!(ctx.code)
    {:ok, rail} = open_enrollment(ctx.primary, ctx.code, home)
    :ok = Rail.send_event(rail, "enroll_request", request(home))
    assert_refused(rail, "enrollment_limit", "enrollment limit")
  end

  test "a wrong secret is closed at its first frame, and nothing is burned", ctx do
    {:ok, facts} = EnrollmentCode.decode(ctx.code)
    {:ok, forged} = EnrollmentCode.encode(%{facts | secret: :binary.copy(<<1>>, 32)})

    # IKpsk2 mixes the PSK into the responder's reply, so the initiator is the
    # one that can tell first: a forger's handshake does not complete.
    assert {:error, {:handshake, _reason}} = open_enrollment(ctx.primary, forged)
    assert %{state: :open} = Enrollment.status(ctx.primary.enrollment)

    home = HomeMove.candidate_home!(ctx.code)
    {:ok, rail} = open_enrollment(ctx.primary, ctx.code, home)
    :ok = Rail.send_event(rail, "enroll_request", request(home))
    assert_receive {:rail, ^rail, {:event, %{"t" => "enroll_accepted"}, _bytes}}, 10_000
  end

  test "a primary with no window serves no enrollment prelude" do
    fresh = HomeMove.primary!()
    {:ok, code} = EnrollmentCode.encode(code_facts(fresh))
    assert {:error, {:remote, 1002, "mobile protocol error"}} = open_enrollment(fresh, code)
  end

  test "the session answers ping while the candidate takes its time", ctx do
    {:ok, rail} = open_enrollment(ctx.primary, ctx.code)
    :ok = Rail.send_event(rail, "ping", %{})
    assert_receive {:rail, ^rail, {:event, %{"t" => "pong"}, _bytes}}, 10_000
  end

  test "the candidate process enrolls, drops the code and waits a day", ctx do
    home = HomeMove.candidate_home!(ctx.code)
    _candidate = HomeMove.start_candidate!(home, ctx.primary)

    state = HomeMove.await_phase(home, "enrolled")
    assert "cand-" <> _id = state["candidate_id"]
    assert state["listen_until"] == "2031-05-05T10:00:00Z"
    refute File.exists?(Candidate.path(home, "code"))
    assert_receive {:scheduled, :listen_end, 86_400_000}, 10_000
  end

  test "the candidate process ends its enrollment on a refusal, by name, dropping the code",
       ctx do
    HomeMove.advance!(ctx.primary, 1_800)
    home = HomeMove.candidate_home!(ctx.code)
    _candidate = HomeMove.start_candidate!(home, ctx.primary)

    state = HomeMove.await_phase(home, "failed")
    assert state["sentence"] == "The enrollment code expired at studio-mac; open a new one there."
    refute File.exists?(Candidate.path(home, "code"))
  end

  test "no code is opened while the rail is not ready" do
    rail = start_supervised!({HomeMove.RailStatus, %{state: :off}})
    suffix = System.unique_integer([:positive])

    enrollment =
      start_supervised!({Enrollment, name: :"enrollment_off_#{suffix}", helper: rail})

    assert {:error, {:unavailable, "Remote reach is off." <> _rest}} =
             Enrollment.open(enrollment)

    assert Enrollment.status(enrollment) == nil
  end

  # The refusal is a sentence an owner reads, in Always On too (a create
  # keeps it as its failure), so the rail's own failure words, with its
  # relays, versions and keys, stay in the log and Doctor.
  test "a failed rail opens no code, in plain words that carry none of its own" do
    failure = "the helper runs iroh 1.3.0, the relays run 1.2.0"
    rail = start_supervised!({HomeMove.RailStatus, %{state: :failed, failure: failure}})
    suffix = System.unique_integer([:positive])

    enrollment =
      start_supervised!({Enrollment, name: :"enrollment_failed_#{suffix}", helper: rail})

    assert {:error, {:unavailable, sentence}} = Enrollment.open(enrollment)
    refute sentence =~ failure
    assert Copy.violations(sentence, :prose) == []
    assert Copy.summary_violations(sentence) == []
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

  defp assert_refused(rail, code, close) do
    assert_receive {:rail, ^rail, {:event, %{"t" => "error", "code" => ^code}, _bytes}}, 10_000
    assert_receive {:rail, ^rail, {:closed, {:remote, 4003, ^close}}}, 10_000
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

  defp code_facts(primary) do
    %{
      secret: :binary.copy(<<9>>, 32),
      gateway_pk: primary.gateway.public,
      node_id: primary.node_id,
      relays: [%{"url" => "https://eu1.relay.invalid/", "quic_port" => 7842}],
      relays_rev: "0123456789abcdef",
      name: "studio-mac",
      expires_at: ~U[2031-05-04 10:10:00Z]
    }
  end

  defp instance do
    %{
      "provider" => "hetzner",
      "instance_id" => "61839204",
      "region" => "fsn1"
    }
  end

  defp held(name) do
    %{
      name: name,
      os: "linux",
      arch: "aarch64",
      version: "9.9.9",
      node_id: String.duplicate("ab", 32),
      relays: [%{"url" => "https://eu1.relay.invalid/", "quic_port" => 7842}],
      noise_pk: :binary.copy(<<1>>, 32),
      recipient: :binary.copy(<<2>>, 32),
      snapshots: nil
    }
  end
end
