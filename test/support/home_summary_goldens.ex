defmodule FermixTestSupport.HomeSummaryGoldens do
  @moduledoc """
  The `home.status` goldens beyond the first (`success.jsonl`), one for each
  family of the summary's states (M75 lean v1 §7): the computer that sets
  Always On up while its server installs and once it is ready, the server
  before and after its move, and a linked desktop when all is well and when
  its server stopped answering. Each is the record `Management.Home.picture/1`
  builds from invented facts, with the summary `HomeSummary.summary/1`
  answers for the same facts, so a golden can only say what the engine says.
  """

  alias FermixCore.Home.MoveReadiness
  alias FermixCore.Home.Provision.Hetzner
  alias FermixCore.Home.Snapshot.S3, as: SnapshotS3
  alias FermixCore.Home.Snapshot.Status, as: SnapshotStatus
  alias FermixCore.Management.Home
  alias FermixCore.Management.HomeSummary

  @now ~U[2031-05-04 12:00:00Z]
  @cand "cand-5e2a9c1f7b3d4086"
  @server_name "fermix-general-a3f9"

  @doc "Each golden's name and the `home.status` result it holds."
  @spec rows() :: [{String.t(), map()}]
  def rows do
    [
      {"home_status_creating", creating()},
      {"home_status_ready", ready(s3_snapshots())},
      {"home_status_ready_first_move", ready(unkeyed_snapshots())},
      {"home_status_candidate", candidate()},
      {"home_status_server", server()},
      {"home_status_on", on()},
      {"home_status_problem", problem()}
    ]
  end

  defp creating do
    window = window(:open, nil)

    record(:primary, %{epoch: 4, snapshots: s3_snapshots(), disk: disk(0.31)}, %{
      link: link(enrollment: window),
      provision: ledger(),
      enrollment: %{
        "state" => "open",
        "expires_at" => "2031-05-05T11:00:00Z",
        "kind" => "provisioned",
        "candidate_id" => nil
      }
    })
  end

  # Ready with the recovery key kept, and ready for the first move, which
  # sets it (Move now's needs say which).
  defp ready(snapshots) do
    review = %{
      candidate_id: @cand,
      reviewed_at: ~U[2031-05-04 11:30:00Z],
      ready: true,
      items: [
        %{
          "id" => "stays_here",
          "status" => "warn",
          "sentence" =>
            "iMessage, voice calls and meetings stop after the move: neither this Mac nor " <>
              "#{@server_name} runs them."
        }
      ]
    }

    record(:primary, %{epoch: 4, snapshots: snapshots, disk: disk(0.31)}, %{
      link: link(enrollment: window(:used, @cand)),
      provision: ledger(),
      candidates: [candidate_view()],
      review: review,
      move_items: MoveReadiness.summary_items({:ok, ""}, true, @server_name, restarts_itself: true),
      enrollment: %{
        "state" => "used",
        "expires_at" => "2031-05-05T11:00:00Z",
        "kind" => "provisioned",
        "candidate_id" => @cand
      }
    })
  end

  defp candidate do
    move = %{
      "phase" => "enrolled",
      "candidate" => nil,
      "sentence" => "Enrolled with studio-mac; waiting for its move until 2031-05-05T11:00:00Z."
    }

    record(:candidate, %{epoch: nil, snapshots: retired_snapshots(:candidate)}, %{move: move})
  end

  defp server do
    desktop = %{device_id: "6f1e2d3c-4b5a-4968-8778-695a4b3c2d1e", name: "studio-mac"}

    record(:primary, %{epoch: 5, snapshots: server_snapshots(), disk: disk(0.42)}, %{
      link:
        link(desktops: [Map.merge(desktop, %{connected: true, since: ~U[2031-05-04 09:00:00Z]})])
    })
  end

  defp on, do: desktop(primary(:connected, nil), server())

  defp problem, do: desktop(primary(:unreachable, 11 * 60_000), nil)

  defp desktop(link_primary, primary_home) do
    moved = %{to: @server_name, moved_at: ~U[2031-05-01 09:00:00Z], epoch: 4}

    record(:device, %{epoch: 4, moved: moved, snapshots: retired_snapshots(:device)}, %{
      link: link(primary: link_primary),
      linked: true,
      provision: ledger(),
      primary_home: primary_home,
      primary_missing:
        if(primary_home, do: nil, else: "The server #{@server_name} is unreachable."),
      copies_bytes: 3 * 48_211
    })
  end

  # The record for `role` from its own facts (`own`) and the summary's
  # (`extra`), as `Management.Home.status/1` puts them together.
  defp record(role, own, extra) do
    link = Map.get(extra, :link, link([]))

    facts =
      Map.merge(
        %{
          role: role,
          moved: nil,
          primary: link.primary,
          desktops: link.desktops,
          enrollment: Map.get(extra, :enrollment),
          candidates: Map.get(extra, :candidates, []),
          move: Map.get(extra, :move),
          primary_home: Map.get(extra, :primary_home),
          primary_missing: Map.get(extra, :primary_missing),
          secrets_missing: [],
          disk: nil,
          version: "1.2.3"
        },
        own
      )

    summary =
      HomeSummary.summary(%{
        role: role,
        host_os: :macos,
        now: @now,
        linked: Map.get(extra, :linked, false),
        moved: facts.moved,
        move: facts.move,
        link: link,
        candidates: facts.candidates,
        provider: Hetzner,
        providers: [Hetzner],
        provision: Map.get(extra, :provision, none()),
        review: Map.get(extra, :review),
        move_items: Map.get(extra, :move_items, []),
        snapshots: facts.snapshots,
        disk: facts.disk,
        primary_home: facts.primary_home,
        primary_too_old: false,
        copies_bytes: Map.get(extra, :copies_bytes),
        stays_here: [],
        zone: "Europe/Berlin"
      })

    Home.picture(Map.put(facts, :summary, summary))
  end

  defp link(overrides),
    do: Map.merge(%{primary: nil, desktops: [], enrollment: nil}, Map.new(overrides))

  defp window(state, candidate_id) do
    %{
      state: state,
      expires_at: ~U[2031-05-05 11:00:00Z],
      kind: :provisioned,
      candidate_id: candidate_id,
      awake_ms: 9 * 60_000
    }
  end

  defp primary(status, down_ms) do
    %{
      name: @server_name,
      connected: status == :connected,
      status: status,
      since: if(status == :connected, do: ~U[2031-05-04 09:00:00Z]),
      epoch: 5,
      sentence:
        if(status == :connected,
          do: "Fermix is connected to the server #{@server_name}.",
          else: "The server #{@server_name} is unreachable: it did not answer."
        ),
      down_ms: down_ms,
      down_at: if(status == :connected, do: nil, else: ~U[2031-05-04 11:49:00Z])
    }
  end

  defp none,
    do: %{
      state: :none,
      token: :none,
      server: nil,
      failure: nil,
      sentence: nil,
      replace: nil,
      action: nil,
      checked_at: nil
    }

  defp ledger do
    %{
      state: :created,
      token: :accepted,
      failure: nil,
      sentence: nil,
      replace: nil,
      action: nil,
      checked_at: ~U[2031-05-04 11:59:00Z],
      server: %{
        name: @server_name,
        id: "61839204",
        status: :created,
        type: "cpx22",
        location: "fsn1",
        ipv4: "203.0.113.7",
        power: "running",
        created_at: ~U[2031-05-04 10:58:00Z],
        seen_at: ~U[2031-05-04 11:50:00Z],
        total_monthly: "8.33",
        currency: "EUR"
      }
    }
  end

  defp candidate_view do
    %{
      "candidate_id" => @cand,
      "name" => @server_name,
      "os" => "linux",
      "arch" => "x86_64",
      "version" => "1.2.3",
      "node_id" => String.duplicate("b7", 32),
      "snapshots" => nil,
      "enrolled_at" => "2031-05-04T11:00:00Z",
      "expires_at" => "2031-05-05T11:00:00Z"
    }
  end

  defp disk(used), do: %{"used" => used, "nearly_full" => used >= 0.85}

  @recipient "fxsnap1.AAECAwQFBgcICQoLDA0ODw.B3l5ExMinEfPofapoLSG57ZGCBl_fiIqFbtB5nPDNqA"

  defp s3_snapshots, do: snapshots_view(~U[2031-05-04 09:30:00Z])
  defp server_snapshots, do: snapshots_view(~U[2031-05-04 10:00:00Z])

  # No recovery passphrase set yet: no key, so no snapshot either.
  defp unkeyed_snapshots do
    SnapshotStatus.view(SnapshotStatus.empty(), %{
      config: [s3_bucket: "invented-fermix-snapshots"],
      targets: [SnapshotS3],
      running: false,
      profile: "general"
    })
  end

  defp snapshots_view(at) do
    attempt = %{
      at: at,
      result: :verified,
      name: "20310504T093000Z-e4.fxsnap",
      epoch: 4,
      size: 48_211,
      sha256: String.duplicate("9c", 32),
      location: "s3://invented-fermix-snapshots/fermix/general/20310504T093000Z-e4.fxsnap",
      key_id: "08c15ca36dd935c4",
      error: nil
    }

    status = %{
      SnapshotStatus.record(SnapshotStatus.empty(), "s3", attempt)
      | next_run_at: DateTime.add(at, 6 * 3_600, :second)
    }

    SnapshotStatus.view(status, %{
      config: [recipient: @recipient, s3_bucket: "invented-fermix-snapshots"],
      targets: [SnapshotS3],
      running: false,
      profile: "general"
    })
  end

  # What a device and a candidate answer for snapshots: they are the
  # primary's (`Management.Home`).
  defp retired_snapshots(role) do
    sentence =
      case role do
        :device ->
          "Snapshots are the primary's to write; this engine runs in the device role."

        :candidate ->
          "Snapshots are the primary's to write; this engine is a candidate waiting for its move."
      end

    %{
      "configured" => false,
      "recipient_set" => false,
      "interval_hours" => 6,
      "running" => false,
      "next_run_at" => nil,
      "targets" => [],
      "sentence" => sentence
    }
  end
end
