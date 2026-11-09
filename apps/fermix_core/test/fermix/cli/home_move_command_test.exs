defmodule Fermix.CLI.HomeMoveCommandTest do
  # Sync: the verbs print refusals on `:standard_error`, one globally
  # registered device that concurrent captures would share.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Fermix.CLI.HomeCommand
  alias FermixCore.Home.Candidate
  alias FermixCore.Home.Candidates
  alias FermixCore.Home.EnrollmentCode
  alias FermixCore.Home.Epoch
  alias FermixCore.Home.Move
  alias FermixCore.Home.Role
  alias FermixCore.Home.Snapshot.Recipient
  alias FermixTestSupport.SafeRm

  @now ~U[2031-05-04 10:00:00Z]
  @passphrase "invented-lantern-orchard"

  setup do
    tmp = SafeRm.make_tmp_dir!("home_move_command")
    on_exit(fn -> SafeRm.rm_rf!(tmp) end)

    {:ok, code} =
      EnrollmentCode.encode(%{
        secret: :binary.copy(<<0x5A>>, 32),
        gateway_pk: :binary.copy(<<0x3C>>, 32),
        node_id: String.duplicate("4f", 32),
        relays: [%{"url" => "https://eu1.relay.invalid/", "quic_port" => 7842}],
        relays_rev: "0123456789abcdef",
        name: "orchard-mini",
        expires_at: ~U[2031-05-04 10:10:00Z]
      })

    code_file = Path.join(tmp, "enroll.code")
    # The first-boot script writes it with printf '%s\n'.
    File.write!(code_file, code <> "\n")

    %{tmp: tmp, home: Path.join(tmp, "home"), code: code, code_file: code_file}
  end

  describe "enroll" do
    test "takes exactly the first boot's arguments, then removes the code file", ctx do
      argv = [
        "enroll",
        "--code-file",
        ctx.code_file,
        "--snapshot-bucket",
        "invented-bucket-91",
        "--snapshot-region",
        "eu-north-1"
      ]

      {status, out, err} = run(argv, home: ctx.home, now: fn -> @now end)

      assert {status, err} == {0, ""}
      assert out =~ "This home is now a candidate of orchard-mini."
      refute out =~ ctx.code
      refute File.exists?(ctx.code_file)
      assert File.read!(Candidate.path(ctx.home, "code")) == ctx.code
      refute File.exists?(Candidate.path(ctx.home, "instance.json"))

      assert {:ok, %{"s3_bucket" => "invented-bucket-91", "s3_region" => "eu-north-1"}} =
               Candidate.destination(ctx.home)

      assert {:ok, %{role: :candidate}} = Role.configured(ctx.home)
    end

    # E1: first boot passes --snapshot-instance-role when the server's
    # infrastructure set the bucket; the candidate keeps it with the bucket.
    test "an infrastructure-set bucket is kept with how it signs", ctx do
      argv = [
        "enroll",
        "--code-file",
        ctx.code_file,
        "--snapshot-bucket",
        "invented-bucket-91",
        "--snapshot-region",
        "eu-north-1",
        "--snapshot-instance-role"
      ]

      assert {0, _out, ""} = run(argv, home: ctx.home, now: fn -> @now end)

      assert Candidate.destination(ctx.home) ==
               {:ok,
                %{
                  "s3_bucket" => "invented-bucket-91",
                  "s3_region" => "eu-north-1",
                  "s3_credentials" => "instance_role"
                }}
    end

    test "the instance role signs only a bucket given with it", ctx do
      assert {2, _out, _err} =
               run(["enroll", "--code-file", ctx.code_file, "--snapshot-instance-role"],
                 home: ctx.home
               )

      assert File.exists?(ctx.code_file)
    end

    test "a refusal leaves the home and the code file as they were", ctx do
      {status, _out, err} =
        run(["enroll", "--code-file", ctx.code_file],
          home: ctx.home,
          now: fn -> ~U[2031-05-04 11:00:00Z] end
        )

      assert status == 1
      assert err =~ "The enrollment code expired at 2031-05-04T10:10:00Z."
      refute err =~ ctx.code
      assert File.exists?(ctx.code_file)
      refute File.exists?(ctx.home)

      File.mkdir_p!(ctx.home)
      :ok = Epoch.write(ctx.home, 2)

      {status, _out, err} =
        run(["enroll", "--code-file", ctx.code_file], home: ctx.home, now: fn -> @now end)

      assert status == 1
      assert err =~ "holds a primary epoch"
      assert File.exists?(ctx.code_file)
    end

    # Always On review M1 (D1): the installer runs this again on a server
    # whose enrollment failed, ran out or waits for a move its computer
    # forgot, with the new code, and reads the exit status; the sentence is a
    # fresh enrollment's. One that ended takes its own code again too.
    test "enrolls again a server whose enrollment failed, ran out or waits for its move", ctx do
      {0, _out, ""} =
        run(["enroll", "--code-file", ctx.code_file], home: ctx.home, now: fn -> @now end)

      {:ok, state} = Candidate.read_state(ctx.home)
      {:ok, facts} = EnrollmentCode.decode(ctx.code)
      {:ok, new_code} = EnrollmentCode.encode(%{facts | secret: :binary.copy(<<0x6B>>, 32)})

      for {phase, code} <- [{"failed", ctx.code}, {"expired", ctx.code}, {"enrolled", new_code}] do
        :ok = Candidate.put_state(ctx.home, Map.put(state, "phase", phase), @now)
        File.write!(ctx.code_file, code <> "\n")

        {status, out, err} =
          run(["enroll", "--code-file", ctx.code_file], home: ctx.home, now: fn -> @now end)

        assert {status, err} == {0, ""}, phase

        # What happens next, true for a person who starts Fermix and for a
        # first boot that starts it on its next line (EC2 test finding 9).
        assert out ==
                 "This home is now a candidate of orchard-mini. When Fermix starts here, it " <>
                   "enrolls with orchard-mini, then waits up to 24 hours for the move.\n"

        assert {:ok, %{"phase" => "enrolling"}} = Candidate.read_state(ctx.home)
        refute File.exists?(ctx.code_file)
      end
    end

    # The installer run again with the code the server enrolled with reads
    # the refusal's exit status and shows its sentence.
    test "refuses the code a server enrolled with, leaving the home and the code file", ctx do
      {0, _out, ""} =
        run(["enroll", "--code-file", ctx.code_file], home: ctx.home, now: fn -> @now end)

      {:ok, state} = Candidate.read_state(ctx.home)
      :ok = Candidate.put_state(ctx.home, Map.put(state, "phase", "enrolled"), @now)
      {:ok, key} = Candidate.noise_keypair(ctx.home)
      File.write!(ctx.code_file, ctx.code <> "\n")

      {status, out, err} =
        run(["enroll", "--code-file", ctx.code_file], home: ctx.home, now: fn -> @now end)

      assert {status, out} == {1, ""}

      assert err ==
               "fermix home enroll: This server enrolled with this code already and waits for " <>
                 "its move. To set it up again, open a new code in Always On and run this " <>
                 "command with that code.\n"

      assert File.exists?(ctx.code_file)
      assert {:ok, %{"phase" => "enrolled"}} = Candidate.read_state(ctx.home)
      assert {:ok, ^key} = Candidate.noise_keypair(ctx.home)
    end

    test "a missing file is a refusal and half an option pair is a usage error", ctx do
      {status, _out, err} =
        run(["enroll", "--code-file", Path.join(ctx.tmp, "absent")],
          home: ctx.home,
          now: fn -> @now end
        )

      assert status == 1
      assert err =~ "could not be read"

      assert {2, _out, _err} =
               run(["enroll", "--code-file", ctx.code_file, "--snapshot-bucket", "b"],
                 home: ctx.home
               )

      assert {2, _out, _err} = run(["enroll"], home: ctx.home)
    end

    # Nothing in v1 writes what a host says of itself, so the option is gone.
    test "an instance file is a usage error, and the code file stays", ctx do
      instance_file = Path.join(ctx.tmp, "instance.json")
      File.write!(instance_file, ~s({"provider": "hetzner"}))

      assert {2, _out, _err} =
               run(["enroll", "--code-file", ctx.code_file, "--instance-file", instance_file],
                 home: ctx.home,
                 now: fn -> @now end
               )

      assert File.exists?(ctx.code_file)
      refute File.exists?(ctx.home)
    end
  end

  # Always On setup §3.5, §8.2: `home.enroll.open` and `home.move.start` are
  # served only to a linked desktop's forward now, so the two verbs that
  # called them over `daemon.sock` are gone, with nothing in their place.
  describe "enroll-code and move" do
    test "are usage errors, reach no engine and are not in the usage", ctx do
      test = self()
      passphrase_file = Path.join(ctx.tmp, "recovery")
      File.write!(passphrase_file, @passphrase <> "\n")

      client = fn method, _params, _opts ->
        send(test, {:called, method})
        {:error, :not_running}
      end

      move = ["move", "--to", "cand-5e2a9c1f7b3d4086", "--recovery-passphrase-file"]

      for argv <- [
            ["enroll-code"],
            ["enroll-code", "--json"],
            move ++ [passphrase_file, "--json"],
            move ++ [passphrase_file, "--retire"]
          ] do
        {status, out, err} = run(argv, home: ctx.home, client: client)
        assert {status, out} == {2, ""}, inspect(argv)
        assert err =~ "fermix home candidates [--json]", inspect(argv)
        refute err =~ "enroll-code", inspect(argv)
        refute err =~ "fermix home move", inspect(argv)
      end

      refute_received {:called, _method}
    end

    test "are not in fermix help" do
      help = capture_io(fn -> assert Fermix.CLI.main(["help"]) == 0 end)

      assert help =~ "fermix home candidates [--json]"
      refute help =~ "enroll-code"
      refute help =~ "fermix home move"
    end
  end

  describe "candidates" do
    test "lists the engine's answer, or the home's file when it is stopped", ctx do
      File.mkdir_p!(ctx.home)
      {:ok, record} = Candidates.add(ctx.home, candidate_attrs(), @now)
      stopped = fn _method, _params, _opts -> {:error, :not_running} end

      {0, out, _err} = run(["candidates"], home: ctx.home, client: stopped, now: fn -> @now end)
      assert out =~ record.candidate_id
      refute out =~ ~r/instance|unverified|compare/i

      empty = fn "home.candidates.list", %{}, _opts -> {:ok, %{"candidates" => []}} end
      {0, out, _err} = run(["candidates"], home: ctx.home, client: empty)
      assert out == "No server is enrolled.\n"
    end
  end

  describe "status during a move" do
    setup ctx do
      File.mkdir_p!(ctx.home)
      :ok = Epoch.write(ctx.home, 4)
      {:ok, record} = Candidates.add(ctx.home, candidate_attrs(), @now)
      %{candidate: record}
    end

    test "home status says where the move stands", ctx do
      stopped = fn _method, _params, _opts -> {:error, :not_running} end
      {:ok, pair} = Recipient.from_passphrase(@passphrase)

      {:ok, _started} =
        Move.start(
          ctx.home,
          %{role: :primary, primary: nil},
          ctx.candidate.candidate_id,
          Recipient.public(pair),
          [now: @now] ++ ready()
        )

      {0, out, _err} = run(["status"], home: ctx.home, client: stopped)
      assert out =~ "Role: device"
      assert out =~ "Move: The move to north-box starts when Fermix restarts."
    end
  end

  # The readiness report's facts about this host, as seams.
  defp ready,
    do: [
      free_bytes: fn _dir -> {:ok, 1_099_511_627_776} end,
      version: "9.9.9",
      host: "macos-aarch64"
    ]

  defp run(argv, deps) do
    parent = self()

    err =
      capture_io(:stderr, fn ->
        out = capture_io(fn -> send(parent, {:status, HomeCommand.run(argv, deps)}) end)
        send(parent, {:out, out})
      end)

    assert_received {:status, status}
    assert_received {:out, out}
    {status, out, err}
  end

  defp candidate_attrs do
    %{
      name: "north-box",
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
