defmodule FermixChannels.Home.CandidateTreeTest do
  @moduledoc """
  A candidate's side of a move, run in the world a candidate runs in (M75 §2):
  a VM of its own (`:peer`) that starts only the core children
  `FermixCore.Application.supervision_children/2` lists for the candidate role,
  then the candidate process. Nothing that reaches the host is stood in for:
  the offer reads the free space with `df` through `CommandRunner`, the restore
  asks the keyring through `SecretWriter.probe/1` on a host that is not a Mac
  (a `busctl` that finds no session bus, on the VM's own `PATH`), and the
  commit renames the staged home into place. This ExUnit VM runs every role's
  children at once, so a child the candidate's tree lacks is invisible to any
  test that runs here.
  """

  # async: false: the candidate's core children are read from application
  # environment that other suites set.
  use ExUnit.Case, async: false

  alias FermixChannels.Home.Candidate, as: CandidateProcess
  alias FermixCore.Application, as: CoreApplication
  alias FermixCore.Home.Candidate
  alias FermixCore.Home.EnrollmentCode
  alias FermixCore.Home.Epoch
  alias FermixCore.Home.Snapshot
  alias FermixCore.Home.Snapshot.Recipient
  alias FermixCore.Net.Egress
  alias FermixTestSupport.SafeRm

  @now ~U[2031-05-04 10:00:00Z]
  @call_ms 30_000
  @move_id "mv-20310504T100000Z-7f3a"
  @candidate :candidate_tree_candidate

  # Runs inside the candidate's VM, loaded there from the binary compiled here.
  {:module, driver, driver_beam, _exports} =
    defmodule Driver do
      @moduledoc false

      alias FermixChannels.Home.Candidate, as: CandidateProcess
      alias FermixCore.Setup.SecretWriter
      alias FermixCore.Trace.TelemetryHandler

      @now ~U[2031-05-04 10:00:00Z]
      @wait_ms 30_000

      # The applications and settings a boot has before its children start
      # (`env`, this suite's), the core children given, then the candidate
      # process.
      def boot(core_children, env, home, name) do
        {:ok, _apps} = Application.ensure_all_started(:logger)
        {:ok, _apps} = Application.ensure_all_started(:telemetry)
        :ok = Application.load(:fermix_core)
        :ok = Application.load(:fermix_channels)
        :ok = Application.put_all_env(env)
        # The writer a Linux host selects (`SecretWriter.Auto` finds no
        # `security` there) in place of the suite's stand-in.
        Application.put_env(:fermix_core, :secret_writer, SecretWriter.Auto)
        Application.put_env(:fermix_core, :secret_writer_candidates, [SecretWriter.SecretTool])
        :ok = TelemetryHandler.attach()
        {:ok, _recorder} = Agent.start(fn -> [] end, name: __MODULE__.Recorder)
        {:ok, core} = Supervisor.start_link(core_children, strategy: :rest_for_one)
        true = Process.unlink(core)

        {:ok, channels} =
          Supervisor.start_link([{CandidateProcess, candidate_opts(home, name)}],
            strategy: :one_for_one
          )

        true = Process.unlink(channels)
        :ok
      end

      def stage(name, move_id) do
        :ok = CandidateProcess.stage(name, move_id, self())

        receive do
          {:candidate_staged, ^move_id, result} -> result
        after
          @wait_ms -> :no_answer
        end
      end

      def scheduled, do: Agent.get(__MODULE__.Recorder, &Enum.reverse/1)

      def now, do: @now

      def schedule(message, _delay) do
        Agent.update(__MODULE__.Recorder, &[message | &1])
        make_ref()
      end

      def restart, do: :ok

      defp candidate_opts(home, name) do
        [
          name: name,
          home: home,
          clock: &__MODULE__.now/0,
          schedule: &__MODULE__.schedule/2,
          restart: &__MODULE__.restart/0,
          # The keyring probe gives each `busctl` 1.5 s, which a loaded
          # runner's process start alone can take; the question is the same.
          restore_opts: [host: "linux-aarch64", probe_timeout_ms: @wait_ms],
          host: %{
            "name" => "north-box",
            "os" => "linux",
            "arch" => "aarch64",
            "version" => "9.9.9"
          }
        ]
      end
    end

  @driver driver
  @driver_beam driver_beam

  setup do
    tmp = SafeRm.make_tmp_dir!("candidate_tree")
    on_exit(fn -> SafeRm.rm_rf!(tmp) end)

    home = Path.join(tmp, "candidate-home")
    stream = Path.join(tmp, "move.fxsnap")
    source = source_home!(Path.join(tmp, "source"))
    enrolled_candidate!(home)
    {:ok, pair} = Candidate.recipient_pair(home)

    {:ok, _written} =
      Snapshot.write(source, Recipient.public(pair), stream, host: "macos-aarch64")

    bin = Path.join(tmp, "bin")
    calls = Path.join(tmp, "busctl.calls")
    stand_in_commands!(bin, calls)

    peer = start_candidate_vm!(bin, home)
    %{peer: peer, home: home, stream: stream, calls: calls}
  end

  test "the candidate's own tree carries a move from the offer to the commit", ctx do
    # What first boot reads until the candidate has enrolled.
    assert {:ok, status} =
             :peer.call(
               ctx.peer,
               FermixCore.Management.Home,
               :status,
               [[home: ctx.home, engine_role: %{role: :candidate, primary: nil}]],
               @call_ms
             )

    assert %{"role" => "candidate", "move" => %{"phase" => "enrolled"}} = status

    # More than any disk holds: refused with the space `df` reported.
    assert {:error, "move_failed", sentence} = offer(ctx.peer, 1_125_899_906_842_624)
    assert sentence =~ ~r/needs about \d+ GiB free for the move and has \d+ (GiB|MiB)/

    size = File.stat!(ctx.stream).size
    assert {:ok, %{incoming: incoming}} = offer(ctx.peer, size)
    File.cp!(ctx.stream, incoming)

    assert {:ok, 7} = :peer.call(ctx.peer, @driver, :stage, [@candidate, @move_id], @call_ms)
    # The restore asked the keyring, found no session bus, and keeps the
    # restored home's secrets in the file store.
    assert File.read!(ctx.calls) =~ "NameHasOwner"
    staged = File.read!(Path.join(Candidate.staging_path(ctx.home), "config.toml"))
    assert staged =~ ~s([fermix_core]\nsecret_store = "file")

    assert {:ok, 7} =
             :peer.call(ctx.peer, CandidateProcess, :commit, [@candidate, @move_id], @call_ms)

    assert File.read!(Path.join(ctx.home, "config.toml")) =~ ~s(role = "primary")
    assert {:ok, 7} = Epoch.read(ctx.home)
    refute File.exists?(Candidate.dir(ctx.home))
    assert :restart in :peer.call(ctx.peer, @driver, :scheduled, [], @call_ms)
  end

  defp offer(peer, size) do
    facts = %{
      "move_id" => @move_id,
      "attempt" => 1,
      "size_bytes" => size,
      "source_epoch" => 6,
      "recovery_recipient" => nil
    }

    :peer.call(peer, CandidateProcess, :offer, [@candidate, facts], @call_ms)
  end

  defp start_candidate_vm!(bin, home) do
    path = Enum.join([bin, "/usr/bin", "/bin"], ":")

    peer =
      start_supervised!(%{
        id: :candidate_vm,
        start:
          {:peer, :start_link,
           [%{connection: 0, wait_boot: @call_ms, env: [{~c"PATH", String.to_charlist(path)}]}]}
      })

    :ok = :peer.call(peer, :code, :add_pathsa, [:code.get_path()], @call_ms)

    {:module, @driver} =
      :peer.call(peer, :code, :load_binary, [@driver, ~c"candidate_tree_driver", @driver_beam])

    env = for app <- [:fermix_core, :fermix_channels], do: {app, Application.get_all_env(app)}
    :ok = :peer.call(peer, @driver, :boot, [core_children(home), env, home, @candidate], @call_ms)
    peer
  end

  # The candidate role's core children as a boot lists them, the run trace
  # written under the candidate's home.
  defp core_children(home) do
    Egress.new([])
    |> CoreApplication.supervision_children(:candidate)
    |> Enum.map(fn
      {FermixCore.Trace, _opts} -> {FermixCore.Trace, base_dir: Path.join(home, "traces")}
      child -> child
    end)
  end

  # `busctl` answers as a host with no session bus does, and says it was
  # asked; `secret-tool` is installed but never run by the probe.
  defp stand_in_commands!(bin, calls) do
    File.mkdir_p!(bin)

    write_script!(Path.join(bin, "busctl"), """
    #!/bin/sh
    echo "$@" >> '#{calls}'
    echo "Failed to connect to bus: No such file or directory"
    exit 1
    """)

    write_script!(Path.join(bin, "secret-tool"), "#!/bin/sh\nexit 1\n")
  end

  defp write_script!(file, text) do
    File.write!(file, text)
    File.chmod!(file, 0o755)
  end

  # A device-role home at epoch 6 in keyring mode (no `secret_store`), as the
  # source captures it.
  defp source_home!(source) do
    File.mkdir_p!(Path.join(source, "journals"))

    File.write!(Path.join(source, "config.toml"), """
    [fermix_core.engine]
    role = "device"

    [sandbox]
    workspace_root = "#{source}/workspace"
    """)

    File.write!(Path.join([source, "journals", "day.md"]), "an invented day\n")
    :ok = Epoch.write(source, 6)
    source
  end

  defp enrolled_candidate!(home) do
    {:ok, code} = EnrollmentCode.encode(code_facts())
    {:ok, _code} = Candidate.enroll(home, code, now: @now)
    {:ok, state} = Candidate.read_state(home)
    :ok = Candidate.drop_code(home)

    enrolled =
      Map.merge(state, %{
        "phase" => "enrolled",
        "candidate_id" => "cand-4f2a",
        "enrolled_at" => "2031-05-04T10:00:00Z",
        "listen_until" => "2031-05-05T10:00:00Z"
      })

    :ok = Candidate.put_state(home, enrolled, @now)
  end

  defp code_facts do
    %{
      secret: :binary.copy(<<0x5A>>, 32),
      gateway_pk: :binary.copy(<<0x3C>>, 32),
      node_id: String.duplicate("4f", 32),
      relays: [%{"url" => "https://eu1.relay.invalid/", "quic_port" => 7842}],
      relays_rev: "0123456789abcdef",
      name: "orchard-mini",
      expires_at: ~U[2031-05-04 10:10:00Z]
    }
  end
end
