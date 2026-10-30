defmodule FermixCore.Home.RoleCandidateTest do
  # M75 §2: the candidate role. async: false: the core child list reads
  # application environment other suites set (the daemon socket, open loops).
  use ExUnit.Case, async: false

  alias FermixCore.Application, as: CoreApplication
  alias FermixCore.Home.Moved
  alias FermixCore.Home.Role
  alias FermixCore.Net.Egress
  alias FermixTestSupport.SafeRm

  setup do
    home = SafeRm.make_tmp_dir!("role_candidate")
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    %{home: home}
  end

  test "the settings name it, and it reads back in the file's spelling", %{home: home} do
    assert Role.normalize(%{"role" => "candidate"}) == [role: :candidate]
    assert Role.to_keyword(role: :candidate) == [role: "candidate"]
    assert {:ok, :candidate} = Role.resolve(home, %{"role" => "candidate"})
    assert {:ok, %{role: :candidate, primary: nil}} = Role.boot(home, role: :candidate)

    File.write!(Path.join(home, "config.toml"), ~s([fermix_core.engine]\nrole = "candidate"\n))
    assert {:ok, %{role: :candidate, primary: nil}} = Role.configured(home)

    assert_raise ArgumentError, ~r/"primary", "device" or "candidate"/, fn ->
      Role.normalize(%{"role" => "standby"})
    end
  end

  test "a moved marker never makes a candidate the primary", %{home: home} do
    :ok = Moved.write(home, %{epoch: 2, moved_at: ~U[2031-05-04 10:00:00Z], to: "north-box"})
    assert {:ok, :candidate} = Role.resolve(home, role: :candidate)
  end

  test "it is refused what a device is refused, with its own sentence" do
    assert {:error, {:device_role, sentence}} = Role.admit(%{role: :candidate, primary: nil})
    assert sentence =~ "candidate primary waiting for its move"
    assert Role.as_record(%{role: :candidate, primary: nil}) == %{role: :candidate, primary: nil}
  end

  test "the core tree of a candidate keeps only what it needs" do
    candidate = modules(CoreApplication.supervision_children(Egress.new([]), :candidate))
    kept = Enum.map(Role.candidate_keeps(), &elem(&1, 0))

    # The offer's free-space check and the restore's keyring probe run
    # commands, which raise without their host (`CandidateTreeTest` runs them
    # in a candidate's own tree).
    assert FermixCore.CommandHost.Supervisor in candidate
    assert Task.Supervisor in candidate
    assert FermixCore.Trace in candidate
    assert Enum.all?(candidate, &(&1 in kept))

    for module <- [
          FermixCore.Memory.Repo,
          FermixCore.Agents.MainAgent,
          FermixCore.Jobs.Scheduler,
          FermixCore.Home.Snapshot.Scheduler,
          FermixCore.Auth.TokenSupervisor
        ] do
      refute module in candidate, "a candidate starts #{inspect(module)}"
    end

    # The daemon socket's children, present only in a daemon boot.
    daemon = [
      FermixCore.Management.Lifecycle,
      FermixCore.Management.Doctor,
      FermixCore.Management.Jobs,
      Fermix.CLI.Daemon
    ]

    assert Role.children(daemon, :candidate) ==
             [FermixCore.Management.Lifecycle, Fermix.CLI.Daemon]
  end

  test "the channels tree of a candidate is its own supervisor, which no other role starts" do
    readiness = %{status: :ready, missing: []}
    plan = FermixChannels.Application.boot_plan(readiness, "epoch-1", :candidate)

    assert modules(plan.children) == [FermixChannels.Home.CandidateSupervisor]
    assert plan.held == []

    for role <- [:primary, :device] do
      refute FermixChannels.Home.CandidateSupervisor in modules(
               FermixChannels.Application.boot_plan(readiness, "epoch-1", role).children
             )
    end

    refute FermixChannels.Home.Enrollment in modules(
             FermixChannels.Application.boot_plan(readiness, "epoch-1", :device).children
           )

    for module <- [FermixChannels.Gateway.Idempotency, FermixChannels.Channels.Slack.SocketMode] do
      refute module in modules(plan.children)
    end
  end

  test "the web tree of a candidate serves no endpoint" do
    children = [
      FermixWebWeb.Telemetry,
      {DNSCluster, query: :ignore},
      {Phoenix.PubSub, name: FermixWeb.PubSub},
      FermixWebWeb.Endpoint
    ]

    refute FermixWebWeb.Endpoint in modules(Role.children(children, :candidate))
    assert FermixWebWeb.Endpoint in modules(Role.children(children, :primary))
  end

  defp modules(children), do: Enum.map(children, &module/1)
  defp module(%{start: {module, _function, _args}}), do: module
  defp module({module, _arg}), do: module
  defp module(module) when is_atom(module), do: module
end
