defmodule FermixCore.ComputerHistory.DeliveryTest do
  # M97 §8.5: how the owner's narrowing from chat reaches each computer. A
  # computer that keeps no store applied nothing and is not recorded as having
  # applied it; `/history off` naming a computer stands on the home at once and
  # is done once the computer says it switched off, now or once it is back.
  use ExUnit.Case, async: true

  alias FermixCore.ComputerHistory.Delivery
  alias FermixCore.ComputerHistory.MachineService
  alias FermixCore.Computers.Computer
  alias FermixCore.Computers.Outcome
  alias FermixCore.Memory.Repo
  alias FermixTestSupport.SafeRm

  setup do
    dir = SafeRm.make_tmp_dir!("ch-delivery")
    on_exit(fn -> SafeRm.rm_rf(dir) end)
    repo = :"ch_delivery_repo_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Repo, name: repo, enabled: true, database_path: Path.join(dir, "memory.db")}
    )

    %{repo: repo}
  end

  defp computer(connected?) do
    %Computer{device_id: "loft-91c2", name: "loft Linux", connected: connected?}
  end

  # A computer that answers each op as the test says, and tells the test.
  defp call(answers) do
    test = self()

    fn computer, MachineService, op, args, _context, _opts ->
      send(test, {:asked, computer.device_id, op, args})
      Map.fetch!(answers, op)
    end
  end

  defp ok(result), do: {:ok, %Outcome{status: :ok, result: result}}

  defp row(repo) do
    {:ok, rows} = Repo.computer_history_home(:computer_rows, [], server: repo)
    Enum.find(rows, &(&1.computer_id == "loft-91c2"))
  end

  test "a computer that keeps no store applied nothing, and is not recorded as having", ctx do
    {:ok, id} = Repo.computer_history_home(:pause_window, [1, 2, 1, :all], server: ctx.repo)

    result =
      Delivery.deliver(
        repo: ctx.repo,
        computers: [computer(true)],
        call: call(%{"apply" => ok(%{"applied" => 0})})
      )

    assert result.no_store == ["loft Linux"]
    assert result.applied == []
    assert_received {:asked, "loft-91c2", "apply", %{"intervals" => [%{"id" => ^id}]}}
    assert %{delivered_mark: 0} = row(ctx.repo)
  end

  test "off for a connected computer is done once it says it switched off", ctx do
    assert :done =
             Delivery.switch_off(computer(true),
               repo: ctx.repo,
               now_ms: 1_000,
               call: call(%{"off" => ok(%{"off" => true})})
             )

    assert_received {:asked, "loft-91c2", "off", %{}}
    assert %{off_requested_at: nil} = row(ctx.repo)
  end

  test "off for a computer that is away stands on the home, and is told once it is back", ctx do
    assert :away = Delivery.switch_off(computer(false), repo: ctx.repo, now_ms: 1_000)
    refute_received {:asked, _id, _op, _args}
    assert %{off_requested_at: 1_000} = row(ctx.repo)

    result =
      Delivery.deliver(
        repo: ctx.repo,
        computers: [computer(true)],
        call: call(%{"off" => ok(%{"off" => true})})
      )

    assert result.applied == ["loft Linux"]
    assert_received {:asked, "loft-91c2", "off", %{}}
    assert %{off_requested_at: nil} = row(ctx.repo)
  end

  test "off a computer could not be told stays owed, and the reason is answered", ctx do
    refused = {:error, Outcome.refused(:off, "Everything is switched off on this computer.")}

    assert {:failed, {:refused, :off}} =
             Delivery.switch_off(computer(true),
               repo: ctx.repo,
               now_ms: 1_000,
               call: call(%{"off" => refused})
             )

    assert %{off_requested_at: 1_000} = row(ctx.repo)
  end
end
