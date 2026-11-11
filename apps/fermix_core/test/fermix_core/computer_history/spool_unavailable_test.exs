defmodule FermixCore.ComputerHistory.SpoolUnavailableTest do
  # M97 §8.1, AGENTS.md "Cascade roots": a machine store that cannot be opened
  # (a full disk, a damaged file, a folder that cannot be made) never stops the
  # engine. The store says why to every caller, the recorder stays off, and
  # whatever starts after it runs.
  use ExUnit.Case, async: true

  alias FermixCore.ComputerHistory.Controller
  alias FermixCore.ComputerHistory.Spool
  alias FermixTestSupport.SafeRm

  setup do
    dir = SafeRm.make_tmp_dir!("ch-spool-unavailable")
    on_exit(fn -> SafeRm.rm_rf(dir) end)

    # A file where the store's folder would be: the folder cannot be made.
    blocker = Path.join(dir, "home")
    File.write!(blocker, "")
    %{dir: dir, blocked: Spool.path(blocker)}
  end

  test "under a rest_for_one parent, the children after it start and stay up", ctx do
    children = [
      %{id: :spool, start: {Spool, :start_link, [[name: nil, path: ctx.blocked]]}},
      %{id: :after, start: {Agent, :start_link, [fn -> :after end]}}
    ]

    sup =
      start_supervised!(%{
        id: :parent,
        start: {Supervisor, :start_link, [children, [strategy: :rest_for_one]]},
        type: :supervisor
      })

    assert [{:after, after_pid, _, _}, {:spool, spool, _, _}] = Supervisor.which_children(sup)
    path = ctx.blocked
    assert {:unavailable, ^path, :enotdir} = Spool.status(server: spool)
    assert {:error, {:store_unavailable, _reason}} = Spool.count_events(server: spool)
    assert {:error, {:store_unavailable, _reason}} = Spool.link(server: spool)

    # Asked again and again, it stays up and so does what follows it.
    for _ <- 1..3, do: {:error, _} = Spool.state(server: spool)
    assert [{:after, ^after_pid, _, _}, {:spool, ^spool, _, _}] = Supervisor.which_children(sup)
  end

  test "the recorder stays off while the store is unavailable; the rest runs", ctx do
    spool = start_supervised!({Spool, name: nil, path: ctx.blocked})
    sup = :"ch_unavailable_dyn_#{System.unique_integer([:positive])}"
    start_supervised!({DynamicSupervisor, name: sup, strategy: :one_for_one})
    recorder = :"ch_unavailable_recorder_#{System.unique_integer([:positive])}"
    always = :"ch_unavailable_always_#{System.unique_integer([:positive])}"

    children = [
      %{name: recorder, spec: agent(recorder), want: :recording},
      %{name: always, spec: agent(always), want: :always}
    ]

    controller =
      start_supervised!(
        {Controller,
         [
           name: :"ch_unavailable_ctrl_#{System.unique_integer([:positive])}",
           dynamic_supervisor: sup,
           operative_fun: fn -> true end,
           installed_fun: fn -> true end,
           children: children,
           spool: spool
         ]}
      )

    assert :ok = Controller.reconcile(controller)
    assert Process.whereis(always)
    refute Process.whereis(recorder)
  end

  defp agent(name), do: %{id: name, start: {Agent, :start_link, [fn -> :ok end, [name: name]]}}
end
