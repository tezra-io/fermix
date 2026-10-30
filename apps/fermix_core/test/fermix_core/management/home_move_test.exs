defmodule FermixCore.Management.HomeMoveTest do
  # M75 §7, §14: enrollment and the move in the home.* family, through the
  # router as a daemon answers them.
  use ExUnit.Case, async: true

  alias FermixCore.Home.Candidate
  alias FermixCore.Home.Candidates
  alias FermixCore.Home.EnrollmentCode
  alias FermixCore.Home.Epoch
  alias FermixCore.Home.Move
  alias FermixCore.Home.Role
  alias FermixCore.Management.Protocol
  alias FermixCore.Management.Router
  alias FermixTestSupport.SafeRm

  @now ~U[2031-05-04 10:00:00Z]
  @primary %{role: :primary, primary: nil}
  @candidate %{role: :candidate, primary: nil}
  @device %{role: :device, primary: "north-box"}
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
      restart: fn ->
        send(test, :restarted)
        :ok
      end
    ]

    %{home: home, seams: seams}
  end

  defp route(method, params, role, seams) do
    Router.route(
      %{method: method, protocol_version: Protocol.protocol_version(), params: params},
      engine_role: role,
      operation_opts: [home: seams]
    )
  end

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
        Keyword.put(ctx.seams, :open_enrollment, fn ->
          {:ok, %{code: "fxenroll1.abc", expires_at: at}}
        end)

      assert {:ok, %{"code" => "fxenroll1.abc", "expires_at" => "2031-05-04T10:10:00Z"}} =
               route("home.enroll.open", %{}, @primary, seams)

      refused =
        Keyword.put(ctx.seams, :open_enrollment, fn ->
          {:error, {:unavailable, "Remote reach is off."}}
        end)

      assert {:error, :unavailable,
              %{"capability" => "home", "sentence" => "Remote reach is off."}} =
               route("home.enroll.open", %{}, @primary, refused)

      assert {:error, :unavailable,
              %{"sentence" => "Only the primary enrolls candidates and starts a move."}} =
               route("home.enroll.open", %{}, @device, seams)

      assert {:error, :invalid_params, _details} =
               route("home.enroll.open", %{"code" => "x"}, @primary, seams)
    end
  end

  describe "home.candidates.list and home.status" do
    test "show the held candidates without their keys, and the window", ctx do
      {:ok, record} = Candidates.add(ctx.home, candidate_attrs(), @now)

      assert {:ok, %{"candidates" => [view]}} =
               route("home.candidates.list", %{}, @primary, ctx.seams)

      assert view["candidate_id"] == record.candidate_id
      refute Map.has_key?(view, "noise_pk")

      window = %{state: :used, expires_at: ~U[2031-05-04 10:10:00Z]}

      seams =
        Keyword.put(ctx.seams, :link_status, fn ->
          %{primary: nil, desktops: [], enrollment: window}
        end)

      assert {:ok, status} = route("home.status", %{}, @primary, seams)
      assert status["enrollment"] == %{"state" => "used", "expires_at" => "2031-05-04T10:10:00Z"}
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
               route(
                 "home.move.readiness",
                 %{"candidate_id" => record.candidate_id},
                 @primary,
                 ctx.seams
               )

      assert Enum.map(items, & &1["id"]) ==
               ~w(keychain_secrets engine_version disk s3_size plugins stays_here cutover_gap
                  serves_nothing)

      assert Enum.all?(items, &(&1["status"] in ~w(ok warn block) and &1["sentence"] != ""))
      refute_received :restarted
    end

    test "refuses an unknown candidate by field, and every role but the primary", ctx do
      {:ok, record} = Candidates.add(ctx.home, candidate_attrs(), @now)

      assert {:error, :invalid_params, %{"field" => "candidate_id"}} =
               route("home.move.readiness", %{"candidate_id" => "cand-0"}, @primary, ctx.seams)

      assert {:error, :unavailable, %{"capability" => "home"}} =
               route(
                 "home.move.readiness",
                 %{"candidate_id" => record.candidate_id},
                 @device,
                 ctx.seams
               )

      assert {:error, :invalid_params, %{"field" => "candidate_id"}} =
               route("home.move.readiness", %{}, @primary, ctx.seams)
    end
  end

  describe "home.move.start" do
    test "refuses while the readiness report blocks, naming why, and restarts nothing", ctx do
      {:ok, record} = Candidates.add(ctx.home, candidate_attrs(), @now)
      seams = Keyword.put(ctx.seams, :free_bytes, fn _dir -> {:ok, 1_000} end)
      params = %{"candidate_id" => record.candidate_id, "recovery_passphrase" => @passphrase}

      assert {:error, :unavailable, %{"capability" => "home", "sentence" => sentence}} =
               route("home.move.start", params, @primary, seams)

      assert sentence =~ "The move cannot start yet."
      assert sentence =~ "make room first"
      refute_received :restarted
      refute Move.pending?(ctx.home)
    end

    test "writes the request, hands the home to the device role, then restarts", ctx do
      {:ok, record} = Candidates.add(ctx.home, candidate_attrs(), @now)
      params = %{"candidate_id" => record.candidate_id, "recovery_passphrase" => @passphrase}

      assert {:ok, answer} = route("home.move.start", params, @primary, ctx.seams)
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

    test "refuses by field and by role, and restarts nothing", ctx do
      {:ok, record} = Candidates.add(ctx.home, candidate_attrs(), @now)

      assert {:error, :invalid_params, %{"field" => "recovery_passphrase"}} =
               route(
                 "home.move.start",
                 %{"candidate_id" => record.candidate_id, "recovery_passphrase" => "short"},
                 @primary,
                 ctx.seams
               )

      assert {:error, :invalid_params, %{"field" => "candidate_id", "sentence" => sentence}} =
               route(
                 "home.move.start",
                 %{"candidate_id" => "cand-0", "recovery_passphrase" => @passphrase},
                 @primary,
                 ctx.seams
               )

      assert sentence =~ "No server waiting for the move has the id cand-0"

      assert {:error, :unavailable, %{"capability" => "home"}} =
               route(
                 "home.move.start",
                 %{"candidate_id" => record.candidate_id, "recovery_passphrase" => @passphrase},
                 @device,
                 ctx.seams
               )

      assert {:error, :invalid_params, _details} =
               route(
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
      instance: nil,
      snapshots: nil
    }
  end
end
