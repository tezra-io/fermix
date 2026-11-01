defmodule FermixChannels.Home.EnrollmentKindTest do
  # M75 lean v1 L15: the window opened for a server Fermix creates lives 24
  # hours, the code a person copies keeps 30 minutes, and only one window is
  # open at a time, so a copied code is refused while a created server's
  # window waits for it. The window's timers come to the test and are never
  # fired by themselves; its clock is the test's.
  use ExUnit.Case, async: true

  alias FermixChannels.Home.Enrollment
  alias FermixChannels.Test.HomeMove
  alias FermixCore.Home.EnrollmentCode
  alias FermixCore.Management.Copy

  @day_ms 86_400_000
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

    {:ok, _code} = Enrollment.open(primary.enrollment, :provisioned)
    assert_received :status_changed

    :ok = Enrollment.withdraw(primary.enrollment, :provisioned)
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

  test "a window opened for a created server lives 24 hours, a copied code 30 minutes", ctx do
    {:ok, %{code: code, expires_at: at}} = Enrollment.open(ctx.primary.enrollment, :provisioned)
    assert_receive {:scheduled, {:expire, ^at}, @day_ms}, 10_000
    assert at == DateTime.add(HomeMove.now(), 86_400, :second)
    {:ok, facts} = EnrollmentCode.decode(code)
    assert facts.expires_at == at

    assert %{state: :open, kind: :provisioned, candidate_id: nil} =
             Enrollment.status(ctx.primary.enrollment)

    # Past the half hour a copied code would have, it still admits its server.
    HomeMove.advance!(ctx.primary, 1_800)
    assert %{state: :open} = Enrollment.status(ctx.primary.enrollment)
    HomeMove.advance!(ctx.primary, 86_400 - 1_800)
    assert %{state: :expired} = Enrollment.status(ctx.primary.enrollment)

    # Once it expired, a code a person copies opens again, for 30 minutes.
    {:ok, %{expires_at: manual_at}} = Enrollment.open(ctx.primary.enrollment)
    assert_receive {:scheduled, {:expire, ^manual_at}, @half_hour_ms}, 10_000
    assert %{state: :open, kind: :manual} = Enrollment.status(ctx.primary.enrollment)
  end

  # How long the window has been open while this computer was awake, on the
  # clock that stops while it sleeps (M75 lean v1 §7: a created server that
  # never checks in within 30 minutes of it did not finish setting up). A
  # restart counts again from when it read the window back, so it never
  # counts more than the computer was awake.
  test "the window counts its open time on the clock that stops while this computer sleeps" do
    test = self()
    {:ok, mono} = Agent.start_link(fn -> 5_000 end)
    monotonic = fn -> Agent.get(mono, & &1) end

    primary =
      HomeMove.primary!(
        monotonic: monotonic,
        schedule: fn message, delay ->
          send(test, {:scheduled, message, delay})
          make_ref()
        end
      )

    assert Enrollment.status(primary.enrollment) == nil
    {:ok, _code} = Enrollment.open(primary.enrollment, :provisioned)
    Agent.update(mono, &(&1 + @half_hour_ms))
    assert %{state: :open, awake_ms: @half_hour_ms} = Enrollment.status(primary.enrollment)

    again = :"enrollment_again_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Enrollment,
       name: again,
       home: primary.root,
       clock: fn -> HomeMove.now() end,
       monotonic: monotonic,
       schedule: fn _message, _delay -> make_ref() end},
      id: again
    )

    Agent.update(mono, &(&1 + 60_000))
    assert %{state: :open, awake_ms: 60_000} = Enrollment.status(again)
  end

  test "a copied code is refused while a created server's window is open, in one sentence",
       ctx do
    {:ok, %{code: code}} = Enrollment.open(ctx.primary.enrollment, :provisioned)
    {:ok, facts} = EnrollmentCode.decode(code)

    assert {:error, {:unavailable, sentence}} = Enrollment.open(ctx.primary.enrollment, :manual)

    assert sentence ==
             "Your new server is still setting up with a code of its own, so Fermix opens " <>
               "no other code until that server connects or is deleted."

    assert Copy.violations(sentence, :prose) == []

    # The server's window is untouched: its secret still admits it.
    assert secret(ctx.primary) == {:ok, facts.secret}
  end

  # The window is the binding between the server Fermix created and the
  # candidate it enrolled as: a copied code would replace it and lose the
  # candidate's id, so it waits while that candidate is held.
  test "the server's used window holds a copied code back while its candidate is held", ctx do
    {:ok, _code} = Enrollment.open(ctx.primary.enrollment, :provisioned)
    HomeMove.advance!(ctx.primary, 600)
    remote = :binary.copy(<<7>>, 32)
    :ok = Enrollment.take(ctx.primary.enrollment, remote)

    # Enrolling: the code is used and its candidate not yet recorded.
    assert {:error, {:unavailable, waits}} = Enrollment.open(ctx.primary.enrollment, :manual)

    {:ok, %{candidate_id: id}} = Enrollment.enroll(ctx.primary.enrollment, request(), remote)

    assert %{state: :used, kind: :provisioned, candidate_id: ^id} =
             Enrollment.status(ctx.primary.enrollment)

    assert {:error, {:unavailable, ^waits}} = Enrollment.open(ctx.primary.enrollment, :manual)

    assert waits ==
             "Your new server waits for its move with the code Fermix gave it, so Fermix " <>
               "opens no other code until you move to it or delete it."

    assert Copy.violations(waits, :prose) == []

    # Past the window's own 24 hours the candidate is still held.
    HomeMove.advance!(ctx.primary, 86_400 - 600 + 1)
    assert {:error, {:unavailable, ^waits}} = Enrollment.open(ctx.primary.enrollment, :manual)

    # Once the primary no longer holds it, a copied code opens.
    HomeMove.advance!(ctx.primary, 600)
    assert {:ok, _manual} = Enrollment.open(ctx.primary.enrollment, :manual)
    assert %{state: :open, kind: :manual} = Enrollment.status(ctx.primary.enrollment)
  end

  test "withdrawing the server's used window lets a copied code open", ctx do
    {:ok, _code} = Enrollment.open(ctx.primary.enrollment, :provisioned)
    remote = :binary.copy(<<7>>, 32)
    :ok = Enrollment.take(ctx.primary.enrollment, remote)
    {:ok, _enrolled} = Enrollment.enroll(ctx.primary.enrollment, request(), remote)

    assert :ok = Enrollment.withdraw(ctx.primary.enrollment, :provisioned)
    assert kept(ctx.primary)["withdrawn"] == true

    restart!(ctx.primary.enrollment)
    assert {:ok, _manual} = Enrollment.open(ctx.primary.enrollment, :manual)
  end

  test "a created server's window replaces a copied code and an earlier server's window", ctx do
    {:ok, %{code: manual}} = Enrollment.open(ctx.primary.enrollment, :manual)
    {:ok, %{code: first}} = Enrollment.open(ctx.primary.enrollment, :provisioned)
    {:ok, %{code: second}} = Enrollment.open(ctx.primary.enrollment, :provisioned)

    secrets = for code <- [manual, first, second], do: decoded_secret(code)
    assert Enum.uniq(secrets) == secrets
    assert secret(ctx.primary) == {:ok, decoded_secret(second)}
  end

  test "withdrawing closes a created server's open window and nothing else", ctx do
    assert :ok = Enrollment.withdraw(ctx.primary.enrollment, :provisioned)

    {:ok, %{code: manual}} = Enrollment.open(ctx.primary.enrollment, :manual)
    assert :ok = Enrollment.withdraw(ctx.primary.enrollment, :provisioned)
    assert secret(ctx.primary) == {:ok, decoded_secret(manual)}

    {:ok, _code} = Enrollment.open(ctx.primary.enrollment, :provisioned)
    assert :ok = Enrollment.withdraw(ctx.primary.enrollment, :manual)
    assert %{state: :open, kind: :provisioned} = Enrollment.status(ctx.primary.enrollment)

    assert :ok = Enrollment.withdraw(ctx.primary.enrollment, :provisioned)
    assert %{state: :expired, kind: :provisioned} = Enrollment.status(ctx.primary.enrollment)
    assert secret(ctx.primary) == :none
    assert kept(ctx.primary)["secret"] == nil

    # A withdrawn window holds back no copied code.
    assert {:ok, _manual} = Enrollment.open(ctx.primary.enrollment, :manual)
  end

  # Always On setup §4: Cancel the code, on the token screen.
  test "withdrawing a copied code's window ends it, so the code admits nobody", ctx do
    {:ok, %{code: manual}} = Enrollment.open(ctx.primary.enrollment, :manual)
    assert secret(ctx.primary) == {:ok, decoded_secret(manual)}

    assert :ok = Enrollment.withdraw(ctx.primary.enrollment, :manual)

    assert %{state: :expired, kind: :manual} = Enrollment.status(ctx.primary.enrollment)
    assert secret(ctx.primary) == :none
    assert kept(ctx.primary)["withdrawn"] == true
    assert kept(ctx.primary)["secret"] == nil

    assert Enrollment.take(ctx.primary.enrollment, :binary.copy(<<7>>, 32)) ==
             {:error, :expired}
  end

  test "the window keeps its kind across an engine restart", ctx do
    {:ok, _code} = Enrollment.open(ctx.primary.enrollment, :provisioned)
    assert kept(ctx.primary)["kind"] == "provisioned"

    restart!(ctx.primary.enrollment)

    assert %{state: :open, kind: :provisioned} = Enrollment.status(ctx.primary.enrollment)
    assert {:error, {:unavailable, _sentence}} = Enrollment.open(ctx.primary.enrollment, :manual)
  end

  test "a window file that names no kind is no window", ctx do
    File.mkdir_p!(Path.dirname(Enrollment.path(ctx.primary.root)))

    File.write!(
      Enrollment.path(ctx.primary.root),
      Jason.encode!(%{
        "v" => 1,
        "secret" => nil,
        "expires_at" => "2031-05-04T10:30:00Z",
        "used" => false,
        "name" => "studio-mac",
        "used_by" => nil,
        "candidate_id" => nil
      })
    )

    restart!(ctx.primary.enrollment)
    assert Enrollment.status(ctx.primary.enrollment) == nil
  end

  defp secret(primary), do: Enrollment.secret(primary.enrollment)

  # What the created server's first boot sends when it enrolls; invented.
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
