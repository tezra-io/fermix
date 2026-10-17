defmodule FermixChannels.X.SupervisorTest do
  # The channel starts only for an installation that can serve it, and
  # otherwise refuses with one line naming why (MILESTONE_63 §2: an enabled
  # channel with no pairing is a named refusal, never a silent no-op). The
  # memory store is found through app env, so this module is synchronous.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixChannels.Test.XConnectHelper, as: Fixtures
  alias FermixChannels.X.Pairing
  alias FermixChannels.X.Supervisor, as: XSupervisor
  alias FermixCore.Memory.Repo
  alias FermixCore.Net.Egress
  alias FermixTestSupport.SafeRm

  setup do
    home = SafeRm.make_tmp_dir!("x-supervisor")
    previous_memory = Application.get_env(:fermix_core, :memory)

    on_exit(fn ->
      if previous_memory,
        do: Application.put_env(:fermix_core, :memory, previous_memory),
        else: Application.delete_env(:fermix_core, :memory)

      SafeRm.rm_rf(home)
    end)

    %{home: home, pairing: [root: home], previous_memory: previous_memory || []}
  end

  defp pair!(pairing) do
    {:ok, public_key} = Pairing.ensure_key(pairing)
    {connect_public, _seed} = Fixtures.connect_key()

    :ok =
      Pairing.save(
        Fixtures.record(connect_public, %{key_id: Pairing.key_id(public_key)}),
        pairing
      )
  end

  defp run_memory!(ctx) do
    repo = :"x_supervisor_repo_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Repo, name: repo, enabled: true, database_path: Path.join(ctx.home, "memory.db")}
    )

    Application.put_env(:fermix_core, :memory, Keyword.put(ctx.previous_memory, :repo, repo))
    repo
  end

  defp start(opts) do
    name = :"x_supervisor_#{System.unique_integer([:positive])}"
    XSupervisor.start_link(Keyword.merge([name: name, egress: %Egress{}], opts))
  end

  test "an unpaired installation starts nothing and says so", ctx do
    log = capture_log(fn -> assert :ignore = start(pairing: ctx.pairing) end)
    assert log =~ "x is enabled but this Fermix is not paired with Connect"
  end

  test "a record whose instance key is gone or different is refused", ctx do
    pair!(ctx.pairing)
    SafeRm.rm!(Pairing.key_path(ctx.pairing))
    log = capture_log(fn -> assert :ignore = start(pairing: ctx.pairing) end)
    assert log =~ "x is enabled but its Connect instance key is unusable"

    {:ok, _other_key} = Pairing.ensure_key(ctx.pairing)
    log = capture_log(fn -> assert :ignore = start(pairing: ctx.pairing) end)
    assert log =~ "does_not_match_pairing"
  end

  test "a broken record is refused with its reason", ctx do
    pair!(ctx.pairing)
    File.write!(Pairing.record_path(ctx.pairing), "{}")
    log = capture_log(fn -> assert :ignore = start(pairing: ctx.pairing) end)
    assert log =~ "x is enabled but its Connect pairing record is unusable"
  end

  test "with no memory store running nothing starts", ctx do
    pair!(ctx.pairing)

    Application.put_env(
      :fermix_core,
      :memory,
      Keyword.put(ctx.previous_memory, :repo, :x_no_repo)
    )

    log = capture_log(fn -> assert :ignore = start(pairing: ctx.pairing) end)
    assert log =~ "the memory store that holds its assignments is not running"
  end

  test "a proxied route is refused, naming the transport refusal", ctx do
    pair!(ctx.pairing)
    run_memory!(ctx)
    proxied = Egress.new(proxy: "http://proxy.fermix.example:3128")

    log = capture_log(fn -> assert :ignore = start(pairing: ctx.pairing, egress: proxied) end)
    assert log =~ ":proxy_unsupported_transport"
  end

  test "a paired installation runs its pump and its client", ctx do
    pair!(ctx.pairing)
    repo = run_memory!(ctx)

    assert {:ok, supervisor} =
             start(
               pairing: ctx.pairing,
               pump: [name: :"x_pump_#{System.unique_integer([:positive])}", repo: repo],
               client: [name: :"x_client_#{System.unique_integer([:positive])}", connect?: false]
             )

    ids = supervisor |> Supervisor.which_children() |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    assert ids == [FermixChannels.X.Client, FermixChannels.X.Pump]
    Supervisor.stop(supervisor)
  end

  # The admission check's world is injectable: the tree-less `fermix doctor`
  # judges the memory store by its setting, since no store runs there.
  test "admission reads the memory store through its seam", ctx do
    pair!(ctx.pairing)
    opts = [pairing: ctx.pairing, egress: %Egress{}]

    assert {:ok, %Pairing{}} = XSupervisor.admit(opts ++ [memory: fn -> :ok end])

    assert {:error, :memory_unavailable} =
             XSupervisor.admit(opts ++ [memory: fn -> {:error, :memory_unavailable} end])
  end

  test "paired/1 answers the record with the key it names", ctx do
    assert {:error, :unpaired} = XSupervisor.paired(ctx.pairing)

    pair!(ctx.pairing)
    {:ok, public_key} = Pairing.public_key(ctx.pairing)
    assert {:ok, %Pairing{}, ^public_key} = XSupervisor.paired(ctx.pairing)

    SafeRm.rm!(Pairing.key_path(ctx.pairing))
    {:ok, _other_key} = Pairing.ensure_key(ctx.pairing)

    assert {:error, {:instance_key, :does_not_match_pairing}} =
             XSupervisor.paired(ctx.pairing)
  end

  describe "the registered subtree" do
    defp parent!(child_start) do
      parent =
        start_supervised!(%{
          id: :x_test_parent,
          start: {Supervisor, :start_link, [[], [strategy: :one_for_one]]}
        })

      {:ok, _pid} =
        Supervisor.start_child(parent, %{id: XSupervisor, start: child_start, restart: :permanent})

      parent
    end

    defp child_pid(parent) do
      [{XSupervisor, pid, _type, _modules}] = Supervisor.which_children(parent)
      pid
    end

    test "pairing starts it again only while the switch is on" do
      parent = parent!({Agent, :start_link, [fn -> :subtree end]})
      :ok = XSupervisor.stop_registered(parent: parent)
      assert child_pid(parent) == :undefined

      assert {:ok, :switched_off} =
               XSupervisor.start_registered(parent: parent, config: [enabled: false])

      assert child_pid(parent) == :undefined

      assert {:ok, :started} =
               XSupervisor.start_registered(parent: parent, config: [enabled: true])

      assert is_pid(child_pid(parent))
    end

    test "a subtree whose admission refuses again is not started, and says why", ctx do
      name = :"x_supervisor_#{System.unique_integer([:positive])}"
      args = [[name: name, pairing: ctx.pairing, egress: %Egress{}]]

      log =
        capture_log(fn ->
          parent = parent!({XSupervisor, :start_link, args})
          assert child_pid(parent) == :undefined

          assert {:ok, :not_started} =
                   XSupervisor.start_registered(parent: parent, config: [enabled: true])
        end)

      assert log =~ "not paired with Connect"
    end

    test "a channel off at boot registered nothing to start or stop" do
      parent =
        start_supervised!(%{
          id: :x_empty_parent,
          start: {Supervisor, :start_link, [[], [strategy: :one_for_one]]}
        })

      assert {:ok, :not_registered} =
               XSupervisor.start_registered(parent: parent, config: [enabled: true])

      assert :ok = XSupervisor.stop_registered(parent: parent)
    end
  end
end
