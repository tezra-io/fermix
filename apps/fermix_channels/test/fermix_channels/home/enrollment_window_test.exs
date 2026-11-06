defmodule FermixChannels.Home.EnrollmentWindowTest do
  # The enrollment window lives 30 minutes, tells the Always On watch of each
  # change, ends when withdrawn, and names the desktop it was opened for. The
  # window's timers come to the test and are never fired by themselves; its
  # clock is the test's.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias FermixChannels.Home.Enrollment
  alias FermixChannels.Test.HomeMove
  alias FermixCore.Home.Candidates
  alias FermixCore.Home.EnrollmentCode

  @half_hour_ms 1_800_000

  setup do
    test = self()

    primary =
      HomeMove.primary!(
        schedule: fn message, delay ->
          send(test, {:scheduled, message, delay})
          make_ref()
        end
      )

    %{primary: primary}
  end

  # Companion protocol 6 (M75 lean v1 §7): the window feeds the Always On
  # summary, so every change of it tells the watch, which reads it again.
  test "opening, withdrawing and the expiry of a window each tell the Always On watch" do
    test = self()

    primary =
      HomeMove.primary!(
        schedule: fn message, delay ->
          send(test, {:scheduled, message, delay})
          make_ref()
        end,
        status_changed: fn ->
          send(test, :status_changed)
          :ok
        end
      )

    {:ok, _code} = Enrollment.open(primary.enrollment)
    assert_received :status_changed

    :ok = Enrollment.withdraw(primary.enrollment)
    assert_received :status_changed

    {:ok, %{expires_at: at}} = Enrollment.open(primary.enrollment)
    assert_received :status_changed
    assert_receive {:scheduled, {:expire, ^at} = expiry, @half_hour_ms}, 10_000

    HomeMove.advance!(primary, 1_800)
    send(GenServer.whereis(primary.enrollment), expiry)
    assert %{state: :expired} = Enrollment.status(primary.enrollment)
    assert_received :status_changed
    refute_received :status_changed
  end

  # Always On setup §4: Cancel the code.
  test "withdrawing a copied code's window ends it, so the code admits nobody", ctx do
    {:ok, %{code: manual}} = Enrollment.open(ctx.primary.enrollment)
    assert secret(ctx.primary) == {:ok, decoded_secret(manual)}

    assert :ok = Enrollment.withdraw(ctx.primary.enrollment)

    assert %{state: :expired} = Enrollment.status(ctx.primary.enrollment)
    assert secret(ctx.primary) == :none
    assert kept(ctx.primary)["withdrawn"] == true
    assert kept(ctx.primary)["secret"] == nil

    assert Enrollment.take(ctx.primary.enrollment, :binary.copy(<<7>>, 32)) ==
             {:error, :expired}
  end

  # Always On review m1: a server that proved the code but was never recorded
  # leaves the window used with no candidate; once its half hour is over it
  # reads expired, so the screen leaves "Connecting your server…".
  test "a window a server used but was not recorded through reads expired past its half hour",
       ctx do
    {:ok, _code} = Enrollment.open(ctx.primary.enrollment)
    :ok = Enrollment.take(ctx.primary.enrollment, :binary.copy(<<7>>, 32))
    assert %{state: :used, candidate_id: nil} = Enrollment.status(ctx.primary.enrollment)

    HomeMove.advance!(ctx.primary, 1_800)
    assert %{state: :expired, candidate_id: nil} = Enrollment.status(ctx.primary.enrollment)
  end

  # Cancel on "Connecting your server…" (review m1): the window a server used
  # but did not finish enrolling through ends now and admits nobody again;
  # one whose server is recorded keeps who used it.
  test "withdrawing a window ends it until a server is recorded through it", ctx do
    remote = :binary.copy(<<7>>, 32)
    {:ok, _code} = Enrollment.open(ctx.primary.enrollment)
    :ok = Enrollment.take(ctx.primary.enrollment, remote)

    assert :ok = Enrollment.withdraw(ctx.primary.enrollment)
    assert %{state: :expired} = Enrollment.status(ctx.primary.enrollment)
    assert Enrollment.take(ctx.primary.enrollment, remote) == {:error, :expired}

    {:ok, _code} = Enrollment.open(ctx.primary.enrollment)
    :ok = Enrollment.take(ctx.primary.enrollment, remote)
    {:ok, %{candidate_id: id}} = Enrollment.enroll(ctx.primary.enrollment, request(), remote)

    assert :ok = Enrollment.withdraw(ctx.primary.enrollment)
    assert %{state: :used, candidate_id: ^id} = Enrollment.status(ctx.primary.enrollment)
  end

  # Forget this server (Always On review M2): the held server leaves the
  # list, which tells the watch; the window keeps who used it. One no longer
  # held is forgotten already.
  test "forgetting a held server drops it and tells the Always On watch" do
    test = self()

    primary =
      HomeMove.primary!(
        schedule: fn _message, _delay -> make_ref() end,
        status_changed: fn ->
          send(test, :status_changed)
          :ok
        end
      )

    remote = :binary.copy(<<7>>, 32)
    {:ok, _code} = Enrollment.open(primary.enrollment)
    :ok = Enrollment.take(primary.enrollment, remote)
    {:ok, %{candidate_id: id}} = Enrollment.enroll(primary.enrollment, request(), remote)
    {:ok, other} = Candidates.add(primary.root, candidate_attrs(), HomeMove.now())
    flush_status_changed()

    assert :ok = Enrollment.forget(primary.enrollment, id)
    assert_received :status_changed
    assert {:ok, [^other]} = Candidates.list(primary.root, HomeMove.now())
    assert %{state: :used, candidate_id: ^id} = Enrollment.status(primary.enrollment)

    assert :ok = Enrollment.forget(primary.enrollment, id)
    assert {:ok, [^other]} = Candidates.list(primary.root, HomeMove.now())
  end

  # Always On's move back: a linked desktop opens a copied-code window on its
  # server to take the home back, and the server keeps which desktop asked, so
  # the candidate that enrolls through it is that desktop's return: a fact the
  # server records, never a guess from the candidate's system.
  test "a window a desktop opened to move back names it, across a restart, and so does " <>
         "the candidate it enrolls",
       ctx do
    desktop = "6f1e2d3c-4b5a-4968-8778-695a4b3c2d1e"
    {:ok, _code} = Enrollment.open(ctx.primary.enrollment, desktop)
    assert kept(ctx.primary)["returning"] == desktop

    restart!(ctx.primary.enrollment)

    remote = :binary.copy(<<7>>, 32)
    :ok = Enrollment.take(ctx.primary.enrollment, remote)
    {:ok, %{candidate_id: id}} = Enrollment.enroll(ctx.primary.enrollment, request(), remote)

    assert {:ok, %{returning: ^desktop}} =
             Candidates.fetch(ctx.primary.root, id, HomeMove.now())
  end

  test "a window opened for anything else names no desktop, nor does its candidate", ctx do
    {:ok, _code} = Enrollment.open(ctx.primary.enrollment)
    assert kept(ctx.primary)["returning"] == nil

    remote = :crypto.strong_rand_bytes(32)
    :ok = Enrollment.take(ctx.primary.enrollment, remote)
    {:ok, %{candidate_id: id}} = Enrollment.enroll(ctx.primary.enrollment, request(), remote)

    assert {:ok, %{returning: nil}} = Candidates.fetch(ctx.primary.root, id, HomeMove.now())
  end

  # A window file of version 1 named its window's kind, and the 24-hour kind
  # is gone: such a file is no window this version reads, said in the log, and
  # its code admits nobody. v0.18.0 writes one, but only with Always On's
  # unsupported release switch on, so there is no migration.
  test "a window file of the earlier version, which named a kind, is no window, and says so",
       ctx do
    file = Enrollment.path(ctx.primary.root)
    File.mkdir_p!(Path.dirname(file))

    File.write!(
      file,
      Jason.encode!(%{
        "v" => 1,
        "kind" => "provisioned",
        "withdrawn" => false,
        "secret" => Base.encode64(:binary.copy(<<9>>, 32)),
        "expires_at" => "2031-05-05T10:00:00Z",
        "used" => false,
        "name" => "studio-mac",
        "used_by" => nil,
        "candidate_id" => nil,
        "returning" => nil
      })
    )

    log = capture_log(fn -> restart!(ctx.primary.enrollment) end)

    assert log =~ "enrollment: #{file} could not be read"
    assert Enrollment.status(ctx.primary.enrollment) == nil
    assert secret(ctx.primary) == :none
  end

  defp secret(primary), do: Enrollment.secret(primary.enrollment)

  # What a server sends when it enrolls; invented.
  defp request do
    %{
      "host" => %{
        "name" => "fermix-general-a3f9",
        "os" => "linux",
        "arch" => "x86_64",
        "version" => "9.9.9"
      },
      "candidate" => %{
        "node_id" => String.duplicate("cd", 32),
        "relays" => [%{"url" => "https://eu1.relay.invalid/", "quic_port" => 7842}],
        "recipient" => Base.encode64(:binary.copy(<<3>>, 32))
      }
    }
  end

  defp candidate_attrs do
    %{
      name: "south-box",
      os: "linux",
      arch: "aarch64",
      version: "9.9.9",
      node_id: String.duplicate("ef", 32),
      relays: [%{"url" => "https://eu1.relay.invalid/", "quic_port" => 7842}],
      noise_pk: :binary.copy(<<4>>, 32),
      recipient: :binary.copy(<<5>>, 32),
      snapshots: nil
    }
  end

  defp flush_status_changed do
    receive do
      :status_changed -> flush_status_changed()
    after
      0 -> :ok
    end
  end

  defp decoded_secret(code) do
    {:ok, facts} = EnrollmentCode.decode(code)
    facts.secret
  end

  defp kept(primary), do: primary.root |> Enrollment.path() |> File.read!() |> Jason.decode!()

  defp restart!(enrollment) do
    old = Process.whereis(enrollment)
    :ok = GenServer.stop(enrollment)
    HomeMove.await(fn -> (pid = Process.whereis(enrollment)) && pid != old && pid end)
  end
end
