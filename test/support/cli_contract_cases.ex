defmodule FermixTestSupport.CliContractCases do
  @moduledoc """
  The cases behind the typed-CLI contract export under `priv/cli/`.

  Every case is built by the **real** builders — `Fermix.CLI.Service.Status`,
  `Fermix.CLI.MachineOutput` and `FermixCore.Management.Diagnostics.Offline` —
  so a golden that disagrees with one of them is a drift the contract test
  fails on, exactly as `protocol_contract_test.exs` pins the management export.

  The identities here are synthetic on purpose. A fixture built from this
  build's own `BuildInfo` would carry the product version, and the export the
  desktop repository vendors would then churn on every release with no contract
  change behind it.
  """

  alias Fermix.CLI.HomeMovedCommand
  alias Fermix.CLI.MachineOutput
  alias Fermix.CLI.Service.Status
  alias FermixCore.Home.Candidates
  alias FermixCore.Home.Snapshot.S3, as: SnapshotS3
  alias FermixCore.Home.Snapshot.Status, as: SnapshotStatus
  alias FermixCore.Management.Diagnostics.Offline
  alias FermixCore.Management.Home
  alias FermixCore.Management.HomeMove

  @vendor_unit "/usr/lib/systemd/user/fermix.service"
  @legacy_unit "/home/operator/.config/systemd/user/fermix.service"
  @observed_at "2026-01-01T00:00:00Z"

  defmodule Identity do
    @moduledoc false

    def public_identity do
      %{
        "engine_id" => "fermix-core",
        "product_version" => "1.2.3",
        "build_id" => "release-9",
        "source_commit" => String.duplicate("a", 40),
        "distribution_identity" => "linux_package",
        "artifact_target" => "linux_x86_64",
        "architecture" => "x86_64"
      }
    end
  end

  defmodule BoundService do
    @moduledoc false

    def status(_opts) do
      {:ok, FermixTestSupport.CliContractCases.status(:active_aligned)}
    end
  end

  defmodule UnreachableService do
    @moduledoc false
    def status(_opts), do: {:error, :user_manager_unreachable}
  end

  @doc """
  Every golden, as `{relative path under priv/cli/fixtures, JSON text}`.

  The text is the pretty form of the envelope the CLI prints, so the checked-in
  file is readable in a diff and the drift a reviewer sees is the drift a
  vendoring client would see.
  """
  @spec cases() :: [{Path.t(), String.t()}]
  def cases do
    status_cases() ++ verb_cases() ++ diagnostics_cases() ++ error_cases()
  end

  @doc "The names of the states `service status` publishes a golden for."
  @spec status_states() :: [atom()]
  def status_states do
    ~w(fresh bound_disabled active_aligned pending_restart unknown_identity
       ownership_conflict legacy_unit foreign_unit invalid_binding)a
  end

  @doc "One published `service status` result, built by `Service.Status.build/1`."
  @spec status(atom()) :: map()
  def status(state), do: state |> evidence() |> Status.build()

  # ── service status ─────────────────────────────────────────────────────────

  defp status_cases do
    Enum.map(status_states(), fn state ->
      {"service_status/#{state}.json", encoded(MachineOutput.ok(status(state)))}
    end)
  end

  defp evidence(:fresh) do
    %{
      binding: {:error, :missing},
      properties: properties(state: "inactive", enabled: "disabled", pid: "0", sub: "dead"),
      user_unit: :absent,
      linger: {:ok, false},
      installed: installed(:unreadable),
      hello: nil,
      configured_listener: {:error, :unbound}
    }
  end

  defp evidence(:bound_disabled) do
    %{
      evidence(:fresh)
      | binding: {:ok, %{home: "/home/operator/.fermix"}},
        configured_listener: {:ok, %{port: 4600, source: :config}}
    }
  end

  defp evidence(:active_aligned) do
    %{
      binding: {:ok, %{home: "/home/operator/.fermix"}},
      properties: properties([]),
      user_unit: :absent,
      linger: {:ok, true},
      installed: installed(:verified),
      hello: hello(Identity.public_identity()),
      configured_listener: {:ok, %{port: 4030, source: :default}}
    }
  end

  defp evidence(:pending_restart) do
    running = Map.put(Identity.public_identity(), "build_id", "release-8")

    %{evidence(:active_aligned) | hello: hello(running)}
  end

  defp evidence(:unknown_identity) do
    running = Map.delete(Identity.public_identity(), "build_id")

    %{evidence(:active_aligned) | hello: hello(running)}
  end

  defp evidence(:ownership_conflict) do
    running = Map.put(Identity.public_identity(), "distribution_identity", "standalone")

    %{evidence(:active_aligned) | hello: hello(running)}
  end

  defp evidence(:legacy_unit) do
    %{
      evidence(:bound_disabled)
      | properties:
          properties(
            state: "inactive",
            enabled: "disabled",
            pid: "0",
            sub: "dead",
            fragment: @legacy_unit
          ),
        user_unit: :legacy_generated
    }
  end

  defp evidence(:foreign_unit) do
    %{evidence(:legacy_unit) | user_unit: :foreign}
  end

  defp evidence(:invalid_binding) do
    %{
      evidence(:fresh)
      | binding: {:error, {:invalid, invalid_binding_sentence()}}
    }
  end

  # systemd's own strings, exactly as `systemctl show` prints them on the right
  # of each `Key=Value`.
  defp properties(overrides) do
    %{
      "LoadState" => "loaded",
      "UnitFileState" => Keyword.get(overrides, :enabled, "enabled"),
      "ActiveState" => Keyword.get(overrides, :state, "active"),
      "SubState" => Keyword.get(overrides, :sub, "running"),
      "MainPID" => Keyword.get(overrides, :pid, "4711"),
      "ExecMainPID" => Keyword.get(overrides, :pid, "4711"),
      "InvocationID" => Keyword.get(overrides, :invocation, "4b1e9d1a"),
      "NRestarts" => "0",
      "NeedDaemonReload" => "no",
      "FragmentPath" => Keyword.get(overrides, :fragment, @vendor_unit),
      "DropInPaths" => ""
    }
  end

  defp installed(:verified) do
    Status.installed(Identity.public_identity(), {:ok, Identity.public_identity()})
  end

  defp installed(:unreadable) do
    Status.installed(Identity.public_identity(), {:error, :enoent})
  end

  defp hello(engine) do
    %{
      "engine" => Map.put(engine, "pid", "4711"),
      "setup" => %{"origin" => "http://127.0.0.1:4030", "path" => "/setup"}
    }
  end

  # ── install, uninstall, restart ────────────────────────────────────────────

  defp verb_cases do
    [
      {"service_install/packaged.json", encoded(MachineOutput.ok(status(:active_aligned)))},
      {"service_install/unit.json", encoded(MachineOutput.ok(action("installed")))},
      {"service_uninstall/ok.json", encoded(MachineOutput.ok(action("uninstalled")))},
      {"restart/ok.json", encoded(MachineOutput.ok(restart("4711")))},
      {"restart/recovered.json", encoded(MachineOutput.ok(restart(nil)))},
      {"home_mark_moved/ok.json", encoded(MachineOutput.ok(HomeMovedCommand.result(moved())))},
      {"home_status/primary.json", encoded(MachineOutput.ok(home_status()))},
      {"home_snapshots_status/ok.json", encoded(MachineOutput.ok(snapshots_view()))},
      {"home_candidates/ok.json", encoded(MachineOutput.ok(candidates_view()))},
      {"home_move/ok.json", encoded(MachineOutput.ok(move_view(true)))},
      {"home_move/retired.json", encoded(MachineOutput.ok(move_view(false)))}
    ]
  end

  # `fermix home candidates`: the one candidate the primary holds, as the
  # engine answers it or, stopped, as the home's own file holds it.
  defp candidates_view, do: %{"candidates" => [Candidates.view(candidate())]}

  # `fermix home move`: the move to that candidate as the running engine
  # answers it, its recovery key the one the snapshot goldens show; with
  # `--retire`, a server being replaced that keeps no desktop.
  defp move_view(keep_as_desktop) do
    HomeMove.started_view(%{
      move_id: "mv-01a17cb1f5c04c1e9a7b",
      candidate: candidate(),
      recovery_recipient:
        "fxsnap1.AAECAwQFBgcICQoLDA0ODw.B3l5ExMinEfPofapoLSG57ZGCBl_fiIqFbtB5nPDNqA",
      key_id: "08c15ca36dd935c4",
      keep_as_desktop: keep_as_desktop
    })
  end

  # The facts a candidate's view publishes, with the instance and the bucket
  # the host reported, so the goldens draw both.
  defp candidate do
    %{
      candidate_id: "cand-5e2a9c1f7b3d4086",
      name: "north-box",
      os: "linux",
      arch: "aarch64",
      version: "1.2.3",
      node_id: "bb716f238ec342e512e3400c6f8363f0fc3fd3ba2b6b749dd6130b81d7cb5827",
      instance: %{"provider" => "hetzner", "instance_id" => "61839204", "region" => "fsn1"},
      snapshots: %{"s3_bucket" => "invented-fermix-snapshots", "s3_region" => "eu-central-1"},
      enrolled_at: ~U[2026-10-27 09:12:00Z],
      expires_at: ~U[2026-10-28 09:12:00Z]
    }
  end

  # `fermix home status`: a primary at epoch 4 whose last snapshot S3 stored.
  defp home_status do
    Home.picture(%{role: :primary, epoch: 4, moved: nil, snapshots: snapshots_view()})
  end

  defp snapshots_view do
    attempt = %{
      at: ~U[2026-10-27 09:30:00Z],
      result: :verified,
      name: "20261027T093000Z-e4.fxsnap",
      epoch: 4,
      size: 48_211,
      sha256: "9c1f4e2a7b3d5c6e8f0a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f6a",
      location: "s3://invented-fermix-snapshots/fermix/general/20261027T093000Z-e4.fxsnap",
      key_id: "08c15ca36dd935c4",
      error: nil
    }

    status = %{
      SnapshotStatus.record(SnapshotStatus.empty(), "s3", attempt)
      | next_run_at: ~U[2026-10-27 15:30:00Z]
    }

    SnapshotStatus.view(status, %{
      config: [
        recipient: "fxsnap1.AAECAwQFBgcICQoLDA0ODw.B3l5ExMinEfPofapoLSG57ZGCBl_fiIqFbtB5nPDNqA",
        s3_bucket: "invented-fermix-snapshots"
      ],
      targets: [SnapshotS3],
      running: false,
      profile: "general"
    })
  end

  # The marker `fermix home mark-moved` writes and prints.
  defp moved,
    do: %{epoch: 4, moved_at: ~U[2026-10-27 09:30:00Z], to: "hetzner fermix-home 48151623"}

  defp action(past_tense), do: %{"action" => past_tense, "scope" => "user"}

  # The shape `Fermix.CLI.Service.Packaged.restart/1` answers with. A daemon
  # that was not answering has no previous generation to name, which is the
  # recovery case rather than a refusal.
  defp restart(previous_pid) do
    %{
      "previous_pid" => previous_pid,
      "pid" => "4822",
      "alignment" => Status.alignment(installed(:verified), Identity.public_identity())
    }
  end

  # ── diagnostics export ─────────────────────────────────────────────────────

  defp diagnostics_cases do
    [
      {"diagnostics_export/ok.json", encoded(MachineOutput.ok(bundle(:ok)))},
      {"diagnostics_export/degraded.json", encoded(MachineOutput.ok(bundle(:degraded)))}
    ]
  end

  defp bundle(shape) do
    {:ok, report} = Offline.build(offline_opts(shape))
    report
  end

  defp offline_opts(:ok) do
    [
      build_info: Identity,
      service: BoundService,
      engine_manifest_path: absent_path("manifest"),
      logs_reader: fn _params -> {:ok, %{"entries" => [log_entry()]}} end,
      cmd: fn "journalctl", _args -> {journal_line(), 0} end,
      find_executable: fn _name -> "/usr/bin/secret-tool" end,
      os: {:unix, :linux},
      now: fn -> @observed_at end
    ]
  end

  defp offline_opts(:degraded) do
    [
      service: UnreachableService,
      logs_reader: fn _params -> {:error, :enoent} end,
      cmd: fn "journalctl", _args -> :absent end,
      find_executable: fn _name -> nil end
    ] ++ Keyword.drop(offline_opts(:ok), [:service, :logs_reader, :cmd, :find_executable])
  end

  defp log_entry do
    %{
      "time" => "2026-01-01T00:00:00Z",
      "level" => "info",
      "subsystem" => "daemon",
      "message" => "started"
    }
  end

  defp journal_line, do: "2026-01-01T00:00:00+0000 host fermix[4711]: started\n"

  defp absent_path(name) do
    Path.join(System.tmp_dir!(), "fermix-cli-contract-absent-#{name}.json")
  end

  # ── errors ─────────────────────────────────────────────────────────────────

  defp error_cases do
    Enum.map(MachineOutput.codes(), fn code ->
      {"errors/#{code}.json", encoded(MachineOutput.error(code, error_details(code)))}
    end)
  end

  @doc """
  Representative details for one error code.

  A sentence that interpolates a fact needs one, and the golden is where the
  interpolated shape is pinned; a code with no details takes none.
  """
  @spec error_details(atom()) :: keyword()
  def error_details(:invalid_home), do: [reason: invalid_binding_sentence()]
  def error_details(:home_change_refused), do: [home: "/home/operator/.fermix"]
  def error_details(:foreign_unit), do: [path: @legacy_unit]
  def error_details(:linger_denied), do: [user: "operator", output: "Access denied"]
  def error_details(:invalid_port), do: [reason: invalid_port_sentence()]
  def error_details(:config_write_failed), do: [output: "permission denied"]
  def error_details(:binding_write_failed), do: [output: "permission denied"]
  def error_details(:systemctl_failed), do: [output: "Unit fermix.service not found."]
  def error_details(:lifecycle_refused), do: [output: "the daemon returned no lease"]
  def error_details(:diagnostics_unavailable), do: [output: "collecting it took too long"]
  def error_details(:already_moved), do: [to: "hetzner cx22", date: "2026-10-20", epoch: 3]

  def error_details(:snapshots_refused),
    do: [output: "Snapshots are off: set a recovery passphrase to turn them on."]

  def error_details(:home_status_unavailable),
    do: [output: "The requested management method is not available. (method_not_found)"]

  def error_details(:enrollment_refused),
    do: [output: "Only the primary enrolls candidates and starts a move."]

  def error_details(:move_refused),
    do: [
      output:
        "No server waiting for the move has the id cand-0f1e2d3c4b5a6978. A server waits 24 " <>
          "hours after it enrolls; after that, get a new code and enroll it again."
    ]

  def error_details(:mark_moved_failed),
    do: [output: "could not tell whether Fermix is running (timeout)"]

  def error_details(_code), do: []

  defp invalid_binding_sentence do
    "The service home must be an absolute path, and \"fermix\" is not."
  end

  defp invalid_port_sentence do
    "the web listener port must be a whole number from 1024 through 65535, and 22 is not"
  end

  # The checked-in form: the envelope the CLI prints, re-encoded with indentation
  # so a reviewer reads a diff rather than one long line.
  defp encoded(envelope) do
    envelope |> Jason.decode!() |> Jason.encode!(pretty: true) |> Kernel.<>("\n")
  end
end
