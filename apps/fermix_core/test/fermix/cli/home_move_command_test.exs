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

  describe "enroll-code" do
    test "prints the code the engine opened, or the envelope", ctx do
      client = fn "home.enroll.open", %{}, _opts ->
        {:ok, %{"code" => ctx.code, "expires_at" => "2031-05-04T10:10:00Z"}}
      end

      {0, out, _err} = run(["enroll-code"], home: ctx.home, client: client)
      assert out =~ ctx.code
      assert out =~ "valid once until 2031-05-04T10:10:00Z"

      {0, out, _err} = run(["enroll-code", "--json"], home: ctx.home, client: client)
      assert %{"ok" => true, "result" => %{"code" => _code}} = Jason.decode!(out)
    end

    test "needs the engine, and says what the engine refused", ctx do
      stopped = fn _method, _params, _opts -> {:error, :not_running} end
      {1, out, _err} = run(["enroll-code", "--json"], home: ctx.home, client: stopped)
      assert %{"ok" => false, "error" => %{"code" => "engine_stopped"}} = Jason.decode!(out)

      refused = fn _method, _params, _opts ->
        {:error,
         {:management_error, "unavailable", "unavailable",
          %{"sentence" => "Remote reach is off."}}}
      end

      {1, _out, err} = run(["enroll-code"], home: ctx.home, client: refused)
      assert err =~ "Fermix did not open an enrollment code. It said: Remote reach is off."
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
      assert out =~ "No candidate is enrolled."
    end
  end

  describe "move" do
    setup ctx do
      File.mkdir_p!(ctx.home)
      :ok = Epoch.write(ctx.home, 4)
      {:ok, record} = Candidates.add(ctx.home, candidate_attrs(), @now)
      passphrase_file = Path.join(ctx.tmp, "recovery")
      File.write!(passphrase_file, @passphrase <> "\n")
      %{candidate: record, passphrase_file: passphrase_file}
    end

    test "asks the running engine, the passphrase never on argv", ctx do
      test = self()

      client = fn "home.move.start", params, opts ->
        send(test, {:params, params})
        send(test, {:timeout, Keyword.fetch!(opts, :timeout)})

        {:ok,
         %{
           "move_id" => "mv-1",
           "candidate" => %{"name" => "north-box"},
           "recovery_recipient" => "fxsnap1.a.b",
           "key_id" => "00",
           "sentence" => "Fermix restarts in the device role and moves this home to north-box."
         }}
      end

      argv = [
        "move",
        "--to",
        ctx.candidate.candidate_id,
        "--recovery-passphrase-file",
        ctx.passphrase_file
      ]

      {0, out, _err} = run(argv, home: ctx.home, client: client)

      assert_received {:params, %{"candidate_id" => id, "recovery_passphrase" => @passphrase}}
      assert id == ctx.candidate.candidate_id

      # The start walks the home for its readiness report before it answers;
      # the management PROTOCOL.md asks a client to allow it 65 s.
      assert_received {:timeout, 65_000}
      assert out =~ "Fermix restarts in the device role"
      refute out =~ @passphrase
    end

    # A server that is itself the primary, being replaced by another and then
    # destroyed, keeps no desktop of the new one: `--retire`.
    test "--retire asks the running engine to keep no desktop here, and only then", ctx do
      test = self()

      client = fn "home.move.start", params, _opts ->
        send(test, {:params, params})

        {:ok,
         %{
           "move_id" => "mv-2",
           "candidate" => %{"name" => "north-box"},
           "recovery_recipient" => "fxsnap1.a.b",
           "key_id" => "00",
           "keep_as_desktop" => false,
           "sentence" =>
             "Fermix restarts, moves this home to north-box and then serves nothing here."
         }}
      end

      base = [
        "move",
        "--to",
        ctx.candidate.candidate_id,
        "--recovery-passphrase-file",
        ctx.passphrase_file
      ]

      {0, out, _err} = run(base ++ ["--retire"], home: ctx.home, client: client)
      assert_received {:params, %{"keep_as_desktop" => false}}
      assert out =~ "then serves nothing here"

      {0, _out, _err} = run(base, home: ctx.home, client: client)
      assert_received {:params, kept}
      refute Map.has_key?(kept, "keep_as_desktop")
    end

    # Always On setup §4: the recovery passphrase is checked against the key
    # the running engine keeps, or kept by it, so a move starts only through
    # the engine; with Fermix stopped there is nothing to check it against.
    test "with the engine stopped, the move is refused and nothing is written", ctx do
      stopped = fn _method, _params, _opts -> {:error, :not_running} end

      argv = [
        "move",
        "--to",
        ctx.candidate.candidate_id,
        "--recovery-passphrase-file",
        ctx.passphrase_file,
        "--json"
      ]

      for extra <- [[], ["--retire"]] do
        {1, out, _err} =
          run(argv ++ extra, [home: ctx.home, client: stopped, now: fn -> @now end] ++ ready())

        assert %{"ok" => false, "error" => %{"code" => "engine_stopped"}} = Jason.decode!(out)
        refute Move.pending?(ctx.home)
        assert {:ok, %{role: :primary}} = Role.configured(ctx.home)
      end
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

    test "a move with no candidate named is a usage error", ctx do
      assert {2, _out, _err} =
               run(["move", "--recovery-passphrase-file", ctx.passphrase_file], home: ctx.home)
    end
  end

  # The readiness report's facts about this host, as seams.
  defp ready,
    do: [
      free_bytes: fn _dir -> {:ok, 1_099_511_627_776} end,
      version: "0.16.0",
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
