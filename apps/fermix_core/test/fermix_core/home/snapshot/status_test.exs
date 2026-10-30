defmodule FermixCore.Home.Snapshot.StatusTest do
  use ExUnit.Case, async: true

  alias FermixCore.Home.Snapshot.Recipient
  alias FermixCore.Home.Snapshot.S3
  alias FermixCore.Home.Snapshot.Status
  alias FermixTestSupport.SafeRm

  @recipient Recipient.encode(%{salt: <<1::128>>, public_key: <<2::256>>})

  setup do
    tmp = SafeRm.make_tmp_dir!("snapshot_status")
    on_exit(fn -> SafeRm.rm_rf!(tmp) end)
    %{home: tmp}
  end

  test "a home that never ran reads as empty, and a written status reads back", %{home: home} do
    assert Status.read(home) == {:ok, Status.empty()}

    status =
      Status.empty()
      |> Status.record("s3", verified(~U[2026-10-27 09:30:00Z]))
      |> Status.record(
        "s3",
        failed(~U[2026-10-27 15:30:00Z], "S3 could not be reached: timeout.")
      )
      |> Map.put(:next_run_at, ~U[2026-10-27 21:30:00Z])

    assert :ok = Status.write(home, status)
    assert Status.read(home) == {:ok, status}
    assert Bitwise.band(File.stat!(Status.path(home)).mode, 0o777) == 0o600

    entry = status.targets["s3"]
    # The verified point outlives the failure after it; the error is the newest.
    assert entry.last_verified.at == ~U[2026-10-27 09:30:00Z]
    assert entry.last_attempt.result == :failed
    assert entry.last_error == "S3 could not be reached: timeout."

    cleared = Status.record(status, "s3", verified(~U[2026-10-28 03:30:00Z]))
    assert cleared.targets["s3"].last_error == nil
  end

  test "a status file that is not one Fermix wrote is reported, not read as never ran",
       %{home: home} do
    File.mkdir_p!(Path.dirname(Status.path(home)))
    File.write!(Status.path(home), ~s({"version": 9}))

    assert Status.read(home) == {:error, {:status_unreadable, :invalid}}
  end

  describe "the view every surface draws" do
    test "off until a recovery passphrase is set" do
      view = view(Status.empty(), s3_bucket: "invented-bucket")

      assert view["configured"] == false
      assert view["recipient_set"] == false
      assert view["sentence"] == "Snapshots are off: set a recovery passphrase to turn them on."
      assert [%{"id" => "s3", "configured" => false, "destination" => nil}] = view["targets"]
    end

    test "off until a bucket is named" do
      view = view(Status.empty(), recipient: @recipient)

      assert view["recipient_set"]
      assert view["sentence"] == "Snapshots are off: name an S3 bucket to keep them in."
    end

    test "on, before the first run" do
      status = %{Status.empty() | next_run_at: ~U[2026-10-27 09:35:00Z]}
      view = view(status, recipient: @recipient, s3_bucket: "invented-bucket")

      assert view["configured"]
      assert view["next_run_at"] == "2026-10-27T09:35:00Z"
      assert view["interval_hours"] == 6
      assert view["sentence"] == "Snapshots are on; the first runs at 2026-10-27 09:35 UTC."

      assert [%{"destination" => "s3://invented-bucket/fermix/general/", "last_verified" => nil}] =
               view["targets"]
    end

    test "after a stored snapshot, and after a failed one" do
      config = [recipient: @recipient, s3_bucket: "invented-bucket"]
      stored = Status.record(Status.empty(), "s3", verified(~U[2026-10-27 09:30:00Z]))

      view = view(stored, config)
      assert view["sentence"] == "The last snapshot was stored at 2026-10-27 09:30 UTC."

      assert [%{"last_result" => "verified", "last_verified" => %{"epoch" => 4}}] =
               view["targets"]

      failed =
        Status.record(
          stored,
          "s3",
          failed(
            ~U[2026-10-27 15:30:00Z],
            "S3 refused the snapshot (403 AccessDenied): Access Denied."
          )
        )

      view = view(failed, config)

      assert view["sentence"] ==
               "The last snapshot to S3 failed: S3 refused the snapshot (403 AccessDenied): " <>
                 "Access Denied. Fermix tries again at the next run."

      assert [%{"last_result" => "failed", "last_verified" => %{"at" => "2026-10-27T09:30:00Z"}}] =
               view["targets"]
    end

    test "a target left waiting is not a failure: its note, and the last verified point kept" do
      config = [recipient: @recipient, s3_bucket: "invented-bucket"]

      waiting =
        Status.empty()
        |> Status.record("s3", verified(~U[2026-10-27 09:30:00Z]))
        |> Status.record("s3", failed(~U[2026-10-27 12:30:00Z], "S3 could not be reached."))
        |> Status.record("s3", waiting(~U[2026-10-27 15:30:00Z], "S3 waits for the next run."))

      assert waiting.targets["s3"].last_error == nil
      view = view(waiting, config)

      assert [
               %{
                 "last_result" => "waiting",
                 "waiting" => "S3 waits for the next run.",
                 "last_error" => nil,
                 "last_verified" => %{
                   "at" => "2026-10-27T09:30:00Z",
                   "key_id" => "0011223344556677"
                 }
               }
             ] = view["targets"]

      assert view["sentence"] ==
               "The last snapshot was stored at 2026-10-27 09:30 UTC. S3 waits for the next run."
    end

    test "a waiting attempt, its recovery key and the boot request read back",
         %{home: home} do
      status =
        Status.empty()
        |> Status.record("s3", waiting(~U[2026-10-27 15:30:00Z], "S3 waits."))
        |> Map.put(:run_at_boot, true)

      assert :ok = Status.write(home, status)
      assert Status.read(home) == {:ok, status}
    end

    test "while a run is going" do
      view =
        view(Status.empty(), [recipient: @recipient, s3_bucket: "invented-bucket"], running: true)

      assert view["sentence"] == "A snapshot is being written now."
    end
  end

  defp view(status, config, extra \\ []) do
    Status.view(status, %{
      config: config,
      targets: [S3],
      running: Keyword.get(extra, :running, false),
      profile: "general"
    })
  end

  defp verified(at) do
    %{
      at: at,
      result: :verified,
      name: "n.fxsnap",
      epoch: 4,
      size: 10,
      sha256: String.duplicate("b", 64),
      location: "s3://invented-bucket/fermix/general/n.fxsnap",
      key_id: "0011223344556677",
      error: nil,
      note: nil
    }
  end

  defp failed(at, sentence),
    do: %{verified(at) | result: :failed, location: nil, error: sentence}

  defp waiting(at, sentence),
    do: %{verified(at) | result: :waiting, location: nil, note: sentence}
end
