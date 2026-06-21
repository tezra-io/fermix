defmodule FermixCore.ComputerUse.ApprovalTest do
  use ExUnit.Case, async: false

  alias FermixCore.ComputerUse.Approval
  alias FermixCore.ComputerUse.Config

  setup do
    start_supervised!(Approval)
    :ok
  end

  defp config(timeout_ms \\ 1000), do: Config.normalize(approval_timeout_ms: timeout_ms)

  test "no owner surface fails closed immediately (consequential action cannot proceed)" do
    assert {:error, :no_owner} = Approval.request("left_click", nil, config())
  end

  test "an approved request returns :ok" do
    test_pid = self()
    surface = fn token, action -> send(test_pid, {:prompted, token, action}) end

    task = Task.async(fn -> Approval.request("left_click", surface, config()) end)

    assert_receive {:prompted, token, "left_click"}
    assert Approval.pending() == [token]
    assert :ok = Approval.resolve(token, :approve)
    assert Task.await(task) == :ok
    assert Approval.pending() == []
  end

  test "a denied request returns {:error, :denied}" do
    test_pid = self()
    surface = fn token, _action -> send(test_pid, {:prompted, token}) end

    task = Task.async(fn -> Approval.request("type", surface, config()) end)

    assert_receive {:prompted, token}
    assert :ok = Approval.resolve(token, :deny)
    assert Task.await(task) == {:error, :denied}
  end

  test "a request that is never resolved fails closed on timeout" do
    surface = fn _token, _action -> :ok end
    assert {:error, :timeout} = Approval.request("left_click", surface, config(50))
    assert Approval.pending() == []
  end

  test "resolving an unknown/expired token is a no-op error" do
    assert {:error, :unknown_token} = Approval.resolve("nope", :approve)
  end
end
