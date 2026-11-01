defmodule FermixChannels.Home.MoveKeepTest do
  # M75 decision 4: a server replaced by another is moved like any home, but
  # `keep_as_desktop: false` keeps it as nothing: no desktop key, no row on the
  # new primary, no link, so it never dials the server that took over. The
  # same real homes, candidate and rail as `MoveTest`.
  use ExUnit.Case, async: true

  alias FermixChannels.Home.Enrollment
  alias FermixChannels.Home.MoveWorker
  alias FermixChannels.Mobile.DeviceStore
  alias FermixChannels.Test.HomeMove
  alias FermixCore.Home.DesktopLink
  alias FermixCore.Home.Epoch
  alias FermixCore.Home.Move
  alias FermixCore.Home.Moved
  alias FermixCore.Home.Role
  alias FermixCore.Home.Snapshot.Recipient

  @primary_record %{role: :primary, primary: nil}

  test "a source not kept as a desktop is retired with no desktop key, row or link" do
    primary = HomeMove.primary!()
    {:ok, %{code: code}} = Enrollment.open(primary.enrollment)
    destination = %{"s3_bucket" => "invented-bucket-17", "s3_region" => "eu-north-1"}
    home = HomeMove.candidate_home!(code, destination: destination)
    candidate = HomeMove.start_candidate!(home, primary)
    %{"candidate_id" => candidate_id} = HomeMove.await_phase(home, "enrolled")
    opts = Keyword.put(HomeMove.start_opts(), :keep_as_desktop, false)

    {:ok, %{keep_as_desktop: false}} =
      Move.start(primary.root, @primary_record, candidate_id, recipient(), opts)

    source = primary.root
    worker = HomeMove.worker_opts(source, candidate, [])
    :ok = Task.await(Task.async(fn -> MoveWorker.run(worker) end), 60_000)

    # The source is retired and holds nothing that would reach the new primary.
    assert_received :source_restart
    assert {:ok, %{to: "north-box"}} = Moved.read(source)
    assert {:ok, %{role: :device}} = Role.configured(source)
    refute File.exists?(DesktopLink.path(source))
    refute File.exists?(DesktopLink.key_path(source))
    refute DesktopLink.linked?(%{role: :device}, source)
    assert :ok = Move.finish_at_boot(source, :device)

    assert %{"phase" => "done", "sentence" => sentence} = Move.view(source)
    assert sentence == "This home moved to north-box; this computer no longer runs it."

    # The new primary took the home and knows no desktop.
    assert_received {:scheduled, :restart, _delay}
    assert {:ok, 5} = Epoch.read(home)
    assert {:ok, devices} = DeviceStore.list(root: home)
    refute Enum.any?(devices, &(&1.kind == :desktop))
  end

  defp recipient, do: Recipient.public(Recipient.generate())
end
