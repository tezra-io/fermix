defmodule FermixCore.Home.CandidateTest do
  use ExUnit.Case, async: true

  alias FermixCore.Home.Candidate
  alias FermixCore.Home.EnrollmentCode
  alias FermixCore.Home.Epoch
  alias FermixCore.Home.Moved
  alias FermixTestSupport.SafeRm

  @now ~U[2031-05-04 10:00:00Z]
  @facts %{
    secret: :binary.copy(<<0x5A>>, 32),
    gateway_pk: :binary.copy(<<0x3C>>, 32),
    node_id: String.duplicate("4f", 32),
    relays: [%{"url" => "https://eu1.relay.invalid/", "quic_port" => 7842}],
    relays_rev: "0123456789abcdef",
    name: "orchard-mini",
    expires_at: ~U[2031-05-04 10:10:00Z]
  }

  setup do
    tmp = SafeRm.make_tmp_dir!("candidate")
    on_exit(fn -> SafeRm.rm_rf!(tmp) end)
    {:ok, code} = EnrollmentCode.encode(@facts)
    %{tmp: tmp, home: Path.join(tmp, "home"), code: code}
  end

  describe "enroll/3" do
    test "makes an absent home a candidate, every file 0600 under 0700", ctx do
      destination = %{"s3_bucket" => "invented-bucket-91", "s3_region" => "eu-north-1"}

      assert {:ok, %{name: "orchard-mini"}} =
               Candidate.enroll(ctx.home, ctx.code <> "\n",
                 destination: destination,
                 now: @now
               )

      assert File.read!(Path.join(ctx.home, "config.toml")) ==
               ~s([fermix_core.engine]\nrole = "candidate"\n)

      assert mode(Candidate.dir(ctx.home)) == 0o700
      assert mode(Path.join(Candidate.dir(ctx.home), "mobile")) == 0o700

      for file <-
            ~w(code destination.json noise_key recipient_key state.json) ++
              ["mobile/iroh_key"] do
        assert mode(Candidate.path(ctx.home, file)) == 0o600, file
      end

      assert File.read!(Candidate.path(ctx.home, "code")) == ctx.code
      assert {:ok, ^destination} = Candidate.destination(ctx.home)
      # Nothing in v1 reports what a host says of itself, so none is kept.
      refute File.exists?(Candidate.path(ctx.home, "instance.json"))
      assert byte_size(File.read!(Candidate.path(ctx.home, "mobile/iroh_key"))) == 32
      assert {:ok, %{private: <<_::256>>, public: <<_::256>>}} = Candidate.noise_keypair(ctx.home)

      assert {:ok, %{secret_key: <<_::256>>, salt: <<_::128>>}} =
               Candidate.recipient_pair(ctx.home)

      assert {:ok, %{"phase" => "enrolling", "primary" => primary}} =
               Candidate.read_state(ctx.home)

      assert primary == %{
               "name" => "orchard-mini",
               "gateway_pk" => Base.encode64(@facts.gateway_pk),
               "node_id" => @facts.node_id
             }
    end

    test "takes a home that holds only what stays on a machine", ctx do
      File.mkdir_p!(Path.join(ctx.home, "logs"))
      File.write!(Path.join(ctx.home, "engine-owner.json"), "{}")

      assert {:ok, _code} = Candidate.enroll(ctx.home, ctx.code, now: @now)
      assert File.exists?(Path.join(ctx.home, "logs"))
    end

    test "refuses a home that was a primary, moved, or holds more than a fresh install", ctx do
      primary = Path.join(ctx.tmp, "primary")
      File.mkdir_p!(primary)
      :ok = Epoch.write(primary, 3)
      assert {:error, :primary_epoch} = Candidate.enroll(primary, ctx.code, now: @now)

      moved = Path.join(ctx.tmp, "moved")
      File.mkdir_p!(moved)
      :ok = Moved.write(moved, %{epoch: 2, moved_at: @now, to: "elsewhere"})
      assert {:error, :moved} = Candidate.enroll(moved, ctx.code, now: @now)

      used = Path.join(ctx.tmp, "used")
      File.mkdir_p!(used)
      File.write!(Path.join(used, "config.toml"), "[fermix_core]\n")
      assert {:error, {:not_fresh, "config.toml"}} = Candidate.enroll(used, ctx.code, now: @now)

      assert {:ok, _code} = Candidate.enroll(ctx.home, ctx.code, now: @now, hello: stopped())
      {:ok, state} = Candidate.read_state(ctx.home)
      :ok = Candidate.put_state(ctx.home, Map.put(state, "phase", "enrolled"), @now)

      assert {:error, :already_candidate} =
               Candidate.enroll(ctx.home, ctx.code, now: @now, hello: stopped())

      for home <- [primary, moved, used], do: refute(Candidate.present?(home))
    end

    test "replaces a candidate that never enrolled, while its engine is stopped", ctx do
      {:ok, _first} = Candidate.enroll(ctx.home, ctx.code, now: @now, hello: stopped())
      {:ok, old_key} = Candidate.noise_keypair(ctx.home)
      {:ok, state} = Candidate.read_state(ctx.home)
      :ok = Candidate.put_state(ctx.home, Map.put(state, "phase", "failed"), @now)

      {:ok, second} = EnrollmentCode.encode(%{@facts | secret: :binary.copy(<<0x6B>>, 32)})

      assert {:error, :daemon_running} =
               Candidate.enroll(ctx.home, second, now: @now, hello: fn -> {:ok, %{}} end)

      assert {:ok, code} = Candidate.enroll(ctx.home, second, now: @now, hello: stopped())
      assert code.secret == :binary.copy(<<0x6B>>, 32)
      assert {:ok, %{secret: <<0x6B, _rest::binary>>}} = Candidate.read_code(ctx.home)
      assert {:ok, %{"phase" => "enrolling"}} = Candidate.read_state(ctx.home)
      {:ok, new_key} = Candidate.noise_keypair(ctx.home)
      refute new_key.public == old_key.public
      assert File.read!(Path.join(ctx.home, "config.toml")) =~ ~s(role = "candidate")
      assert Enum.sort(File.ls!(ctx.home)) == ["candidate", "config.toml"]
    end

    test "a replacement that fails at its last step keeps the candidate it found", ctx do
      {:ok, _first} = Candidate.enroll(ctx.home, ctx.code, now: @now, hello: stopped())
      {:ok, old_key} = Candidate.noise_keypair(ctx.home)
      consume = fn -> {:error, {:code_file, "/run/fermix/enroll.code", :eacces}} end

      {:ok, second} = EnrollmentCode.encode(%{@facts | secret: :binary.copy(<<0x6B>>, 32)})

      assert {:error, {:code_file, _path, :eacces}} =
               Candidate.enroll(ctx.home, second, now: @now, hello: stopped(), consume: consume)

      assert {:ok, %{secret: <<0x5A, _rest::binary>>}} = Candidate.read_code(ctx.home)
      assert {:ok, ^old_key} = Candidate.noise_keypair(ctx.home)
      assert Enum.sort(File.ls!(ctx.home)) == ["candidate", "config.toml"]
    end

    test "refuses a code that ran out, or one Fermix did not open", ctx do
      assert {:error, {:code_expired, ~U[2031-05-04 10:10:00Z]}} =
               Candidate.enroll(ctx.home, ctx.code, now: ~U[2031-05-04 10:10:00Z])

      assert {:error, {:invalid_code, "prefix"}} =
               Candidate.enroll(ctx.home, "fxpair1.abc", now: @now)

      refute File.exists?(ctx.home)
    end

    test "leaves nothing behind when its last step fails, the home it made included", ctx do
      consume = fn -> {:error, {:code_file, "/run/fermix/enroll.code", :eacces}} end

      assert {:error, {:code_file, _path, :eacces}} =
               Candidate.enroll(ctx.home, ctx.code, now: @now, consume: consume)

      refute File.exists?(ctx.home)

      kept = Path.join(ctx.tmp, "kept")
      File.mkdir_p!(Path.join(kept, "logs"))

      assert {:error, _reason} = Candidate.enroll(kept, ctx.code, now: @now, consume: consume)
      assert File.ls!(kept) == ["logs"]
    end
  end

  # A return (Always On's move back): the computer the home left receives it
  # in place, so its candidate is written beside the moved home.
  describe "prepare_return/3" do
    setup ctx do
      mac = moved_home!(Path.join(ctx.tmp, "mac"))
      %{mac: mac}
    end

    test "writes a return-kind candidate beside a moved home, 0600 under 0700", ctx do
      before = Enum.sort(File.ls!(ctx.mac))

      assert {:ok, %{"phase" => "enrolling", "kind" => "return", "primary" => primary}} =
               Candidate.prepare_return(ctx.mac, {:return, ctx.code}, return_opts())

      assert primary == %{
               "name" => "orchard-mini",
               "gateway_pk" => Base.encode64(@facts.gateway_pk),
               "node_id" => @facts.node_id
             }

      assert {:ok, %{"kind" => "return"}} = Candidate.read_state(ctx.mac)
      assert mode(Candidate.dir(ctx.mac)) == 0o700

      for file <- ~w(code destination.json noise_key recipient_key state.json mobile/iroh_key) do
        assert mode(Candidate.path(ctx.mac, file)) == 0o600, file
      end

      assert {:ok, %{}} = Candidate.destination(ctx.mac)
      assert {:ok, %{public: <<_::256>>}} = Candidate.noise_keypair(ctx.mac)
      assert {:ok, %{secret_key: <<_::256>>}} = Candidate.recipient_pair(ctx.mac)
      # Nothing of the home itself changes: it is still a moved device.
      assert Enum.sort(File.ls!(ctx.mac)) == Enum.sort(["candidate" | before])
      assert File.read!(Path.join(ctx.mac, "config.toml")) =~ ~s(role = "device")
      refute Enum.any?(File.ls!(ctx.mac), &String.starts_with?(&1, ".candidate-"))
    end

    test "a restore from a copy here writes its state alone", ctx do
      assert {:ok, %{"phase" => "receiving", "kind" => "local"} = state} =
               Candidate.prepare_return(ctx.mac, {:local, "hetzner-orchard"}, return_opts())

      assert state["primary"] == %{"name" => "hetzner-orchard"}
      assert File.ls!(Candidate.dir(ctx.mac)) == ["state.json"]
    end

    test "refuses a home that is not a linked, moved desktop running as a service", ctx do
      opts = return_opts()

      assert {:error, :not_device} =
               Candidate.prepare_return(
                 ctx.mac,
                 {:return, ctx.code},
                 Keyword.put(opts, :role, :primary)
               )

      assert {:error, :not_supervised} =
               Candidate.prepare_return(ctx.mac, {:return, ctx.code},
                 role: :device,
                 restarts_itself?: false,
                 now: @now
               )

      SafeRm.rm!(Path.join(ctx.mac, "device/desktop.json"))
      assert {:error, :not_linked} = Candidate.prepare_return(ctx.mac, {:return, ctx.code}, opts)
      # A restore from a copy here needs no link: it is for a server that is gone.
      assert {:ok, _state} = Candidate.prepare_return(ctx.mac, {:local, "gone"}, opts)

      never_moved = Path.join(ctx.tmp, "never-moved")
      File.mkdir_p!(never_moved)
      assert {:error, :not_moved} = Candidate.prepare_return(never_moved, {:local, "x"}, opts)

      for home <- [never_moved], do: refute(Candidate.present?(home))
    end

    test "refuses while a move is under way here", ctx do
      write!(ctx.mac, ".move/phase.json", ~s({"v":1,"phase":"streaming","candidate":"x"}))

      assert {:error, :move_pending} =
               Candidate.prepare_return(ctx.mac, {:return, ctx.code}, return_opts())

      refute Candidate.present?(ctx.mac)
    end

    test "refuses beside a candidate under way, and replaces one that ended", ctx do
      {:ok, _state} = Candidate.prepare_return(ctx.mac, {:return, ctx.code}, return_opts())
      {:ok, old_key} = Candidate.noise_keypair(ctx.mac)

      for phase <- ~w(enrolling enrolled receiving staged activating) do
        {:ok, state} = Candidate.read_state(ctx.mac)
        :ok = Candidate.put_state(ctx.mac, Map.put(state, "phase", phase), @now)

        assert {:error, :candidate_present} =
                 Candidate.prepare_return(ctx.mac, {:return, ctx.code}, return_opts()),
               phase
      end

      for phase <- ~w(failed expired) do
        {:ok, state} = Candidate.read_state(ctx.mac)
        :ok = Candidate.put_state(ctx.mac, Map.put(state, "phase", phase), @now)

        assert {:ok, %{"phase" => "enrolling"}} =
                 Candidate.prepare_return(ctx.mac, {:return, ctx.code}, return_opts()),
               phase
      end

      {:ok, new_key} = Candidate.noise_keypair(ctx.mac)
      refute new_key.public == old_key.public
    end

    test "removes a builder a crash left, and leaves none when it fails", ctx do
      write!(ctx.mac, ".candidate-0A1B2C3D/state.json", "{}")

      assert {:error, {:code_expired, _at}} =
               Candidate.prepare_return(ctx.mac, {:return, ctx.code},
                 role: :device,
                 restarts_itself?: true,
                 now: ~U[2031-05-04 10:10:00Z]
               )

      assert {:ok, _state} = Candidate.prepare_return(ctx.mac, {:return, ctx.code}, return_opts())
      refute Enum.any?(File.ls!(ctx.mac), &String.starts_with?(&1, ".candidate-"))
    end

    test "every refusal has its sentence" do
      for reason <-
            [:not_device, :not_supervised, :not_moved, :not_linked, :move_pending] ++
              [:candidate_present] do
        assert Candidate.error_sentence(reason) =~ ~r/^[A-Z].*\.$/, inspect(reason)
      end

      assert Candidate.error_sentence(:not_supervised) ==
               "Fermix runs from a terminal here, so it could not start again on its own " <>
                 "after the move back. Install it as a service first."
    end
  end

  test "state is written whole and read back by phase", ctx do
    {:ok, _code} = Candidate.enroll(ctx.home, ctx.code, now: @now)
    {:ok, state} = Candidate.read_state(ctx.home)

    :ok = Candidate.put_state(ctx.home, Map.put(state, "phase", "enrolled"), @now)

    assert {:ok, %{"phase" => "enrolled", "updated_at" => "2031-05-04T10:00:00Z"}} =
             Candidate.read_state(ctx.home)

    File.write!(Candidate.path(ctx.home, "state.json"), ~s({"v":1,"phase":"dreaming"}))
    assert {:error, {:invalid_state, _file}} = Candidate.read_state(ctx.home)
  end

  defp mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)

  defp return_opts, do: [role: :device, restarts_itself?: true, now: @now]

  # The computer a home moved from: a linked desktop in the device role.
  defp moved_home!(home) do
    write!(home, "config.toml", ~s([fermix_core.engine]\nrole = "device"\n))
    write!(home, "memory.db", "the retired copy")
    write!(home, "device/desktop.json", "{}")
    :ok = Moved.write(home, %{epoch: 5, moved_at: @now, to: "hetzner-orchard"})
    home
  end

  defp write!(root, path, contents) do
    file = Path.join(root, path)
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, contents)
  end

  defp stopped, do: fn -> {:error, :not_running} end
end
