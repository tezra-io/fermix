defmodule FermixCore.Management.HomeMoveTest do
  # M75 §7, §14: enrollment and the move in the home.* family, through the
  # router as a daemon answers them. The server's Always On steps
  # (`Placement.rail_only?/1`) are served only to a desktop's forward, and
  # the manual code opened here is `home.act`'s, so it is called directly.
  use ExUnit.Case, async: true

  alias FermixCore.Home.Candidate
  alias FermixCore.Home.Candidates
  alias FermixCore.Home.EnrollmentCode
  alias FermixCore.Home.Epoch
  alias FermixCore.Home.Move
  alias FermixCore.Home.Role
  alias FermixCore.Home.Snapshot.Recipient
  alias FermixCore.Management.HomeMove
  alias FermixCore.Management.Protocol
  alias FermixCore.Management.Router
  alias FermixTestSupport.SafeRm

  @now ~U[2031-05-04 10:00:00Z]
  @primary %{role: :primary, primary: nil}
  @candidate %{role: :candidate, primary: nil}
  @device %{role: :device, primary: "north-box"}
  @desktop {:desktop, "6f1e2d3c-4b5a-4968-8778-695a4b3c2d1e"}
  @passphrase "invented-lantern-orchard"

  setup do
    home = SafeRm.make_tmp_dir!("home_move")
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    :ok = Epoch.write(home, 4)
    test = self()

    seams = [
      home: home,
      config: [],
      scheduler: nil,
      now: @now,
      link_status: fn -> %{primary: nil, desktops: [], enrollment: nil} end,
      free_bytes: fn _dir -> {:ok, 1_099_511_627_776} end,
      version: "0.16.0",
      host: "macos-aarch64",
      restarts_itself: true,
      restart: fn ->
        send(test, :restarted)
        :ok
      end,
      save_recipient: fn recipient ->
        send(test, {:saved, recipient})
        {:ok, %{}}
      end
    ]

    %{home: home, seams: seams}
  end

  defp route(method, params, role, seams, opts \\ []) do
    Router.route(
      %{method: method, protocol_version: Protocol.protocol_version(), params: params},
      [engine_role: role, operation_opts: [home: seams]] ++ opts
    )
  end

  # The server answering a desktop's forward over the rail, the one caller a
  # rail-only method is served to.
  defp forwarded(method, params, role, seams),
    do: route(method, params, role, seams, actor: @desktop)

  describe "a candidate's daemon socket" do
    test "answers home.status and refuses every other method by name", ctx do
      for {method, params} <- [
            {"overview.get", %{}},
            {"home.snapshots.status", %{}},
            {"home.enroll.open", %{}},
            {"home.candidates.list", %{}},
            {"settings.sections", %{}},
            {"providers.models.list", %{"provider" => "anthropic", "live" => false}}
          ] do
        assert {:error, :unavailable, %{"capability" => "candidate", "sentence" => sentence}} =
                 route(method, params, @candidate, ctx.seams)

        assert sentence =~ "candidate primary waiting for its move"
      end

      enrolled!(ctx.home)

      assert {:ok, status} = route("home.status", %{}, @candidate, ctx.seams)
      assert status["role"] == "candidate"
      assert status["snapshots"]["configured"] == false
      assert status["candidates"] == []
      assert status["enrollment"] == nil

      assert status["move"] == %{
               "phase" => "enrolling",
               "candidate" => nil,
               "sentence" => "Enrolling with orchard-mini."
             }
    end

    test "lets the protocol's hello through its gate", ctx do
      refute match?(
               {:error, :unavailable, %{"capability" => "candidate"}},
               route("hello", %{}, @candidate, ctx.seams)
             )
    end
  end

  describe "home.enroll.open" do
    test "answers the code the rail opened, once, on the primary", ctx do
      at = ~U[2031-05-04 10:10:00Z]

      seams =
        Keyword.put(ctx.seams, :open_enrollment, fn :manual ->
          {:ok, %{code: "fxenroll1.abc", expires_at: at}}
        end)

      assert {:ok, %{"code" => "fxenroll1.abc", "expires_at" => "2031-05-04T10:10:00Z"}} =
               HomeMove.enroll_open(nil, [engine_role: @primary] ++ seams)

      refused =
        Keyword.put(ctx.seams, :open_enrollment, fn :manual ->
          {:error, {:unavailable, "Remote reach is off."}}
        end)

      assert {:error, {:unavailable, "home", "Remote reach is off."}} =
               HomeMove.enroll_open(nil, [engine_role: @primary] ++ refused)

      assert {:error,
              {:unavailable, "home", "Only the primary enrolls candidates and starts a move."}} =
               HomeMove.enroll_open(nil, [engine_role: @device] ++ seams)

      assert {:error, :invalid_params, _details} =
               forwarded("home.enroll.open", %{"code" => "x"}, @primary, seams)

      assert {:ok, %{"code" => "fxenroll1.abc"}} =
               HomeMove.enroll_open("manual", [engine_role: @primary] ++ seams)
    end

    # M75 lean v1 L15, §4.3: the code inside a server Fermix creates lives 24
    # hours, and a desktop replacing its server asks the server for one.
    test "a 24-hour code opens only when the desktop asks over the link", ctx do
      test = self()

      seams =
        Keyword.put(ctx.seams, :open_enrollment, fn kind ->
          send(test, {:opened, kind})
          {:ok, %{code: "fxenroll1.def", expires_at: ~U[2031-05-05 10:00:00Z]}}
        end)

      assert {:ok, %{"code" => "fxenroll1.def", "expires_at" => "2031-05-05T10:00:00Z"}} =
               forwarded("home.enroll.open", %{"kind" => "provisioned"}, @primary, seams)

      assert_received {:opened, :provisioned}

      # Anything but a desktop's forward is refused by name: `home.act` takes the step.
      assert {:error, :unavailable,
              %{
                "capability" => "home",
                "method" => "home.enroll.open",
                "sentence" => <<_, _::binary>>
              }} = route("home.enroll.open", %{"kind" => "provisioned"}, @primary, seams)

      assert {:error, {:invalid_params, "kind", sentence}} =
               HomeMove.enroll_open("provisioned", [engine_role: @primary] ++ seams)

      assert sentence ==
               "A code that lives 24 hours opens only for a server Fermix creates from your " <>
                 "computer."

      assert {:error, :invalid_params, %{"field" => "kind"}} =
               forwarded("home.enroll.open", %{"kind" => "forever"}, @primary, seams)

      refute_received {:opened, _kind}
    end
  end

  describe "home.enroll.withdraw" do
    test "closes the server's 24-hour code on the primary", ctx do
      test = self()

      seams =
        Keyword.put(ctx.seams, :withdraw_enrollment, fn :provisioned ->
          send(test, :withdrawn)
          :ok
        end)

      assert {:ok, %{"withdrawn" => true}} =
               forwarded("home.enroll.withdraw", %{}, @primary, seams)

      assert_received :withdrawn

      refused =
        Keyword.put(ctx.seams, :withdraw_enrollment, fn :provisioned ->
          {:error, {:unavailable, "Fermix could not keep the enrollment window."}}
        end)

      assert {:error, :unavailable,
              %{
                "capability" => "home",
                "sentence" => "Fermix could not keep the enrollment window."
              }} =
               forwarded("home.enroll.withdraw", %{}, @primary, refused)

      assert {:error, :unavailable,
              %{"sentence" => "Only the primary enrolls candidates and starts a move."}} =
               forwarded("home.enroll.withdraw", %{}, @device, seams)

      assert {:error, :invalid_params, _details} =
               forwarded("home.enroll.withdraw", %{"kind" => "manual"}, @primary, seams)

      assert {:error, :unavailable,
              %{
                "capability" => "home",
                "method" => "home.enroll.withdraw",
                "sentence" => <<_, _::binary>>
              }} =
               route("home.enroll.withdraw", %{}, @primary, seams)

      refute_received :withdrawn
    end
  end

  describe "home.candidates.list and home.status" do
    test "show the held candidates without their keys, and the window", ctx do
      {:ok, record} = Candidates.add(ctx.home, candidate_attrs(), @now)

      assert {:ok, %{"candidates" => [view]}} =
               route("home.candidates.list", %{}, @primary, ctx.seams)

      assert view["candidate_id"] == record.candidate_id
      refute Map.has_key?(view, "noise_pk")

      window = %{
        state: :used,
        expires_at: ~U[2031-05-04 10:10:00Z],
        kind: :provisioned,
        candidate_id: record.candidate_id
      }

      seams =
        Keyword.put(ctx.seams, :link_status, fn ->
          %{primary: nil, desktops: [], enrollment: window}
        end)

      assert {:ok, status} = route("home.status", %{}, @primary, seams)
      # Which candidate used the window, and whether it was the code inside a
      # server Fermix created: the desktop that replaces its server reads it.
      assert status["enrollment"] == %{
               "state" => "used",
               "expires_at" => "2031-05-04T10:10:00Z",
               "kind" => "provisioned",
               "candidate_id" => record.candidate_id
             }

      assert [%{"name" => "north-box"}] = status["candidates"]
      assert status["move"] == nil

      # A device's leftover list is not its to show.
      assert {:ok, %{"candidates" => []}} = route("home.status", %{}, @device, ctx.seams)
    end
  end

  describe "home.move.readiness" do
    test "answers each item for a held candidate: ok, warn or block, with its sentence", ctx do
      {:ok, record} = Candidates.add(ctx.home, candidate_attrs(), @now)

      assert {:ok, %{"ready" => true, "items" => items}} =
               forwarded(
                 "home.move.readiness",
                 %{"candidate_id" => record.candidate_id},
                 @primary,
                 ctx.seams
               )

      assert Enum.map(items, & &1["id"]) ==
               ~w(keychain_secrets engine_version disk s3_size plugins stays_here whatsapp slack
                  coding_agents cutover_gap serves_nothing service)

      assert Enum.all?(items, &(&1["status"] in ~w(ok warn block) and &1["sentence"] != ""))
      refute_received :restarted
    end

    test "refuses an unknown candidate by field, and every role but the primary", ctx do
      {:ok, record} = Candidates.add(ctx.home, candidate_attrs(), @now)

      assert {:error, :invalid_params, %{"field" => "candidate_id"}} =
               forwarded(
                 "home.move.readiness",
                 %{"candidate_id" => "cand-0"},
                 @primary,
                 ctx.seams
               )

      assert {:error, :unavailable, %{"capability" => "home"}} =
               forwarded(
                 "home.move.readiness",
                 %{"candidate_id" => record.candidate_id},
                 @device,
                 ctx.seams
               )

      assert {:error, :invalid_params, %{"field" => "candidate_id"}} =
               forwarded("home.move.readiness", %{}, @primary, ctx.seams)
    end
  end

  describe "home.move.start" do
    test "refuses while the readiness report blocks, naming why, and restarts nothing", ctx do
      {:ok, record} = Candidates.add(ctx.home, candidate_attrs(), @now)
      seams = Keyword.put(ctx.seams, :free_bytes, fn _dir -> {:ok, 1_000} end)
      params = %{"candidate_id" => record.candidate_id, "recovery_passphrase" => @passphrase}

      assert {:error, :unavailable, %{"capability" => "home", "sentence" => sentence}} =
               forwarded("home.move.start", params, @primary, seams)

      assert sentence =~ "The move cannot start yet."
      assert sentence =~ "make room first"
      refute_received :restarted
      refute Move.pending?(ctx.home)
    end

    test "writes the request, hands the home to the device role, then restarts", ctx do
      {:ok, record} = Candidates.add(ctx.home, candidate_attrs(), @now)
      params = %{"candidate_id" => record.candidate_id, "recovery_passphrase" => @passphrase}

      assert {:ok, answer} = forwarded("home.move.start", params, @primary, ctx.seams)
      assert_received :restarted

      assert "mv-" <> _id = answer["move_id"]
      assert answer["candidate"]["name"] == "north-box"
      assert "fxsnap1." <> _key = answer["recovery_recipient"]
      assert answer["sentence"] =~ "restarts in the device role"
      refute inspect(answer) =~ @passphrase

      assert {:ok, %{role: :device}} = Role.configured(ctx.home)
      assert Move.pending?(ctx.home)

      assert {:ok, %{"move" => %{"phase" => "requested", "candidate" => "north-box"}}} =
               route("home.status", %{}, @primary, ctx.seams)
    end

    # Always On setup §4: the passphrase is the one set, checked against the
    # key this primary keeps, so a move carries that key rather than a second.
    test "a passphrase that is the one set carries the kept key, and saves nothing", ctx do
      {:ok, record} = Candidates.add(ctx.home, candidate_attrs(), @now)
      kept = kept_key()
      seams = Keyword.put(ctx.seams, :config, recipient: Recipient.encode(kept))
      params = %{"candidate_id" => record.candidate_id, "recovery_passphrase" => @passphrase}

      assert {:ok, answer} = forwarded("home.move.start", params, @primary, seams)
      assert answer["recovery_recipient"] == Recipient.encode(kept)
      assert {:ok, %{"recovery_recipient" => carried}} = Move.read_request(ctx.home)
      assert carried == Recipient.encode(kept)
      assert_received :restarted
      refute_received {:saved, _recipient}
    end

    test "a passphrase that is not the one set is refused, and nothing moves", ctx do
      {:ok, record} = Candidates.add(ctx.home, candidate_attrs(), @now)
      seams = Keyword.put(ctx.seams, :config, recipient: Recipient.encode(kept_key()))

      params = %{
        "candidate_id" => record.candidate_id,
        "recovery_passphrase" => "invented-orchard-meridian"
      }

      assert forwarded("home.move.start", params, @primary, seams) ==
               {:error, :invalid_params,
                %{
                  "field" => "recovery_passphrase",
                  "sentence" => "That is not the recovery passphrase you set."
                }}

      refute Move.pending?(ctx.home)
      refute_received :restarted
      refute_received {:saved, _recipient}
    end

    test "with no passphrase set, the move sets it and carries the key it kept", ctx do
      {:ok, record} = Candidates.add(ctx.home, candidate_attrs(), @now)
      params = %{"candidate_id" => record.candidate_id, "recovery_passphrase" => @passphrase}

      assert {:ok, answer} = forwarded("home.move.start", params, @primary, ctx.seams)
      assert_received {:saved, saved}
      assert answer["recovery_recipient"] == Recipient.encode(saved)
      assert {:ok, %{"recovery_recipient" => carried}} = Move.read_request(ctx.home)
      assert carried == Recipient.encode(saved)
    end

    test "refuses by field and by role, and restarts nothing", ctx do
      {:ok, record} = Candidates.add(ctx.home, candidate_attrs(), @now)

      assert {:error, :invalid_params, %{"field" => "recovery_passphrase"}} =
               forwarded(
                 "home.move.start",
                 %{"candidate_id" => record.candidate_id, "recovery_passphrase" => "short"},
                 @primary,
                 ctx.seams
               )

      assert {:error, :invalid_params, %{"field" => "candidate_id", "sentence" => sentence}} =
               forwarded(
                 "home.move.start",
                 %{"candidate_id" => "cand-0", "recovery_passphrase" => @passphrase},
                 @primary,
                 ctx.seams
               )

      assert sentence =~ "No server waiting for the move has the id cand-0"

      assert {:error, :unavailable, %{"capability" => "home"}} =
               forwarded(
                 "home.move.start",
                 %{"candidate_id" => record.candidate_id, "recovery_passphrase" => @passphrase},
                 @device,
                 ctx.seams
               )

      assert {:error, :unavailable,
              %{
                "capability" => "home",
                "method" => "home.move.start",
                "sentence" => <<_, _::binary>>
              }} =
               route(
                 "home.move.start",
                 %{"candidate_id" => record.candidate_id, "recovery_passphrase" => @passphrase},
                 @primary,
                 ctx.seams
               )

      assert {:error, :invalid_params, _details} =
               forwarded(
                 "home.move.start",
                 %{
                   "candidate_id" => record.candidate_id,
                   "recovery_passphrase" => @passphrase,
                   "to" => "x"
                 },
                 @primary,
                 ctx.seams
               )

      refute_received :restarted
      refute Move.pending?(ctx.home)
    end
  end

  defp kept_key do
    {:ok, pair} = Recipient.derive(@passphrase, :binary.copy(<<5>>, 16))
    Recipient.public(pair)
  end

  defp enrolled!(home) do
    candidate_home = Path.join(home, "as-candidate")

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

    {:ok, _code} = Candidate.enroll(candidate_home, code, now: @now)
    File.rename!(Candidate.dir(candidate_home), Candidate.dir(home))
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
