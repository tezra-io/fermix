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

  test "the server's window, once used, makes room for a copied code", ctx do
    {:ok, _code} = Enrollment.open(ctx.primary.enrollment, :provisioned)
    :ok = Enrollment.take(ctx.primary.enrollment, :binary.copy(<<7>>, 32))
    assert %{state: :used, kind: :provisioned} = Enrollment.status(ctx.primary.enrollment)

    assert {:ok, _manual} = Enrollment.open(ctx.primary.enrollment, :manual)
    assert %{state: :open, kind: :manual} = Enrollment.status(ctx.primary.enrollment)
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
    assert :ok = Enrollment.withdraw(ctx.primary.enrollment)

    {:ok, %{code: manual}} = Enrollment.open(ctx.primary.enrollment, :manual)
    assert :ok = Enrollment.withdraw(ctx.primary.enrollment)
    assert secret(ctx.primary) == {:ok, decoded_secret(manual)}

    {:ok, _code} = Enrollment.open(ctx.primary.enrollment, :provisioned)
    assert :ok = Enrollment.withdraw(ctx.primary.enrollment)
    assert %{state: :expired, kind: :provisioned} = Enrollment.status(ctx.primary.enrollment)
    assert secret(ctx.primary) == :none
    assert kept(ctx.primary)["secret"] == nil

    # A withdrawn window holds back no copied code.
    assert {:ok, _manual} = Enrollment.open(ctx.primary.enrollment, :manual)
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
